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
    },
    Move {
        folder: String,
        uid: u32,
        dest: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OutboxItem {
    pub id: i64,
    pub account_id: i64,
    pub op: Op,
    pub attempts: u32,
    pub last_error: Option<String>,
}
