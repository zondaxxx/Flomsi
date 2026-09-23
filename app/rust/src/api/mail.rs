//! Bridge API: thin DTOs over mailcore. Everything the Flutter app calls lives here.

use anyhow::{anyhow, Result};
use flutter_rust_bridge::frb;
use mailcore::compose::{AttachmentSource, Draft, DraftAttachment};
use mailcore::sanitize::html_to_text;
use mailcore::Address;
use mailcore::diagnose::ErrorKind;
use mailcore::{AuthKind, Core, FolderRole, NewAccount, ProviderKind, Security, SyncEvent, SyncOptions};
use std::path::PathBuf;
use std::sync::OnceLock;

static CORE: OnceLock<Core> = OnceLock::new();

fn core() -> Result<&'static Core> {
    CORE.get().ok_or_else(|| anyhow!("core not opened; call open_core first"))
}

#[frb(init)]
pub fn init_app() {
    // Not setup_default_user_utils(): it logs at trace to the system log, and async-imap
    // traces every command, LOGIN with its password included.
    flutter_rust_bridge::setup_backtrace();
    flutter_rust_bridge::setup_log_to_console(mailcore::logging::max_level());
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
    /// `tls` or `starttls`.
    pub imap_security: String,
    /// Empty when the SMTP server is guessed from the IMAP one at send time.
    pub smtp_host: String,
    pub smtp_port: u16,
    pub smtp_security: String,
    /// A bridge on this computer (Proton) whose self-signed certificate is accepted.
    pub local_bridge: bool,
}

/// One server as the add-account form describes it; `security` is `tls` or `starttls`.
pub struct ServerDto {
    pub host: String,
    pub port: u16,
    pub security: String,
}

/// What went wrong, for people: `kind` is auth, network, tls, server or local.
pub struct DiagnosisDto {
    pub kind: String,
    pub title: String,
    pub hint: Option<String>,
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
    /// Unix seconds: when a snooze ends (future) or ended (past).
    pub snoozed_until: Option<i64>,
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
    /// The HTML sets its own text or background colours: made for a light page, shown on one.
    pub styled: bool,
    /// Sent from the account's own address (a reply then goes to its recipients).
    pub is_mine: bool,
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
    /// The account could not sync at all (sign-in, network).
    pub errors: Vec<String>,
    /// Folders that failed while the rest synced, as `folder: error`.
    pub folder_errors: Vec<String>,
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

fn security(s: &str) -> Result<Security> {
    Security::parse(s).ok_or_else(|| anyhow!("unknown security {s:?}; use tls or starttls"))
}

fn server(dto: &ServerDto) -> Result<(String, u16, Security)> {
    let host = dto.host.trim().to_string();
    if host.is_empty() {
        return Err(anyhow!("server name is empty"));
    }
    if dto.port == 0 {
        return Err(anyhow!("port is empty"));
    }
    Ok((host, dto.port, security(&dto.security)?))
}

/// Register an account; the password goes to the OS keychain. Fails when the address is
/// already added, so a second add cannot overwrite a working password.
pub fn add_imap_account(
    email: String,
    display_name: String,
    imap: ServerDto,
    smtp: ServerDto,
    local_bridge: bool,
    password: String,
) -> Result<AccountDto> {
    let (imap_host, imap_port, imap_security) = server(&imap)?;
    let (smtp_host, smtp_port, smtp_security) = server(&smtp)?;
    let c = core()?;
    let a = c.add_account(
        &NewAccount {
            kind: if imap_host.contains("gmail") { ProviderKind::Gmail } else { ProviderKind::Imap },
            email: email.trim().to_string(),
            display_name: display_name.trim().to_string(),
            imap_host,
            imap_port,
            smtp_host,
            smtp_port,
            auth: AuthKind::Password,
            imap_security,
            smtp_security: Some(smtp_security),
            local_bridge,
        },
        &password,
    )?;
    Ok(account_dto(a, 0))
}

fn account_dto(a: mailcore::Account, unread: u32) -> AccountDto {
    let (smtp_host, smtp_port) = if a.smtp_host.is_empty() {
        mailcore::smtp::guess_smtp(&a.imap_host).unwrap_or_default()
    } else {
        (a.smtp_host.clone(), a.smtp_port)
    };
    let smtp_security = a
        .smtp_security
        .unwrap_or(if smtp_port == 465 { Security::Tls } else { Security::StartTls });
    AccountDto {
        id: a.id,
        email: a.email,
        kind: a.kind.as_str().to_string(),
        display_name: a.display_name,
        unread,
        signature: a.signature,
        imap_host: a.imap_host,
        imap_port: a.imap_port,
        imap_security: a.imap_security.as_str().to_string(),
        smtp_host,
        smtp_port,
        smtp_security: smtp_security.as_str().to_string(),
        local_bridge: a.local_bridge,
    }
}

/// Sign in to IMAP once; nothing is stored. The error text carries the server's reason;
/// pass it to [diagnose_error] for something to show.
pub async fn test_imap_login(email: String, imap: ServerDto, local_bridge: bool, password: String) -> Result<()> {
    let (host, port, security) = server(&imap)?;
    let transport = mailcore::Transport { security, local_bridge };
    Ok(Core::check_login(&host, port, transport, email.trim(), &password).await?)
}

/// Sign in to SMTP once without sending anything.
pub async fn test_smtp_login(email: String, smtp: ServerDto, local_bridge: bool, password: String) -> Result<()> {
    let (host, port, security) = server(&smtp)?;
    Ok(Core::check_smtp(&host, port, security, local_bridge, email.trim(), &password).await?)
}

/// The SMTP server usually paired with an IMAP host (`imap.x` → `smtp.x`).
#[frb(sync)]
pub fn suggest_smtp(imap_host: String) -> Option<ServerDto> {
    mailcore::smtp::guess_smtp(imap_host.trim()).map(|(host, port)| ServerDto {
        host,
        port,
        security: if port == 465 { "tls" } else { "starttls" }.to_string(),
    })
}

/// Turn an error from sign-in or sync into a title and a hint.
#[frb(sync)]
pub fn diagnose_error(message: String, host: String) -> DiagnosisDto {
    let d = mailcore::diagnose::diagnose(&message, &host);
    DiagnosisDto {
        kind: match d.kind {
            ErrorKind::Auth => "auth",
            ErrorKind::Network => "network",
            ErrorKind::Tls => "tls",
            ErrorKind::Server => "server",
            ErrorKind::Local => "local",
        }
        .to_string(),
        title: d.title,
        hint: d.hint,
    }
}

/// Replace the stored password of an account (after the server started refusing it).
pub fn update_account_password(id: i64, password: String) -> Result<()> {
    Ok(core()?.set_password(id, &password)?)
}

pub fn remove_account(id: i64) -> Result<()> {
    Ok(core()?.remove_account(id)?)
}

/// Folders one can open or move mail into (`\\Noselect` containers such as `[Gmail]` left
/// out), with names decoded from IMAP's modified UTF-7 for display.
pub fn list_folders(account_id: i64) -> Result<Vec<FolderDto>> {
    Ok(core()?
        .store()
        .folders(account_id)?
        .into_iter()
        .filter(|f| f.selectable)
        .map(|f| FolderDto {
            id: f.id,
            account_id: f.account_id,
            name: f.display_name(),
            role: f.role.as_str().to_string(),
        })
        .collect())
}

// ---------- reading ----------

fn thread_dto(t: mailcore::Thread) -> ThreadDto {
    ThreadDto {
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
        snoozed_until: t.snoozed_until.map(|d| d.timestamp()),
    }
}

pub fn list_threads(query: String, limit: u32) -> Result<Vec<ThreadDto>> {
    Ok(core()?.threads(&query, limit)?.into_iter().map(thread_dto).collect())
}

/// One thread by id, wherever it lives (snoozed, archived, any folder); None when gone.
pub fn get_thread(thread_id: i64) -> Result<Option<ThreadDto>> {
    match core()?.store().thread(thread_id) {
        Ok(t) => Ok(Some(thread_dto(t))),
        Err(mailcore::Error::NotFound(_)) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

pub fn thread_messages(thread_id: i64) -> Result<Vec<MessageDto>> {
    let c = core()?;
    let mut out = Vec::new();
    let mut own: std::collections::HashMap<i64, String> = std::collections::HashMap::new();
    for m in c.store().thread_messages(thread_id)? {
        if let std::collections::hash_map::Entry::Vacant(e) = own.entry(m.account_id) {
            e.insert(c.store().account(m.account_id).map(|a| a.email).unwrap_or_default());
        }
        let is_mine = own.get(&m.account_id).is_some_and(|me| m.from.addr.eq_ignore_ascii_case(me));
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
            styled: html.as_deref().is_some_and(mailcore::sanitize::has_own_colours),
            is_mine,
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
/// The extension (lower case) of an attachment that could run code or open a browser when
/// opened, judged by the name it will be saved under; None for ordinary files.
#[frb(sync)]
pub fn risky_extension(name: String) -> Option<String> {
    mailcore::files::risky_extension(&name)
}

/// The name an attachment is saved under (invisible characters removed, device names
/// renamed): what the chip should show.
#[frb(sync)]
pub fn safe_file_name(name: String) -> String {
    mailcore::files::safe_file_name(&name)
}

pub fn describe_file(path: String) -> Result<DraftAttachmentDto> {
    Ok(attachment_to_dto(DraftAttachment::from_path(&PathBuf::from(path))?))
}

pub fn unread_count() -> Result<u32> {
    Ok(core()?.store().unread_count(None)?)
}

// ---------- actions (local-first, replayed on sync) ----------

/// Archive or Delete had nowhere to put mail.
pub struct MissingFolderDto {
    pub account_id: i64,
    /// `archive` or `trash`.
    pub role: String,
    /// Gmail hides the folder from IMAP: the switch is in Gmail's settings, not here.
    pub gmail: bool,
    pub message: String,
}

pub struct FiledDto {
    /// How many messages moved (0: not in the inbox, or already in Trash).
    pub moved: u32,
    pub missing: Option<MissingFolderDto>,
}

fn filed(r: mailcore::Result<usize>) -> Result<FiledDto> {
    match r {
        Ok(n) => Ok(FiledDto { moved: n as u32, missing: None }),
        Err(e @ mailcore::Error::NoFolder { account_id, role, gmail }) => Ok(FiledDto {
            moved: 0,
            missing: Some(MissingFolderDto {
                account_id,
                role: role.as_str().to_string(),
                gmail,
                message: e.to_string(),
            }),
        }),
        Err(e) => Err(e.into()),
    }
}

/// Out of the inbox; `moved` is 0 when it was not there.
pub fn archive_thread(thread_id: i64) -> Result<FiledDto> {
    filed(core()?.actions().archive(thread_id))
}

/// To Trash; `moved` is 0 when it was there already (or only in Sent elsewhere).
pub fn trash_thread(thread_id: i64) -> Result<FiledDto> {
    filed(core()?.actions().trash(thread_id))
}

/// Create the `archive` or `trash` folder the account's server is missing; returns its name.
pub async fn create_role_folder(account_id: i64, role: String) -> Result<String> {
    let role = match role.as_str() {
        "archive" => FolderRole::Archive,
        "trash" => FolderRole::Trash,
        other => return Err(anyhow!("cannot create a {other} folder")),
    };
    Ok(core()?.create_role_folder(account_id, role).await?)
}

pub fn mark_read(thread_id: i64, read: bool) -> Result<()> {
    Ok(core()?.actions().mark_read(thread_id, read)?)
}

pub fn star_thread(thread_id: i64, on: bool) -> Result<()> {
    Ok(core()?.actions().star(thread_id, on)?)
}

/// "Move to…" any folder of the thread's account; returns how many messages moved.
pub fn move_thread(thread_id: i64, folder_id: i64) -> Result<u32> {
    Ok(core()?.actions().move_to_folder(thread_id, folder_id)? as u32)
}

// ---------- snooze (on this device) ----------

/// Hide the thread from the inbox until `until` (Unix seconds).
pub fn snooze_thread(thread_id: i64, until: i64) -> Result<()> {
    let until = chrono::DateTime::from_timestamp(until, 0).ok_or_else(|| anyhow!("bad time"))?;
    Ok(core()?.actions().snooze(thread_id, until)?)
}

pub fn unsnooze_thread(thread_id: i64) -> Result<()> {
    Ok(core()?.actions().unsnooze(thread_id)?)
}

/// Wake threads whose snooze ended; returns how many woke.
pub fn wake_snoozed() -> Result<u32> {
    Ok(core()?.actions().wake_snoozed(chrono::Utc::now())? as u32)
}

/// When the next snooze ends (Unix seconds), to schedule a wake-up.
pub fn next_snooze_wake() -> Result<Option<i64>> {
    Ok(core()?.store().next_wake()?.map(|d| d.timestamp()))
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
/// Send over SMTP. An error means nothing went out; `Some(text)` means it went out but a
/// later step (the copy in Sent) failed.
pub async fn send_draft(draft: DraftDto) -> Result<Option<String>> {
    let d = dto_to_draft(&draft)?;
    if d.to.is_empty() {
        return Err(anyhow!("no recipients"));
    }
    Ok(core()?.send(draft.account_id, &d).await?.warning)
}

// ---------- sync ----------

pub async fn sync_all(inbox_only: bool) -> Result<SyncSummaryDto> {
    let c = core()?;
    let mut opts = SyncOptions::default();
    if inbox_only {
        opts.roles = vec![FolderRole::Inbox];
    }
    let mut summary =
        SyncSummaryDto { accounts: 0, fetched: 0, removed: 0, errors: vec![], folder_errors: vec![] };
    for (a, r) in c.sync_all(&opts).await? {
        summary.accounts += 1;
        match r {
            Ok(rep) => {
                summary.fetched += rep.fetched as u32;
                summary.removed += rep.removed as u32;
                summary.folder_errors.extend(rep.errors.into_iter().map(|e| format!("{}: {e}", a.email)));
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
    let mut summary =
        SyncSummaryDto { accounts: 1, fetched: 0, removed: 0, errors: vec![], folder_errors: vec![] };
    match c.sync_account(account_id, &opts).await {
        Ok(rep) => {
            summary.fetched = rep.fetched as u32;
            summary.removed = rep.removed as u32;
            summary.folder_errors = rep.errors;
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
