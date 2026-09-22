//! SQLite cache. One database per profile, WAL mode, FTS5 for search.

use crate::error::{Error, Result};
use crate::model::*;
use crate::search::Query;
use crate::threading;
use chrono::{DateTime, TimeZone, Utc};
use rusqlite::{params, params_from_iter, Connection, OptionalExtension, Row};
use std::path::Path;
use std::sync::Mutex;

const SCHEMA_VERSION: i32 = 1;

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

pub struct Store {
    conn: Mutex<Connection>,
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

    fn init(conn: Connection) -> Result<Store> {
        conn.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY;",
        )?;
        let version: i32 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version < 1 {
            conn.execute_batch(SCHEMA_V1)?;
            conn.pragma_update(None, "user_version", SCHEMA_VERSION)?;
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
                "INSERT INTO accounts(kind,email,display_name,imap_host,imap_port,smtp_host,smtp_port,auth_kind,created_at)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)",
                params![
                    a.kind.as_str(), a.email, a.display_name, a.imap_host, a.imap_port,
                    a.smtp_host, a.smtp_port, a.auth.as_str(), ts(Utc::now())
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
            })
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
        })
    }

    pub fn upsert_folder(
        &self,
        account_id: i64,
        remote_name: &str,
        role: FolderRole,
    ) -> Result<Folder> {
        self.with(|c| {
            c.execute(
                "INSERT INTO folders(account_id, remote_name, role) VALUES(?1,?2,?3)
                 ON CONFLICT(account_id, remote_name) DO UPDATE SET role=excluded.role",
                params![account_id, remote_name, role.as_str()],
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
        self.with(|c| {
            let ids: Vec<i64> = {
                let mut st = c.prepare("SELECT id FROM messages WHERE folder_id=?1")?;
                let v = st.query_map([folder_id], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
                v
            };
            for id in ids {
                c.execute("DELETE FROM messages_fts WHERE rowid=?1", [id])?;
            }
            c.execute("DELETE FROM messages WHERE folder_id=?1", [folder_id])?;
            c.execute(
                "UPDATE folders SET uidvalidity=NULL, uidnext=NULL, highest_modseq=NULL WHERE id=?1",
                [folder_id],
            )?;
            Self::refresh_all_threads(c)?;
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
        self.with(|c| {
            let existing: Option<i64> = c
                .query_row("SELECT id FROM messages WHERE folder_id=?1 AND uid=?2", params![folder_id, uid], |r| r.get(0))
                .optional()?;
            if let Some(id) = existing {
                c.execute("UPDATE messages SET flags=?2 WHERE id=?1", params![id, flags.0])?;
                return Ok(id);
            }
            let thread_id = Self::assign_thread(c, account_id, m)?;
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
            c.execute(
                "INSERT INTO bodies(message_id, text, html) VALUES(?1,?2,?3)",
                params![id, m.text, m.html],
            )?;
            let from_text = format!("{} {}", m.from.name.clone().unwrap_or_default(), m.from.addr);
            let to_text = m
                .to
                .iter()
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
        })
    }

    fn assign_thread(c: &Connection, account_id: i64, m: &ParsedMessage) -> Result<i64> {
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
                "SELECT thread_id FROM messages WHERE account_id=? AND message_id IN ({placeholders}) ORDER BY date DESC LIMIT 1"
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
        if threading::is_reply(&m.subject) && !norm.is_empty() {
            let since = ts(m.date) - 30 * 86_400;
            if let Some(tid) = c
                .query_row(
                    "SELECT id FROM threads WHERE account_id=?1 AND subject_norm=?2 AND last_date>=?3 ORDER BY last_date DESC LIMIT 1",
                    params![account_id, norm, since],
                    |r| r.get::<_, i64>(0),
                )
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
        let count: i64 = c.query_row(
            "SELECT COUNT(*) FROM messages WHERE thread_id=?1",
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
               unread_count=(SELECT COUNT(*) FROM messages WHERE thread_id=?1 AND (flags & 1)=0),
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
                c.execute("DELETE FROM messages_fts WHERE rowid=?1", [id])?;
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

    pub fn thread_messages(&self, thread_id: i64) -> Result<Vec<Message>> {
        self.with(|c| {
            let mut st =
                c.prepare("SELECT * FROM messages WHERE thread_id=?1 ORDER BY date ASC")?;
            let rows = st.query_map([thread_id], Self::row_message)?;
            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
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
        })
    }

    /// Threads matching a query, newest first. Empty query = unified inbox.
    pub fn threads(&self, q: &Query, limit: u32) -> Result<Vec<Thread>> {
        let mut conds: Vec<String> = Vec::new();
        let mut p: Vec<rusqlite::types::Value> = Vec::new();

        let role = q.folder.unwrap_or(FolderRole::Inbox);
        if role == FolderRole::Starred {
            conds.push("(m.flags & 2) != 0".into());
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
        let sql = format!(
            "SELECT t.* FROM threads t WHERE t.id IN (
               SELECT m.thread_id FROM messages m
               JOIN folders f ON f.id = m.folder_id
               JOIN accounts a ON a.id = m.account_id
               WHERE {}
             ) ORDER BY t.last_date DESC LIMIT ?",
            conds.join(" AND ")
        );
        p.push((limit as i64).into());
        self.with(|c| {
            let mut st = c.prepare(&sql)?;
            let rows = st.query_map(params_from_iter(p), Self::row_thread)?;
            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
        })
    }

    pub fn thread(&self, id: i64) -> Result<Thread> {
        self.with(|c| {
            c.query_row("SELECT * FROM threads WHERE id=?1", [id], Self::row_thread)
                .optional()?
                .ok_or_else(|| Error::NotFound(format!("thread {id}")))
        })
    }

    pub fn unread_count(&self, account_id: Option<i64>) -> Result<u32> {
        self.with(|c| {
            let n: i64 = match account_id {
                Some(id) => c.query_row(
                    "SELECT COUNT(*) FROM messages m JOIN folders f ON f.id=m.folder_id WHERE m.account_id=?1 AND f.role='inbox' AND (m.flags & 1)=0",
                    [id],
                    |r| r.get(0),
                )?,
                None => c.query_row(
                    "SELECT COUNT(*) FROM messages m JOIN folders f ON f.id=m.folder_id WHERE f.role='inbox' AND (m.flags & 1)=0",
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
}
