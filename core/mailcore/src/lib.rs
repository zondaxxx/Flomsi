//! mailcore: the UI-independent heart of the mail client.
//!
//! ```text
//! Core::open(dir) ──► Store (SQLite)  ◄── SyncEngine ◄── Provider (IMAP …)
//!        │                                   │
//!        └── threads(query) / apply(action)  └── events() stream
//! ```

pub mod auth;
pub mod compose;
pub mod error;
pub mod files;
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
        secrets::set(&account.email, kind, secret)?;
        self.store.add_account(account)
    }

    pub fn remove_account(&self, id: i64) -> Result<()> {
        let a = self.store.account(id)?;
        for k in [SECRET_PASSWORD, SECRET_REFRESH_TOKEN, SECRET_ACCESS_TOKEN] {
            secrets::delete(&a.email, k)?;
        }
        self.store.delete_account(id)
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
        ImapProvider::connect(&account.imap_host, account.imap_port, &account.email, cred).await
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
        let inbox = self
            .store
            .folder_by_role(account_id, FolderRole::Inbox)?
            .map(|f| f.remote_name)
            .unwrap_or_else(|| "INBOX".to_string());
        provider.select(&inbox).await?;
        let outcome = provider.idle(timeout).await?;
        provider.logout().await?;
        Ok(outcome)
    }

    /// Connect and authenticate once without storing anything: the "check credentials" step.
    pub async fn check_login(host: &str, port: u16, email: &str, password: &str) -> Result<()> {
        let mut p = ImapProvider::connect(
            host,
            port,
            email,
            Credential::Password(password.to_string()),
        )
        .await?;
        p.logout().await
    }

    pub fn threads(&self, query: &str, limit: u32) -> Result<Vec<Thread>> {
        self.store.threads(&Query::parse(query), limit)
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
        draft.text = format!(
            "\n\n{}",
            quote(
                text.as_deref().unwrap_or(&last.snippet),
                &last.from,
                last.date
            )
        );
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
        draft.text = format!(
            "\n\n---------- Forwarded message ----------\nFrom: {} <{}>\nDate: {}\nSubject: {}\n\n{}",
            last.from.display(),
            last.from.addr,
            last.date.format("%a, %d %b %Y at %H:%M"),
            last.subject,
            text.as_deref().unwrap_or(&last.snippet)
        );
        Ok((account, draft))
    }

    /// Send over SMTP, keep a copy in the Sent folder (unless the server does it itself),
    /// and flag the replied-to message as answered.
    pub async fn send(&self, account_id: i64, draft: &Draft) -> Result<()> {
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
        let raw = message.formatted();
        smtp::send(
            &SmtpConfig::new(host, port, account.email.clone(), secret),
            message,
        )
        .await?;

        // Gmail files sent mail on its own; everyone else gets an APPEND into Sent.
        if !account.imap_host.contains("gmail") {
            if let Some(sent) = self.store.folder_by_role(account_id, FolderRole::Sent)? {
                let mut p = self.connect(&account).await?;
                let r = p.append(&sent.remote_name, &raw, Flags::SEEN).await;
                let _ = p.logout().await;
                r?;
            }
        }

        if let Some(irt) = &draft.in_reply_to {
            self.actions().mark_answered(account_id, irt)?;
        }
        Ok(())
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
        let dir = self
            .data_dir
            .join("files")
            .join(format!("{message_id}-{idx}"));
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
        assert_eq!(
            core.cached_attachment_file(id, pdf.idx).await.unwrap(),
            opened
        );

        let out = dir.join("Downloads");
        let first = core.save_attachment(id, pdf.idx, &out).await.unwrap();
        let second = core.save_attachment(id, pdf.idx, &out).await.unwrap();
        assert_eq!(first.file_name().unwrap(), "Счёт.pdf");
        assert_eq!(second.file_name().unwrap(), "Счёт (1).pdf");
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
}
