//! Bridge API: thin DTOs over mailcore. Everything the Flutter app calls lives here.

use anyhow::{anyhow, Result};
use flutter_rust_bridge::frb;
use mailcore::compose::{AttachmentSource, Draft, DraftAttachment};
use mailcore::sanitize::html_to_text;
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
    pub signature: String,
    pub imap_host: String,
    pub imap_port: u16,
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
    /// Remote images blocked plus inline images not available offline.
    pub blocked_images: u32,
    pub has_attachment: bool,
    pub unread: bool,
    /// Real attachments only; inline images render inside `html`.
    pub attachments: Vec<AttachmentDto>,
}

pub struct AttachmentDto {
    pub message_id: i64,
    pub idx: u32,
    pub name: String,
    pub mime: String,
    pub size: i64,
}

/// A file going out with a draft: a local `path`, or part `idx` of stored message `message_id`.
pub struct DraftAttachmentDto {
    pub name: String,
    pub mime: String,
    pub size: i64,
    pub path: Option<String>,
    pub message_id: Option<i64>,
    pub idx: Option<u32>,
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
    pub attachments: Vec<DraftAttachmentDto>,
}

fn attachment_to_dto(a: DraftAttachment) -> DraftAttachmentDto {
    let (path, message_id, idx) = match a.source {
        AttachmentSource::File { path } => (Some(path), None, None),
        AttachmentSource::Message { message_id, idx } => (None, Some(message_id), Some(idx)),
    };
    DraftAttachmentDto { name: a.name, mime: a.mime, size: a.size as i64, path, message_id, idx }
}

fn dto_to_attachment(a: &DraftAttachmentDto) -> Result<DraftAttachment> {
    let source = match (&a.path, a.message_id, a.idx) {
        (Some(path), _, _) => AttachmentSource::File { path: path.clone() },
        (None, Some(message_id), Some(idx)) => AttachmentSource::Message { message_id, idx },
        _ => return Err(anyhow!("attachment {} has no source", a.name)),
    };
    Ok(DraftAttachment { name: a.name.clone(), mime: a.mime.clone(), size: a.size.max(0) as u64, source })
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
        attachments: d.attachments.into_iter().map(attachment_to_dto).collect(),
    }
}

fn dto_to_draft(d: &DraftDto) -> Result<Draft> {
    Ok(Draft {
        from: parse_addr(&d.from),
        to: d.to.iter().filter(|s| !s.trim().is_empty()).map(|s| parse_addr(s)).collect(),
        cc: d.cc.iter().filter(|s| !s.trim().is_empty()).map(|s| parse_addr(s)).collect(),
        bcc: d.bcc.iter().filter(|s| !s.trim().is_empty()).map(|s| parse_addr(s)).collect(),
        subject: d.subject.clone(),
        text: d.text.clone(),
        in_reply_to: d.in_reply_to.clone(),
        references: d.references.clone(),
        attachments: d.attachments.iter().map(dto_to_attachment).collect::<Result<_>>()?,
    })
}

/// A draft kept on this device. `kind` is fresh, reply or forward.
pub struct SavedDraftDto {
    pub id: i64,
    pub kind: String,
    pub updated_at: i64,
    pub draft: DraftDto,
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
        let unread = c.store().unread_count(Some(a.id))?;
        out.push(account_dto(a, unread));
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
    Ok(account_dto(a, 0))
}

fn account_dto(a: mailcore::Account, unread: u32) -> AccountDto {
    AccountDto {
        id: a.id,
        email: a.email,
        kind: a.kind.as_str().to_string(),
        display_name: a.display_name,
        unread,
        signature: a.signature,
        imap_host: a.imap_host,
        imap_port: a.imap_port,
    }
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
        let (text, raw_html) = c.store().body(m.id).unwrap_or((None, None));
        let cleaned = c.message_html_cached(m.id, false).unwrap_or(None);
        let text = text.or_else(|| raw_html.as_deref().map(html_to_text));
        let blocked_images = cleaned.as_ref().map(|s| s.blocked_images as u32).unwrap_or(0);
        let html = cleaned.map(|s| s.html);
        let attachments = c
            .store()
            .attachments(m.id)
            .unwrap_or_default()
            .into_iter()
            .filter(|a| !a.inline)
            .map(|a| AttachmentDto { message_id: m.id, idx: a.idx, name: a.name, mime: a.mime, size: a.size as i64 })
            .collect();
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
            attachments,
        });
    }
    Ok(out)
}

/// Sanitized HTML body of one message. With `load_images`, remote images stay in and inline
/// images missing from the cache are fetched from the server.
pub async fn message_html(message_id: i64, load_images: bool) -> Result<Option<String>> {
    Ok(core()?.message_html(message_id, load_images).await?.map(|s| s.html))
}

// ---------- attachments ----------

/// Path of the attachment in the app's file cache (fetched from the server when needed).
/// This is the file to hand to "open with" or a share sheet.
pub async fn open_attachment(message_id: i64, idx: u32) -> Result<String> {
    let p = core()?.cached_attachment_file(message_id, idx).await?;
    Ok(p.to_string_lossy().into_owned())
}

/// Save an attachment into `dir` under a free name; returns the path written.
pub async fn save_attachment(message_id: i64, idx: u32, dir: String) -> Result<String> {
    let p = core()?.save_attachment(message_id, idx, &PathBuf::from(dir)).await?;
    Ok(p.to_string_lossy().into_owned())
}

/// Describe a local file for a draft: name, size, MIME type from the extension.
pub fn describe_file(path: String) -> Result<DraftAttachmentDto> {
    Ok(attachment_to_dto(DraftAttachment::from_path(&PathBuf::from(path))?))
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

/// Empty draft (signature included) from the given account, or the first one.
pub fn new_draft(account_id: Option<i64>) -> Result<DraftDto> {
    let (account, draft) = core()?.new_draft(account_id)?;
    Ok(draft_to_dto(account.id, draft))
}

/// Name shown in From, and the signature new drafts start with.
pub fn update_account(id: i64, display_name: String, signature: String) -> Result<()> {
    Ok(core()?.store().update_account_profile(id, display_name.trim(), &signature)?)
}

// ---------- app preferences ----------

pub fn get_setting(key: String) -> Result<Option<String>> {
    Ok(core()?.store().setting(&key)?)
}

pub fn set_setting(key: String, value: String) -> Result<()> {
    Ok(core()?.store().set_setting(&key, &value)?)
}

// ---------- drafts kept on this device ----------

/// Save a draft (insert, or update `id` in place); returns its id.
pub fn save_local_draft(id: Option<i64>, kind: String, draft: DraftDto) -> Result<i64> {
    let d = dto_to_draft(&draft)?;
    Ok(core()?.store().save_draft(id, draft.account_id, &kind, &d)?)
}

/// Every saved draft, most recently edited first.
pub fn list_local_drafts() -> Result<Vec<SavedDraftDto>> {
    Ok(core()?
        .store()
        .drafts()?
        .into_iter()
        .map(|s| SavedDraftDto {
            id: s.id,
            kind: s.kind,
            updated_at: s.updated_at.timestamp(),
            draft: draft_to_dto(s.account_id, s.draft),
        })
        .collect())
}

pub fn delete_local_draft(id: i64) -> Result<()> {
    Ok(core()?.store().delete_draft(id)?)
}

/// SMTP send; copies to Sent where the server does not; flags the original as answered.
pub async fn send_draft(draft: DraftDto) -> Result<()> {
    let d = dto_to_draft(&draft)?;
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

/// Sit in IMAP IDLE on the account's inbox. Returns true when the server reported a change,
/// false when `timeout_secs` passed quietly. Errors surface as exceptions (no connection, auth…).
pub async fn wait_for_change(account_id: i64, timeout_secs: u32) -> Result<bool> {
    let outcome = core()?
        .wait_for_change(account_id, std::time::Duration::from_secs(u64::from(timeout_secs)))
        .await?;
    Ok(matches!(outcome, mailcore::provider::IdleOutcome::Changed))
}

/// Sync one account (inbox only when `inbox_only`).
pub async fn sync_account(account_id: i64, inbox_only: bool) -> Result<SyncSummaryDto> {
    let c = core()?;
    let mut opts = SyncOptions::default();
    if inbox_only {
        opts.roles = vec![FolderRole::Inbox];
    }
    let mut summary = SyncSummaryDto { accounts: 1, fetched: 0, removed: 0, errors: vec![] };
    match c.sync_account(account_id, &opts).await {
        Ok(rep) => {
            summary.fetched = rep.fetched as u32;
            summary.removed = rep.removed as u32;
        }
        Err(e) => summary.errors.push(e.to_string()),
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
