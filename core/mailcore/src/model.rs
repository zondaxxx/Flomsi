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
    /// The hierarchy separator the server uses (`/`, `.`), when known.
    pub delimiter: Option<String>,
    /// The oldest UID the sync covers; older cached mail came from a search.
    pub floor_uid: Option<u32>,
}

impl Folder {
    /// The name people see: decoded from modified UTF-7, without the server's own prefix
    /// (`[Gmail]/`, `INBOX.`), levels joined with ` / `.
    pub fn display_name(&self) -> String {
        display_name(&self.remote_name, self.delimiter.as_deref())
    }
}

/// See [Folder::display_name].
pub fn display_name(remote: &str, delimiter: Option<&str>) -> String {
    let decoded = crate::provider::imap::decode_folder_name(remote);
    let Some(d) = delimiter.filter(|d| !d.is_empty()) else {
        return decoded;
    };
    let mut parts: Vec<&str> = decoded.split(d).filter(|p| !p.is_empty()).collect();
    if parts.len() > 1 {
        let first = parts[0];
        let namespace =
            first.eq_ignore_ascii_case("INBOX") || (first.starts_with('[') && first.ends_with(']'));
        if namespace {
            parts.remove(0);
        }
    }
    parts.join(" / ")
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
    /// The name to show for this address. Direction overrides, invisible and control
    /// characters are removed and spaces collapsed, so a name cannot reorder or push away
    /// the address shown next to it. A name that looks like an address (`@`, `<`, `>`) is
    /// not trusted: the real address is shown instead.
    pub fn display(&self) -> String {
        let name = self.name.as_deref().map(clean_name).unwrap_or_default();
        if name.is_empty() || name.contains(['@', '<', '>']) {
            self.addr.clone()
        } else {
            name
        }
    }
}

/// A display name without characters that change how the text around it reads.
pub fn clean_name(name: &str) -> String {
    name.chars()
        .filter(|c| !crate::files::invisible(*c))
        .map(|c| {
            if c.is_control() || c.is_whitespace() {
                ' '
            } else {
                c
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
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
    /// Empty Trash or Spam: every message under `below` (the folder's UIDNEXT when the user
    /// asked) is deleted for good, but those in `keep`: mail a queued restore or "not spam"
    /// takes out. Mail that arrived since stays.
    Empty {
        folder: String,
        below: u32,
        #[serde(default)]
        uidvalidity: Option<u32>,
        #[serde(default)]
        keep: Vec<u32>,
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
            Op::SetFlags { folder, .. }
            | Op::Move { folder, .. }
            | Op::Delete { folder, .. }
            | Op::Empty { folder, .. } => folder,
        }
    }
    pub fn uidvalidity(&self) -> Option<u32> {
        match self {
            Op::SetFlags { uidvalidity, .. }
            | Op::Move { uidvalidity, .. }
            | Op::Delete { uidvalidity, .. }
            | Op::Empty { uidvalidity, .. } => *uidvalidity,
        }
    }
    /// Every local copy the op changed: its own, then the others. None for emptying a
    /// folder, which names no message (see [Op::below]).
    pub fn touched(&self) -> Vec<LocalCopy> {
        let (uid, also) = match self {
            Op::SetFlags { uid, also, .. }
            | Op::Move { uid, also, .. }
            | Op::Delete { uid, also, .. } => (*uid, also),
            Op::Empty { .. } => return Vec::new(),
        };
        let mut v = vec![LocalCopy {
            folder: self.folder().to_string(),
            uid,
        }];
        v.extend(also.iter().cloned());
        v
    }
    /// Every UID of [Op::folder] under this one is on its way out, but those in [Op::keep];
    /// 0 for all but emptying.
    pub fn below(&self) -> u32 {
        match self {
            Op::Empty { below, .. } => *below,
            _ => 0,
        }
    }
    /// The UIDs under [Op::below] that emptying leaves.
    pub fn keep(&self) -> &[u32] {
        match self {
            Op::Empty { keep, .. } => keep,
            _ => &[],
        }
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

#[cfg(test)]
mod tests {
    use super::Address;

    fn shown(name: &str, addr: &str) -> String {
        Address {
            name: Some(name.into()),
            addr: addr.into(),
        }
        .display()
    }

    #[test]
    fn a_display_name_cannot_pose_as_another_address() {
        assert_eq!(shown("Anna Sokolova", "anna@studio.dev"), "Anna Sokolova");
        // An override would turn the address that follows around.
        assert_eq!(shown("PayPal\u{202E}", "moc.lapyap@evil.io"), "PayPal");
        assert_eq!(
            shown("Anna Sokolova <anna@studio.dev>", "x@evil.example"),
            "x@evil.example"
        );
        assert_eq!(shown("anna@studio.dev", "x@evil.example"), "x@evil.example");
        // Padding and line breaks cannot push the address out of a one-line label.
        assert_eq!(
            shown("Anna\u{2028}\n   Sokolova\t\t", "a@s.dev"),
            "Anna Sokolova"
        );
        assert_eq!(shown("\u{200B}\u{2066}", "a@s.dev"), "a@s.dev");
    }
}
