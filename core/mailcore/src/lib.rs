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
pub mod http;
pub mod logging;
pub mod model;
pub mod probe;
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
/// The app registration an OAuth account was signed in with (JSON [auth::OAuthClient]),
/// needed to refresh its access token.
pub const SECRET_OAUTH_CLIENT: &str = "oauth_client";

/// An access token is refreshed this long before it runs out.
const TOKEN_MARGIN_SECS: i64 = 120;

/// Raw messages fetched on demand are cached up to this size; bigger ones are fetched again.
const RAW_CACHE_LIMIT: usize = 32 * 1024 * 1024;

/// The name for a new top-level folder: inside `INBOX` on servers where every folder lives
/// under it (Courier, some cPanel hosts), where a folder beside INBOX would be refused.
fn new_folder_name(listed: &[provider::RemoteFolder], base: &str) -> String {
    let inbox = listed.iter().find(|f| f.name.eq_ignore_ascii_case("INBOX"));
    let others: Vec<&provider::RemoteFolder> = listed
        .iter()
        .filter(|f| !f.name.eq_ignore_ascii_case("INBOX"))
        .collect();
    match inbox.and_then(|i| Some((i, i.delimiter.as_deref().filter(|d| !d.is_empty())?))) {
        Some((inbox, d)) if !others.is_empty() => {
            let prefix = format!("{}{d}", inbox.name);
            let nested = others.iter().all(|f| {
                f.name.len() > prefix.len()
                    && f.name.is_char_boundary(prefix.len())
                    && f.name[..prefix.len()].eq_ignore_ascii_case(&prefix)
            });
            if nested {
                format!("{prefix}{base}")
            } else {
                base.to_string()
            }
        }
        _ => base.to_string(),
    }
}

pub struct Core {
    store: Arc<Store>,
    engine: SyncEngine,
    data_dir: PathBuf,
    token_lock: tokio::sync::Mutex<()>,
}

/// Access tokens are kept as `expires_at|token`.
fn store_access_token(email: &str, tokens: &auth::Tokens) -> Result<()> {
    secrets::set(
        email,
        SECRET_ACCESS_TOKEN,
        &format!("{}|{}", tokens.expires_at, tokens.access_token),
    )
}

fn parse_access_token(stored: &str) -> Option<(i64, String)> {
    let (at, token) = stored.split_once('|')?;
    Some((at.parse().ok()?, token.to_string()))
}

impl Core {
    pub fn open(data_dir: &Path) -> Result<Core> {
        // Before the database: a directory without one gets a profile of its own.
        secrets::use_profile(data_dir);
        let store = Arc::new(Store::open(&data_dir.join("mail.sqlite"))?);
        let engine = SyncEngine::new(store.clone());
        remove_legacy_file_cache(data_dir);
        Ok(Core {
            store,
            engine,
            data_dir: data_dir.to_path_buf(),
            token_lock: tokio::sync::Mutex::new(()),
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
        for k in [
            SECRET_PASSWORD,
            SECRET_REFRESH_TOKEN,
            SECRET_ACCESS_TOKEN,
            SECRET_OAUTH_CLIENT,
        ] {
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

    /// Add a Gmail or Microsoft account signed in through the browser, or sign an existing
    /// one in again. The address comes from the ID token and the servers from the
    /// provider; IMAP sign-in is checked before anything is kept. [expect]: the address
    /// being signed in again (another one is refused). Refusals come back as
    /// `Error::Auth("sign-in: <kind>: …")` for the app to put in words.
    pub async fn add_oauth_account(
        &self,
        client: &auth::OAuthClient,
        tokens: &auth::Tokens,
        expect: Option<&str>,
    ) -> Result<Account> {
        let email = tokens
            .id_token
            .as_deref()
            .and_then(auth::email_from_id_token)
            .ok_or_else(|| Error::Auth("sign-in: failed: no address came back".into()))?;
        if let Some(want) = expect.filter(|w| !w.is_empty()) {
            if !want.eq_ignore_ascii_case(&email) {
                return Err(Error::Auth(format!(
                    "sign-in: wrong_account: {email} {want}"
                )));
            }
        }
        // Google lets people untick mail on its consent page: then there is nothing to do.
        if client.provider == auth::OAuthProvider::Google
            && tokens.scope.as_deref().is_some_and(|s| {
                !s.split_whitespace()
                    .any(|x| x == "https://mail.google.com/")
            })
        {
            return Err(Error::Auth(
                "sign-in: scope: mail access was not allowed".into(),
            ));
        }
        let refresh = tokens.refresh_token.clone().ok_or_else(|| {
            Error::Auth("sign-in: no_refresh: only temporary access was given".into())
        })?;
        let existing = self
            .store
            .accounts()?
            .into_iter()
            .find(|a| a.email.eq_ignore_ascii_case(&email));
        if let Some(a) = &existing {
            if a.auth != AuthKind::XOAuth2 {
                return Err(Error::Auth(format!("sign-in: duplicate_password: {email}")));
            }
        }
        let (kind, imap_host, smtp_host, smtp_port, smtp_security) = match client.provider {
            auth::OAuthProvider::Google => (
                ProviderKind::Gmail,
                "imap.gmail.com",
                "smtp.gmail.com",
                465,
                Security::Tls,
            ),
            auth::OAuthProvider::Microsoft => (
                ProviderKind::Outlook,
                "outlook.office365.com",
                "smtp.office365.com",
                587,
                Security::StartTls,
            ),
        };
        let (host, port, transport) = match &existing {
            Some(a) => (
                a.imap_host.clone(),
                a.imap_port,
                Transport {
                    security: a.imap_security,
                    local_bridge: a.local_bridge,
                },
            ),
            None => (imap_host.to_string(), 993, Transport::default()),
        };
        let mut p = ImapProvider::connect_with(
            &host,
            port,
            transport,
            &[],
            &email,
            Credential::AccessToken(tokens.access_token.clone()),
        )
        .await
        .map_err(|e| match e {
            // Signed in with the provider, but its mail server says no: IMAP is off.
            Error::Auth(m) => Error::Auth(format!("sign-in: imap_off: {m}")),
            other => other,
        })?;
        let _ = p.logout().await;
        let client_json = serde_json::to_string(client)?;
        secrets::set(&email, SECRET_REFRESH_TOKEN, &refresh)?;
        secrets::set(&email, SECRET_OAUTH_CLIENT, &client_json)?;
        store_access_token(&email, tokens)?;
        if let Some(a) = existing {
            return Ok(a);
        }
        self.store.add_account(&NewAccount {
            kind,
            email: email.clone(),
            display_name: String::new(),
            imap_host: imap_host.into(),
            imap_port: 993,
            smtp_host: smtp_host.into(),
            smtp_port,
            auth: AuthKind::XOAuth2,
            imap_security: Security::Tls,
            smtp_security: Some(smtp_security),
            local_bridge: false,
        })
    }

    /// A current access token for an OAuth account: the stored one while it lasts, else a
    /// new one from the refresh token (which the provider may also replace). With [fresh],
    /// always a new one (the server turned the stored one down).
    async fn access_token(&self, account: &Account, fresh: bool) -> Result<String> {
        // One refresh at a time: two syncs must not race to spend a rotating refresh token.
        let _one = self.token_lock.lock().await;
        if !fresh {
            if let Some((expires_at, token)) = secrets::get(&account.email, SECRET_ACCESS_TOKEN)?
                .as_deref()
                .and_then(parse_access_token)
            {
                if expires_at - TOKEN_MARGIN_SECS > chrono::Utc::now().timestamp() {
                    return Ok(token);
                }
            }
        }
        let client: auth::OAuthClient = serde_json::from_str(
            &secrets::get(&account.email, SECRET_OAUTH_CLIENT)?
                .ok_or_else(|| Error::Auth(format!("{} needs to sign in again", account.email)))?,
        )?;
        let refresh = secrets::get(&account.email, SECRET_REFRESH_TOKEN)?
            .ok_or_else(|| Error::Auth(format!("{} needs to sign in again", account.email)))?;
        let tokens = auth::refresh(&client, &refresh).await?;
        if let Some(r) = &tokens.refresh_token {
            secrets::set(&account.email, SECRET_REFRESH_TOKEN, r)?;
        }
        store_access_token(&account.email, &tokens)?;
        Ok(tokens.access_token)
    }

    async fn connect(&self, account: &Account) -> Result<ImapProvider> {
        let transport = Transport {
            security: account.imap_security,
            local_bridge: account.local_bridge,
        };
        let open = |cred| {
            ImapProvider::connect_with(
                &account.imap_host,
                account.imap_port,
                transport,
                &[],
                &account.email,
                cred,
            )
        };
        match account.auth {
            AuthKind::Password => {
                open(Credential::Password(
                    secrets::get(&account.email, SECRET_PASSWORD)?.ok_or_else(|| {
                        Error::Secrets(format!("no password stored for {}", account.email))
                    })?,
                ))
                .await
            }
            AuthKind::XOAuth2 => {
                let token = self.access_token(account, false).await?;
                match open(Credential::AccessToken(token)).await {
                    // Revoked early, or a clock that is off: one new token, then the verdict.
                    Err(Error::Auth(_)) => {
                        let token = self.access_token(account, true).await?;
                        open(Credential::AccessToken(token)).await
                    }
                    r => r,
                }
            }
        }
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

    /// The folders a list query covers on one account: its role (Inbox when none), and on
    /// Gmail, or where there is no Archive, All Mail for the archive.
    fn folders_for(&self, account: &Account, role: FolderRole) -> Result<Vec<Folder>> {
        let folders = self.store.folders(account.id)?;
        let with = |r: FolderRole| -> Vec<Folder> {
            folders
                .iter()
                .filter(|f| f.role == r && f.selectable)
                .cloned()
                .collect()
        };
        let gmail = account.kind == ProviderKind::Gmail
            || account.imap_host.to_ascii_lowercase().contains("gmail");
        Ok(match role {
            FolderRole::Archive if gmail || with(FolderRole::Archive).is_empty() => {
                with(FolderRole::All)
            }
            r => with(r),
        })
    }

    /// Older mail for the list [query] shows on [account_id]: the next [count] messages of
    /// each folder it covers, below what the sync holds. Returns how many arrived and
    /// whether the server has older mail still. A folder that fails is skipped (and the
    /// first such error returned only when nothing else came in).
    pub async fn load_older(
        &self,
        account_id: i64,
        query: &str,
        count: usize,
    ) -> Result<(usize, bool)> {
        let account = self.store.account(account_id)?;
        let q = Query::parse(query);
        let role = q.folder.unwrap_or(FolderRole::Inbox);
        let folders = self.folders_for(&account, role)?;
        if folders.is_empty() {
            return Ok((0, false));
        }
        // Gmail's archive is All Mail without the inbox: older inbox mail must not come in
        // as archived.
        let only = (role == FolderRole::Archive
            && folders.iter().all(|f| f.role == FolderRole::All))
        .then_some("NOT X-GM-LABELS \\Inbox");
        let mut p = self.connect(&account).await?;
        let r = async {
            let (mut fetched, mut more, mut first_error) = (0, false, None);
            for f in &folders {
                match self
                    .engine
                    .load_older(&account, &mut p, f, count, only, &SyncOptions::default())
                    .await
                {
                    Ok((n, m)) => {
                        fetched += n;
                        more |= m;
                    }
                    Err(e @ Error::Io(_)) => return Err(e),
                    Err(e) => {
                        log::warn!("{}: older mail not loaded: {e}", f.remote_name);
                        more = true;
                        first_error.get_or_insert(e);
                    }
                }
            }
            match first_error {
                Some(e) if fetched == 0 => Err(e),
                _ => Ok((fetched, more)),
            }
        }
        .await;
        let _ = p.logout().await;
        r
    }

    /// Look on [account_id]'s server for what [query] names, beyond what is cached: in All
    /// Mail and the inbox on Gmail (so a match still in the inbox shows there), elsewhere
    /// in every synced folder but Spam, Trash and Drafts (or the one folder the query
    /// names). Up to [limit] matches per folder are stored and then show in [threads]. A
    /// folder that fails is skipped. Returns how many arrived.
    pub async fn search_server(&self, account_id: i64, query: &str, limit: usize) -> Result<usize> {
        let account = self.store.account(account_id)?;
        let q = Query::parse(query);
        if q.imap_criteria(false).is_none() {
            return Ok(0);
        }
        let gmail = account.kind == ProviderKind::Gmail
            || account.imap_host.to_ascii_lowercase().contains("gmail");
        let everywhere = || -> Result<Vec<Folder>> {
            Ok(self
                .store
                .folders(account.id)?
                .into_iter()
                .filter(|f| {
                    f.selectable
                        && !matches!(
                            f.role,
                            FolderRole::Junk | FolderRole::Trash | FolderRole::Drafts
                        )
                })
                .collect())
        };
        let folders: Vec<Folder> = match q.folder {
            Some(role) => self.folders_for(&account, role)?,
            None if gmail => {
                let all = self.folders_for(&account, FolderRole::All)?;
                if all.is_empty() {
                    // All Mail hidden from IMAP: the labels there are, then.
                    everywhere()?
                } else {
                    [all, self.folders_for(&account, FolderRole::Inbox)?].concat()
                }
            }
            None => everywhere()?,
        };
        if folders.is_empty() {
            return Ok(0);
        }
        let mut p = self.connect(&account).await?;
        let r = async {
            let (mut found, mut first_error) = (0, None);
            for f in &folders {
                // A folder never synced has no UIDVALIDITY yet to keep matches under.
                if f.uidvalidity.is_none() {
                    continue;
                }
                match self
                    .engine
                    .search_server(&account, &mut p, f, &q, limit, &SyncOptions::default())
                    .await
                {
                    Ok(n) => found += n,
                    Err(e @ Error::Io(_)) => return Err(e),
                    Err(e) => {
                        log::warn!("{}: not searched: {e}", f.remote_name);
                        first_error.get_or_insert(e);
                    }
                }
            }
            match first_error {
                Some(e) if found == 0 => Err(e),
                _ => Ok(found),
            }
        }
        .await;
        let _ = p.logout().await;
        r
    }

    /// Create the folder Archive or Delete needs when the server has none. It is marked
    /// with its special-use attribute where the server takes one, and made inside the INBOX
    /// namespace on servers that keep every folder there. Returns the folder's name, and does
    /// nothing when the folder already exists. Gmail is left alone: its All Mail and Trash
    /// always exist and only need showing to IMAP, which is the user's switch.
    pub async fn create_role_folder(&self, account_id: i64, role: FolderRole) -> Result<String> {
        let base = match role {
            FolderRole::Archive => "Archive",
            FolderRole::Trash => "Trash",
            other => {
                return Err(Error::Other(format!(
                    "only Archive and Trash are created, not {}",
                    other.as_str()
                )))
            }
        };
        let account = self.store.account(account_id)?;
        let mut p = self.connect(&account).await?;
        let r = async {
            let has = |list: &[provider::RemoteFolder]| {
                list.iter()
                    .find(|f| f.role == role && f.selectable)
                    .map(|f| f.name.clone())
            };
            let listed = p.list_folders().await?;
            if let Some(name) = has(&listed) {
                self.engine.store_folder_list(account_id, &listed)?;
                return Ok(name);
            }
            if p.is_gmail() {
                return Err(Error::NoFolder {
                    account_id,
                    role,
                    gmail: true,
                });
            }
            let name = new_folder_name(&listed, base);
            p.create_folder(&name, Some(role)).await?;
            let listed = p.list_folders().await?;
            self.engine.store_folder_list(account_id, &listed)?;
            has(&listed).ok_or_else(|| {
                Error::Imap(format!(
                    "created {name}, but the server does not list it as a folder for mail"
                ))
            })
        }
        .await;
        let _ = p.logout().await;
        r
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
            AuthKind::XOAuth2 => {
                SmtpCredential::AccessToken(self.access_token(&account, false).await?)
            }
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
        // Opened by the system on a click: it must know the file came from the internet.
        files::mark_from_internet(&partial);
        tokio::fs::rename(&partial, &path).await?;
        Ok(path)
    }

    /// Save an attachment into `dir` under a free name (`report (1).pdf` when taken).
    pub async fn save_attachment(&self, message_id: i64, idx: u32, dir: &Path) -> Result<PathBuf> {
        let (meta, bytes) = self.attachment(message_id, idx).await?;
        tokio::fs::create_dir_all(dir).await?;
        let path = files::unique_path(dir, &files::safe_file_name(&meta.name));
        tokio::fs::write(&path, &bytes).await?;
        files::mark_from_internet(&path);
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
            delimiter: None,
            floor_uid: None,
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
        // A search the server refuses is not "not there": no blind second copy.
        fake.with(|s| s.refuse_search = true);
        assert!(append_once(&mut p, "Sent", &raw, Some(&id)).await.is_err());
        fake.with(|s| s.refuse_search = false);
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

    fn remote(name: &str, delimiter: &str) -> provider::RemoteFolder {
        provider::RemoteFolder {
            name: name.into(),
            role: FolderRole::Other,
            selectable: true,
            delimiter: Some(delimiter.into()),
        }
    }

    #[test]
    fn a_new_folder_goes_where_the_server_keeps_folders() {
        let flat = [
            remote("INBOX", "/"),
            remote("Sent", "/"),
            remote("Trash", "/"),
        ];
        assert_eq!(new_folder_name(&flat, "Archive"), "Archive");
        // Courier and some cPanel hosts: every folder lives under INBOX.
        let nested = [
            remote("INBOX", "."),
            remote("INBOX.Sent", "."),
            remote("INBOX.Trash", "."),
        ];
        assert_eq!(new_folder_name(&nested, "Archive"), "INBOX.Archive");
        // One folder beside INBOX means the server allows them there.
        let mixed = [
            remote("INBOX", "."),
            remote("INBOX.Sent", "."),
            remote("Work", "."),
        ];
        assert_eq!(new_folder_name(&mixed, "Archive"), "Archive");
        assert_eq!(new_folder_name(&[remote("INBOX", "/")], "Trash"), "Trash");
    }

    /// An account on the fake server, reached as a local bridge (the fake's certificate is
    /// self-signed), with the password in the test secret store.
    async fn core_on(fake: &provider::fake_imap::FakeImap, tag: &str) -> (Core, PathBuf, i64) {
        let dir = std::env::temp_dir().join(format!("mailcore-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let core = Core::open(&dir).unwrap();
        let email = format!("{tag}@x.dev");
        fake.with(|s| s.log.clear());
        let a = core
            .add_account(
                &NewAccount {
                    kind: ProviderKind::Imap,
                    email: email.clone(),
                    display_name: "Z".into(),
                    imap_host: "localhost".into(),
                    imap_port: fake.port,
                    smtp_host: String::new(),
                    smtp_port: 0,
                    auth: AuthKind::Password,
                    imap_security: Default::default(),
                    smtp_security: None,
                    local_bridge: true,
                },
                "secret",
            )
            .unwrap();
        (core, dir, a.id)
    }

    #[tokio::test]
    async fn archive_without_an_archive_folder_says_so_and_can_create_one() {
        use crate::provider::fake_imap::FakeImap;
        for special_use in [true, false] {
            let tag = format!("mkarchive{}", special_use as u8);
            let fake = FakeImap::start(&format!("{tag}@x.dev"), "secret").await;
            fake.with(|s| {
                s.add_box("INBOX", None);
                s.add_box("Sent", Some("\\Sent"));
                s.deliver("INBOX", INVOICE_EML, &[]);
                s.special_use_create = special_use;
            });
            let (core, dir, account) = core_on(&fake, &tag).await;
            core.sync_account(account, &SyncOptions::default())
                .await
                .unwrap();
            let thread = core.threads("", 10).unwrap()[0].id;
            match core.actions().archive(thread) {
                Err(Error::NoFolder {
                    account_id,
                    role: FolderRole::Archive,
                    gmail: false,
                }) => assert_eq!(account_id, account),
                other => panic!("{other:?}"),
            }
            assert_eq!(
                core.create_role_folder(account, FolderRole::Archive)
                    .await
                    .unwrap(),
                "Archive"
            );
            let (special, created) = fake.with(|s| {
                (
                    s.boxes.get("Archive").map(|b| b.special),
                    s.log.iter().filter(|l| l.starts_with("CREATE")).count(),
                )
            });
            let expected = if special_use { Some("\\Archive") } else { None };
            assert_eq!(special, Some(expected), "special-use {special_use}");
            assert_eq!(created, 1);
            // Known now, without another sync; asking again creates nothing.
            assert_eq!(core.actions().archive(thread).unwrap(), 1);
            core.create_role_folder(account, FolderRole::Archive)
                .await
                .unwrap();
            assert_eq!(
                fake.with(|s| s.log.iter().filter(|l| l.starts_with("CREATE")).count()),
                1
            );
            std::fs::remove_dir_all(&dir).unwrap();
        }
    }

    #[tokio::test]
    async fn gmail_with_all_mail_hidden_is_told_where_the_switch_is() {
        use crate::provider::fake_imap::FakeImap;
        let fake = FakeImap::start("hidden@x.dev", "secret").await;
        fake.with(|s| {
            s.gmail = true;
            s.add_box("INBOX", None);
            s.deliver("INBOX", INVOICE_EML, &[]);
        });
        let (core, dir, account) = core_on(&fake, "hidden").await;
        let err = core
            .create_role_folder(account, FolderRole::Archive)
            .await
            .unwrap_err();
        assert!(
            matches!(err, Error::NoFolder { gmail: true, .. }),
            "{err:?}"
        );
        assert!(err.to_string().contains("Show in IMAP"), "{err}");
        assert!(err.to_string().contains("All Mail"), "{err}");
        assert!(fake.with(|s| !s.log.iter().any(|l| l.starts_with("CREATE"))));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    fn numbered(n: u32, subject: &str) -> Vec<u8> {
        format!(
            "From: Anna <anna@studio.dev>\r\nTo: z@x.dev\r\nSubject: {subject}\r\n\
             Message-ID: <m{n}@studio.dev>\r\nDate: Mon, 1 Jan 2024 10:00:00 +0000\r\n\r\n\
             Body {n}.\r\n"
        )
        .into_bytes()
    }

    /// 30 messages in INBOX (UID 3 is the one a search looks for), synced with a window of 10.
    async fn thirty(tag: &str) -> (provider::fake_imap::FakeImap, Core, PathBuf, i64) {
        use crate::provider::fake_imap::FakeImap;
        let fake = FakeImap::start(&format!("{tag}@x.dev"), "secret").await;
        fake.with(|s| {
            s.add_box("INBOX", None);
            for n in 1..=30 {
                let subject = if n == 3 {
                    "Quarterly report".to_string()
                } else {
                    format!("Note {n}")
                };
                s.deliver("INBOX", &numbered(n, &subject), &[]);
            }
        });
        let (core, dir, account) = core_on(&fake, tag).await;
        let opts = SyncOptions {
            roles: vec![FolderRole::Inbox],
            initial_window: 10,
            ..SyncOptions::default()
        };
        assert_eq!(core.sync_account(account, &opts).await.unwrap().fetched, 10);
        (fake, core, dir, account)
    }

    #[tokio::test]
    async fn older_mail_comes_in_pages_until_there_is_none() {
        let (_fake, core, dir, account) = thirty("older").await;
        assert_eq!(core.load_older(account, "", 10).await.unwrap(), (10, true));
        assert_eq!(core.load_older(account, "", 10).await.unwrap(), (10, false));
        assert_eq!(core.load_older(account, "", 10).await.unwrap(), (0, false));
        assert_eq!(core.threads("", 100).unwrap().len(), 30);
        // The next sync keeps all of it and fetches nothing again.
        let r = core
            .sync_account(account, &SyncOptions::default())
            .await
            .unwrap();
        assert_eq!((r.fetched, r.removed), (0, 0));
        assert_eq!(core.threads("", 100).unwrap().len(), 30);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[tokio::test]
    async fn a_server_search_finds_old_mail_without_pulling_in_the_years_between() {
        let (fake, core, dir, account) = thirty("srvsearch").await;
        assert!(core.threads("quarterly", 10).unwrap().is_empty());
        assert_eq!(
            core.search_server(account, "quarterly", 50).await.unwrap(),
            1
        );
        let found = core.threads("quarterly", 10).unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].subject, "Quarterly report");
        // Nothing to look for: the server is not asked.
        assert_eq!(
            core.search_server(account, "is:unread", 50).await.unwrap(),
            0
        );

        // The next sync fetches none of UIDs 4..20, and still follows the found one's flags.
        fake.with(|s| s.set_flags("INBOX", 3, &["\\Seen"]));
        let r = core
            .sync_account(account, &SyncOptions::default())
            .await
            .unwrap();
        assert_eq!(r.fetched, 0);
        assert_eq!(core.threads("", 100).unwrap().len(), 11);
        assert_eq!(core.threads("quarterly is:unread", 10).unwrap().len(), 0);
        // Deleted on the server: gone here too.
        fake.with(|s| {
            let b = s.boxes.get_mut("INBOX").unwrap();
            b.msgs.retain(|m| m.uid != 3);
        });
        core.sync_account(account, &SyncOptions::default())
            .await
            .unwrap();
        assert!(core.threads("quarterly", 10).unwrap().is_empty());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A token endpoint over TLS: refresh token "r1" is worth access token "tok2" until
    /// [revoked]; every request is counted.
    struct FakeTokens {
        url: String,
        requests: Arc<std::sync::atomic::AtomicUsize>,
        revoked: Arc<std::sync::atomic::AtomicBool>,
    }

    impl FakeTokens {
        async fn start() -> FakeTokens {
            use rustls::pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer};
            use std::sync::atomic::Ordering;
            use tokio::io::{AsyncReadExt, AsyncWriteExt};
            let ck = rcgen::generate_simple_self_signed(vec!["localhost".to_string()]).unwrap();
            let cert = ck.cert.der().clone();
            let key =
                PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(ck.signing_key.serialize_der()));
            crate::http::TEST_ROOTS.lock().unwrap().push(cert.clone());
            let config = rustls::ServerConfig::builder()
                .with_no_client_auth()
                .with_single_cert(vec![cert], key)
                .unwrap();
            let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let requests = Arc::new(std::sync::atomic::AtomicUsize::new(0));
            let revoked = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let (n, gone) = (requests.clone(), revoked.clone());
            tokio::spawn(async move {
                loop {
                    let Ok((tcp, _)) = listener.accept().await else {
                        return;
                    };
                    let Ok(mut tls) = acceptor.accept(tcp).await else {
                        continue;
                    };
                    n.fetch_add(1, Ordering::SeqCst);
                    let mut buf = vec![0u8; 4096];
                    let mut got = 0;
                    loop {
                        let k = tls.read(&mut buf[got..]).await.unwrap_or(0);
                        got += k;
                        let text = String::from_utf8_lossy(&buf[..got]);
                        if k == 0 || text.contains("refresh_token=") {
                            break;
                        }
                    }
                    let text = String::from_utf8_lossy(&buf[..got]).into_owned();
                    let ok = text.contains("refresh_token=r1") && !gone.load(Ordering::SeqCst);
                    let body = if ok {
                        r#"{"access_token":"tok2","expires_in":3599,"token_type":"Bearer"}"#
                    } else {
                        r#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#
                    };
                    let status = if ok { "200 OK" } else { "400 Bad Request" };
                    let reply = format!(
                        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = tls.write_all(reply.as_bytes()).await;
                    let _ = tls.shutdown().await;
                }
            });
            let url = format!("https://localhost:{port}/token");
            *crate::auth::TEST_TOKEN_URL.lock().unwrap() = Some(url.clone());
            FakeTokens {
                url,
                requests,
                revoked,
            }
        }
    }

    #[tokio::test]
    async fn an_oauth_account_refreshes_its_token_and_asks_again_only_once() {
        use crate::provider::fake_imap::FakeImap;
        use std::sync::atomic::Ordering;
        let tokens = FakeTokens::start().await;
        assert!(tokens.url.starts_with("https://localhost:"));
        let email = "oa@x.dev";
        // The fake takes XOAUTH2 with the current access token in place of a password.
        let fake = FakeImap::start(email, "tok2").await;
        fake.with(|s| s.add_box("INBOX", None));
        let dir = std::env::temp_dir().join(format!("mailcore-oauth-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let core = Core::open(&dir).unwrap();
        let account = core
            .store()
            .add_account(&NewAccount {
                kind: ProviderKind::Gmail,
                email: email.into(),
                display_name: String::new(),
                imap_host: "localhost".into(),
                imap_port: fake.port,
                smtp_host: String::new(),
                smtp_port: 0,
                auth: AuthKind::XOAuth2,
                imap_security: Security::Tls,
                smtp_security: None,
                local_bridge: true,
            })
            .unwrap();
        let client = auth::OAuthClient {
            provider: auth::OAuthProvider::Google,
            client_id: "cid".into(),
            client_secret: None,
        };
        secrets::set(email, SECRET_REFRESH_TOKEN, "r1").unwrap();
        secrets::set(
            email,
            SECRET_OAUTH_CLIENT,
            &serde_json::to_string(&client).unwrap(),
        )
        .unwrap();
        let past = chrono::Utc::now().timestamp() - 10;
        secrets::set(email, SECRET_ACCESS_TOKEN, &format!("{past}|tok1")).unwrap();
        let opts = SyncOptions::default();

        // Run out: refreshed before signing in.
        core.sync_account(account.id, &opts).await.unwrap();
        assert_eq!(tokens.requests.load(Ordering::SeqCst), 1);
        // Still good: no new request.
        core.sync_account(account.id, &opts).await.unwrap();
        assert_eq!(tokens.requests.load(Ordering::SeqCst), 1);

        // Turned down though not expired (revoked early): one new token, then signed in.
        let later = chrono::Utc::now().timestamp() + 3000;
        secrets::set(email, SECRET_ACCESS_TOKEN, &format!("{later}|stale")).unwrap();
        core.sync_account(account.id, &opts).await.unwrap();
        assert_eq!(tokens.requests.load(Ordering::SeqCst), 2);

        // The grant itself is gone: the account needs signing in, said as an auth error.
        tokens.revoked.store(true, Ordering::SeqCst);
        secrets::set(email, SECRET_ACCESS_TOKEN, &format!("{past}|tok2")).unwrap();
        match core.sync_account(account.id, &opts).await {
            Err(Error::Auth(m)) => assert!(m.contains("revoked"), "{m}"),
            other => panic!("{other:?}"),
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    fn id_token(email: &str) -> String {
        use base64::Engine;
        let claims = format!(r#"{{"email":"{email}"}}"#);
        format!(
            "e30.{}.sig",
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(claims)
        )
    }

    fn google_tokens(email: &str, access: &str, scope: &str) -> auth::Tokens {
        auth::Tokens {
            access_token: access.into(),
            refresh_token: Some(format!("refresh-{access}")),
            expires_at: chrono::Utc::now().timestamp() + 3600,
            id_token: Some(id_token(email)),
            scope: Some(scope.into()),
        }
    }

    #[tokio::test]
    async fn signing_in_again_replaces_the_tokens_and_refusals_are_named() {
        use crate::provider::fake_imap::FakeImap;
        let email = "again@x.dev";
        let fake = FakeImap::start(email, "fresh-token").await;
        fake.with(|s| s.add_box("INBOX", None));
        let dir = std::env::temp_dir().join(format!("mailcore-again-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let core = Core::open(&dir).unwrap();
        let account = core
            .store()
            .add_account(&NewAccount {
                kind: ProviderKind::Gmail,
                email: email.into(),
                display_name: String::new(),
                imap_host: "localhost".into(),
                imap_port: fake.port,
                smtp_host: String::new(),
                smtp_port: 0,
                auth: AuthKind::XOAuth2,
                imap_security: Security::Tls,
                smtp_security: None,
                local_bridge: true,
            })
            .unwrap();
        let client = auth::OAuthClient {
            provider: auth::OAuthProvider::Google,
            client_id: "cid".into(),
            client_secret: None,
        };
        let mail = "https://mail.google.com/ openid email";
        let refusal = |r: Result<Account>| match r {
            Err(Error::Auth(m)) => m,
            other => panic!("{other:?}"),
        };

        // Someone else's account on the provider's page.
        let m = refusal(
            core.add_oauth_account(&client, &google_tokens("bob@x.dev", "t", mail), Some(email))
                .await,
        );
        assert!(m.starts_with("sign-in: wrong_account: bob@x.dev"), "{m}");
        // The mail box unticked on Google's page.
        let m = refusal(
            core.add_oauth_account(&client, &google_tokens(email, "t", "openid email"), None)
                .await,
        );
        assert!(m.starts_with("sign-in: scope:"), "{m}");

        // Signed in again: the same account, its tokens replaced, sync works with them.
        let again = core
            .add_oauth_account(
                &client,
                &google_tokens(email, "fresh-token", mail),
                Some(email),
            )
            .await
            .unwrap();
        assert_eq!(again.id, account.id);
        assert_eq!(core.store().accounts().unwrap().len(), 1);
        assert_eq!(
            secrets::get(email, SECRET_REFRESH_TOKEN)
                .unwrap()
                .as_deref(),
            Some("refresh-fresh-token")
        );
        core.sync_account(account.id, &SyncOptions::default())
            .await
            .unwrap();

        // A password account at that address is not taken over.
        let pw = core
            .store()
            .add_account(&NewAccount {
                kind: ProviderKind::Imap,
                email: "pw@x.dev".into(),
                display_name: String::new(),
                imap_host: "imap.x.dev".into(),
                imap_port: 993,
                smtp_host: String::new(),
                smtp_port: 0,
                auth: AuthKind::Password,
                imap_security: Security::Tls,
                smtp_security: None,
                local_bridge: false,
            })
            .unwrap();
        let _ = pw;
        let m = refusal(
            core.add_oauth_account(&client, &google_tokens("pw@x.dev", "t", mail), None)
                .await,
        );
        assert!(
            m.starts_with("sign-in: duplicate_password: pw@x.dev"),
            "{m}"
        );
        let d = diagnose::diagnose(&format!("auth: {m}"), "imap.gmail.com");
        assert_eq!(d.kind, diagnose::ErrorKind::DuplicatePassword);
        assert!(d.title.contains("pw@x.dev"), "{}", d.title);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
