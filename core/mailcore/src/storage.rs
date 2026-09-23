//! SQLite cache. One database per profile, WAL mode, FTS5 for search.

use crate::compose::{Draft, SavedDraft};
use crate::error::{Error, Result};
use crate::model::*;
use crate::search::Query;
use crate::threading;
use chrono::{DateTime, TimeZone, Utc};
use rusqlite::{params, params_from_iter, Connection, OptionalExtension, Row};
use std::collections::HashSet;
use std::path::Path;
use std::sync::Mutex;

const SCHEMA_VERSION: i32 = 8;

const SCHEMA_V1: &str = r#"
CREATE TABLE accounts (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,
  email TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL DEFAULT '',
  imap_host TEXT NOT NULL,
  imap_port INTEGER NOT NULL,
  smtp_host TEXT NOT NULL DEFAULT '',
  smtp_port INTEGER NOT NULL DEFAULT 0,
  auth_kind TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE folders (
  id INTEGER PRIMARY KEY,
  account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  remote_name TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'other',
  uidvalidity INTEGER,
  uidnext INTEGER,
  highest_modseq INTEGER,
  last_sync_at INTEGER,
  UNIQUE(account_id, remote_name)
);
CREATE TABLE threads (
  id INTEGER PRIMARY KEY,
  account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  subject TEXT NOT NULL DEFAULT '',
  subject_norm TEXT NOT NULL DEFAULT '',
  last_date INTEGER NOT NULL DEFAULT 0,
  msg_count INTEGER NOT NULL DEFAULT 0,
  unread_count INTEGER NOT NULL DEFAULT 0,
  snippet TEXT NOT NULL DEFAULT '',
  has_attachment INTEGER NOT NULL DEFAULT 0,
  starred INTEGER NOT NULL DEFAULT 0,
  participants TEXT NOT NULL DEFAULT '[]'
);
CREATE INDEX threads_account_date ON threads(account_id, last_date DESC);
CREATE INDEX threads_subject ON threads(account_id, subject_norm);
CREATE TABLE messages (
  id INTEGER PRIMARY KEY,
  account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
  uid INTEGER NOT NULL,
  message_id TEXT,
  thread_id INTEGER NOT NULL REFERENCES threads(id),
  subject TEXT NOT NULL DEFAULT '',
  from_name TEXT,
  from_addr TEXT NOT NULL DEFAULT '',
  to_json TEXT NOT NULL DEFAULT '[]',
  cc_json TEXT NOT NULL DEFAULT '[]',
  date INTEGER NOT NULL,
  snippet TEXT NOT NULL DEFAULT '',
  flags INTEGER NOT NULL DEFAULT 0,
  has_attachment INTEGER NOT NULL DEFAULT 0,
  size INTEGER NOT NULL DEFAULT 0,
  UNIQUE(folder_id, uid)
);
CREATE INDEX messages_thread ON messages(thread_id);
CREATE INDEX messages_msgid ON messages(account_id, message_id);
CREATE INDEX messages_date ON messages(date DESC);
CREATE TABLE bodies (
  message_id INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
  text TEXT,
  html TEXT
);
CREATE VIRTUAL TABLE messages_fts USING fts5(subject, from_text, to_text, body, tokenize='unicode61 remove_diacritics 2');
CREATE TABLE labels (
  id INTEGER PRIMARY KEY,
  account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  color TEXT,
  UNIQUE(account_id, name)
);
CREATE TABLE message_labels (
  message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  label_id INTEGER NOT NULL REFERENCES labels(id) ON DELETE CASCADE,
  PRIMARY KEY(message_id, label_id)
);
CREATE TABLE outbox (
  id INTEGER PRIMARY KEY,
  account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  op_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  done INTEGER NOT NULL DEFAULT 0
);
"#;

/// v2: attachment metadata and a compressed copy of raw messages. v1 caches carry no
/// attachment rows, so the message cache is dropped and rebuilt by the next sync (the server
/// stays the source of truth; accounts, labels and the outbox are kept).
const SCHEMA_V2: &str = r#"
CREATE TABLE attachments (
  message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  idx INTEGER NOT NULL,
  name TEXT NOT NULL,
  mime TEXT NOT NULL,
  size INTEGER NOT NULL DEFAULT 0,
  content_id TEXT,
  inline INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(message_id, idx)
);
CREATE TABLE raw_messages (
  message_id INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
  data BLOB NOT NULL
);
"#;

/// v3: drafts kept on this device while they are written (autosave).
const SCHEMA_V3: &str = r#"
CREATE TABLE drafts (
  id INTEGER PRIMARY KEY,
  account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  kind TEXT NOT NULL DEFAULT 'fresh',
  draft_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX drafts_updated ON drafts(updated_at DESC);
"#;

/// v4: per-account signatures and a small key/value table for app preferences.
const SCHEMA_V4: &str = r#"
ALTER TABLE accounts ADD COLUMN signature TEXT NOT NULL DEFAULT '';
CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
"#;

/// v5: snoozes, kept on this device. Keyed by the thread's root Message-ID so they survive
/// a rebuilt cache; `thread_id` is a cached pointer that `rebind_snoozes` refreshes.
const SCHEMA_V5: &str = r#"
CREATE TABLE snoozes (
  account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  thread_key TEXT NOT NULL,
  thread_id INTEGER NOT NULL,
  until INTEGER NOT NULL,
  woke INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(account_id, thread_key)
);
CREATE INDEX snoozes_thread ON snoozes(thread_id);
"#;

/// v6: the search index follows message deletions, including account-removal cascades.
/// Orphaned rows collided with reused message ids and broke the next insert; an id that was
/// reused may already carry another message's text, so the index is rebuilt, not pruned.
const SCHEMA_V6: &str = r#"
DELETE FROM messages_fts;
INSERT INTO messages_fts(rowid, subject, from_text, to_text, body)
SELECT m.id, m.subject,
       COALESCE(m.from_name, '') || ' ' || m.from_addr,
       COALESCE((SELECT group_concat(COALESCE(json_extract(j.value, '$.name'), '') || ' ' || json_extract(j.value, '$.addr'), ' ')
                 FROM (SELECT value FROM json_each(m.to_json) UNION ALL SELECT value FROM json_each(m.cc_json)) AS j), ''),
       COALESCE(b.text, '')
FROM messages m LEFT JOIN bodies b ON b.message_id = m.id;
CREATE TRIGGER messages_fts_cleanup AFTER DELETE ON messages BEGIN
  DELETE FROM messages_fts WHERE rowid = old.id;
END;
"#;

/// v7: one message, several places. Gmail shows a message in INBOX and in All Mail (and in
/// every label); counts, lists and actions work on `dedup_key` (X-GM-MSGID on Gmail, the
/// Message-ID elsewhere) instead of on rows. Folders remember whether they can be selected.
const SCHEMA_V7: &str = r#"
ALTER TABLE messages ADD COLUMN gm_msgid INTEGER;
ALTER TABLE messages ADD COLUMN dedup_key TEXT;
UPDATE messages SET dedup_key = COALESCE(message_id, 'id:' || id);
CREATE INDEX messages_dedup ON messages(account_id, dedup_key);
ALTER TABLE folders ADD COLUMN selectable INTEGER NOT NULL DEFAULT 1;
"#;

/// v8: how each account connects: IMAP TLS or STARTTLS, SMTP mode (empty = by port), and
/// whether a self-signed certificate on 127.0.0.1 is accepted (local bridges).
const SCHEMA_V8: &str = r#"
ALTER TABLE accounts ADD COLUMN imap_security TEXT NOT NULL DEFAULT 'tls';
ALTER TABLE accounts ADD COLUMN smtp_security TEXT NOT NULL DEFAULT '';
ALTER TABLE accounts ADD COLUMN local_bridge INTEGER NOT NULL DEFAULT 0;
"#;

const RESET_MESSAGE_CACHE: &str = r#"
DELETE FROM messages_fts;
DELETE FROM message_labels;
DELETE FROM messages;
DELETE FROM threads;
UPDATE folders SET uidvalidity=NULL, uidnext=NULL, highest_modseq=NULL, last_sync_at=NULL;
"#;

pub struct Store {
    conn: Mutex<Connection>,
}

fn deflate(raw: &[u8]) -> Result<Vec<u8>> {
    use std::io::Write;
    let mut e = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    e.write_all(raw)?;
    Ok(e.finish()?)
}

fn inflate(data: &[u8]) -> Result<Vec<u8>> {
    use std::io::Read;
    let mut out = Vec::new();
    flate2::read::ZlibDecoder::new(data).read_to_end(&mut out)?;
    Ok(out)
}

fn ts(dt: DateTime<Utc>) -> i64 {
    dt.timestamp()
}
fn dt(ts: i64) -> DateTime<Utc> {
    Utc.timestamp_opt(ts, 0).single().unwrap_or_else(Utc::now)
}

impl Store {
    pub fn open(path: &Path) -> Result<Store> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let conn = Connection::open(path)?;
        Self::init(conn)
    }

    pub fn open_in_memory() -> Result<Store> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(mut conn: Connection) -> Result<Store> {
        conn.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY;",
        )?;
        let version: i32 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version > SCHEMA_VERSION {
            // mailctl and the app share ~/.mail_; an older build must not touch a newer schema.
            return Err(Error::Other(format!(
                "this mail database was written by a newer Flomsi (schema {version}, this build knows {SCHEMA_VERSION}); update the app"
            )));
        }
        if version < SCHEMA_VERSION {
            // All steps or none: an interrupted upgrade leaves the previous schema intact.
            let tx = conn.transaction()?;
            if version < 1 {
                tx.execute_batch(SCHEMA_V1)?;
                tx.execute_batch(SCHEMA_V2)?;
            } else if version < 2 {
                tx.execute_batch(SCHEMA_V2)?;
                tx.execute_batch(RESET_MESSAGE_CACHE)?;
            }
            if version < 3 {
                tx.execute_batch(SCHEMA_V3)?;
            }
            if version < 4 {
                tx.execute_batch(SCHEMA_V4)?;
            }
            if version < 5 {
                tx.execute_batch(SCHEMA_V5)?;
            }
            if version < 6 {
                tx.execute_batch(SCHEMA_V6)?;
            }
            if version < 7 {
                tx.execute_batch(SCHEMA_V7)?;
                Self::refresh_all_threads(&tx)?;
            }
            if version < 8 {
                tx.execute_batch(SCHEMA_V8)?;
            }
            tx.pragma_update(None, "user_version", SCHEMA_VERSION)?;
            tx.commit()?;
        }
        Ok(Store {
            conn: Mutex::new(conn),
        })
    }

    fn with<T>(&self, f: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
        let conn = self
            .conn
            .lock()
            .map_err(|_| Error::Other("store lock poisoned".into()))?;
        f(&conn)
    }

    // ---------------- accounts ----------------

    pub fn add_account(&self, a: &NewAccount) -> Result<Account> {
        self.with(|c| {
            c.execute(
                "INSERT INTO accounts(kind,email,display_name,imap_host,imap_port,smtp_host,smtp_port,auth_kind,created_at,imap_security,smtp_security,local_bridge)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)",
                params![
                    a.kind.as_str(), a.email, a.display_name, a.imap_host, a.imap_port,
                    a.smtp_host, a.smtp_port, a.auth.as_str(), ts(Utc::now()),
                    a.imap_security.as_str(), a.smtp_security.map(|s| s.as_str()).unwrap_or(""),
                    a.local_bridge as i64
                ],
            )?;
            let id = c.last_insert_rowid();
            Ok(Account {
                id,
                kind: a.kind,
                email: a.email.clone(),
                display_name: a.display_name.clone(),
                imap_host: a.imap_host.clone(),
                imap_port: a.imap_port,
                smtp_host: a.smtp_host.clone(),
                smtp_port: a.smtp_port,
                auth: a.auth,
                signature: String::new(),
                imap_security: a.imap_security,
                smtp_security: a.smtp_security,
                local_bridge: a.local_bridge,
            })
        })
    }

    /// Name shown in From and the signature appended to new drafts.
    pub fn update_account_profile(
        &self,
        id: i64,
        display_name: &str,
        signature: &str,
    ) -> Result<()> {
        self.with(|c| {
            let n = c.execute(
                "UPDATE accounts SET display_name=?2, signature=?3 WHERE id=?1",
                params![id, display_name, signature],
            )?;
            if n == 0 {
                return Err(Error::NotFound(format!("account {id}")));
            }
            Ok(())
        })
    }

    // ---------------- settings ----------------

    pub fn setting(&self, key: &str) -> Result<Option<String>> {
        self.with(|c| {
            Ok(
                c.query_row("SELECT value FROM settings WHERE key=?1", [key], |r| {
                    r.get(0)
                })
                .optional()?,
            )
        })
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<()> {
        self.with(|c| {
            c.execute(
                "INSERT INTO settings(key, value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                params![key, value],
            )?;
            Ok(())
        })
    }

    fn row_account(r: &Row) -> rusqlite::Result<Account> {
        Ok(Account {
            id: r.get("id")?,
            kind: ProviderKind::parse(&r.get::<_, String>("kind")?).unwrap_or(ProviderKind::Imap),
            email: r.get("email")?,
            display_name: r.get("display_name")?,
            imap_host: r.get("imap_host")?,
            imap_port: r.get::<_, i64>("imap_port")? as u16,
            smtp_host: r.get("smtp_host")?,
            smtp_port: r.get::<_, i64>("smtp_port")? as u16,
            auth: AuthKind::parse(&r.get::<_, String>("auth_kind")?).unwrap_or(AuthKind::Password),
            signature: r.get("signature")?,
            imap_security: Security::parse(&r.get::<_, String>("imap_security")?)
                .unwrap_or_default(),
            smtp_security: Security::parse(&r.get::<_, String>("smtp_security")?),
            local_bridge: r.get::<_, i64>("local_bridge")? != 0,
        })
    }

    pub fn accounts(&self) -> Result<Vec<Account>> {
        self.with(|c| {
            let mut st = c.prepare("SELECT * FROM accounts ORDER BY id")?;
            let rows = st.query_map([], Self::row_account)?;
            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
        })
    }

    pub fn account(&self, id: i64) -> Result<Account> {
        self.with(|c| {
            c.query_row(
                "SELECT * FROM accounts WHERE id=?1",
                [id],
                Self::row_account,
            )
            .optional()?
            .ok_or_else(|| Error::NotFound(format!("account {id}")))
        })
    }

    pub fn delete_account(&self, id: i64) -> Result<()> {
        self.with(|c| {
            c.execute("DELETE FROM accounts WHERE id=?1", [id])?;
            Ok(())
        })
    }

    // ---------------- folders ----------------

    fn row_folder(r: &Row) -> rusqlite::Result<Folder> {
        Ok(Folder {
            id: r.get("id")?,
            account_id: r.get("account_id")?,
            remote_name: r.get("remote_name")?,
            role: FolderRole::parse(&r.get::<_, String>("role")?).unwrap_or(FolderRole::Other),
            uidvalidity: r.get::<_, Option<i64>>("uidvalidity")?.map(|v| v as u32),
            uidnext: r.get::<_, Option<i64>>("uidnext")?.map(|v| v as u32),
            highest_modseq: r.get::<_, Option<i64>>("highest_modseq")?.map(|v| v as u64),
            last_sync_at: r.get::<_, Option<i64>>("last_sync_at")?.map(dt),
            selectable: r.get::<_, i64>("selectable")? != 0,
        })
    }

    pub fn upsert_folder(
        &self,
        account_id: i64,
        remote_name: &str,
        role: FolderRole,
    ) -> Result<Folder> {
        self.upsert_remote_folder(account_id, remote_name, role, true)
    }

    /// A folder as the server lists it, selectable or not (`\Noselect`).
    pub fn upsert_remote_folder(
        &self,
        account_id: i64,
        remote_name: &str,
        role: FolderRole,
        selectable: bool,
    ) -> Result<Folder> {
        self.with(|c| {
            c.execute(
                "INSERT INTO folders(account_id, remote_name, role, selectable) VALUES(?1,?2,?3,?4)
                 ON CONFLICT(account_id, remote_name) DO UPDATE SET role=excluded.role, selectable=excluded.selectable",
                params![account_id, remote_name, role.as_str(), selectable as i64],
            )?;
            c.query_row(
                "SELECT * FROM folders WHERE account_id=?1 AND remote_name=?2",
                params![account_id, remote_name],
                Self::row_folder,
            )
            .map_err(Into::into)
        })
    }

    pub fn folders(&self, account_id: i64) -> Result<Vec<Folder>> {
        self.with(|c| {
            let mut st = c.prepare("SELECT * FROM folders WHERE account_id=?1 ORDER BY id")?;
            let rows = st.query_map([account_id], Self::row_folder)?;
            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
        })
    }

    pub fn folder_by_role(&self, account_id: i64, role: FolderRole) -> Result<Option<Folder>> {
        self.with(|c| {
            c.query_row(
                "SELECT * FROM folders WHERE account_id=?1 AND role=?2 LIMIT 1",
                params![account_id, role.as_str()],
                Self::row_folder,
            )
            .optional()
            .map_err(Into::into)
        })
    }

    pub fn update_folder_state(
        &self,
        folder_id: i64,
        uidvalidity: u32,
        uidnext: u32,
        highest_modseq: Option<u64>,
    ) -> Result<()> {
        self.with(|c| {
            c.execute(
                "UPDATE folders SET uidvalidity=?2, uidnext=?3, highest_modseq=?4, last_sync_at=?5 WHERE id=?1",
                params![folder_id, uidvalidity, uidnext, highest_modseq.map(|v| v as i64), ts(Utc::now())],
            )?;
            Ok(())
        })
    }

    /// Drop every cached message of a folder (UIDVALIDITY changed).
    pub fn reset_folder(&self, folder_id: i64) -> Result<()> {
        self.with(|conn| {
            let tx = rusqlite::Transaction::new_unchecked(
                conn,
                rusqlite::TransactionBehavior::Immediate,
            )?;
            tx.execute("DELETE FROM messages WHERE folder_id=?1", [folder_id])?;
            tx.execute(
                "UPDATE folders SET uidvalidity=NULL, uidnext=NULL, highest_modseq=NULL WHERE id=?1",
                [folder_id],
            )?;
            Self::refresh_all_threads(&tx)?;
            tx.commit()?;
            Ok(())
        })
    }

    pub fn max_uid(&self, folder_id: i64) -> Result<Option<u32>> {
        self.with(|c| {
            let v: Option<i64> = c.query_row(
                "SELECT MAX(uid) FROM messages WHERE folder_id=?1",
                [folder_id],
                |r| r.get(0),
            )?;
            Ok(v.map(|v| v as u32))
        })
    }

    pub fn uids(&self, folder_id: i64) -> Result<Vec<u32>> {
        self.with(|c| {
            let mut st = c.prepare("SELECT uid FROM messages WHERE folder_id=?1")?;
            let rows = st.query_map([folder_id], |r| r.get::<_, i64>(0).map(|v| v as u32))?;
            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
        })
    }

    // ---------------- messages ----------------

    /// Insert or update a message by (folder, uid). Assigns a thread. Returns the message id.
    pub fn upsert_message(
        &self,
        account_id: i64,
        folder_id: i64,
        uid: u32,
        flags: Flags,
        size: u64,
        m: &ParsedMessage,
    ) -> Result<i64> {
        self.upsert_fetched(account_id, folder_id, uid, flags, size, None, m)
    }

    /// Like `upsert_message`, with Gmail's X-GM-MSGID when the server gave one.
    #[allow(clippy::too_many_arguments)]
    pub fn upsert_fetched(
        &self,
        account_id: i64,
        folder_id: i64,
        uid: u32,
        flags: Flags,
        size: u64,
        gm_msgid: Option<u64>,
        m: &ParsedMessage,
    ) -> Result<i64> {
        self.with(|conn| {
            // Message, body, parts, index row and thread counters land together or not at all.
            // IMMEDIATE takes the write lock up front, so another process writing (mailctl
            // shares the file) makes this wait on the busy timeout instead of failing when
            // the first SELECT would have to upgrade to a write.
            let tx = rusqlite::Transaction::new_unchecked(
                conn,
                rusqlite::TransactionBehavior::Immediate,
            )?;
            let id =
                Self::upsert_message_in(&tx, account_id, folder_id, uid, flags, size, gm_msgid, m)?;
            tx.commit()?;
            Ok(id)
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn upsert_message_in(
        c: &Connection,
        account_id: i64,
        folder_id: i64,
        uid: u32,
        flags: Flags,
        size: u64,
        gm_msgid: Option<u64>,
        m: &ParsedMessage,
    ) -> Result<i64> {
        {
            let existing: Option<i64> = c
                .query_row(
                    "SELECT id FROM messages WHERE folder_id=?1 AND uid=?2",
                    params![folder_id, uid],
                    |r| r.get(0),
                )
                .optional()?;
            if let Some(id) = existing {
                c.execute(
                    "UPDATE messages SET flags=?2 WHERE id=?1",
                    params![id, flags.0],
                )?;
                return Ok(id);
            }
            let thread_id = Self::assign_thread(c, account_id, folder_id, m)?;
            c.execute(
                "INSERT INTO messages(account_id,folder_id,uid,message_id,thread_id,subject,from_name,from_addr,to_json,cc_json,date,snippet,flags,has_attachment,size)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)",
                params![
                    account_id, folder_id, uid, m.message_id, thread_id, m.subject, m.from.name, m.from.addr,
                    serde_json::to_string(&m.to)?, serde_json::to_string(&m.cc)?, ts(m.date), m.snippet,
                    flags.0, m.has_attachment as i64, size as i64
                ],
            )?;
            let id = c.last_insert_rowid();
            let dedup_key = match (gm_msgid, &m.message_id) {
                (Some(g), _) => format!("gm:{g}"),
                (None, Some(mid)) => mid.clone(),
                (None, None) => format!("id:{id}"),
            };
            c.execute(
                "UPDATE messages SET dedup_key=?2, gm_msgid=?3 WHERE id=?1",
                params![id, dedup_key, gm_msgid.map(|g| g as i64)],
            )?;
            // Copies cached before X-GM-MSGID was fetched (schema v6 and older) carry the
            // Message-ID as key: move them onto the Gmail key so one message counts once.
            if let (Some(g), Some(mid)) = (gm_msgid, &m.message_id) {
                let stale: Vec<i64> = {
                    let mut st = c.prepare(
                        "SELECT DISTINCT thread_id FROM messages
                         WHERE account_id=?1 AND message_id=?2 AND gm_msgid IS NULL AND id<>?3",
                    )?;
                    let v = st
                        .query_map(params![account_id, mid, id], |r| r.get(0))?
                        .collect::<rusqlite::Result<_>>()?;
                    v
                };
                if !stale.is_empty() {
                    c.execute(
                        "UPDATE messages SET gm_msgid=?1, dedup_key=?2
                         WHERE account_id=?3 AND message_id=?4 AND gm_msgid IS NULL",
                        params![g as i64, format!("gm:{g}"), account_id, mid],
                    )?;
                    for tid in stale {
                        Self::refresh_thread(c, tid)?;
                    }
                }
            }
            c.execute(
                "INSERT INTO bodies(message_id, text, html) VALUES(?1,?2,?3)",
                params![id, m.text, m.html],
            )?;
            for a in &m.attachments {
                c.execute(
                    "INSERT INTO attachments(message_id, idx, name, mime, size, content_id, inline) VALUES(?1,?2,?3,?4,?5,?6,?7)",
                    params![id, a.idx, a.name, a.mime, a.size as i64, a.content_id, a.inline as i64],
                )?;
            }
            let from_text = format!(
                "{} {}",
                m.from.name.clone().unwrap_or_default(),
                m.from.addr
            );
            let to_text =
                m.to.iter()
                    .chain(m.cc.iter())
                    .map(|a| format!("{} {}", a.name.clone().unwrap_or_default(), a.addr))
                    .collect::<Vec<_>>()
                    .join(" ");
            c.execute(
                "INSERT INTO messages_fts(rowid, subject, from_text, to_text, body) VALUES(?1,?2,?3,?4,?5)",
                params![id, m.subject, from_text, to_text, m.text.clone().unwrap_or_default()],
            )?;
            Self::refresh_thread(c, thread_id)?;
            Ok(id)
        }
    }

    fn assign_thread(
        c: &Connection,
        account_id: i64,
        folder_id: i64,
        m: &ParsedMessage,
    ) -> Result<i64> {
        // Spam and Trash keep their own conversations: a deleted reply or a spam "Re:" must
        // not join (and become the reply target of) a live conversation.
        let role: String =
            c.query_row("SELECT role FROM folders WHERE id=?1", [folder_id], |r| {
                r.get(0)
            })?;
        let zone = |col: &str| match role.as_str() {
            "junk" => format!("{col} = 'junk'"),
            "trash" => format!("{col} = 'trash'"),
            _ => format!("{col} NOT IN ('junk', 'trash')"),
        };
        // 1. References / In-Reply-To
        let mut candidates: Vec<&str> = m.references.iter().map(|s| s.as_str()).collect();
        if let Some(irt) = &m.in_reply_to {
            candidates.push(irt.as_str());
        }
        if let Some(mid) = &m.message_id {
            candidates.push(mid.as_str());
        }
        if !candidates.is_empty() {
            let placeholders = vec!["?"; candidates.len()].join(",");
            let sql = format!(
                "SELECT m.thread_id FROM messages m JOIN folders f ON f.id = m.folder_id
                 WHERE m.account_id=? AND m.message_id IN ({placeholders}) AND {}
                 ORDER BY m.date DESC LIMIT 1",
                zone("f.role")
            );
            let mut st = c.prepare(&sql)?;
            let mut p: Vec<rusqlite::types::Value> = vec![account_id.into()];
            p.extend(
                candidates
                    .iter()
                    .map(|s| rusqlite::types::Value::from(s.to_string())),
            );
            if let Some(tid) = st
                .query_row(params_from_iter(p), |r| r.get::<_, i64>(0))
                .optional()?
            {
                return Ok(tid);
            }
        }
        // 2. Reply-looking subject within 30 days
        let norm = threading::normalize_subject(&m.subject);
        if threading::is_reply(&m.subject) && !norm.is_empty() && role != "junk" {
            let since = ts(m.date) - 30 * 86_400;
            let sql = format!(
                "SELECT t.id FROM threads t WHERE t.account_id=?1 AND t.subject_norm=?2 AND t.last_date>=?3
                   AND EXISTS (SELECT 1 FROM messages mm JOIN folders ff ON ff.id = mm.folder_id
                               WHERE mm.thread_id = t.id AND {})
                 ORDER BY t.last_date DESC LIMIT 1",
                zone("ff.role")
            );
            if let Some(tid) = c
                .query_row(&sql, params![account_id, norm, since], |r| {
                    r.get::<_, i64>(0)
                })
                .optional()?
            {
                return Ok(tid);
            }
        }
        // 3. New thread
        c.execute(
            "INSERT INTO threads(account_id, subject, subject_norm, last_date) VALUES(?1,?2,?3,?4)",
            params![account_id, m.subject, norm, ts(m.date)],
        )?;
        Ok(c.last_insert_rowid())
    }

    /// Recompute a thread's aggregates from its messages. Deletes the thread when empty.
    fn refresh_thread(c: &Connection, thread_id: i64) -> Result<()> {
        // Copies of one message (INBOX + All Mail on Gmail) count once.
        let count: i64 = c.query_row(
            "SELECT COUNT(DISTINCT dedup_key) FROM messages WHERE thread_id=?1",
            [thread_id],
            |r| r.get(0),
        )?;
        if count == 0 {
            c.execute("DELETE FROM threads WHERE id=?1", [thread_id])?;
            return Ok(());
        }
        let mut st = c.prepare(
            "SELECT from_name, from_addr FROM messages WHERE thread_id=?1 ORDER BY date",
        )?;
        let mut participants: Vec<String> = Vec::new();
        for row in st.query_map([thread_id], |r| {
            Ok((r.get::<_, Option<String>>(0)?, r.get::<_, String>(1)?))
        })? {
            let (name, addr) = row?;
            let p = name.filter(|n| !n.is_empty()).unwrap_or(addr);
            if !participants.contains(&p) {
                participants.push(p);
            }
        }
        c.execute(
            "UPDATE threads SET
               last_date=(SELECT MAX(date) FROM messages WHERE thread_id=?1),
               msg_count=?2,
               unread_count=(SELECT COUNT(*) FROM (
                   SELECT mu.dedup_key FROM messages mu JOIN folders fu ON fu.id = mu.folder_id
                   WHERE mu.thread_id=?1 GROUP BY mu.dedup_key
                   HAVING COALESCE(MIN(CASE WHEN fu.role = 'inbox' THEN mu.flags & 1 END),
                                   MAX(mu.flags & 1)) = 0)),
               snippet=(SELECT snippet FROM messages WHERE thread_id=?1 ORDER BY date DESC LIMIT 1),
               subject=(SELECT subject FROM messages WHERE thread_id=?1 ORDER BY date ASC LIMIT 1),
               has_attachment=(SELECT MAX(has_attachment) FROM messages WHERE thread_id=?1),
               starred=(SELECT MAX(flags & 2) FROM messages WHERE thread_id=?1) > 0,
               participants=?3
             WHERE id=?1",
            params![thread_id, count, serde_json::to_string(&participants)?],
        )?;
        Ok(())
    }

    fn refresh_all_threads(c: &Connection) -> Result<()> {
        let ids: Vec<i64> = {
            let mut st = c.prepare("SELECT id FROM threads")?;
            let v = st
                .query_map([], |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            v
        };
        for id in ids {
            Self::refresh_thread(c, id)?;
        }
        Ok(())
    }

    pub fn set_flags_by_uid(&self, folder_id: i64, uid: u32, flags: Flags) -> Result<()> {
        self.with(|c| {
            let tid: Option<i64> = c
                .query_row(
                    "SELECT thread_id FROM messages WHERE folder_id=?1 AND uid=?2",
                    params![folder_id, uid],
                    |r| r.get(0),
                )
                .optional()?;
            c.execute(
                "UPDATE messages SET flags=?3 WHERE folder_id=?1 AND uid=?2",
                params![folder_id, uid, flags.0],
            )?;
            if let Some(tid) = tid {
                Self::refresh_thread(c, tid)?;
            }
            Ok(())
        })
    }

    pub fn delete_by_uid(&self, folder_id: i64, uid: u32) -> Result<()> {
        self.with(|c| {
            let row: Option<(i64, i64)> = c
                .query_row(
                    "SELECT id, thread_id FROM messages WHERE folder_id=?1 AND uid=?2",
                    params![folder_id, uid],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?;
            if let Some((id, tid)) = row {
                c.execute("DELETE FROM messages WHERE id=?1", [id])?;
                Self::refresh_thread(c, tid)?;
            }
            Ok(())
        })
    }

    fn row_message(r: &Row) -> rusqlite::Result<Message> {
        let to: Vec<Address> =
            serde_json::from_str(&r.get::<_, String>("to_json")?).unwrap_or_default();
        let cc: Vec<Address> =
            serde_json::from_str(&r.get::<_, String>("cc_json")?).unwrap_or_default();
        Ok(Message {
            id: r.get("id")?,
            account_id: r.get("account_id")?,
            folder_id: r.get("folder_id")?,
            uid: r.get::<_, i64>("uid")? as u32,
            message_id: r.get("message_id")?,
            thread_id: r.get("thread_id")?,
            subject: r.get("subject")?,
            from: Address {
                name: r.get("from_name")?,
                addr: r.get("from_addr")?,
            },
            to,
            cc,
            date: dt(r.get("date")?),
            snippet: r.get("snippet")?,
            flags: Flags(r.get::<_, i64>("flags")? as u32),
            has_attachment: r.get::<_, i64>("has_attachment")? != 0,
            size: r.get::<_, i64>("size")? as u64,
        })
    }

    /// Every stored copy of every message in the thread (for actions).
    pub fn thread_copies(&self, thread_id: i64) -> Result<Vec<Message>> {
        self.with(|c| {
            let mut st = c.prepare(
                "SELECT m.* FROM messages m JOIN folders f ON f.id = m.folder_id WHERE m.thread_id=?1
                 ORDER BY m.date ASC,
                   CASE f.role WHEN 'inbox' THEN 0 WHEN 'all' THEN 2 ELSE 1 END, m.id",
            )?;
            let rows = st.query_map([thread_id], Self::row_message)?;
            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
        })
    }

    /// The thread's messages, one per message: the INBOX copy when there is one, All Mail
    /// last. Flagged and answered merge across copies; Seen too, unless the kept copy is the
    /// INBOX one (elsewhere copies are separate messages with their own read state).
    pub fn thread_messages(&self, thread_id: i64) -> Result<Vec<Message>> {
        let copies = self.thread_copies(thread_id)?;
        let keys = self.dedup_keys(thread_id)?;
        let inbox_folders: HashSet<i64> = self.with(|c| {
            let mut st = c.prepare("SELECT id FROM folders WHERE role='inbox'")?;
            let v = st
                .query_map([], |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            Ok(v)
        })?;
        let mut out: Vec<Message> = Vec::new();
        let mut seen: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
        for m in copies {
            let key = keys
                .get(&m.id)
                .cloned()
                .unwrap_or_else(|| format!("id:{}", m.id));
            match seen.get(&key) {
                Some(&i) => {
                    let mut merge = Flags::FLAGGED.0 | Flags::ANSWERED.0;
                    if !inbox_folders.contains(&out[i].folder_id) {
                        merge |= Flags::SEEN.0;
                    }
                    out[i].flags = Flags(out[i].flags.0 | (m.flags.0 & merge));
                }
                None => {
                    seen.insert(key, out.len());
                    out.push(m);
                }
            }
        }
        Ok(out)
    }

    fn dedup_keys(&self, thread_id: i64) -> Result<std::collections::HashMap<i64, String>> {
        self.with(|c| {
            let mut st = c.prepare("SELECT id, dedup_key FROM messages WHERE thread_id=?1")?;
            let rows = st.query_map([thread_id], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, Option<String>>(1)?))
            })?;
            let mut map = std::collections::HashMap::new();
            for row in rows {
                let (id, key) = row?;
                map.insert(id, key.unwrap_or_else(|| format!("id:{id}")));
            }
            Ok(map)
        })
    }

    /// Stable identity of a message across its copies.
    pub fn dedup_key(&self, message_id: i64) -> Result<String> {
        self.with(|c| {
            Ok(c.query_row(
                "SELECT COALESCE(dedup_key, 'id:' || id) FROM messages WHERE id=?1",
                [message_id],
                |r| r.get(0),
            )?)
        })
    }

    pub fn messages_by_message_id(
        &self,
        account_id: i64,
        message_id: &str,
    ) -> Result<Vec<Message>> {
        self.with(|c| {
            let mut st =
                c.prepare("SELECT * FROM messages WHERE account_id=?1 AND message_id=?2")?;
            let rows = st.query_map(params![account_id, message_id], Self::row_message)?;
            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
        })
    }

    pub fn body(&self, message_id: i64) -> Result<(Option<String>, Option<String>)> {
        self.with(|c| {
            c.query_row(
                "SELECT text, html FROM bodies WHERE message_id=?1",
                [message_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?
            .ok_or_else(|| Error::NotFound(format!("body {message_id}")))
        })
    }

    pub fn message(&self, id: i64) -> Result<Message> {
        self.with(|c| {
            c.query_row(
                "SELECT * FROM messages WHERE id=?1",
                [id],
                Self::row_message,
            )
            .optional()?
            .ok_or_else(|| Error::NotFound(format!("message {id}")))
        })
    }

    pub fn folder(&self, id: i64) -> Result<Folder> {
        self.with(|c| {
            c.query_row("SELECT * FROM folders WHERE id=?1", [id], Self::row_folder)
                .optional()?
                .ok_or_else(|| Error::NotFound(format!("folder {id}")))
        })
    }

    /// Every non-body part of a message, inline images included, in parser order.
    pub fn attachments(&self, message_id: i64) -> Result<Vec<AttachmentMeta>> {
        self.with(|c| {
            let mut st = c.prepare(
                "SELECT idx, name, mime, size, content_id, inline FROM attachments WHERE message_id=?1 ORDER BY idx",
            )?;
            let rows = st.query_map([message_id], |r| {
                Ok(AttachmentMeta {
                    idx: r.get::<_, i64>(0)? as u32,
                    name: r.get(1)?,
                    mime: r.get(2)?,
                    size: r.get::<_, i64>(3)? as u64,
                    content_id: r.get(4)?,
                    inline: r.get::<_, i64>(5)? != 0,
                })
            })?;
            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
        })
    }

    /// Keep a compressed copy of the raw message, for attachments and inline images offline.
    pub fn put_raw(&self, message_id: i64, raw: &[u8]) -> Result<()> {
        let data = deflate(raw)?;
        self.with(|c| {
            c.execute(
                "INSERT OR REPLACE INTO raw_messages(message_id, data) VALUES(?1,?2)",
                params![message_id, data],
            )?;
            Ok(())
        })
    }

    /// The cached raw message, or that of a copy with the same Message-ID in another folder
    /// of the same account (Gmail shows one message in INBOX and All Mail).
    pub fn raw(&self, message_id: i64) -> Result<Option<Vec<u8>>> {
        let data: Option<Vec<u8>> = self.with(|c| {
            Ok(c.query_row(
                "SELECT r.data FROM raw_messages r JOIN messages m ON m.id = r.message_id
                 WHERE m.id = ?1
                    OR (m.message_id IS NOT NULL AND (m.account_id, m.message_id) =
                        (SELECT account_id, message_id FROM messages WHERE id = ?1))
                 ORDER BY m.id = ?1 DESC LIMIT 1",
                [message_id],
                |r| r.get(0),
            )
            .optional()?)
        })?;
        data.map(|d| inflate(&d)).transpose()
    }

    /// True when this message, or a same-Message-ID copy, already has its raw bytes cached.
    pub fn has_raw(&self, account_id: i64, message_id: Option<&str>, id: i64) -> Result<bool> {
        self.with(|c| {
            Ok(c.query_row(
                "SELECT EXISTS(SELECT 1 FROM raw_messages r JOIN messages m ON m.id = r.message_id
                 WHERE m.id = ?3 OR (?2 IS NOT NULL AND m.account_id = ?1 AND m.message_id = ?2))",
                params![account_id, message_id, id],
                |r| r.get::<_, i64>(0),
            )? != 0)
        })
    }

    // ---------------- drafts ----------------

    /// Insert a draft, or update it in place when `id` names one that still exists.
    pub fn save_draft(
        &self,
        id: Option<i64>,
        account_id: i64,
        kind: &str,
        draft: &Draft,
    ) -> Result<i64> {
        let json = serde_json::to_string(draft)?;
        let now = Utc::now().timestamp();
        self.with(|c| {
            if let Some(id) = id {
                let changed = c.execute(
                    "UPDATE drafts SET account_id=?2, kind=?3, draft_json=?4, updated_at=?5 WHERE id=?1",
                    params![id, account_id, kind, json, now],
                )?;
                if changed > 0 {
                    return Ok(id);
                }
            }
            c.execute(
                "INSERT INTO drafts(account_id, kind, draft_json, updated_at) VALUES(?1,?2,?3,?4)",
                params![account_id, kind, json, now],
            )?;
            Ok(c.last_insert_rowid())
        })
    }

    fn saved_drafts(&self, sql: &str, args: impl rusqlite::Params) -> Result<Vec<SavedDraft>> {
        let rows: Vec<(i64, i64, String, String, i64)> = self.with(|c| {
            let mut st = c.prepare(sql)?;
            let rows = st.query_map(args, |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
            })?;
            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
        })?;
        rows.into_iter()
            .map(|(id, account_id, kind, json, updated)| {
                Ok(SavedDraft {
                    id,
                    account_id,
                    kind,
                    draft: serde_json::from_str(&json)?,
                    updated_at: dt(updated),
                })
            })
            .collect()
    }

    /// Every saved draft, most recently edited first.
    pub fn drafts(&self) -> Result<Vec<SavedDraft>> {
        self.saved_drafts(
            "SELECT id, account_id, kind, draft_json, updated_at FROM drafts ORDER BY updated_at DESC, id DESC",
            [],
        )
    }

    pub fn draft(&self, id: i64) -> Result<SavedDraft> {
        self.saved_drafts(
            "SELECT id, account_id, kind, draft_json, updated_at FROM drafts WHERE id=?1",
            [id],
        )?
        .pop()
        .ok_or_else(|| Error::NotFound(format!("draft {id}")))
    }

    pub fn delete_draft(&self, id: i64) -> Result<()> {
        self.with(|c| {
            c.execute("DELETE FROM drafts WHERE id=?1", [id])?;
            Ok(())
        })
    }

    // ---------------- threads / search ----------------

    fn row_thread(r: &Row) -> rusqlite::Result<Thread> {
        Ok(Thread {
            id: r.get("id")?,
            account_id: r.get("account_id")?,
            subject: r.get("subject")?,
            participants: serde_json::from_str(&r.get::<_, String>("participants")?)
                .unwrap_or_default(),
            last_date: dt(r.get("last_date")?),
            msg_count: r.get::<_, i64>("msg_count")? as u32,
            unread_count: r.get::<_, i64>("unread_count")? as u32,
            snippet: r.get("snippet")?,
            has_attachment: r.get::<_, i64>("has_attachment")? != 0,
            starred: r.get::<_, i64>("starred")? != 0,
            // Only the list query selects it.
            snoozed_until: r
                .get::<_, Option<i64>>("snoozed_until")
                .ok()
                .flatten()
                .map(dt),
        })
    }

    /// Threads matching a query, newest first. Empty query = unified inbox.
    pub fn threads(&self, q: &Query, limit: u32) -> Result<Vec<Thread>> {
        let mut conds: Vec<String> = Vec::new();
        let mut p: Vec<rusqlite::types::Value> = Vec::new();

        let now = Utc::now().timestamp();
        let role = q.folder.unwrap_or(FolderRole::Inbox);
        if role == FolderRole::Starred {
            conds.push("(m.flags & 2) != 0".into());
        } else if role == FolderRole::Archive {
            // Gmail has no Archive folder: an archived conversation is one in All Mail with no
            // message left in the inbox (or in Spam or Trash).
            conds.push(
                "(f.role = 'archive' OR (f.role = 'all' AND NOT EXISTS (
                   SELECT 1 FROM messages mi JOIN folders fi ON fi.id = mi.folder_id
                   WHERE mi.thread_id = m.thread_id AND fi.role = 'inbox')))"
                    .into(),
            );
        } else {
            conds.push("f.role = ?".into());
            p.push(role.as_str().to_string().into());
        }
        if let Some(from) = &q.from {
            conds.push("(m.from_addr LIKE ? OR m.from_name LIKE ?)".into());
            p.push(format!("%{from}%").into());
            p.push(format!("%{from}%").into());
        }
        if let Some(to) = &q.to {
            conds.push("(m.to_json LIKE ? OR m.cc_json LIKE ?)".into());
            p.push(format!("%{to}%").into());
            p.push(format!("%{to}%").into());
        }
        if let Some(s) = &q.subject {
            conds.push("m.subject LIKE ?".into());
            p.push(format!("%{s}%").into());
        }
        if q.has_attachment {
            conds.push("m.has_attachment = 1".into());
        }
        match q.unread {
            Some(true) => conds.push("(m.flags & 1) = 0".into()),
            Some(false) => conds.push("(m.flags & 1) != 0".into()),
            None => {}
        }
        if q.starred {
            conds.push("(m.flags & 2) != 0".into());
        }
        if let Some(b) = q.before {
            conds.push("m.date < ?".into());
            p.push(ts(b.and_hms_opt(0, 0, 0).unwrap().and_utc()).into());
        }
        if let Some(a) = q.after {
            conds.push("m.date >= ?".into());
            p.push(ts(a.and_hms_opt(0, 0, 0).unwrap().and_utc()).into());
        }
        if let Some(acc) = &q.account {
            conds.push("a.email LIKE ?".into());
            p.push(format!("%{acc}%").into());
        }
        if let Some(label) = &q.label {
            conds.push("m.id IN (SELECT ml.message_id FROM message_labels ml JOIN labels l ON l.id=ml.label_id WHERE l.name=?)".into());
            p.push(label.clone().into());
        }
        if let Some(fts) = q.fts_expression() {
            conds
                .push("m.id IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?)".into());
            p.push(fts.into());
        }
        // Snoozed threads leave the inbox until their time; `in:snoozed` lists exactly those.
        // A thread that woke up sorts by its wake time, so it comes back on top.
        let snooze_filter = if q.snoozed {
            "AND EXISTS (SELECT 1 FROM snoozes s WHERE s.thread_id = t.id AND s.until > ?)"
        } else if role == FolderRole::Inbox && q.folder.is_none() {
            "AND NOT EXISTS (SELECT 1 FROM snoozes s WHERE s.thread_id = t.id AND s.until > ?)"
        } else {
            "AND ? IS NOT NULL"
        };
        p.push(now.into());
        let sql = format!(
            "SELECT t.*, (SELECT s.until FROM snoozes s WHERE s.thread_id = t.id) AS snoozed_until
             FROM threads t WHERE t.id IN (
               SELECT m.thread_id FROM messages m
               JOIN folders f ON f.id = m.folder_id
               JOIN accounts a ON a.id = m.account_id
               WHERE {}
             ) {snooze_filter}
             ORDER BY MAX(t.last_date, COALESCE(
               (SELECT s.until FROM snoozes s WHERE s.thread_id = t.id AND s.until <= ?), 0
             )) DESC LIMIT ?",
            conds.join(" AND ")
        );
        p.push(now.into());
        p.push((limit as i64).into());
        self.with(|c| {
            let mut st = c.prepare(&sql)?;
            let rows = st.query_map(params_from_iter(p), Self::row_thread)?;
            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
        })
    }

    // ---------------- snoozes ----------------

    /// Stable key for a thread: the Message-ID of its first message.
    fn thread_key(c: &Connection, thread_id: i64) -> Result<(i64, String)> {
        c.query_row(
            "SELECT account_id, COALESCE(message_id, 'thread:' || thread_id) FROM messages
             WHERE thread_id=?1 ORDER BY date ASC, id ASC LIMIT 1",
            [thread_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?
        .ok_or_else(|| Error::NotFound(format!("thread {thread_id}")))
    }

    pub fn snooze(&self, thread_id: i64, until: DateTime<Utc>) -> Result<()> {
        self.with(|c| {
            let (account_id, key) = Self::thread_key(c, thread_id)?;
            c.execute(
                "INSERT INTO snoozes(account_id, thread_key, thread_id, until, woke) VALUES(?1,?2,?3,?4,0)
                 ON CONFLICT(account_id, thread_key) DO UPDATE SET thread_id=excluded.thread_id, until=excluded.until, woke=0",
                params![account_id, key, thread_id, ts(until)],
            )?;
            Ok(())
        })
    }

    pub fn unsnooze(&self, thread_id: i64) -> Result<()> {
        self.with(|c| {
            c.execute("DELETE FROM snoozes WHERE thread_id=?1", [thread_id])?;
            Ok(())
        })
    }

    /// Snoozes whose time has come and that have not been woken yet: (thread id, until).
    pub fn due_snoozes(&self, now: DateTime<Utc>) -> Result<Vec<(i64, DateTime<Utc>)>> {
        self.with(|c| {
            let mut st = c.prepare(
                "SELECT thread_id, until FROM snoozes WHERE woke = 0 AND until <= ?1 ORDER BY until",
            )?;
            let rows = st.query_map([ts(now)], |r| Ok((r.get(0)?, dt(r.get(1)?))))?;
            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
        })
    }

    /// Mark woken, and forget snoozes that woke more than a week ago.
    pub fn mark_woken(&self, thread_id: i64, now: DateTime<Utc>) -> Result<()> {
        self.with(|c| {
            c.execute(
                "UPDATE snoozes SET woke = 1 WHERE thread_id=?1",
                [thread_id],
            )?;
            c.execute(
                "DELETE FROM snoozes WHERE woke = 1 AND until < ?1",
                [ts(now) - 7 * 86_400],
            )?;
            Ok(())
        })
    }

    /// The next time a snooze ends, for scheduling a wake-up.
    pub fn next_wake(&self) -> Result<Option<DateTime<Utc>>> {
        self.with(|c| {
            Ok(
                c.query_row("SELECT MIN(until) FROM snoozes WHERE woke = 0", [], |r| {
                    r.get::<_, Option<i64>>(0)
                })?
                .map(dt),
            )
        })
    }

    /// Point snoozes at the current thread ids after a cache rebuild or re-threading.
    pub fn rebind_snoozes(&self) -> Result<()> {
        self.with(|c| {
            c.execute(
                "UPDATE snoozes SET thread_id = COALESCE((SELECT m.thread_id FROM messages m
                   WHERE m.account_id = snoozes.account_id AND m.message_id = snoozes.thread_key
                   LIMIT 1), thread_id)",
                [],
            )?;
            Ok(())
        })
    }

    pub fn thread(&self, id: i64) -> Result<Thread> {
        self.with(|c| {
            c.query_row(
                "SELECT t.*, (SELECT s.until FROM snoozes s WHERE s.thread_id = t.id) AS snoozed_until
                 FROM threads t WHERE t.id=?1",
                [id],
                Self::row_thread,
            )
            .optional()?
            .ok_or_else(|| Error::NotFound(format!("thread {id}")))
        })
    }

    pub fn unread_count(&self, account_id: Option<i64>) -> Result<u32> {
        self.with(|c| {
            let n: i64 = match account_id {
                Some(id) => c.query_row(
                    "SELECT COUNT(DISTINCT m.dedup_key) FROM messages m JOIN folders f ON f.id=m.folder_id WHERE m.account_id=?1 AND f.role='inbox' AND (m.flags & 1)=0",
                    [id],
                    |r| r.get(0),
                )?,
                None => c.query_row(
                    "SELECT COUNT(DISTINCT m.account_id || '|' || m.dedup_key) FROM messages m JOIN folders f ON f.id=m.folder_id WHERE f.role='inbox' AND (m.flags & 1)=0",
                    [],
                    |r| r.get(0),
                )?,
            };
            Ok(n as u32)
        })
    }

    // ---------------- outbox ----------------

    pub fn enqueue(&self, account_id: i64, op: &Op) -> Result<i64> {
        self.with(|c| {
            c.execute(
                "INSERT INTO outbox(account_id, op_json, created_at) VALUES(?1,?2,?3)",
                params![account_id, serde_json::to_string(op)?, ts(Utc::now())],
            )?;
            Ok(c.last_insert_rowid())
        })
    }

    pub fn pending_ops(&self, account_id: i64) -> Result<Vec<OutboxItem>> {
        self.with(|c| {
            let mut st = c.prepare("SELECT id, account_id, op_json, attempts, last_error FROM outbox WHERE account_id=?1 AND done=0 AND attempts<10 ORDER BY id")?;
            let rows = st.query_map([account_id], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, String>(2)?, r.get::<_, i64>(3)?, r.get::<_, Option<String>>(4)?))
            })?;
            let mut out = Vec::new();
            for row in rows {
                let (id, account_id, op_json, attempts, last_error) = row?;
                out.push(OutboxItem { id, account_id, op: serde_json::from_str(&op_json)?, attempts: attempts as u32, last_error });
            }
            Ok(out)
        })
    }

    pub fn mark_done(&self, id: i64) -> Result<()> {
        self.with(|c| {
            c.execute("UPDATE outbox SET done=1 WHERE id=?1", [id])?;
            Ok(())
        })
    }

    pub fn mark_failed(&self, id: i64, err: &str) -> Result<()> {
        self.with(|c| {
            c.execute(
                "UPDATE outbox SET attempts=attempts+1, last_error=?2 WHERE id=?1",
                params![id, err],
            )?;
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn acct(s: &Store) -> Account {
        s.add_account(&NewAccount {
            kind: ProviderKind::Imap,
            email: "t@example.com".into(),
            display_name: "T".into(),
            imap_host: "imap.example.com".into(),
            imap_port: 993,
            smtp_host: "".into(),
            smtp_port: 0,
            auth: AuthKind::Password,
            imap_security: Default::default(),
            smtp_security: None,
            local_bridge: false,
        })
        .unwrap()
    }

    fn msg(
        subject: &str,
        mid: &str,
        refs: &[&str],
        from: &str,
        text: &str,
        day: i64,
    ) -> ParsedMessage {
        ParsedMessage {
            message_id: Some(mid.into()),
            in_reply_to: refs.last().map(|s| s.to_string()),
            references: refs.iter().map(|s| s.to_string()).collect(),
            subject: subject.into(),
            from: Address {
                name: Some(from.into()),
                addr: format!("{}@x.dev", from.to_lowercase()),
            },
            to: vec![],
            cc: vec![],
            date: dt(1_780_000_000 + day * 86_400),
            snippet: text.chars().take(40).collect(),
            has_attachment: false,
            attachments: vec![],
            text: Some(text.into()),
            html: None,
        }
    }

    #[test]
    fn threads_and_search() {
        let s = Store::open_in_memory().unwrap();
        let a = acct(&s);
        let inbox = s.upsert_folder(a.id, "INBOX", FolderRole::Inbox).unwrap();
        s.upsert_message(
            a.id,
            inbox.id,
            1,
            Flags::default(),
            10,
            &msg(
                "Design review",
                "m1@x.dev",
                &[],
                "Anna",
                "glass prototype needs a pass",
                0,
            ),
        )
        .unwrap();
        s.upsert_message(
            a.id,
            inbox.id,
            2,
            Flags::SEEN,
            10,
            &msg(
                "Re: Design review",
                "m2@x.dev",
                &["m1@x.dev"],
                "Zonda",
                "works for me",
                1,
            ),
        )
        .unwrap();
        s.upsert_message(
            a.id,
            inbox.id,
            3,
            Flags::default(),
            10,
            &msg("Invoice", "m3@x.dev", &[], "Hetzner", "paid", 2),
        )
        .unwrap();

        let all = s.threads(&Query::parse(""), 50).unwrap();
        assert_eq!(all.len(), 2);
        assert_eq!(all[0].subject, "Invoice");
        assert_eq!(all[1].msg_count, 2);
        assert_eq!(all[1].unread_count, 1);
        assert_eq!(all[1].participants, vec!["Anna", "Zonda"]);

        let anna = s.threads(&Query::parse("from:anna"), 50).unwrap();
        assert_eq!(anna.len(), 1);
        let fts = s.threads(&Query::parse("glass"), 50).unwrap();
        assert_eq!(fts.len(), 1);
        assert_eq!(fts[0].subject, "Design review");
        let unread = s.threads(&Query::parse("is:unread"), 50).unwrap();
        assert_eq!(unread.len(), 2);
        assert_eq!(s.unread_count(None).unwrap(), 2);

        s.set_flags_by_uid(inbox.id, 1, Flags::SEEN).unwrap();
        assert_eq!(s.thread(all[1].id).unwrap().unread_count, 0);

        s.enqueue(
            a.id,
            &Op::SetFlags {
                folder: "INBOX".into(),
                uid: 1,
                add: Flags::SEEN,
                remove: Flags::default(),
            },
        )
        .unwrap();
        assert_eq!(s.pending_ops(a.id).unwrap().len(), 1);
    }

    #[test]
    fn uidvalidity_reset_clears_folder() {
        let s = Store::open_in_memory().unwrap();
        let a = acct(&s);
        let inbox = s.upsert_folder(a.id, "INBOX", FolderRole::Inbox).unwrap();
        s.upsert_message(
            a.id,
            inbox.id,
            1,
            Flags::default(),
            1,
            &msg("x", "a@x.dev", &[], "A", "b", 0),
        )
        .unwrap();
        s.reset_folder(inbox.id).unwrap();
        assert!(s.threads(&Query::parse(""), 10).unwrap().is_empty());
        assert_eq!(s.max_uid(inbox.id).unwrap(), None);
    }

    #[test]
    fn attachments_and_raw_cache() {
        use crate::testdata::INVOICE_EML;
        let s = Store::open_in_memory().unwrap();
        let a = acct(&s);
        let inbox = s.upsert_folder(a.id, "INBOX", FolderRole::Inbox).unwrap();
        let all = s
            .upsert_folder(a.id, "[Gmail]/All Mail", FolderRole::All)
            .unwrap();
        let parsed = crate::provider::parse::parse_rfc822(INVOICE_EML, Utc::now());
        let id = s
            .upsert_message(a.id, inbox.id, 7, Flags::default(), 100, &parsed)
            .unwrap();
        let copy = s
            .upsert_message(a.id, all.id, 70, Flags::default(), 100, &parsed)
            .unwrap();
        assert_eq!(s.attachments(id).unwrap(), parsed.attachments);
        assert!(s.message(id).unwrap().has_attachment);
        assert_eq!(s.raw(id).unwrap(), None);
        assert!(!s.has_raw(a.id, Some("inv@studio.dev"), copy).unwrap());

        s.put_raw(id, INVOICE_EML).unwrap();
        assert_eq!(s.raw(id).unwrap().as_deref(), Some(INVOICE_EML));
        // The All Mail copy finds the same bytes through its Message-ID.
        assert_eq!(s.raw(copy).unwrap().as_deref(), Some(INVOICE_EML));
        assert!(s.has_raw(a.id, Some("inv@studio.dev"), copy).unwrap());

        // Deleting a message drops its parts and its raw copy.
        s.delete_by_uid(inbox.id, 7).unwrap();
        assert!(s.attachments(id).unwrap().is_empty());
        assert_eq!(s.raw(copy).unwrap(), None);
    }

    #[test]
    fn v1_message_cache_is_rebuilt_on_upgrade() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA_V1).unwrap();
        conn.pragma_update(None, "user_version", 1).unwrap();
        conn.execute_batch(
            "INSERT INTO accounts(kind,email,imap_host,imap_port,auth_kind,created_at) VALUES('imap','t@x','h',993,'password',0);
             INSERT INTO folders(account_id,remote_name,role,uidvalidity,uidnext) VALUES(1,'INBOX','inbox',5,10);
             INSERT INTO threads(account_id,subject) VALUES(1,'s');
             INSERT INTO messages(account_id,folder_id,uid,thread_id,date) VALUES(1,1,3,1,0);",
        )
        .unwrap();
        let s = Store::init(conn).unwrap();
        assert_eq!(s.accounts().unwrap().len(), 1);
        let f = &s.folders(1).unwrap()[0];
        assert_eq!(f.uidvalidity, None);
        assert!(s.uids(f.id).unwrap().is_empty());
        let v: i32 = s
            .with(|c| Ok(c.query_row("PRAGMA user_version", [], |r| r.get(0))?))
            .unwrap();
        assert_eq!(v, SCHEMA_VERSION);
    }

    #[test]
    fn drafts_are_kept_updated_and_removed() {
        let s = Store::open_in_memory().unwrap();
        let a = acct(&s);
        let mut d = Draft::new(Address {
            name: None,
            addr: "t@example.com".into(),
        });
        d.subject = "Plan".into();
        let id = s.save_draft(None, a.id, "fresh", &d).unwrap();
        d.text = "first line".into();
        assert_eq!(s.save_draft(Some(id), a.id, "fresh", &d).unwrap(), id);
        let all = s.drafts().unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].draft, d);
        assert_eq!(all[0].kind, "fresh");
        assert_eq!(s.draft(id).unwrap().draft.text, "first line");

        // A stale id (deleted elsewhere) saves as a new draft instead of failing.
        let other = s.save_draft(Some(9999), a.id, "reply", &d).unwrap();
        assert_ne!(other, id);
        s.delete_draft(id).unwrap();
        assert_eq!(s.drafts().unwrap().len(), 1);
        assert!(s.draft(id).is_err());

        // Removing the account removes its drafts.
        s.delete_account(a.id).unwrap();
        assert!(s.drafts().unwrap().is_empty());
    }

    #[test]
    fn v2_upgrade_adds_drafts_and_keeps_messages() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA_V1).unwrap();
        conn.execute_batch(SCHEMA_V2).unwrap();
        conn.pragma_update(None, "user_version", 2).unwrap();
        conn.execute_batch(
            "INSERT INTO accounts(kind,email,imap_host,imap_port,auth_kind,created_at) VALUES('imap','t@x','h',993,'password',0);
             INSERT INTO folders(account_id,remote_name,role,uidvalidity,uidnext) VALUES(1,'INBOX','inbox',5,10);
             INSERT INTO threads(account_id,subject) VALUES(1,'s');
             INSERT INTO messages(account_id,folder_id,uid,thread_id,date) VALUES(1,1,3,1,0);",
        )
        .unwrap();
        let s = Store::init(conn).unwrap();
        assert_eq!(s.uids(1).unwrap(), vec![3]);
        assert_eq!(s.folders(1).unwrap()[0].uidvalidity, Some(5));
        assert!(s.drafts().unwrap().is_empty());
    }

    #[test]
    fn profiles_and_settings() {
        let s = Store::open_in_memory().unwrap();
        let a = acct(&s);
        assert_eq!(a.signature, "");
        s.update_account_profile(a.id, "Zonda", "Zonda\nflomsi.dev")
            .unwrap();
        let back = s.account(a.id).unwrap();
        assert_eq!(back.display_name, "Zonda");
        assert_eq!(back.signature, "Zonda\nflomsi.dev");
        assert!(s.update_account_profile(999, "x", "").is_err());

        assert_eq!(s.setting("keymap").unwrap(), None);
        s.set_setting("keymap", "gmail").unwrap();
        s.set_setting("keymap", "vim").unwrap();
        assert_eq!(s.setting("keymap").unwrap().as_deref(), Some("vim"));
    }

    #[test]
    fn v3_upgrade_adds_signatures_and_keeps_drafts() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA_V1).unwrap();
        conn.execute_batch(SCHEMA_V2).unwrap();
        conn.execute_batch(SCHEMA_V3).unwrap();
        conn.pragma_update(None, "user_version", 3).unwrap();
        conn.execute_batch(
            "INSERT INTO accounts(kind,email,imap_host,imap_port,auth_kind,created_at) VALUES('imap','t@x','h',993,'password',0);
             INSERT INTO drafts(account_id,kind,draft_json,updated_at) VALUES(1,'fresh','{\"from\":{\"name\":null,\"addr\":\"t@x\"},\"to\":[],\"cc\":[],\"bcc\":[],\"subject\":\"kept\",\"text\":\"\",\"in_reply_to\":null,\"references\":[]}',0);",
        )
        .unwrap();
        let s = Store::init(conn).unwrap();
        assert_eq!(s.account(1).unwrap().signature, "");
        assert_eq!(s.drafts().unwrap()[0].draft.subject, "kept");
        s.set_setting("theme", "light").unwrap();
    }

    #[test]
    fn snoozed_threads_leave_the_inbox_and_come_back_on_top() {
        let s = Store::open_in_memory().unwrap();
        let a = acct(&s);
        let inbox = s.upsert_folder(a.id, "INBOX", FolderRole::Inbox).unwrap();
        let old = s
            .upsert_message(
                a.id,
                inbox.id,
                1,
                Flags::SEEN,
                10,
                &msg("Old", "old@x.dev", &[], "Anna", "a", 0),
            )
            .unwrap();
        s.upsert_message(
            a.id,
            inbox.id,
            2,
            Flags::SEEN,
            10,
            &msg("New", "new@x.dev", &[], "Bob", "b", 5),
        )
        .unwrap();
        let old_thread = s.message(old).unwrap().thread_id;
        let subjects = |q: &str| -> Vec<String> {
            s.threads(&Query::parse(q), 10)
                .unwrap()
                .into_iter()
                .map(|t| t.subject)
                .collect()
        };
        assert_eq!(subjects(""), vec!["New", "Old"]);

        let later = Utc::now() + chrono::Duration::hours(3);
        s.snooze(old_thread, later).unwrap();
        assert_eq!(subjects(""), vec!["New"]);
        assert_eq!(subjects("in:snoozed"), vec!["Old"]);
        let listed = s.threads(&Query::parse("in:snoozed"), 10).unwrap();
        assert_eq!(
            listed[0].snoozed_until.map(|d| d.timestamp()),
            Some(later.timestamp())
        );
        assert_eq!(
            s.thread(old_thread)
                .unwrap()
                .snoozed_until
                .map(|d| d.timestamp()),
            Some(later.timestamp())
        );
        assert_eq!(
            s.next_wake().unwrap().map(|d| d.timestamp()),
            Some(later.timestamp())
        );

        // Time passes: the thread is back, above newer mail, and waking marks it unread.
        let past = Utc::now() - chrono::Duration::minutes(1);
        s.snooze(old_thread, past).unwrap();
        assert_eq!(subjects(""), vec!["Old", "New"]);
        assert!(subjects("in:snoozed").is_empty());
        let actions = crate::sync::Actions { store: &s };
        assert_eq!(actions.wake_snoozed(Utc::now()).unwrap(), 1);
        assert!(!s.message(old).unwrap().flags.contains(Flags::SEEN));
        assert_eq!(s.pending_ops(a.id).unwrap().len(), 1);
        assert_eq!(actions.wake_snoozed(Utc::now()).unwrap(), 0);
        assert_eq!(s.next_wake().unwrap(), None);
    }

    #[test]
    fn snoozes_follow_the_thread_through_a_cache_rebuild() {
        let s = Store::open_in_memory().unwrap();
        let a = acct(&s);
        let inbox = s.upsert_folder(a.id, "INBOX", FolderRole::Inbox).unwrap();
        let m = msg("Plan", "plan@x.dev", &[], "Anna", "a", 0);
        let id = s
            .upsert_message(a.id, inbox.id, 1, Flags::SEEN, 10, &m)
            .unwrap();
        let later = Utc::now() + chrono::Duration::days(1);
        s.snooze(s.message(id).unwrap().thread_id, later).unwrap();

        // UIDVALIDITY reset: rows and threads are rebuilt with new ids.
        s.reset_folder(inbox.id).unwrap();
        s.upsert_message(a.id, inbox.id, 100, Flags::SEEN, 10, &m)
            .unwrap();
        s.rebind_snoozes().unwrap();
        assert!(s.threads(&Query::parse(""), 10).unwrap().is_empty());
        assert_eq!(s.threads(&Query::parse("in:snoozed"), 10).unwrap().len(), 1);
    }

    fn temp_db(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("mailcore-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("mail.sqlite")
    }

    #[test]
    fn a_failed_upgrade_leaves_the_old_schema_intact() {
        let path = temp_db("failed-upgrade");
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(SCHEMA_V1).unwrap();
            conn.pragma_update(None, "user_version", 1).unwrap();
            conn.execute_batch(
                "INSERT INTO accounts(kind,email,imap_host,imap_port,auth_kind,created_at) VALUES('imap','t@x','h',993,'password',0);
                 INSERT INTO folders(account_id,remote_name,role) VALUES(1,'INBOX','inbox');
                 INSERT INTO threads(account_id,subject) VALUES(1,'s');
                 INSERT INTO messages(account_id,folder_id,uid,thread_id,date) VALUES(1,1,3,1,0);
                 CREATE TABLE raw_messages(x);", // makes the v2 step fail halfway
            )
            .unwrap();
        }
        assert!(Store::open(&path).is_err());
        let conn = Connection::open(&path).unwrap();
        let version: i32 = conn
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, 1);
        let attachments: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE name='attachments'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(attachments, 0, "the half-applied step was rolled back");
        let messages: i64 = conn
            .query_row("SELECT COUNT(*) FROM messages", [], |r| r.get(0))
            .unwrap();
        assert_eq!(messages, 1, "the cache was not reset by a failed upgrade");
    }

    #[test]
    fn a_newer_schema_is_refused() {
        let path = temp_db("newer-schema");
        {
            let conn = Connection::open(&path).unwrap();
            conn.pragma_update(None, "user_version", SCHEMA_VERSION + 1)
                .unwrap();
        }
        let err = Store::open(&path).err().unwrap().to_string();
        assert!(err.contains("newer Flomsi"), "{err}");
    }

    #[test]
    fn deleted_messages_leave_no_index_rows() {
        let s = Store::open_in_memory().unwrap();
        let a = acct(&s);
        let inbox = s.upsert_folder(a.id, "INBOX", FolderRole::Inbox).unwrap();
        for uid in 1..=3 {
            let m = msg(
                "Budget",
                &format!("b{uid}@x.dev"),
                &[],
                "Anna",
                "quarterly budget",
                uid,
            );
            s.upsert_message(a.id, inbox.id, uid as u32, Flags::default(), 1, &m)
                .unwrap();
        }
        let fts = |s: &Store| -> i64 {
            s.with(|c| Ok(c.query_row("SELECT COUNT(*) FROM messages_fts", [], |r| r.get(0))?))
                .unwrap()
        };
        assert_eq!(fts(&s), 3);
        s.delete_by_uid(inbox.id, 1).unwrap();
        assert_eq!(fts(&s), 2);
        s.delete_account(a.id).unwrap(); // cascades to messages
        assert_eq!(fts(&s), 0);
    }

    #[test]
    fn upgrading_to_v6_rebuilds_a_stale_index() {
        let conn = Connection::open_in_memory().unwrap();
        for step in [SCHEMA_V1, SCHEMA_V2, SCHEMA_V3, SCHEMA_V4, SCHEMA_V5] {
            conn.execute_batch(step).unwrap();
        }
        conn.pragma_update(None, "user_version", 5).unwrap();
        conn.execute_batch(
            r#"INSERT INTO accounts(kind,email,imap_host,imap_port,auth_kind,created_at) VALUES('imap','t@x','h',993,'password',0);
               INSERT INTO folders(account_id,remote_name,role) VALUES(1,'INBOX','inbox');
               INSERT INTO threads(account_id,subject) VALUES(1,'Invoice');
               INSERT INTO messages(account_id,folder_id,uid,thread_id,subject,from_name,from_addr,to_json,date)
                 VALUES(1,1,3,1,'Invoice','Hetzner','billing@hetzner.com','[{"name":"Z","addr":"z@x.dev"}]',0);
               INSERT INTO bodies(message_id,text) VALUES(1,'server paid');
               INSERT INTO messages_fts(rowid,subject,from_text,to_text,body) VALUES(1,'Boarding pass','','','gate 12');
               INSERT INTO messages_fts(rowid,subject,from_text,to_text,body) VALUES(7,'orphan','','','orphan');"#,
        )
        .unwrap();
        let s = Store::init(conn).unwrap();
        let hits = |q: &str| s.threads(&Query::parse(q), 10).unwrap().len();
        assert_eq!(
            hits("gate"),
            0,
            "a reused id no longer matches the old message's text"
        );
        assert_eq!(hits("paid"), 1);
        assert_eq!(hits("from:hetzner"), 1);
        assert_eq!(hits("z@x.dev"), 1);
    }

    #[test]
    fn separate_copies_keep_their_own_read_state() {
        // Not Gmail: a message to yourself is unread in INBOX and read in Sent.
        let s = Store::open_in_memory().unwrap();
        let a = acct(&s);
        let inbox = s.upsert_folder(a.id, "INBOX", FolderRole::Inbox).unwrap();
        let sent = s.upsert_folder(a.id, "Sent", FolderRole::Sent).unwrap();
        let m = msg("Note to self", "self@x.dev", &[], "Me", "remember", 1);
        let id = s
            .upsert_message(a.id, inbox.id, 1, Flags::default(), 1, &m)
            .unwrap();
        s.upsert_message(a.id, sent.id, 1, Flags::SEEN, 1, &m)
            .unwrap();
        let thread = s.message(id).unwrap().thread_id;
        assert_eq!(s.thread(thread).unwrap().unread_count, 1);
        assert_eq!(s.thread(thread).unwrap().msg_count, 1);
        let shown = s.thread_messages(thread).unwrap();
        assert_eq!(shown.len(), 1);
        assert!(shown[0].flags.is_unread());
        assert_eq!(s.unread_count(Some(a.id)).unwrap(), 1);
    }

    #[test]
    fn copies_cached_before_gmail_ids_join_the_gmail_key() {
        let s = Store::open_in_memory().unwrap();
        let a = acct(&s);
        let all = s
            .upsert_folder(a.id, "[Gmail]/All Mail", FolderRole::All)
            .unwrap();
        let inbox = s.upsert_folder(a.id, "INBOX", FolderRole::Inbox).unwrap();
        let m = msg("Plan", "plan@x.dev", &[], "Anna", "a", 1);
        let old = s
            .upsert_message(a.id, all.id, 7, Flags::SEEN, 1, &m)
            .unwrap(); // cached by v6
        let new = s
            .upsert_fetched(a.id, inbox.id, 3, Flags::SEEN, 1, Some(42), &m)
            .unwrap();
        assert_eq!(s.dedup_key(old).unwrap(), "gm:42");
        assert_eq!(s.dedup_key(new).unwrap(), "gm:42");
        assert_eq!(
            s.thread(s.message(new).unwrap().thread_id)
                .unwrap()
                .msg_count,
            1
        );
    }
}
