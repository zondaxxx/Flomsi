//! mailcore: the UI-independent heart of the mail client.
//!
//! ```text
//! Core::open(dir) ──► Store (SQLite)  ◄── SyncEngine ◄── Provider (IMAP …)
//!        │                                   │
//!        └── threads(query) / apply(action)  └── events() stream
//! ```

pub mod auth;
pub mod compose;
pub mod diagnose;
pub mod error;
pub mod files;
pub mod logging;
pub mod model;
pub mod provider;
pub mod sanitize;
pub mod search;
pub mod secrets;
pub mod smtp;
pub mod storage;
pub mod sync;
pub mod threading;

#[cfg(test)]
mod fake_smtp;
#[cfg(test)]
mod testdata;

pub use error::{Error, Result};
pub use model::*;
pub use search::Query;
pub use storage::Store;
pub use sync::{SyncEvent, SyncOptions, SyncReport};

use compose::{quote, AttachmentSource, Draft, DraftAttachment, OutgoingFile};
pub use provider::imap::Transport;
use provider::imap::{Credential, ImapProvider};
use provider::parse;
use provider::{IdleOutcome, Provider};
use sanitize::{inline_cid_images, sanitize, SanitizeOptions, Sanitized};
use smtp::{SmtpConfig, SmtpCredential};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use sync::{Actions, SyncEngine};
use tokio::sync::broadcast;

pub const SECRET_PASSWORD: &str = "password";
pub const SECRET_REFRESH_TOKEN: &str = "refresh_token";
pub const SECRET_ACCESS_TOKEN: &str = "access_token";

/// Raw messages fetched on demand are cached up to this size; bigger ones are fetched again.
const RAW_CACHE_LIMIT: usize = 32 * 1024 * 1024;

pub struct Core {
    store: Arc<Store>,
    engine: SyncEngine,
    data_dir: PathBuf,
}

impl Core {
    pub fn open(data_dir: &Path) -> Result<Core> {
        let store = Arc::new(Store::open(&data_dir.join("mail.sqlite"))?);
        let engine = SyncEngine::new(store.clone());
        remove_legacy_file_cache(data_dir);
        Ok(Core {
            store,
            engine,
            data_dir: data_dir.to_path_buf(),
        })
    }

    pub fn data_dir(&self) -> &Path {
        &self.data_dir
    }

    pub fn store(&self) -> &Store {
        &self.store
    }

    pub fn subscribe(&self) -> broadcast::Receiver<SyncEvent> {
        self.engine.subscribe()
    }

    /// Register an account and put its secret into the OS keychain.
    pub fn add_account(&self, account: &NewAccount, secret: &str) -> Result<Account> {
        let kind = match account.auth {
            AuthKind::Password => SECRET_PASSWORD,
            AuthKind::XOAuth2 => SECRET_REFRESH_TOKEN,
        };
        // A second add of the same address must not replace the stored password of the
        // account that already works.
        let email = account.email.trim();
        if self
            .store
            .accounts()?
            .iter()
            .any(|a| a.email.eq_ignore_ascii_case(email))
        {
            return Err(Error::Other(format!("{email} is already added")));
        }
        secrets::set(&account.email, kind, secret)?;
        self.store.add_account(account)
    }

    /// Replace the stored password of an existing account, keeping its mail.
    pub fn set_password(&self, account_id: i64, password: &str) -> Result<()> {
        let a = self.store.account(account_id)?;
        if a.auth != AuthKind::Password {
            return Err(Error::Other(format!(
                "{} does not sign in with a password",
                a.email
            )));
        }
        secrets::set(&a.email, SECRET_PASSWORD, password)
    }

    pub fn remove_account(&self, id: i64) -> Result<()> {
        let a = self.store.account(id)?;
        // Files first: if a viewer still holds one (Windows), fail before anything
        // irreversible so the removal can simply be retried.
        self.forget_account_files(&a)?;
        for k in [SECRET_PASSWORD, SECRET_REFRESH_TOKEN, SECRET_ACCESS_TOKEN] {
            secrets::delete(&a.email, k)?;
        }
        self.store.delete_account(id)
    }

    fn account_files_dir(&self, account: &Account) -> PathBuf {
        self.data_dir
            .join("files")
            .join(files::safe_file_name(&account.email))
    }

    /// Delete the attachment files cached for an account.
    pub fn forget_account_files(&self, account: &Account) -> Result<()> {
        match std::fs::remove_dir_all(self.account_files_dir(account)) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.into()),
            _ => Ok(()),
        }
    }

    /// Where a part's cached file lives. Keyed by what identifies it on the server (folder,
    /// UIDVALIDITY, UID), not by the local message id, which SQLite hands out again after
    /// deletions.
    fn attachment_cache_dir(&self, message_id: i64, idx: u32) -> Result<PathBuf> {
        use sha2::{Digest, Sha256};
        let m = self.store.message(message_id)?;
        let folder = self.store.folder(m.folder_id)?;
        let account = self.store.account(m.account_id)?;
        let short = |s: &str| -> String {
            Sha256::digest(s.as_bytes())
                .iter()
                .take(4)
                .map(|b| format!("{b:02x}"))
                .collect()
        };
        // UIDVALIDITY is unknown while a first sync runs; the message's own identity keeps a
        // reused UID in a later epoch from picking up this file.
        let identity = m
            .message_id
            .clone()
            .unwrap_or_else(|| format!("{}|{}|{}", m.date.timestamp(), m.size, m.subject));
        Ok(self.account_files_dir(&account).join(format!(
            "{}-{}-{}-{}-{idx}",
            short(&folder.remote_name),
            folder.uidvalidity.unwrap_or(0),
            m.uid,
            short(&identity)
        )))
    }

    async fn connect(&self, account: &Account) -> Result<ImapProvider> {
        let cred = match account.auth {
            AuthKind::Password => {
                Credential::Password(secrets::get(&account.email, SECRET_PASSWORD)?.ok_or_else(
                    || Error::Secrets(format!("no password stored for {}", account.email)),
                )?)
            }
            AuthKind::XOAuth2 => Credential::AccessToken(
                secrets::get(&account.email, SECRET_ACCESS_TOKEN)?.ok_or_else(|| {
                    Error::Secrets(format!("no access token for {}", account.email))
                })?,
            ),
        };
        ImapProvider::connect_with(
            &account.imap_host,
            account.imap_port,
            Transport {
                security: account.imap_security,
                local_bridge: account.local_bridge,
            },
            &[],
            &account.email,
            cred,
        )
        .await
    }

    pub async fn sync_account(&self, account_id: i64, opts: &SyncOptions) -> Result<SyncReport> {
        let account = self.store.account(account_id)?;
        let mut provider = self.connect(&account).await?;
        let report = self
            .engine
            .sync_account(&account, &mut provider, opts)
            .await;
        provider.logout().await?;
        report
    }

    pub async fn sync_all(&self, opts: &SyncOptions) -> Result<Vec<(Account, Result<SyncReport>)>> {
        let mut out = Vec::new();
        for a in self.store.accounts()? {
            let r = self.sync_account(a.id, opts).await;
            out.push((a, r));
        }
        Ok(out)
    }

    /// Sit in IMAP IDLE on the inbox; returns when the server reports a change or the timeout passes.
    pub async fn wait_for_change(&self, account_id: i64, timeout: Duration) -> Result<IdleOutcome> {
        let account = self.store.account(account_id)?;
        let mut provider = self.connect(&account).await?;
        let known = self.store.folder_by_role(account_id, FolderRole::Inbox)?;
        let inbox = known
            .as_ref()
            .map(|f| f.remote_name.clone())
            .unwrap_or_else(|| "INBOX".to_string());
        let state = provider.select(&inbox).await?;
        // Mail that arrived between two waits never raises IDLE: compare with what the
        // last sync saw and report it at once.
        let outcome = if missed_mail(known.as_ref(), &state) {
            IdleOutcome::Changed
        } else {
            provider.idle(timeout).await?
        };
        provider.logout().await?;
        Ok(outcome)
    }

    /// Connect and authenticate once without storing anything: the "check credentials" step.
    /// Sign in to IMAP once and leave, without storing anything.
    pub async fn check_login(
        host: &str,
        port: u16,
        transport: Transport,
        email: &str,
        password: &str,
    ) -> Result<()> {
        let mut p = ImapProvider::connect_with(
            host,
            port,
            transport,
            &[],
            email,
            Credential::Password(password.to_string()),
        )
        .await?;
        p.logout().await
    }

    /// Sign in to SMTP once without sending anything.
    pub async fn check_smtp(
        host: &str,
        port: u16,
        security: Security,
        local_bridge: bool,
        email: &str,
        password: &str,
    ) -> Result<()> {
        let mut cfg = SmtpConfig::new(
            host.to_string(),
            port,
            email.to_string(),
            SmtpCredential::Password(password.to_string()),
        );
        cfg.implicit_tls = security == Security::Tls;
        cfg.local_bridge = local_bridge;
        smtp::check(&cfg, &[]).await
    }

    pub fn threads(&self, query: &str, limit: u32) -> Result<Vec<Thread>> {
        self.store.threads(&Query::parse(query), limit)
    }

    /// An empty draft from `account_id`, or from the first account.
    pub fn new_draft(&self, account_id: Option<i64>) -> Result<(Account, Draft)> {
        let account = match account_id {
            Some(id) => self.store.account(id)?,
            None => self
                .store
                .accounts()?
                .into_iter()
                .next()
                .ok_or_else(|| Error::NotFound("no accounts".into()))?,
        };
        let mut draft = Draft::new(self.me(&account));
        draft.text = draft_body(&account, "");
        Ok((account, draft))
    }

    fn me(&self, account: &Account) -> Address {
        Address {
            name: if account.display_name.is_empty() {
                None
            } else {
                Some(account.display_name.clone())
            },
            addr: account.email.clone(),
        }
    }

    /// Reply (or reply-all) to the latest message of a thread, with the original quoted.
    /// When the latest message is ours, the reply goes to its recipients instead of to ourselves.
    pub fn reply_draft(&self, thread_id: i64, reply_all: bool) -> Result<(Account, Draft)> {
        let messages = self.store.thread_messages(thread_id)?;
        let last = messages
            .last()
            .ok_or_else(|| Error::NotFound(format!("thread {thread_id}")))?;
        let account = self.store.account(last.account_id)?;
        let me = self.me(&account);
        let refs: Vec<String> = messages
            .iter()
            .filter_map(|m| m.message_id.clone())
            .collect();
        let earlier = &refs[..refs.len().saturating_sub(1)];
        let mut draft = Draft::reply(last, last.message_id.as_deref(), earlier, &me, reply_all);
        if last.from.addr.eq_ignore_ascii_case(&me.addr) {
            draft.to = last.to.clone();
            draft.cc = if reply_all {
                last.cc.clone()
            } else {
                Vec::new()
            };
        }
        let (text, _) = self.store.body(last.id)?;
        let quoted = quote(
            text.as_deref().unwrap_or(&last.snippet),
            &last.from,
            last.date,
        );
        draft.text = draft_body(&account, &quoted);
        Ok((account, draft))
    }

    pub fn forward_draft(&self, thread_id: i64) -> Result<(Account, Draft)> {
        let messages = self.store.thread_messages(thread_id)?;
        let last = messages
            .last()
            .ok_or_else(|| Error::NotFound(format!("thread {thread_id}")))?;
        let account = self.store.account(last.account_id)?;
        let me = self.me(&account);
        let mut draft = Draft::forward(last, &me);
        draft.attachments = self
            .store
            .attachments(last.id)?
            .into_iter()
            .filter(|a| !a.inline)
            .map(|a| DraftAttachment {
                name: a.name,
                mime: a.mime,
                size: a.size,
                source: AttachmentSource::Message {
                    message_id: last.id,
                    idx: a.idx,
                },
            })
            .collect();
        let (text, _) = self.store.body(last.id)?;
        let forwarded = format!(
            "---------- Forwarded message ----------\nFrom: {} <{}>\nDate: {}\nSubject: {}\n\n{}",
            last.from.display(),
            last.from.addr,
            last.date.format("%a, %d %b %Y at %H:%M"),
            last.subject,
            text.as_deref().unwrap_or(&last.snippet)
        );
        draft.text = draft_body(&account, &forwarded);
        Ok((account, draft))
    }

    /// Send over SMTP, keep a copy in the Sent folder (unless the server does it itself),
    /// and flag the replied-to message as answered.
    /// Send over SMTP, then file a copy in Sent. An error means the mail did not go;
    /// trouble after that comes back as [SendReport::warning].
    pub async fn send(&self, account_id: i64, draft: &Draft) -> Result<SendReport> {
        let account = self.store.account(account_id)?;
        let secret = match account.auth {
            AuthKind::Password => SmtpCredential::Password(
                secrets::get(&account.email, SECRET_PASSWORD)?.ok_or_else(|| {
                    Error::Secrets(format!("no password stored for {}", account.email))
                })?,
            ),
            AuthKind::XOAuth2 => SmtpCredential::AccessToken(
                secrets::get(&account.email, SECRET_ACCESS_TOKEN)?.ok_or_else(|| {
                    Error::Secrets(format!("no access token for {}", account.email))
                })?,
            ),
        };
        let (host, port) = if account.smtp_host.is_empty() {
            smtp::guess_smtp(&account.imap_host).ok_or_else(|| {
                Error::Other(format!("no SMTP server known for {}", account.imap_host))
            })?
        } else {
            (account.smtp_host.clone(), account.smtp_port)
        };
        let mut files = Vec::with_capacity(draft.attachments.len());
        for a in &draft.attachments {
            let bytes = match &a.source {
                AttachmentSource::File { path } => tokio::fs::read(path)
                    .await
                    .map_err(|e| Error::Other(format!("{}: {e}", a.name)))?,
                AttachmentSource::Message { message_id, idx } => {
                    self.attachment(*message_id, *idx).await?.1
                }
            };
            files.push(OutgoingFile {
                name: a.name.clone(),
                mime: a.mime.clone(),
                bytes,
            });
        }
        let message = draft.to_mime(&files)?;
        let message_id = message.headers().get_raw("Message-ID").map(|v| {
            v.trim()
                .trim_start_matches('<')
                .trim_end_matches('>')
                .to_string()
        });
        let raw = message.formatted();
        let smtp_host = host.clone();
        let mut cfg = SmtpConfig::new(host, port, account.email.clone(), secret);
        if let Some(sec) = account.smtp_security {
            cfg.implicit_tls = sec == Security::Tls;
        }
        cfg.local_bridge = account.local_bridge;
        smtp::send(&cfg, message).await?;

        // The mail is gone. Nothing below may turn that into "not sent": the person would
        // send it again. Later steps only add a warning.
        let mut report = SendReport::default();
        if let Err(e) = self
            .file_in_sent(&account, &smtp_host, &raw, message_id.as_deref())
            .await
        {
            report.warning = Some(format!("Sent, but the copy for Sent was not saved: {e}"));
        }
        if let Some(irt) = &draft.in_reply_to {
            if let Err(e) = self.actions().mark_answered(account_id, irt) {
                log::warn!("marking {irt} answered: {e}");
            }
        }
        Ok(report)
    }

    /// Put the sent message into Sent, once. Gmail and Microsoft file sent mail
    /// themselves; elsewhere a copy the server already filed (some do) is found by
    /// Message-ID first, so there are never two.
    async fn file_in_sent(
        &self,
        account: &Account,
        smtp_host: &str,
        raw: &[u8],
        message_id: Option<&str>,
    ) -> Result<()> {
        if files_sent_mail_itself(smtp_host) {
            return Ok(());
        }
        let Some(sent) = self.store.folder_by_role(account.id, FolderRole::Sent)? else {
            return Ok(());
        };
        let mut p = self.connect(account).await?;
        let r = append_once(&mut p, &sent.remote_name, raw, message_id).await;
        let _ = p.logout().await;
        r
    }

    pub fn actions(&self) -> Actions<'_> {
        Actions { store: &self.store }
    }

    // ---------------- raw messages, attachments, inline images ----------------

    /// The full RFC 822 bytes of a message: from the local cache, else from the server
    /// (then cached when not huge).
    pub async fn raw_message(&self, message_id: i64) -> Result<Vec<u8>> {
        if let Some(raw) = self.store.raw(message_id)? {
            return Ok(raw);
        }
        let m = self.store.message(message_id)?;
        let folder = self.store.folder(m.folder_id)?;
        let account = self.store.account(m.account_id)?;
        let mut p = self.connect(&account).await?;
        let fetched = async {
            p.select(&folder.remote_name).await?;
            p.fetch(&[m.uid]).await
        }
        .await;
        let _ = p.logout().await;
        let gone = || {
            Error::NotFound(format!(
                "message {message_id} is no longer in {}; sync and try again",
                folder.remote_name
            ))
        };
        let raw = fetched?
            .into_iter()
            .find(|f| f.uid == m.uid)
            .map(|f| f.raw)
            .filter(|r| !r.is_empty())
            .ok_or_else(gone)?;
        // A UIDVALIDITY change we have not synced yet would hand us someone else's message.
        if m.message_id.is_some() && parse::raw_message_id(&raw) != m.message_id {
            return Err(gone());
        }
        if raw.len() <= RAW_CACHE_LIMIT {
            self.store.put_raw(message_id, &raw)?;
        }
        Ok(raw)
    }

    /// One attachment's metadata and bytes (`idx` as listed by `Store::attachments`).
    pub async fn attachment(&self, message_id: i64, idx: u32) -> Result<(AttachmentMeta, Vec<u8>)> {
        let raw = self.raw_message(message_id).await?;
        parse::extract_attachment(&raw, idx)
            .ok_or_else(|| Error::NotFound(format!("attachment {idx} of message {message_id}")))
    }

    /// Write an attachment under the profile's file cache and return its path, reusing an
    /// earlier copy. This is the file handed to "open with" and share sheets.
    pub async fn cached_attachment_file(&self, message_id: i64, idx: u32) -> Result<PathBuf> {
        let dir = self.attachment_cache_dir(message_id, idx)?;
        let finished = std::fs::read_dir(&dir).ok().and_then(|entries| {
            entries
                .filter_map(|e| e.ok())
                .find(|e| !e.file_name().to_string_lossy().starts_with(".part-"))
        });
        if let Some(existing) = finished {
            return Ok(existing.path());
        }
        let (meta, bytes) = self.attachment(message_id, idx).await?;
        tokio::fs::create_dir_all(&dir).await?;
        let name = files::safe_file_name(&meta.name);
        let partial = dir.join(format!(".part-{name}"));
        let path = dir.join(&name);
        tokio::fs::write(&partial, &bytes).await?;
        tokio::fs::rename(&partial, &path).await?;
        Ok(path)
    }

    /// Save an attachment into `dir` under a free name (`report (1).pdf` when taken).
    pub async fn save_attachment(&self, message_id: i64, idx: u32, dir: &Path) -> Result<PathBuf> {
        let (meta, bytes) = self.attachment(message_id, idx).await?;
        tokio::fs::create_dir_all(dir).await?;
        let path = files::unique_path(dir, &files::safe_file_name(&meta.name));
        tokio::fs::write(&path, &bytes).await?;
        Ok(path)
    }

    /// Sanitized HTML body with `cid:` images resolved from the local raw copy. Remote images
    /// stay blocked unless `load_remote_images`; unresolved inline images count as blocked.
    pub fn message_html_cached(
        &self,
        message_id: i64,
        load_remote_images: bool,
    ) -> Result<Option<Sanitized>> {
        Ok(self
            .html_with_inline(message_id, load_remote_images)?
            .map(|h| h.html))
    }

    /// Like `message_html_cached`, but with `load_images` it also fetches the raw message
    /// from the server when inline images are missing from the cache.
    pub async fn message_html(
        &self,
        message_id: i64,
        load_images: bool,
    ) -> Result<Option<Sanitized>> {
        let Some(first) = self.html_with_inline(message_id, load_images)? else {
            return Ok(None);
        };
        if !load_images || first.unresolved == 0 || first.had_raw {
            return Ok(Some(first.html));
        }
        self.raw_message(message_id).await?;
        self.message_html_cached(message_id, load_images)
    }

    fn html_with_inline(
        &self,
        message_id: i64,
        load_remote_images: bool,
    ) -> Result<Option<InlineHtml>> {
        let (_, html) = self.store.body(message_id)?;
        let Some(html) = html else { return Ok(None) };
        let clean = sanitize(&html, SanitizeOptions { load_remote_images });
        if sanitize::cid_refs(&clean.html).is_empty() {
            return Ok(Some(InlineHtml {
                html: clean,
                unresolved: 0,
                had_raw: false,
            }));
        }
        let raw = self.store.raw(message_id)?;
        let parts = raw
            .as_deref()
            .map(parse::content_id_parts)
            .unwrap_or_default();
        let (html, unresolved) = inline_cid_images(&clean.html, |cid| {
            parts
                .iter()
                .find(|(id, _, _)| id == cid)
                .map(|(_, mime, bytes)| (mime.clone(), bytes.clone()))
        });
        Ok(Some(InlineHtml {
            html: Sanitized {
                html,
                blocked_images: clean.blocked_images + unresolved,
            },
            unresolved,
            had_raw: raw.is_some(),
        }))
    }
}

/// Body of a fresh draft: room to write, the signature under a `-- ` line, then `rest`
/// (a quote or a forwarded message).
fn draft_body(account: &Account, rest: &str) -> String {
    let sig = account.signature.trim_end();
    match (sig.is_empty(), rest.is_empty()) {
        (true, true) => String::new(),
        (true, false) => format!("\n\n{rest}"),
        (false, true) => format!("\n\n-- \n{sig}\n"),
        (false, false) => format!("\n\n-- \n{sig}\n\n{rest}"),
    }
}

/// Attachment files used to be cached as `files/<message id>-<part>`, keyed by an id SQLite
/// reuses; they are a cache, so they simply go. Account directories contain '@'.
fn remove_legacy_file_cache(data_dir: &Path) {
    let Ok(entries) = std::fs::read_dir(data_dir.join("files")) else {
        return;
    };
    for e in entries.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let legacy = name.split_once('-').is_some_and(|(a, b)| {
            !a.is_empty()
                && !b.is_empty()
                && a.bytes().all(|c| c.is_ascii_digit())
                && b.bytes().all(|c| c.is_ascii_digit())
        });
        if legacy {
            let _ = std::fs::remove_dir_all(e.path());
        }
    }
}

/// True when the inbox has mail the last sync did not see (or was never synced), so
/// waiting in IDLE would miss it.
fn missed_mail(known: Option<&Folder>, state: &provider::FolderState) -> bool {
    match known.and_then(|f| f.uidvalidity.zip(f.uidnext)) {
        Some((validity, next)) => state.uidvalidity != validity || state.uidnext > next,
        None => true,
    }
}

/// Google and Microsoft 365 put mail sent through their own SMTP into Sent; a copy from
/// us would be the second. Decided by the SMTP server that carried it, by whole domain
/// (an on-premises Exchange at outlook.example.com does not file anything).
fn files_sent_mail_itself(smtp_host: &str) -> bool {
    let h = smtp_host.trim().trim_end_matches('.').to_ascii_lowercase();
    [
        "gmail.com",
        "googlemail.com",
        "office365.com",
        "outlook.com",
    ]
    .iter()
    .any(|d| h == *d || h.ends_with(&format!(".{d}")))
}

/// APPEND [raw] to [folder] unless a message with [message_id] is already there.
async fn append_once(
    p: &mut ImapProvider,
    folder: &str,
    raw: &[u8],
    message_id: Option<&str>,
) -> Result<()> {
    if let Some(id) = message_id {
        p.select(folder).await?;
        if !p.find_message_id(id).await?.is_empty() {
            return Ok(());
        }
    }
    p.append(folder, raw, Flags::SEEN).await
}

/// What happened after SMTP accepted a message.
#[derive(Debug, Default, Clone)]
pub struct SendReport {
    /// Something after the send went wrong (the copy in Sent); the mail itself went out.
    pub warning: Option<String>,
}

struct InlineHtml {
    html: Sanitized,
    unresolved: usize,
    had_raw: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testdata::*;

    fn setup(tag: &str) -> (Core, PathBuf, i64) {
        let dir = std::env::temp_dir().join(format!("mailcore-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let core = Core::open(&dir).unwrap();
        let a = core
            .store()
            .add_account(&NewAccount {
                kind: ProviderKind::Imap,
                email: "z@x.dev".into(),
                display_name: "Z".into(),
                imap_host: "imap.x.dev".into(),
                imap_port: 993,
                smtp_host: String::new(),
                smtp_port: 0,
                auth: AuthKind::Password,
                imap_security: Default::default(),
                smtp_security: None,
                local_bridge: false,
            })
            .unwrap();
        let inbox = core
            .store()
            .upsert_folder(a.id, "INBOX", FolderRole::Inbox)
            .unwrap();
        let parsed = parse::parse_rfc822(INVOICE_EML, chrono::Utc::now());
        let id = core
            .store()
            .upsert_message(a.id, inbox.id, 1, Flags::default(), 100, &parsed)
            .unwrap();
        core.store().put_raw(id, INVOICE_EML).unwrap();
        (core, dir, id)
    }

    #[tokio::test]
    async fn attachments_open_and_save_from_the_cache() {
        let (core, dir, id) = setup("attach");
        let pdf = core
            .store()
            .attachments(id)
            .unwrap()
            .into_iter()
            .find(|a| !a.inline)
            .unwrap();
        let (meta, bytes) = core.attachment(id, pdf.idx).await.unwrap();
        assert_eq!(meta.name, "Счёт.pdf");
        assert_eq!(bytes, PDF_BYTES);

        let opened = core.cached_attachment_file(id, pdf.idx).await.unwrap();
        assert_eq!(std::fs::read(&opened).unwrap(), PDF_BYTES);
        // Keyed by server identity (UID 1 here), under the account's own directory.
        let key = opened
            .parent()
            .unwrap()
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        assert!(key.contains("-0-1-"), "{key}");
        assert!(key.ends_with(&format!("-{}", pdf.idx)), "{key}");
        let account = core.store().accounts().unwrap()[0].clone();
        assert!(opened.starts_with(dir.join("files").join("z@x.dev")));
        assert_eq!(
            core.cached_attachment_file(id, pdf.idx).await.unwrap(),
            opened
        );

        let out = dir.join("Downloads");
        let first = core.save_attachment(id, pdf.idx, &out).await.unwrap();
        let second = core.save_attachment(id, pdf.idx, &out).await.unwrap();
        assert_eq!(first.file_name().unwrap(), "Счёт.pdf");
        assert_eq!(second.file_name().unwrap(), "Счёт (1).pdf");

        core.forget_account_files(&account).unwrap();
        assert!(!opened.exists());
        core.forget_account_files(&account).unwrap(); // nothing left: still fine
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn legacy_cache_directories_are_removed_on_open() {
        let dir = std::env::temp_dir().join(format!("mailcore-legacy-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("files/12-0")).unwrap();
        std::fs::write(dir.join("files/12-0/Invoice.pdf"), b"%PDF").unwrap();
        std::fs::create_dir_all(dir.join("files/z@x.dev/ab12-7-3-cd34-0")).unwrap();
        let _core = Core::open(&dir).unwrap();
        assert!(!dir.join("files/12-0").exists());
        assert!(dir.join("files/z@x.dev/ab12-7-3-cd34-0").exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn inline_images_render_from_the_cache() {
        let (core, dir, id) = setup("inline");
        let html = core.message_html_cached(id, false).unwrap().unwrap();
        assert!(
            html.html.contains("src=\"data:image/png;base64,"),
            "{}",
            html.html
        );
        assert_eq!(html.blocked_images, 0);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn drafts_carry_the_signature_above_quotes() {
        let (core, dir, id) = setup("signature");
        let account = core.store().accounts().unwrap()[0].clone();
        let (_, plain) = core.new_draft(None).unwrap();
        assert_eq!(plain.text, "");

        core.store()
            .update_account_profile(account.id, "Z", "Z\nflomsi.dev\n")
            .unwrap();
        let (_, fresh) = core.new_draft(Some(account.id)).unwrap();
        assert_eq!(fresh.text, "\n\n-- \nZ\nflomsi.dev\n");
        assert_eq!(fresh.from.name.as_deref(), Some("Z"));

        let thread = core.store().message(id).unwrap().thread_id;
        let (_, reply) = core.reply_draft(thread, false).unwrap();
        assert!(
            reply.text.starts_with("\n\n-- \nZ\nflomsi.dev\n\nOn "),
            "{:?}",
            reply.text
        );
        let (_, fwd) = core.forward_draft(thread).unwrap();
        assert!(fwd
            .text
            .starts_with("\n\n-- \nZ\nflomsi.dev\n\n---------- Forwarded message"));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn forwarding_keeps_real_attachments_only() {
        let (core, dir, id) = setup("forward");
        let thread = core.store().message(id).unwrap().thread_id;
        let (_, d) = core.forward_draft(thread).unwrap();
        assert_eq!(d.attachments.len(), 1);
        assert_eq!(d.attachments[0].name, "Счёт.pdf");
        assert!(matches!(
            d.attachments[0].source,
            AttachmentSource::Message { message_id, .. } if message_id == id
        ));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_second_add_of_the_same_address_leaves_the_first_alone() {
        let (core, dir, _) = setup("dup");
        let again = NewAccount {
            kind: ProviderKind::Imap,
            email: " Z@X.dev ".into(),
            display_name: String::new(),
            imap_host: "imap.x.dev".into(),
            imap_port: 993,
            smtp_host: String::new(),
            smtp_port: 0,
            auth: AuthKind::Password,
            imap_security: Default::default(),
            smtp_security: None,
            local_bridge: false,
        };
        // Refused before the keychain is touched, so the stored password stays.
        let err = core.add_account(&again, "other").unwrap_err().to_string();
        assert!(err.contains("already added"), "{err}");
        assert_eq!(core.store().accounts().unwrap().len(), 1);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn idle_starts_only_when_nothing_was_missed() {
        let folder = |validity, next| Folder {
            id: 1,
            account_id: 1,
            remote_name: "INBOX".into(),
            role: FolderRole::Inbox,
            uidvalidity: validity,
            uidnext: next,
            highest_modseq: None,
            last_sync_at: None,
            selectable: true,
        };
        let state = |validity, next| provider::FolderState {
            uidvalidity: validity,
            uidnext: next,
            exists: 3,
            highest_modseq: None,
        };
        assert!(!missed_mail(
            Some(&folder(Some(7), Some(10))),
            &state(7, 10)
        ));
        assert!(missed_mail(Some(&folder(Some(7), Some(10))), &state(7, 11)));
        assert!(missed_mail(Some(&folder(Some(7), Some(10))), &state(8, 10)));
        assert!(missed_mail(Some(&folder(None, None)), &state(7, 10)));
        assert!(missed_mail(None, &state(7, 10)));
    }

    #[tokio::test]
    async fn a_sent_copy_is_filed_once() {
        use crate::provider::fake_imap::FakeImap;
        let fake = FakeImap::start("z@x.dev", "secret").await;
        fake.with(|s| {
            s.add_box("INBOX", None);
            s.add_box("Sent", Some("\\Sent"));
        });
        let mut p = ImapProvider::connect_trusting(
            "localhost",
            fake.port,
            "z@x.dev",
            Credential::Password("secret".into()),
            std::slice::from_ref(&fake.cert),
        )
        .await
        .unwrap();
        let from = Address {
            name: None,
            addr: "z@x.dev".into(),
        };
        let mut d = Draft::new(from.clone());
        d.to = vec![Address {
            name: None,
            addr: "anna@studio.dev".into(),
        }];
        d.subject = "Once".into();
        let message = d.to_mime(&[]).unwrap();
        let id = message
            .headers()
            .get_raw("Message-ID")
            .unwrap()
            .trim()
            .trim_matches(['<', '>'])
            .to_string();
        assert!(id.ends_with("@x.dev"), "{id}");
        let raw = message.formatted();
        append_once(&mut p, "Sent", &raw, Some(&id)).await.unwrap();
        // A retry, or a server that filed it already: still one copy.
        append_once(&mut p, "Sent", &raw, Some(&id)).await.unwrap();
        p.logout().await.unwrap();
        assert_eq!(fake.with(|s| s.msgs("Sent").len()), 1);
        // Each message gets its own id.
        let other = d.to_mime(&[]).unwrap();
        assert_ne!(
            other.headers().get_raw("Message-ID").unwrap().trim(),
            format!("<{id}>")
        );
    }

    #[test]
    fn only_the_big_two_file_sent_mail_themselves() {
        assert!(files_sent_mail_itself("smtp.gmail.com"));
        assert!(files_sent_mail_itself("smtp.office365.com"));
        assert!(files_sent_mail_itself("smtp-mail.outlook.com"));
        assert!(!files_sent_mail_itself("outlook.example.com"));
        assert!(!files_sent_mail_itself("smtp.gmail.com.evil.dev"));
        assert!(!files_sent_mail_itself("smtp.mail.me.com"));
        assert!(!files_sent_mail_itself("mail.isp.net"));
    }
}
