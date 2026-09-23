//! Sync engine: provider → store, outbox → provider, events out.

use crate::error::Result;
use crate::model::{Account, Flags, Folder, FolderRole, Message, Op};
use crate::provider::parse::parse_rfc822;
use crate::provider::Provider;
use crate::storage::Store;
use chrono::Utc;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use tokio::sync::broadcast;

#[derive(Debug, Clone)]
pub enum SyncEvent {
    Started {
        account_id: i64,
    },
    Folder {
        account_id: i64,
        folder: String,
        fetched: usize,
        removed: usize,
    },
    OutboxReplayed {
        account_id: i64,
        ops: usize,
    },
    Finished {
        account_id: i64,
    },
    Error {
        account_id: i64,
        message: String,
    },
}

#[derive(Debug, Default, Clone)]
pub struct SyncReport {
    pub folders: usize,
    pub fetched: usize,
    pub removed: usize,
    pub ops_replayed: usize,
    /// Folders that failed, as `folder: error`; the rest of the account still synced.
    pub errors: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct SyncOptions {
    /// Folder roles to sync. Empty = every selectable folder.
    pub roles: Vec<FolderRole>,
    /// On first sync of a folder, only fetch this many most-recent messages.
    pub initial_window: usize,
    /// Smaller first window for Spam and Trash.
    pub minor_window: usize,
    /// Messages with attachments or inline images up to this raw size keep a compressed copy
    /// of their bytes, so those parts open offline. Bigger ones are fetched when opened.
    pub keep_raw_below: usize,
}

impl Default for SyncOptions {
    fn default() -> Self {
        SyncOptions {
            roles: vec![
                FolderRole::Inbox,
                FolderRole::Sent,
                FolderRole::Archive,
                FolderRole::All,
                FolderRole::Junk,
                FolderRole::Trash,
            ],
            initial_window: 200,
            minor_window: 50,
            keep_raw_below: 2 * 1024 * 1024,
        }
    }
}

pub struct SyncEngine {
    store: Arc<Store>,
    events: broadcast::Sender<SyncEvent>,
}

impl SyncEngine {
    pub fn new(store: Arc<Store>) -> SyncEngine {
        let (events, _) = broadcast::channel(256);
        SyncEngine { store, events }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<SyncEvent> {
        self.events.subscribe()
    }

    fn emit(&self, e: SyncEvent) {
        let _ = self.events.send(e);
    }

    pub async fn sync_account<P: Provider>(
        &self,
        account: &Account,
        provider: &mut P,
        opts: &SyncOptions,
    ) -> Result<SyncReport> {
        let mut report = SyncReport::default();
        self.emit(SyncEvent::Started {
            account_id: account.id,
        });

        report.ops_replayed = self.replay_outbox(account, provider).await?;

        let remote = provider.list_folders().await?;
        let mut targets = Vec::new();
        for rf in &remote {
            let folder =
                self.store
                    .upsert_remote_folder(account.id, &rf.name, rf.role, rf.selectable)?;
            if rf.selectable && (opts.roles.is_empty() || opts.roles.contains(&rf.role)) {
                targets.push(folder);
            }
        }

        for folder in targets {
            match self.sync_folder(account, provider, &folder, opts).await {
                Ok((fetched, removed)) => {
                    report.folders += 1;
                    report.fetched += fetched;
                    report.removed += removed;
                    self.emit(SyncEvent::Folder {
                        account_id: account.id,
                        folder: folder.remote_name.clone(),
                        fetched,
                        removed,
                    });
                }
                Err(e) => {
                    let message = format!("{}: {e}", folder.remote_name);
                    report.errors.push(message.clone());
                    self.emit(SyncEvent::Error {
                        account_id: account.id,
                        message,
                    });
                }
            }
        }
        self.store.rebind_snoozes()?;
        self.emit(SyncEvent::Finished {
            account_id: account.id,
        });
        Ok(report)
    }

    async fn sync_folder<P: Provider>(
        &self,
        account: &Account,
        provider: &mut P,
        folder: &crate::model::Folder,
        opts: &SyncOptions,
    ) -> Result<(usize, usize)> {
        let state = provider.select(&folder.remote_name).await?;

        let mut first_sync = folder.uidvalidity.is_none();
        if let Some(v) = folder.uidvalidity {
            if v != state.uidvalidity {
                self.store.reset_folder(folder.id)?;
                // Everything is new again: take the window, not the whole folder.
                first_sync = true;
            }
        }

        // Reconcile UID set: what's gone remotely goes locally too.
        let remote_uids = provider.uids().await?;
        let remote_set: HashSet<u32> = remote_uids.iter().copied().collect();
        let mut removed = 0;
        for uid in self.store.uids(folder.id)? {
            if !remote_set.contains(&uid) {
                self.store.delete_by_uid(folder.id, uid)?;
                removed += 1;
            }
        }

        // Flags: nothing to reconcile on an empty cache. With CONDSTORE only what changed;
        // otherwise only the UID range we hold (never `1:*` over a 100k-message All Mail).
        let local_uids = self.store.uids(folder.id)?;
        if let (Some(lo), Some(hi)) = (local_uids.first(), local_uids.last()) {
            let since = folder
                .highest_modseq
                .filter(|_| state.highest_modseq.is_some());
            let set = if since.is_some() {
                "1:*".to_string()
            } else {
                format!("{lo}:{hi}")
            };
            let local: HashSet<u32> = local_uids.iter().copied().collect();
            for fc in provider.fetch_flags(&set, since).await? {
                if local.contains(&fc.uid) {
                    self.store.set_flags_by_uid(folder.id, fc.uid, fc.flags)?;
                }
            }
        }
        let local: HashSet<u32> = local_uids.into_iter().collect();

        // New messages: on a first sync the newest window; afterwards every remote UID from
        // the lowest one we hold up that is missing here (new mail, and holes left by an
        // interrupted sync or a move that did not happen). Oldest first, so a thread's root
        // is stored before its replies and an interruption leaves no gap below the maximum.
        // The UI refreshes after every batch.
        let floor = if first_sync {
            None
        } else {
            local.iter().min().copied().or(folder.uidnext)
        };
        let mut new_uids: Vec<u32> = remote_uids
            .into_iter()
            .filter(|u| !local.contains(u) && floor.is_none_or(|f| *u >= f))
            .collect();
        let window = if matches!(folder.role, FolderRole::Junk | FolderRole::Trash) {
            opts.minor_window.min(opts.initial_window)
        } else {
            opts.initial_window
        };
        if first_sync && new_uids.len() > window {
            new_uids = new_uids.split_off(new_uids.len() - window);
        }
        let mut fetched = 0;
        let now = Utc::now();
        for chunk in new_uids.chunks(50) {
            let mut batch = 0;
            for fm in provider.fetch(chunk).await? {
                let parsed = parse_rfc822(&fm.raw, now);
                let id = self.store.upsert_fetched(
                    account.id,
                    folder.id,
                    fm.uid,
                    fm.flags,
                    fm.size as u64,
                    fm.gm_msgid,
                    &parsed,
                )?;
                if !parsed.attachments.is_empty()
                    && fm.raw.len() <= opts.keep_raw_below
                    && !self
                        .store
                        .has_raw(account.id, parsed.message_id.as_deref(), id)?
                {
                    self.store.put_raw(id, &fm.raw)?;
                }
                batch += 1;
            }
            fetched += batch;
            if batch > 0 && new_uids.len() > chunk.len() {
                self.emit(SyncEvent::Folder {
                    account_id: account.id,
                    folder: folder.remote_name.clone(),
                    fetched: batch,
                    removed: 0,
                });
            }
        }

        self.store.update_folder_state(
            folder.id,
            state.uidvalidity,
            state.uidnext,
            state.highest_modseq,
        )?;
        Ok((fetched, removed))
    }

    /// Push pending local operations to the server. Failed ops stay queued with an attempt count.
    pub async fn replay_outbox<P: Provider>(
        &self,
        account: &Account,
        provider: &mut P,
    ) -> Result<usize> {
        let ops = self.store.pending_ops(account.id)?;
        let mut done = 0;
        let mut selected: Option<String> = None;
        for item in ops {
            let folder = match &item.op {
                Op::SetFlags { folder, .. } | Op::Move { folder, .. } => folder.clone(),
            };
            let result: Result<()> = async {
                if selected.as_deref() != Some(folder.as_str()) {
                    provider.select(&folder).await?;
                    selected = Some(folder.clone());
                }
                match &item.op {
                    Op::SetFlags {
                        uid, add, remove, ..
                    } => provider.store_flags(*uid, *add, *remove).await,
                    Op::Move { uid, dest, .. } => provider.move_to(*uid, dest).await,
                }
            }
            .await;
            match result {
                Ok(()) => {
                    self.store.mark_done(item.id)?;
                    done += 1;
                }
                Err(e) => self.store.mark_failed(item.id, &e.to_string())?,
            }
        }
        if done > 0 {
            self.emit(SyncEvent::OutboxReplayed {
                account_id: account.id,
                ops: done,
            });
        }
        Ok(done)
    }
}

/// Local-first thread actions. Each mutates the cache and enqueues the remote op.
pub struct Actions<'a> {
    pub store: &'a Store,
}

impl<'a> Actions<'a> {
    /// Gmail keeps one message in many labels: flags are per message and a MOVE out of a
    /// label or into Trash/Spam affects every copy. Elsewhere copies are separate messages.
    fn is_gmail(&self, account_id: i64) -> Result<bool> {
        let a = self.store.account(account_id)?;
        Ok(a.kind == crate::model::ProviderKind::Gmail
            || a.imap_host.to_ascii_lowercase().contains("gmail"))
    }

    /// The thread's copies grouped per message, preferred copy first (INBOX, then other
    /// folders, All Mail last), groups in date order.
    fn groups(&self, thread_id: i64) -> Result<Vec<Vec<Message>>> {
        let mut order: Vec<String> = Vec::new();
        let mut map: HashMap<String, Vec<Message>> = HashMap::new();
        for m in self.store.thread_copies(thread_id)? {
            let key = self.store.dedup_key(m.id)?;
            if !map.contains_key(&key) {
                order.push(key.clone());
            }
            map.entry(key).or_default().push(m);
        }
        Ok(order.into_iter().filter_map(|k| map.remove(&k)).collect())
    }

    fn folder_of<'f>(folders: &'f [Folder], m: &Message) -> Option<&'f Folder> {
        folders.iter().find(|f| f.id == m.folder_id)
    }

    /// Which copy to address on the server for a Gmail message: the All Mail copy when cached,
    /// because its UID stays valid until the message is trashed or marked spam, while an
    /// INBOX UID may already be gone (archived on another device).
    fn gmail_anchor<'m>(group: &'m [Message], folders: &[Folder]) -> Option<&'m Message> {
        group
            .iter()
            .find(|m| Self::folder_of(folders, m).is_some_and(|f| f.role == FolderRole::All))
            .or_else(|| group.first())
    }

    /// Set or clear one flag on every copy locally; queue the remote STORE once per message
    /// on Gmail (on the All Mail copy when cached), once per changed copy elsewhere.
    fn set_flag(&self, copies_by_message: Vec<Vec<Message>>, flag: Flags, on: bool) -> Result<()> {
        for group in copies_by_message {
            let Some(first) = group.first() else { continue };
            let gmail = self.is_gmail(first.account_id)?;
            let folders = self.store.folders(first.account_id)?;
            let changed = |m: &Message| {
                if on {
                    m.flags.with(flag)
                } else {
                    m.flags.without(flag)
                }
            };
            let any_change = group.iter().any(|m| changed(m) != m.flags);
            let anchor = if gmail {
                Self::gmail_anchor(&group, &folders).map(|m| m.id)
            } else {
                None
            };
            for m in &group {
                let new = changed(m);
                if new != m.flags {
                    self.store.set_flags_by_uid(m.folder_id, m.uid, new)?;
                }
                let send = match anchor {
                    // Gmail: flags belong to the message; one STORE on the anchor copy.
                    Some(a) => any_change && m.id == a,
                    None => new != m.flags,
                };
                if !send {
                    continue;
                }
                let Some(folder) = Self::folder_of(&folders, m) else {
                    continue;
                };
                let (add, remove) = if on {
                    (flag, Flags::default())
                } else {
                    (Flags::default(), flag)
                };
                self.store.enqueue(
                    m.account_id,
                    &Op::SetFlags {
                        folder: folder.remote_name.clone(),
                        uid: m.uid,
                        add,
                        remove,
                    },
                )?;
            }
        }
        Ok(())
    }

    pub fn mark_read(&self, thread_id: i64, read: bool) -> Result<()> {
        self.set_flag(self.groups(thread_id)?, Flags::SEEN, read)
    }

    pub fn star(&self, thread_id: i64, on: bool) -> Result<()> {
        self.set_flag(self.groups(thread_id)?, Flags::FLAGGED, on)
    }

    pub fn mark_answered(&self, account_id: i64, message_id: &str) -> Result<()> {
        let copies = self.store.messages_by_message_id(account_id, message_id)?;
        if copies.is_empty() {
            return Ok(());
        }
        self.set_flag(vec![copies], Flags::ANSWERED, true)
    }

    fn enqueue_move(&self, m: &Message, src: &Folder, dest: &Folder) -> Result<()> {
        self.store.enqueue(
            m.account_id,
            &Op::Move {
                folder: src.remote_name.clone(),
                uid: m.uid,
                dest: dest.remote_name.clone(),
            },
        )?;
        Ok(())
    }

    /// Out of the inbox: to Archive, or on Gmail (no Archive folder) to All Mail, which just
    /// drops the Inbox label and keeps the All Mail copy.
    pub fn archive(&self, thread_id: i64) -> Result<usize> {
        self.store.unsnooze(thread_id)?;
        let mut moved = 0;
        for group in self.groups(thread_id)? {
            let Some(first) = group.first() else { continue };
            let folders = self.store.folders(first.account_id)?;
            for m in &group {
                let Some(src) = Self::folder_of(&folders, m) else {
                    continue;
                };
                if src.role != FolderRole::Inbox {
                    continue;
                }
                let dest = [FolderRole::Archive, FolderRole::All]
                    .iter()
                    .find_map(|r| folders.iter().find(|f| f.role == *r && f.selectable))
                    .ok_or_else(|| crate::error::Error::NotFound("archive folder".into()))?;
                self.store.delete_by_uid(m.folder_id, m.uid)?;
                self.enqueue_move(m, src, dest)?;
                moved += 1;
            }
        }
        Ok(moved)
    }

    /// Delete from wherever the thread is. On Gmail one MOVE per message takes it out of
    /// every label (Sent included, like Gmail's own delete); elsewhere every copy outside
    /// Sent, Drafts and Trash moves to Trash.
    pub fn trash(&self, thread_id: i64) -> Result<usize> {
        self.store.unsnooze(thread_id)?;
        let mut moved = 0;
        for group in self.groups(thread_id)? {
            let Some(first) = group.first() else { continue };
            let folders = self.store.folders(first.account_id)?;
            let trash = folders
                .iter()
                .find(|f| f.role == FolderRole::Trash && f.selectable)
                .ok_or_else(|| crate::error::Error::NotFound("trash folder".into()))?;
            if self.is_gmail(first.account_id)? {
                moved += self.gmail_leave_everything(&group, &folders, trash)?;
                continue;
            }
            for m in &group {
                let Some(src) = Self::folder_of(&folders, m) else {
                    continue;
                };
                if matches!(
                    src.role,
                    FolderRole::Sent | FolderRole::Drafts | FolderRole::Trash
                ) {
                    continue;
                }
                self.store.delete_by_uid(m.folder_id, m.uid)?;
                self.enqueue_move(m, src, trash)?;
                moved += 1;
            }
        }
        Ok(moved)
    }

    /// Gmail: one MOVE into Trash or Spam removes the message from all labels, so every local
    /// copy goes; the copy in `dest` arrives with the next sync.
    fn gmail_leave_everything(
        &self,
        group: &[Message],
        folders: &[Folder],
        dest: &Folder,
    ) -> Result<usize> {
        if group.iter().any(|m| m.folder_id == dest.id) {
            return Ok(0);
        }
        let Some(m) = Self::gmail_anchor(group, folders) else {
            return Ok(0);
        };
        let Some(src) = Self::folder_of(folders, m) else {
            return Ok(0);
        };
        self.enqueue_move(m, src, dest)?;
        for c in group {
            self.store.delete_by_uid(c.folder_id, c.uid)?;
        }
        Ok(1)
    }

    /// "Move to…": every message of the thread goes to `folder_id` of its account. Sent and
    /// Drafts copies stay put. On Gmail a move adds the label and drops the source label;
    /// from All Mail it only adds the label, and the All Mail copy stays. Returns how many
    /// messages moved.
    pub fn move_to_folder(&self, thread_id: i64, folder_id: i64) -> Result<usize> {
        let dest = self.store.folder(folder_id)?;
        let folders = self.store.folders(dest.account_id)?;
        if dest.role != FolderRole::Inbox {
            self.store.unsnooze(thread_id)?;
        }
        let gmail = self.is_gmail(dest.account_id)?;
        let groups = self.groups(thread_id)?;
        // Copies in Trash or Spam only move when the whole thread is there (a restore).
        let binned = |m: &Message| {
            Self::folder_of(&folders, m)
                .is_some_and(|f| matches!(f.role, FolderRole::Trash | FolderRole::Junk))
        };
        let restore = groups.iter().flatten().all(binned);
        let mut moved = 0;
        for group in groups {
            let Some(first) = group.first() else { continue };
            if first.account_id != dest.account_id || group.iter().any(|m| m.folder_id == dest.id) {
                continue;
            }
            if gmail {
                if matches!(dest.role, FolderRole::Trash | FolderRole::Junk) {
                    moved += self.gmail_leave_everything(&group, &folders, &dest)?;
                    continue;
                }
                let source = group.iter().find_map(|m| {
                    let f = Self::folder_of(&folders, m)?;
                    let usable = !matches!(f.role, FolderRole::Sent | FolderRole::Drafts)
                        && (restore || !binned(m));
                    usable.then_some((m, f))
                });
                let Some((m, src)) = source else { continue };
                self.enqueue_move(m, src, &dest)?;
                if src.role != FolderRole::All {
                    self.store.delete_by_uid(m.folder_id, m.uid)?;
                }
                moved += 1;
                continue;
            }
            for m in &group {
                let Some(src) = Self::folder_of(&folders, m) else {
                    continue;
                };
                if matches!(
                    src.role,
                    FolderRole::Sent | FolderRole::Drafts | FolderRole::All
                ) || (!restore && binned(m))
                {
                    continue;
                }
                self.store.delete_by_uid(m.folder_id, m.uid)?;
                self.enqueue_move(m, src, &dest)?;
                moved += 1;
            }
        }
        Ok(moved)
    }

    /// Hide the thread from the inbox until `until` (on this device).
    pub fn snooze(&self, thread_id: i64, until: chrono::DateTime<chrono::Utc>) -> Result<()> {
        self.store.snooze(thread_id, until)
    }

    pub fn unsnooze(&self, thread_id: i64) -> Result<()> {
        self.store.unsnooze(thread_id)
    }

    /// Bring back snoozed threads whose time has come: each is marked unread once (like new
    /// mail) and sorts by its wake time. Returns how many woke.
    pub fn wake_snoozed(&self, now: chrono::DateTime<chrono::Utc>) -> Result<usize> {
        let due = self.store.due_snoozes(now)?;
        for (thread_id, _) in &due {
            if self
                .store
                .thread_messages(*thread_id)
                .is_ok_and(|m| !m.is_empty())
            {
                self.mark_read(*thread_id, false)?;
            }
            self.store.mark_woken(*thread_id, now)?;
        }
        Ok(due.len())
    }
}
