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
pub mod model;
pub mod provider;
pub mod sanitize;
pub mod search;
pub mod secrets;
pub mod smtp;
pub mod storage;
pub mod sync;
pub mod threading;

pub use error::{Error, Result};
pub use model::*;
pub use search::Query;
pub use storage::Store;
pub use sync::{SyncEvent, SyncOptions, SyncReport};

use compose::{quote, Draft};
use provider::imap::{Credential, ImapProvider};
use provider::{IdleOutcome, Provider};
use smtp::{SmtpConfig, SmtpCredential};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use sync::{Actions, SyncEngine};
use tokio::sync::broadcast;

pub const SECRET_PASSWORD: &str = "password";
pub const SECRET_REFRESH_TOKEN: &str = "refresh_token";
pub const SECRET_ACCESS_TOKEN: &str = "access_token";

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
        let refs: Vec<String> = messages.iter().filter_map(|m| m.message_id.clone()).collect();
        let earlier = &refs[..refs.len().saturating_sub(1)];
        let mut draft = Draft::reply(last, last.message_id.as_deref(), earlier, &me, reply_all);
        if last.from.addr.eq_ignore_ascii_case(&me.addr) {
            draft.to = last.to.clone();
            draft.cc = if reply_all { last.cc.clone() } else { Vec::new() };
        }
        let (text, _) = self.store.body(last.id)?;
        draft.text = format!(
            "\n\n{}",
            quote(text.as_deref().unwrap_or(&last.snippet), &last.from, last.date)
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
        let message = draft.to_mime()?;
        let raw = message.formatted();
        smtp::send(
            &SmtpConfig {
                host,
                port,
                user: account.email.clone(),
                cred: secret,
            },
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
}
