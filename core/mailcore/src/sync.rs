//! Sync engine: provider → store, outbox → provider, events out.

use crate::error::Result;
use crate::model::{Account, Flags, Folder, FolderRole, LocalCopy, Message, Op};
use crate::provider::parse::parse_rfc822;
use crate::provider::Provider;
use crate::storage::{Failure, Store};
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

        // Ops given up (now or in a sync that was cut short): take their local change back
        // by reading their folders from the server again. Kept in the database until done.
        let given_up = self.store.given_up_ops(account.id)?;
        let mut undo: HashMap<String, Undo> = HashMap::new();
        for item in &given_up {
            let removes = item.op.removes();
            for copy in item.op.touched() {
                let u = undo.entry(copy.folder).or_default();
                if removes {
                    u.restore.insert(copy.uid);
                } else {
                    u.refresh.insert(copy.uid);
                }
            }
        }

        let remote = provider.list_folders().await?;
        let mut targets = Vec::new();
        for rf in &remote {
            let folder =
                self.store
                    .upsert_remote_folder(account.id, &rf.name, rf.role, rf.selectable)?;
            // A folder with something to take back is synced even when this run would skip
            // it (an inbox-only sync after a failed "not spam").
            let wanted = opts.roles.is_empty()
                || opts.roles.contains(&rf.role)
                || undo.contains_key(&rf.name);
            if rf.selectable && wanted {
                targets.push(folder);
            }
        }
        let on_server: HashSet<&str> = remote.iter().map(|f| f.name.as_str()).collect();
        let mut synced: HashSet<String> = HashSet::new();

        for folder in targets {
            let undo = undo.get(&folder.remote_name).cloned().unwrap_or_default();
            match self
                .sync_folder(account, provider, &folder, opts, &undo)
                .await
            {
                Ok((fetched, removed)) => {
                    synced.insert(folder.remote_name.clone());
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
                // A dead connection fails every folder after it; stop here and let the
                // caller reconnect later.
                Err(e @ crate::Error::Io(_)) => {
                    self.emit(SyncEvent::Error {
                        account_id: account.id,
                        message: format!("{}: {e}", folder.remote_name),
                    });
                    // What did sync still counts: snoozes follow their threads.
                    let _ = self.store.rebind_snoozes();
                    return Err(e);
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
        // A given-up op is done with once every folder it touched came back from the
        // server (or no longer exists there); only then is it reported, once.
        for item in given_up {
            let settled = item
                .op
                .touched()
                .iter()
                .all(|c| synced.contains(&c.folder) || !on_server.contains(c.folder.as_str()));
            if settled {
                self.store.mark_undone(item.id)?;
                report.errors.push(format!(
                    "Could not finish {}: {}",
                    describe(&item.op),
                    item.last_error
                        .as_deref()
                        .unwrap_or("the server refused it")
                ));
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
        undo: &Undo,
    ) -> Result<(usize, usize)> {
        let restore = &undo.restore;
        let state = provider.select(&folder.remote_name).await?;

        let mut first_sync = folder.uidvalidity.is_none();
        if let Some(v) = folder.uidvalidity {
            if v != state.uidvalidity {
                self.store.reset_folder(folder.id)?;
                // Everything is new again: take the window, not the whole folder.
                first_sync = true;
            }
        }

        // Local actions still waiting for the server (a replay that failed this time)
        // must not be undone by the server's older state: flags stay, moved mail stays out.
        let (flags_waiting, moves_waiting) =
            self.store.pending_uids(account.id, &folder.remote_name)?;

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

        let mut held_back = false;
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
                if !local.contains(&fc.uid) {
                    continue;
                }
                if flags_waiting.contains(&fc.uid) {
                    // Skipped for now; with CHANGEDSINCE it must be offered again.
                    held_back = true;
                } else if fc.flags.contains(Flags::DELETED) {
                    // Marked for deletion (another client, or our own move on a server
                    // without UIDPLUS): as good as gone.
                    self.store.delete_by_uid(folder.id, fc.uid)?;
                    removed += 1;
                } else {
                    self.store.set_flags_by_uid(folder.id, fc.uid, fc.flags)?;
                }
            }
            // Given-up flag changes: the server did not change, so CHANGEDSINCE will not
            // mention them. Ask for exactly those.
            let mut again: Vec<u32> = undo
                .refresh
                .iter()
                .copied()
                .filter(|u| local.contains(u) && !flags_waiting.contains(u))
                .collect();
            if !again.is_empty() {
                again.sort_unstable();
                let set = again
                    .iter()
                    .map(u32::to_string)
                    .collect::<Vec<_>>()
                    .join(",");
                for fc in provider.fetch_flags(&set, None).await? {
                    if again.contains(&fc.uid) {
                        self.store.set_flags_by_uid(folder.id, fc.uid, fc.flags)?;
                    }
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
            .filter(|u| {
                !local.contains(u)
                    && !moves_waiting.contains(u)
                    && (floor.is_none_or(|f| *u >= f) || restore.contains(u))
            })
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
                if fm.flags.contains(Flags::DELETED) {
                    continue;
                }
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

        // A change held back for a waiting op must come again next time: keep the old
        // HIGHESTMODSEQ so CHANGEDSINCE still covers it.
        let modseq = if held_back {
            folder.highest_modseq
        } else {
            state.highest_modseq
        };
        self.store
            .update_folder_state(folder.id, state.uidvalidity, state.uidnext, modseq)?;
        Ok((fetched, removed))
    }

    /// Push pending local operations to the server. Failed ops stay queued with an attempt count.
    /// Push queued local actions to the server; returns how many went through. Ops that
    /// fail for good are marked given up in the database (see [Store::given_up_ops]).
    pub async fn replay_outbox<P: Provider>(
        &self,
        account: &Account,
        provider: &mut P,
    ) -> Result<usize> {
        let ops = self.store.pending_ops(account.id)?;
        let mut done = 0;
        let mut selected: Option<(String, u32)> = None;
        for item in ops {
            let folder = item.op.folder().to_string();
            let result: Result<()> = async {
                let validity = match &selected {
                    Some((name, v)) if *name == folder => *v,
                    _ => {
                        let state = provider.select(&folder).await?;
                        selected = Some((folder.clone(), state.uidvalidity));
                        state.uidvalidity
                    }
                };
                // Under another UIDVALIDITY the same UID is another message: never touch it.
                if item.op.uidvalidity().is_some_and(|v| v != validity) {
                    return Err(crate::Error::Other(REBUILT.into()));
                }
                match &item.op {
                    Op::SetFlags {
                        uid, add, remove, ..
                    } => provider.store_flags(*uid, *add, *remove).await,
                    Op::Move {
                        folder,
                        uid,
                        dest,
                        uidvalidity,
                        also,
                    } if provider.moves_by_copy() => {
                        provider.copy_to(*uid, dest).await?;
                        // The copy exists now; from here on the op only removes the original,
                        // so a retry never copies twice.
                        self.store.rewrite_op(
                            item.id,
                            &Op::Delete {
                                folder: folder.clone(),
                                uid: *uid,
                                uidvalidity: *uidvalidity,
                                also: also.clone(),
                            },
                        )?;
                        provider.delete(*uid).await
                    }
                    Op::Move { uid, dest, .. } => provider.move_to(*uid, dest).await,
                    Op::Delete { uid, .. } => provider.delete(*uid).await,
                }
            }
            .await;
            match result {
                Ok(()) => {
                    self.store.mark_done(item.id)?;
                    done += 1;
                }
                // The connection died: the rest of the queue waits for the next sync. The op
                // in flight still counts an attempt, so one that always kills the connection
                // cannot block the account forever.
                Err(e @ crate::Error::Io(_)) => {
                    self.store
                        .mark_failed(item.id, &e.to_string(), Failure::Retry)?;
                    return Err(e);
                }
                Err(e) => {
                    let failure = if refused(&e) {
                        Failure::Refused
                    } else {
                        Failure::Retry
                    };
                    self.store.mark_failed(item.id, &e.to_string(), failure)?;
                }
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
                // On Gmail one STORE on the anchor changes every copy: list them, so a sync
                // leaves them alone while it waits and restores them if it is given up.
                let also = if anchor.is_some() {
                    Self::other_copies(&group, m, &folders)
                } else {
                    Vec::new()
                };
                self.store.enqueue(
                    m.account_id,
                    &Op::SetFlags {
                        folder: folder.remote_name.clone(),
                        uid: m.uid,
                        add,
                        remove,
                        uidvalidity: folder.uidvalidity,
                        also,
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

    fn enqueue_move(
        &self,
        m: &Message,
        src: &Folder,
        dest: &Folder,
        also: Vec<LocalCopy>,
    ) -> Result<()> {
        self.store.enqueue(
            m.account_id,
            &Op::Move {
                folder: src.remote_name.clone(),
                uid: m.uid,
                dest: dest.remote_name.clone(),
                uidvalidity: src.uidvalidity,
                also,
            },
        )?;
        Ok(())
    }

    /// The copies of a message other than [m], as (folder, UID).
    fn other_copies(group: &[Message], m: &Message, folders: &[Folder]) -> Vec<LocalCopy> {
        group
            .iter()
            .filter(|c| c.id != m.id)
            .filter_map(|c| {
                Some(LocalCopy {
                    folder: Self::folder_of(folders, c)?.remote_name.clone(),
                    uid: c.uid,
                })
            })
            .collect()
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
                self.enqueue_move(m, src, dest, Vec::new())?;
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
                self.enqueue_move(m, src, trash, Vec::new())?;
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
        self.enqueue_move(m, src, dest, Self::other_copies(group, m, folders))?;
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
                self.enqueue_move(m, src, &dest, Vec::new())?;
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
                self.enqueue_move(m, src, &dest, Vec::new())?;
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

/// Given-up local changes of one folder to take back during its sync.
#[derive(Default, Clone)]
struct Undo {
    restore: HashSet<u32>,
    refresh: HashSet<u32>,
}

const REBUILT: &str = "the folder was rebuilt on the server, so this change no longer applies";

/// A refusal that will not change on a retry: the folder was rebuilt, or the server says
/// the target does not exist. (async-imap prints known response codes as `Some(TryCreate)`
/// and keeps unknown ones in the text as `[NONEXISTENT]`.)
fn refused(e: &crate::Error) -> bool {
    let m = e.to_string().to_ascii_lowercase();
    m.contains(REBUILT) || m.contains("trycreate") || m.contains("[nonexistent]")
}

fn describe(op: &Op) -> String {
    match op {
        Op::Move { dest, .. } => {
            format!(
                "moving a message to {}",
                crate::provider::imap::decode_folder_name(dest)
            )
        }
        Op::SetFlags { .. } => "changing a message's flags".into(),
        Op::Delete { folder, .. } => format!(
            "moving a message out of {}",
            crate::provider::imap::decode_folder_name(folder)
        ),
    }
}
