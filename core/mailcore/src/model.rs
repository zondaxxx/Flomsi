use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderKind {
    Imap,
    Gmail,
    Outlook,
    Jmap,
}

impl ProviderKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ProviderKind::Imap => "imap",
            ProviderKind::Gmail => "gmail",
            ProviderKind::Outlook => "outlook",
            ProviderKind::Jmap => "jmap",
        }
    }
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "imap" => ProviderKind::Imap,
            "gmail" => ProviderKind::Gmail,
            "outlook" => ProviderKind::Outlook,
            "jmap" => ProviderKind::Jmap,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthKind {
    /// Plain password or provider app password. Stored in the OS keychain.
    Password,
    /// OAuth2 refresh token exchanged for XOAUTH2 tokens. Stored in the OS keychain.
    XOAuth2,
}

impl AuthKind {
    pub fn as_str(self) -> &'static str {
        match self {
            AuthKind::Password => "password",
            AuthKind::XOAuth2 => "xoauth2",
        }
    }
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "password" => AuthKind::Password,
            "xoauth2" => AuthKind::XOAuth2,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NewAccount {
    pub kind: ProviderKind,
    pub email: String,
    pub display_name: String,
    pub imap_host: String,
    pub imap_port: u16,
    pub smtp_host: String,
    pub smtp_port: u16,
    pub auth: AuthKind,
    pub imap_security: Security,
    /// None: by port, as mail apps usually do (465 TLS, otherwise STARTTLS).
    pub smtp_security: Option<Security>,
    /// Accept a self-signed certificate on 127.0.0.1 (local bridges such as Proton Bridge).
    pub local_bridge: bool,
}

/// How a connection is secured: TLS from the first byte, or STARTTLS on a plain port.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Security {
    #[default]
    Tls,
    StartTls,
}

impl Security {
    pub fn as_str(self) -> &'static str {
        match self {
            Security::Tls => "tls",
            Security::StartTls => "starttls",
        }
    }
    pub fn parse(s: &str) -> Option<Security> {
        match s {
            "tls" => Some(Security::Tls),
            "starttls" => Some(Security::StartTls),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Account {
    pub id: i64,
    pub kind: ProviderKind,
    pub email: String,
    pub display_name: String,
    pub imap_host: String,
    pub imap_port: u16,
    pub smtp_host: String,
    pub smtp_port: u16,
    pub auth: AuthKind,
    /// Plain-text signature; drafts get it below a `-- ` line.
    pub signature: String,
    pub imap_security: Security,
    pub smtp_security: Option<Security>,
    pub local_bridge: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FolderRole {
    Inbox,
    Sent,
    Drafts,
    Trash,
    Junk,
    Archive,
    /// Gmail "All Mail": every message, used as archive target.
    All,
    Starred,
    Other,
}

impl FolderRole {
    pub fn as_str(self) -> &'static str {
        match self {
            FolderRole::Inbox => "inbox",
            FolderRole::Sent => "sent",
            FolderRole::Drafts => "drafts",
            FolderRole::Trash => "trash",
            FolderRole::Junk => "junk",
            FolderRole::Archive => "archive",
            FolderRole::All => "all",
            FolderRole::Starred => "starred",
            FolderRole::Other => "other",
        }
    }
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "inbox" => FolderRole::Inbox,
            "sent" => FolderRole::Sent,
            "drafts" => FolderRole::Drafts,
            "trash" => FolderRole::Trash,
            "junk" | "spam" => FolderRole::Junk,
            "archive" => FolderRole::Archive,
            "all" => FolderRole::All,
            "starred" => FolderRole::Starred,
            "other" => FolderRole::Other,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Folder {
    pub id: i64,
    pub account_id: i64,
    pub remote_name: String,
    pub role: FolderRole,
    pub uidvalidity: Option<u32>,
    pub uidnext: Option<u32>,
    pub highest_modseq: Option<u64>,
    pub last_sync_at: Option<DateTime<Utc>>,
    /// False for `\Noselect` containers such as Gmail's `[Gmail]`.
    pub selectable: bool,
}

/// IMAP-style message flags as a bitmask.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Flags(pub u32);

impl Flags {
    pub const SEEN: Flags = Flags(1);
    pub const FLAGGED: Flags = Flags(2);
    pub const ANSWERED: Flags = Flags(4);
    pub const DRAFT: Flags = Flags(8);
    pub const DELETED: Flags = Flags(16);

    pub fn contains(self, other: Flags) -> bool {
        self.0 & other.0 == other.0
    }
    pub fn with(self, other: Flags) -> Flags {
        Flags(self.0 | other.0)
    }
    pub fn without(self, other: Flags) -> Flags {
        Flags(self.0 & !other.0)
    }
    pub fn is_unread(self) -> bool {
        !self.contains(Flags::SEEN)
    }
    pub fn is_starred(self) -> bool {
        self.contains(Flags::FLAGGED)
    }
    /// IMAP flag atoms for a STORE command, e.g. `(\Seen \Flagged)`.
    pub fn imap_atoms(self) -> String {
        let mut v = Vec::new();
        if self.contains(Flags::SEEN) {
            v.push("\\Seen");
        }
        if self.contains(Flags::FLAGGED) {
            v.push("\\Flagged");
        }
        if self.contains(Flags::ANSWERED) {
            v.push("\\Answered");
        }
        if self.contains(Flags::DRAFT) {
            v.push("\\Draft");
        }
        if self.contains(Flags::DELETED) {
            v.push("\\Deleted");
        }
        format!("({})", v.join(" "))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Address {
    pub name: Option<String>,
    pub addr: String,
}

impl Address {
    pub fn display(&self) -> String {
        match &self.name {
            Some(n) if !n.is_empty() => n.clone(),
            _ => self.addr.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub id: i64,
    pub account_id: i64,
    pub folder_id: i64,
    pub uid: u32,
    pub message_id: Option<String>,
    pub thread_id: i64,
    pub subject: String,
    pub from: Address,
    pub to: Vec<Address>,
    pub cc: Vec<Address>,
    pub date: DateTime<Utc>,
    pub snippet: String,
    pub flags: Flags,
    pub has_attachment: bool,
    pub size: u64,
}

/// One non-body MIME part. `idx` is its position in mail-parser's attachment order, which is
/// how the bytes are found again later. `inline` parts are images the HTML body references
/// through `cid:`; they render in place and are not listed as attachments.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttachmentMeta {
    pub idx: u32,
    pub name: String,
    pub mime: String,
    pub size: u64,
    pub content_id: Option<String>,
    pub inline: bool,
}

/// A message parsed from raw RFC 822 bytes, before it has database ids.
#[derive(Debug, Clone)]
pub struct ParsedMessage {
    pub message_id: Option<String>,
    pub in_reply_to: Option<String>,
    pub references: Vec<String>,
    pub subject: String,
    pub from: Address,
    pub to: Vec<Address>,
    pub cc: Vec<Address>,
    pub date: DateTime<Utc>,
    pub snippet: String,
    pub has_attachment: bool,
    pub attachments: Vec<AttachmentMeta>,
    pub text: Option<String>,
    pub html: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Thread {
    pub id: i64,
    pub account_id: i64,
    pub subject: String,
    pub participants: Vec<String>,
    pub last_date: DateTime<Utc>,
    pub msg_count: u32,
    pub unread_count: u32,
    pub snippet: String,
    pub has_attachment: bool,
    pub starred: bool,
    /// When a snooze ends (future: hidden from the inbox) or ended (past: it woke up).
    pub snoozed_until: Option<DateTime<Utc>>,
}

/// A user action, applied locally first and replayed to the provider from the outbox.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Op {
    SetFlags {
        folder: String,
        uid: u32,
        add: Flags,
        remove: Flags,
        /// The folder's UIDVALIDITY when the action was taken; the UID means nothing
        /// under another one. None for ops queued before this was recorded.
        #[serde(default)]
        uidvalidity: Option<u32>,
        /// Other local copies the action changed (Gmail: the same message under other
        /// labels), to protect while the op waits and to restore if it is given up.
        #[serde(default)]
        also: Vec<LocalCopy>,
    },
    Move {
        folder: String,
        uid: u32,
        dest: String,
        #[serde(default)]
        uidvalidity: Option<u32>,
        #[serde(default)]
        also: Vec<LocalCopy>,
    },
    /// What is left of a move on a server without MOVE once its COPY went through: mark
    /// the original deleted and expunge it. (A COPY is never repeated.)
    Delete {
        folder: String,
        uid: u32,
        #[serde(default)]
        uidvalidity: Option<u32>,
        #[serde(default)]
        also: Vec<LocalCopy>,
    },
}

/// A message copy in the local cache: folder (remote name) and UID.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalCopy {
    pub folder: String,
    pub uid: u32,
}

impl Op {
    pub fn folder(&self) -> &str {
        match self {
            Op::SetFlags { folder, .. } | Op::Move { folder, .. } | Op::Delete { folder, .. } => {
                folder
            }
        }
    }
    pub fn uid(&self) -> u32 {
        match self {
            Op::SetFlags { uid, .. } | Op::Move { uid, .. } | Op::Delete { uid, .. } => *uid,
        }
    }
    pub fn uidvalidity(&self) -> Option<u32> {
        match self {
            Op::SetFlags { uidvalidity, .. }
            | Op::Move { uidvalidity, .. }
            | Op::Delete { uidvalidity, .. } => *uidvalidity,
        }
    }
    /// Every local copy the op changed: its own, then the others.
    pub fn touched(&self) -> Vec<LocalCopy> {
        let also = match self {
            Op::SetFlags { also, .. } | Op::Move { also, .. } | Op::Delete { also, .. } => also,
        };
        let mut v = vec![LocalCopy {
            folder: self.folder().to_string(),
            uid: self.uid(),
        }];
        v.extend(also.iter().cloned());
        v
    }
    /// True for ops that took a message out of its folder locally.
    pub fn removes(&self) -> bool {
        !matches!(self, Op::SetFlags { .. })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OutboxItem {
    pub id: i64,
    pub account_id: i64,
    pub op: Op,
    pub attempts: u32,
    pub last_error: Option<String>,
}
