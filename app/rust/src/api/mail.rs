//! Bridge API: thin DTOs over mailcore. Everything the Flutter app calls lives here.

use anyhow::{anyhow, Result};
use flutter_rust_bridge::frb;
use mailcore::compose::Draft;
use mailcore::sanitize::{html_to_text, sanitize, SanitizeOptions};
use mailcore::Address;
use mailcore::{AuthKind, Core, FolderRole, NewAccount, ProviderKind, SyncEvent, SyncOptions};
use std::path::PathBuf;
use std::sync::OnceLock;

static CORE: OnceLock<Core> = OnceLock::new();

fn core() -> Result<&'static Core> {
    CORE.get().ok_or_else(|| anyhow!("core not opened; call open_core first"))
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Open (or create) the profile database under `data_dir`. Idempotent.
pub fn open_core(data_dir: String) -> Result<()> {
    if CORE.get().is_some() {
        return Ok(());
    }
    let core = Core::open(&PathBuf::from(data_dir))?;
    let _ = CORE.set(core);
    Ok(())
}

// ---------- DTOs ----------

pub struct AccountDto {
    pub id: i64,
    pub email: String,
    pub kind: String,
    pub display_name: String,
    pub unread: u32,
}

pub struct FolderDto {
    pub id: i64,
    pub account_id: i64,
    pub name: String,
    pub role: String,
}

pub struct ThreadDto {
    pub id: i64,
    pub account_id: i64,
    pub subject: String,
    pub participants: Vec<String>,
    /// Unix seconds, UTC.
    pub last_date: i64,
    pub msg_count: u32,
    pub unread_count: u32,
    pub snippet: String,
    pub has_attachment: bool,
    pub starred: bool,
}

pub struct MessageDto {
    pub id: i64,
    pub thread_id: i64,
    pub from_name: String,
    pub from_addr: String,
    pub to: Vec<String>,
    pub date: i64,
    pub snippet: String,
    /// Plain text body, derived from HTML when the message has no text part.
    pub text: Option<String>,
    /// Sanitized HTML (no scripts, styles, forms; remote images blocked → `data-blocked-src`).
    pub html: Option<String>,
    pub blocked_images: u32,
    pub has_attachment: bool,
    pub unread: bool,
}

pub struct SyncSummaryDto {
    pub accounts: u32,
    pub fetched: u32,
    pub removed: u32,
    pub errors: Vec<String>,
}

/// A message being written. Addresses are `Name <addr>` or bare `addr`.
pub struct DraftDto {
    pub account_id: i64,
    pub from: String,
    pub to: Vec<String>,
    pub cc: Vec<String>,
    pub bcc: Vec<String>,
    pub subject: String,
    pub text: String,
    pub in_reply_to: Option<String>,
    pub references: Vec<String>,
}

fn fmt_addr(a: &Address) -> String {
    match &a.name {
        Some(n) if !n.is_empty() => format!("{n} <{}>", a.addr),
        _ => a.addr.clone(),
    }
}

fn parse_addr(s: &str) -> Address {
    let s = s.trim();
    if let (Some(lt), Some(gt)) = (s.rfind('<'), s.rfind('>')) {
        if lt < gt {
            let name = s[..lt].trim().trim_matches('"').to_string();
            return Address { name: if name.is_empty() { None } else { Some(name) }, addr: s[lt + 1..gt].trim().to_string() };
        }
    }
    Address { name: None, addr: s.to_string() }
}

fn draft_to_dto(account_id: i64, d: Draft) -> DraftDto {
    DraftDto {
        account_id,
        from: fmt_addr(&d.from),
        to: d.to.iter().map(fmt_addr).collect(),
        cc: d.cc.iter().map(fmt_addr).collect(),
        bcc: d.bcc.iter().map(fmt_addr).collect(),
        subject: d.subject,
        text: d.text,
        in_reply_to: d.in_reply_to,
        references: d.references,
    }
}

fn dto_to_draft(d: &DraftDto) -> Draft {
    Draft {
        from: parse_addr(&d.from),
        to: d.to.iter().filter(|s| !s.trim().is_empty()).map(|s| parse_addr(s)).collect(),
        cc: d.cc.iter().filter(|s| !s.trim().is_empty()).map(|s| parse_addr(s)).collect(),
        bcc: d.bcc.iter().filter(|s| !s.trim().is_empty()).map(|s| parse_addr(s)).collect(),
        subject: d.subject.clone(),
        text: d.text.clone(),
        in_reply_to: d.in_reply_to.clone(),
        references: d.references.clone(),
    }
}

/// Flat event record: `kind` is one of started, folder, finished, error.
pub struct SyncEventDto {
    pub kind: String,
    pub account_id: i64,
    pub folder: String,
    pub fetched: u32,
    pub removed: u32,
    pub message: String,
}

impl SyncEventDto {
    fn new(kind: &str, account_id: i64) -> Self {
        SyncEventDto { kind: kind.to_string(), account_id, folder: String::new(), fetched: 0, removed: 0, message: String::new() }
    }
}

// ---------- accounts ----------

pub fn list_accounts() -> Result<Vec<AccountDto>> {
    let c = core()?;
    let mut out = Vec::new();
    for a in c.store().accounts()? {
        out.push(AccountDto {
            id: a.id,
            email: a.email.clone(),
            kind: a.kind.as_str().to_string(),
            display_name: a.display_name.clone(),
            unread: c.store().unread_count(Some(a.id))?,
        });
    }
    Ok(out)
}

pub fn add_imap_account(email: String, host: String, port: u16, password: String, display_name: String) -> Result<AccountDto> {
    let c = core()?;
    let a = c.add_account(
        &NewAccount {
            kind: if host.contains("gmail") { ProviderKind::Gmail } else { ProviderKind::Imap },
            email,
            display_name,
            imap_host: host,
            imap_port: port,
            smtp_host: String::new(),
            smtp_port: 0,
            auth: AuthKind::Password,
        },
        &password,
    )?;
    Ok(AccountDto { id: a.id, email: a.email, kind: a.kind.as_str().to_string(), display_name: a.display_name, unread: 0 })
}

/// Connect + authenticate once; nothing is stored. The error text carries the server's reason.
pub async fn test_imap_login(email: String, host: String, port: u16, password: String) -> Result<()> {
    Ok(Core::check_login(&host, port, &email, &password).await?)
}

pub fn remove_account(id: i64) -> Result<()> {
    Ok(core()?.remove_account(id)?)
}

pub fn list_folders(account_id: i64) -> Result<Vec<FolderDto>> {
    Ok(core()?
        .store()
        .folders(account_id)?
        .into_iter()
        .map(|f| FolderDto { id: f.id, account_id: f.account_id, name: f.remote_name, role: f.role.as_str().to_string() })
        .collect())
}

// ---------- reading ----------

pub fn list_threads(query: String, limit: u32) -> Result<Vec<ThreadDto>> {
    Ok(core()?
        .threads(&query, limit)?
        .into_iter()
        .map(|t| ThreadDto {
            id: t.id,
            account_id: t.account_id,
            subject: t.subject,
            participants: t.participants,
            last_date: t.last_date.timestamp(),
            msg_count: t.msg_count,
            unread_count: t.unread_count,
            snippet: t.snippet,
            has_attachment: t.has_attachment,
            starred: t.starred,
        })
        .collect())
}

pub fn thread_messages(thread_id: i64) -> Result<Vec<MessageDto>> {
    let c = core()?;
    let mut out = Vec::new();
    for m in c.store().thread_messages(thread_id)? {
        let (text, html) = c.store().body(m.id).unwrap_or((None, None));
        let cleaned = html.as_deref().map(|h| sanitize(h, SanitizeOptions::default()));
        let text = text.or_else(|| html.as_deref().map(html_to_text));
        let blocked_images = cleaned.as_ref().map(|s| s.blocked_images as u32).unwrap_or(0);
        let html = cleaned.map(|s| s.html);
        out.push(MessageDto {
            id: m.id,
            thread_id: m.thread_id,
            from_name: m.from.display(),
            from_addr: m.from.addr.clone(),
            to: m.to.iter().map(|a| a.display()).collect(),
            date: m.date.timestamp(),
            snippet: m.snippet.clone(),
            text,
            html,
            blocked_images,
            has_attachment: m.has_attachment,
            unread: m.flags.is_unread(),
        });
    }
    Ok(out)
}

/// Sanitized HTML body of one message; `load_remote_images` keeps http(s) images instead of blocking them.
pub fn message_html(message_id: i64, load_remote_images: bool) -> Result<Option<String>> {
    let (_, html) = core()?.store().body(message_id)?;
    Ok(html.map(|h| sanitize(&h, SanitizeOptions { load_remote_images }).html))
}

pub fn unread_count() -> Result<u32> {
    Ok(core()?.store().unread_count(None)?)
}

// ---------- actions (local-first, replayed on sync) ----------

pub fn archive_thread(thread_id: i64) -> Result<()> {
    Ok(core()?.actions().archive(thread_id)?)
}

pub fn trash_thread(thread_id: i64) -> Result<()> {
    Ok(core()?.actions().trash(thread_id)?)
}

pub fn mark_read(thread_id: i64, read: bool) -> Result<()> {
    Ok(core()?.actions().mark_read(thread_id, read)?)
}

pub fn star_thread(thread_id: i64, on: bool) -> Result<()> {
    Ok(core()?.actions().star(thread_id, on)?)
}

// ---------- composing ----------

pub fn reply_draft(thread_id: i64, reply_all: bool) -> Result<DraftDto> {
    let (account, draft) = core()?.reply_draft(thread_id, reply_all)?;
    Ok(draft_to_dto(account.id, draft))
}

pub fn forward_draft(thread_id: i64) -> Result<DraftDto> {
    let (account, draft) = core()?.forward_draft(thread_id)?;
    Ok(draft_to_dto(account.id, draft))
}

/// Empty draft from the given account (or the first one).
pub fn new_draft(account_id: Option<i64>) -> Result<DraftDto> {
    let c = core()?;
    let account = match account_id {
        Some(id) => c.store().account(id)?,
        None => c.store().accounts()?.into_iter().next().ok_or_else(|| anyhow!("no accounts"))?,
    };
    let from = Address {
        name: if account.display_name.is_empty() { None } else { Some(account.display_name.clone()) },
        addr: account.email.clone(),
    };
    Ok(draft_to_dto(account.id, Draft::new(from)))
}

/// SMTP send; copies to Sent where the server does not; flags the original as answered.
pub async fn send_draft(draft: DraftDto) -> Result<()> {
    let d = dto_to_draft(&draft);
    if d.to.is_empty() {
        return Err(anyhow!("no recipients"));
    }
    Ok(core()?.send(draft.account_id, &d).await?)
}

// ---------- sync ----------

pub async fn sync_all(inbox_only: bool) -> Result<SyncSummaryDto> {
    let c = core()?;
    let mut opts = SyncOptions::default();
    if inbox_only {
        opts.roles = vec![FolderRole::Inbox];
    }
    let mut summary = SyncSummaryDto { accounts: 0, fetched: 0, removed: 0, errors: vec![] };
    for (a, r) in c.sync_all(&opts).await? {
        summary.accounts += 1;
        match r {
            Ok(rep) => {
                summary.fetched += rep.fetched as u32;
                summary.removed += rep.removed as u32;
            }
            Err(e) => summary.errors.push(format!("{}: {e}", a.email)),
        }
    }
    Ok(summary)
}

/// Subscribe to sync events. The stream stays open for the life of the app.
pub async fn sync_events(sink: crate::frb_generated::StreamSink<SyncEventDto>) -> Result<()> {
    let mut rx = core()?.subscribe();
    loop {
        match rx.recv().await {
            Ok(ev) => {
                let dto = match ev {
                    SyncEvent::Started { account_id } => SyncEventDto::new("started", account_id),
                    SyncEvent::Folder { account_id, folder, fetched, removed } => SyncEventDto {
                        folder,
                        fetched: fetched as u32,
                        removed: removed as u32,
                        ..SyncEventDto::new("folder", account_id)
                    },
                    SyncEvent::OutboxReplayed { .. } => continue,
                    SyncEvent::Finished { account_id } => SyncEventDto::new("finished", account_id),
                    SyncEvent::Error { account_id, message } => SyncEventDto { message, ..SyncEventDto::new("error", account_id) },
                };
                if sink.add(dto).is_err() {
                    return Ok(());
                }
            }
            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
            Err(tokio::sync::broadcast::error::RecvError::Closed) => return Ok(()),
        }
    }
}
