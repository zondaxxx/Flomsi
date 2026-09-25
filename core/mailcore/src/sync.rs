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

    /// Keep a complete, checked LIST: each folder's role, selectability and delimiter, and
    /// forget folders renamed or deleted elsewhere with their cached mail. Returns the stored
    /// folders in LIST order.
    pub fn store_folder_list(
        &self,
        account_id: i64,
        remote: &[crate::provider::RemoteFolder],
    ) -> Result<Vec<Folder>> {
        let mut stored = Vec::with_capacity(remote.len());
        for rf in remote {
            stored.push(self.store.upsert_remote_folder(
                account_id,
                &rf.name,
                rf.role,
                rf.selectable,
                rf.delimiter.as_deref(),
            )?);
        }
        let keep: HashSet<String> = remote.iter().map(|f| f.name.clone()).collect();
        self.store.remove_folders_except(account_id, &keep)?;
        Ok(stored)
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
            // The op's own folder is read again even when no single copy is named (an
            // emptied Trash: its mail is above the floor and comes back by itself).
            undo.entry(item.op.folder().to_string()).or_default();
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
        let stored = self.store_folder_list(account.id, &remote)?;
        let mut targets = Vec::new();
        for (rf, folder) in remote.iter().zip(stored) {
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
            let settled = std::iter::once(item.op.folder().to_string())
                .chain(item.op.touched().into_iter().map(|c| c.folder))
                .all(|f| synced.contains(&f) || !on_server.contains(f.as_str()));
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

        // Moves still waiting for the server: that mail stays out (checked again when each
        // message is stored, in case one is made while this sync runs).
        let waiting = self.store.pending_uids(account.id, &folder.remote_name)?;

        // Reconcile UID set: what's gone remotely goes locally too. A SEARCH that lists fewer
        // messages than SELECT counted is not trusted to delete anything (a server that
        // expunged meanwhile is simply caught up next time).
        let remote_uids = provider.uids().await?;
        let remote_set: HashSet<u32> = remote_uids.iter().copied().collect();
        let mut removed = 0;
        // A server may count messages in EXISTS that SEARCH never lists (some hide the ones
        // marked deleted): a second SEARCH that agrees with the first is believed.
        let trusted =
            remote_uids.len() >= state.exists as usize || provider.uids().await? == remote_uids;
        if trusted {
            for uid in self.store.uids(folder.id)? {
                if !remote_set.contains(&uid) {
                    self.store.delete_by_uid(folder.id, uid)?;
                    removed += 1;
                }
            }
        } else {
            log::warn!(
                "{}: SEARCH listed {} of {} messages; nothing deleted this time",
                folder.remote_name,
                remote_uids.len(),
                state.exists
            );
        }

        let mut held_back = false;
        // Flags: nothing to reconcile on an empty cache. With CONDSTORE only what changed;
        // otherwise only the UID range we hold (never `1:*` over a 100k-message All Mail).
        let local_uids = self.store.uids(folder.id)?;
        if let (Some(lo), Some(hi)) = (local_uids.first(), local_uids.last()) {
            let since = folder
                .highest_modseq
                .filter(|_| state.highest_modseq.is_some());
            // The synced range, plus the odd older message a server search brought in (all
            // of them as one range when there are many).
            let set = if since.is_some() {
                "1:*".to_string()
            } else {
                let start = folder.floor_uid.map_or(*lo, |f| f.max(*lo));
                let older: Vec<String> = local_uids
                    .iter()
                    .filter(|u| **u < start)
                    .map(u32::to_string)
                    .collect();
                match older.len() {
                    0 => format!("{start}:{hi}"),
                    n if n <= 200 => format!("{start}:{hi},{}", older.join(",")),
                    _ => format!("{lo}:{hi}"),
                }
            };
            let local: HashSet<u32> = local_uids.iter().copied().collect();
            // A server that refuses the flag fetch must not also stop new mail: skip the flags
            // this time and keep HIGHESTMODSEQ, so they all come again.
            let reported = match provider.fetch_flags(&set, since).await {
                Ok(v) => v,
                Err(e @ crate::Error::Io(_)) => return Err(e),
                Err(e) => {
                    log::warn!("{}: flags not fetched ({e})", folder.remote_name);
                    held_back = true;
                    Vec::new()
                }
            };
            let changes: Vec<(u32, Flags)> = reported
                .into_iter()
                .filter(|fc| local.contains(&fc.uid))
                .map(|fc| (fc.uid, fc.flags))
                .collect();
            // Messages a waiting op is about to change keep their local flags; with
            // CHANGEDSINCE such a change must be offered again next time.
            let applied = self.store.apply_server_flags(
                account.id,
                folder.id,
                &folder.remote_name,
                &changes,
            )?;
            held_back |= applied.held > 0;
            removed += applied.deleted;
            // Given-up flag changes: the server did not change, so CHANGEDSINCE will not
            // mention them. Ask for exactly those.
            let mut again: Vec<u32> = undo
                .refresh
                .iter()
                .copied()
                .filter(|u| local.contains(u))
                .collect();
            if !again.is_empty() {
                again.sort_unstable();
                let set = again
                    .iter()
                    .map(u32::to_string)
                    .collect::<Vec<_>>()
                    .join(",");
                let changes: Vec<(u32, Flags)> = provider
                    .fetch_flags(&set, None)
                    .await?
                    .into_iter()
                    .filter(|fc| again.contains(&fc.uid))
                    .map(|fc| (fc.uid, fc.flags))
                    .collect();
                let applied = self.store.apply_server_flags(
                    account.id,
                    folder.id,
                    &folder.remote_name,
                    &changes,
                )?;
                removed += applied.deleted;
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
            // Never the oldest cached UID while a floor or UIDNEXT is known: that may be a
            // search result from years back.
            folder
                .floor_uid
                .or(folder.uidnext)
                .or_else(|| local.iter().min().copied())
        };
        // UIDs asked for before and not received are asked for again, whatever the floor.
        let holes = self.store.fetch_holes(folder.id)?;
        self.store.forget_fetch_holes(folder.id, &remote_set)?;
        let mut new_uids: Vec<u32> = remote_uids
            .into_iter()
            .filter(|u| {
                !local.contains(u)
                    && !waiting.leaving(*u)
                    && (floor.is_none_or(|f| *u >= f) || restore.contains(u) || holes.contains(u))
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
        let fetched = self
            .fetch_into(account, provider, folder, &new_uids, opts)
            .await?;
        // The oldest message the sync now covers, or where the next one will come when the
        // folder is empty, so a later search result is never taken for it.
        if first_sync || folder.floor_uid.is_none() {
            let covered = match floor {
                Some(f) => Some(f),
                None => self.store.uids(folder.id)?.first().copied(),
            };
            if let Some(f) = covered.or(Some(state.uidnext)) {
                self.store.set_floor(folder.id, f)?;
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

    /// Older mail of [folder], on request: up to [count] of the newest messages below the
    /// oldest one the sync covers. The floor moves down to them, so later syncs keep their
    /// flags current. Returns how many arrived and whether older ones remain.
    pub async fn load_older<P: Provider>(
        &self,
        account: &Account,
        provider: &mut P,
        folder: &crate::model::Folder,
        count: usize,
        only: Option<&str>,
        opts: &SyncOptions,
    ) -> Result<(usize, bool)> {
        let state = provider.select(&folder.remote_name).await?;
        // Not synced yet, or rebuilt on the server: the next sync starts it over.
        if folder.uidvalidity != Some(state.uidvalidity) {
            return Ok((0, true));
        }
        let local: HashSet<u32> = self.store.uids(folder.id)?.into_iter().collect();
        let Some(floor) = folder
            .floor_uid
            .or(folder.uidnext)
            .or_else(|| local.iter().min().copied())
        else {
            return Ok((0, false));
        };
        let waiting = self.store.pending_uids(account.id, &folder.remote_name)?;
        // [only]: the part of the folder the list shows (Gmail's archive: not in the inbox).
        let all = match only {
            Some(criteria) => provider.search(criteria).await?,
            None => provider.uids().await?,
        };
        let older: Vec<u32> = all
            .into_iter()
            .filter(|u| *u < floor && !waiting.leaving(*u))
            .collect();
        let take = &older[older.len().saturating_sub(count)..];
        let wanted: Vec<u32> = take
            .iter()
            .copied()
            .filter(|u| !local.contains(u))
            .collect();
        let fetched = self
            .fetch_into(account, provider, folder, &wanted, opts)
            .await?;
        if let Some(lowest) = take.first() {
            self.store.set_floor(folder.id, *lowest)?;
        }
        Ok((fetched, older.len() > take.len()))
    }

    /// Look on the server for what [query] names in [folder] and store up to [limit] of the
    /// newest matches not cached yet. The floor stays: a match from years ago is kept
    /// without the next sync fetching everything since. Returns how many arrived.
    pub async fn search_server<P: Provider>(
        &self,
        account: &Account,
        provider: &mut P,
        folder: &crate::model::Folder,
        query: &crate::search::Query,
        limit: usize,
        opts: &SyncOptions,
    ) -> Result<usize> {
        let Some(criteria) = query.imap_criteria(provider.literal_plus()) else {
            return Ok(0);
        };
        let state = provider.select(&folder.remote_name).await?;
        if folder.uidvalidity != Some(state.uidvalidity) {
            return Ok(0);
        }
        let local: HashSet<u32> = self.store.uids(folder.id)?.into_iter().collect();
        let waiting = self.store.pending_uids(account.id, &folder.remote_name)?;
        let found: Vec<u32> = provider
            .search(&criteria)
            .await?
            .into_iter()
            .filter(|u| !local.contains(u) && !waiting.leaving(*u))
            .collect();
        let newest = &found[found.len().saturating_sub(limit)..];
        self.fetch_into(account, provider, folder, newest, opts)
            .await
    }

    /// Fetch [uids] of the selected [folder] and store them, 50 at a time, oldest first.
    /// A UID asked for and not received is remembered as a hole and asked for again.
    async fn fetch_into<P: Provider>(
        &self,
        account: &Account,
        provider: &mut P,
        folder: &crate::model::Folder,
        uids: &[u32],
        opts: &SyncOptions,
    ) -> Result<usize> {
        let mut fetched = 0;
        let now = Utc::now();
        for chunk in uids.chunks(50) {
            let mut batch = 0;
            let got = provider.fetch(chunk).await?;
            // Asked for and not received (no body, or the server refused that one): a hole,
            // tried again next sync even if it lies below every cached UID.
            let received: HashSet<u32> = got
                .iter()
                .filter(|m| !m.raw.is_empty())
                .map(|m| m.uid)
                .collect();
            let missing: Vec<u32> = chunk
                .iter()
                .copied()
                .filter(|u| !received.contains(u))
                .collect();
            let arrived: Vec<u32> = received.iter().copied().collect();
            self.store
                .update_fetch_holes(folder.id, &missing, &arrived)?;
            for fm in got {
                // Marked deleted, or a body that came back empty: nothing to keep.
                if fm.flags.contains(Flags::DELETED) || fm.raw.is_empty() {
                    continue;
                }
                let parsed = parse_rfc822(&fm.raw, now);
                let Some(id) = self.store.upsert_fetched(
                    account.id,
                    folder.id,
                    fm.uid,
                    fm.flags,
                    fm.size as u64,
                    fm.gm_msgid,
                    &parsed,
                )?
                else {
                    continue;
                };
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
            if batch > 0 && uids.len() > chunk.len() {
                self.emit(SyncEvent::Folder {
                    account_id: account.id,
                    folder: folder.remote_name.clone(),
                    fetched: batch,
                    removed: 0,
                });
            }
        }
        Ok(fetched)
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
                        // Forgotten first: a SELECT that fails may still have closed the
                        // folder that was open.
                        selected = None;
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
                    // A MOVE of a UID the server no longer has answers OK and does nothing.
                    // Taken as done only where that is the truth: the last try's answer was
                    // lost on a dropped connection (it went through), or it is a Gmail
                    // archive (out of the inbox is where it is). Anything else is said, so a
                    // restore that did not happen is not taken as done.
                    Op::Move { uid, dest, .. }
                        if !provider.search(&format!("UID {uid}")).await?.contains(uid) =>
                    {
                        let lost_answer = item.attempts > 0
                            && item
                                .last_error
                                .as_deref()
                                .is_some_and(|e| e.starts_with("io"));
                        let archived = self
                            .store
                            .folders(account.id)?
                            .iter()
                            .any(|f| f.remote_name == *dest && f.role == FolderRole::All);
                        if lost_answer || archived {
                            Ok(())
                        } else {
                            Err(crate::Error::Other(GONE.into()))
                        }
                    }
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
                        provider.delete(folder, *uid).await
                    }
                    Op::Move { uid, dest, .. } => provider.move_to(*uid, dest).await,
                    Op::Delete { folder, uid, .. } => provider.delete(folder, *uid).await,
                    Op::Empty {
                        folder,
                        below,
                        uidvalidity,
                        keep,
                    } => {
                        // Only ever Trash or Spam at the top, checked again here: a folder
                        // the server has since given another role keeps its mail. Without
                        // a UIDVALIDITY the UIDs could name other mail: nothing goes.
                        let bin = self
                            .store
                            .folders(account.id)?
                            .into_iter()
                            .find(|f| f.remote_name == *folder);
                        if uidvalidity.is_none() || !bin.as_ref().is_some_and(emptiable) {
                            return Err(crate::Error::Other(NOT_BIN.into()));
                        }
                        // Mail another op takes out of the folder stays: what was on its
                        // way when the user emptied (keep), and anything queued since.
                        let mut spare: HashSet<u32> = keep.iter().copied().collect();
                        spare.extend(self.store.removing(account.id, folder, Some(item.id))?);
                        provider.delete_below(folder, *below, &spare).await
                    }
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
        let mut plan = Vec::new();
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
                    plan.push(Change::Flags(m.folder_id, m.uid, new));
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
                plan.push(Change::Enqueue(
                    m.account_id,
                    Op::SetFlags {
                        folder: folder.remote_name.clone(),
                        uid: m.uid,
                        add,
                        remove,
                        uidvalidity: folder.uidvalidity,
                        also,
                    },
                ));
            }
        }
        self.commit(plan)
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
        plan: &mut Vec<Change>,
        m: &Message,
        src: &Folder,
        dest: &Folder,
        also: Vec<LocalCopy>,
    ) {
        plan.push(Change::Enqueue(
            m.account_id,
            Op::Move {
                folder: src.remote_name.clone(),
                uid: m.uid,
                dest: dest.remote_name.clone(),
                uidvalidity: src.uidvalidity,
                also,
            },
        ));
    }

    /// Apply the planned local changes and queue their ops as one step (see [Store::batch]).
    fn commit(&self, plan: Vec<Change>) -> Result<()> {
        if plan.is_empty() {
            return Ok(());
        }
        self.store.batch(|b| {
            for c in &plan {
                match c {
                    Change::Delete(folder_id, uid) => b.delete(*folder_id, *uid)?,
                    Change::Flags(folder_id, uid, flags) => {
                        b.set_flags(*folder_id, *uid, *flags)?
                    }
                    Change::Enqueue(account_id, op) => {
                        b.enqueue(*account_id, op)?;
                    }
                }
            }
            Ok(())
        })
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
        let mut plan = Vec::new();
        for group in self.groups(thread_id)? {
            let Some(first) = group.first() else { continue };
            let folders = self.store.folders(first.account_id)?;
            // On Gmail a label someone named "Archive" is just a label: archiving there
            // means leaving the inbox for All Mail.
            let order = if self.is_gmail(first.account_id)? {
                [FolderRole::All, FolderRole::Archive]
            } else {
                [FolderRole::Archive, FolderRole::All]
            };
            for m in &group {
                let Some(src) = Self::folder_of(&folders, m) else {
                    continue;
                };
                if src.role != FolderRole::Inbox {
                    continue;
                }
                let Some(dest) = order
                    .iter()
                    .find_map(|r| folders.iter().find(|f| f.role == *r && f.selectable))
                else {
                    return Err(crate::error::Error::NoFolder {
                        account_id: m.account_id,
                        role: FolderRole::Archive,
                        gmail: self.is_gmail(m.account_id)?,
                    });
                };
                plan.push(Change::Delete(m.folder_id, m.uid));
                Self::enqueue_move(&mut plan, m, src, dest, Vec::new());
                moved += 1;
            }
        }
        self.commit(plan)?;
        Ok(moved)
    }

    /// Delete from wherever the thread is. On Gmail one MOVE per message takes it out of
    /// every label (Sent included, like Gmail's own delete); elsewhere every copy outside
    /// Sent, Drafts and Trash moves to Trash.
    pub fn trash(&self, thread_id: i64) -> Result<usize> {
        self.store.unsnooze(thread_id)?;
        let mut moved = 0;
        let mut plan = Vec::new();
        for group in self.groups(thread_id)? {
            let Some(first) = group.first() else { continue };
            let folders = self.store.folders(first.account_id)?;
            let Some(trash) = folders
                .iter()
                .find(|f| f.role == FolderRole::Trash && f.selectable)
            else {
                return Err(crate::error::Error::NoFolder {
                    account_id: first.account_id,
                    role: FolderRole::Trash,
                    gmail: self.is_gmail(first.account_id)?,
                });
            };
            if self.is_gmail(first.account_id)? {
                moved += Self::gmail_leave_everything(&mut plan, &group, &folders, trash)?;
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
                plan.push(Change::Delete(m.folder_id, m.uid));
                Self::enqueue_move(&mut plan, m, src, trash, Vec::new());
                moved += 1;
            }
        }
        self.commit(plan)?;
        Ok(moved)
    }

    /// The thread's copies in Trash and Spam, as the server knows them: what Delete forever
    /// asks about, and all it deletes.
    pub fn bin_copies(&self, thread_id: i64) -> Result<Vec<BinCopy>> {
        let mut out = Vec::new();
        for group in self.groups(thread_id)? {
            let Some(first) = group.first() else { continue };
            let folders = self.store.folders(first.account_id)?;
            for m in &group {
                let Some(f) = Self::folder_of(&folders, m) else {
                    continue;
                };
                let Some(uidvalidity) = f.uidvalidity else {
                    continue;
                };
                if emptiable(f) {
                    out.push(BinCopy {
                        folder_id: f.id,
                        uidvalidity,
                        uid: m.uid,
                    });
                }
            }
        }
        Ok(out)
    }

    /// Delete forever the copies [Actions::bin_copies] named: each still in Trash or Spam,
    /// under the same UIDVALIDITY, goes from the server for good. Mail that joined the
    /// conversation since stays. Returns how many messages went.
    pub fn delete_forever(&self, copies: &[BinCopy]) -> Result<usize> {
        self.store.batch(|b| {
            let mut deleted = 0;
            for c in copies {
                let folder = b.folder(c.folder_id)?;
                if !emptiable(&folder) || folder.uidvalidity != Some(c.uidvalidity) {
                    continue;
                }
                if !b.uids(folder.id)?.contains(&c.uid) {
                    continue;
                }
                b.delete(folder.id, c.uid)?;
                b.enqueue(
                    folder.account_id,
                    &Op::Delete {
                        folder: folder.remote_name.clone(),
                        uid: c.uid,
                        uidvalidity: Some(c.uidvalidity),
                        also: Vec::new(),
                    },
                )?;
                deleted += 1;
            }
            Ok(deleted)
        })
    }

    /// What Trash or Spam holds right after it was read from the server: the question
    /// Empty asks is about this, and Empty deletes no more. None when the folder was never
    /// read (no UIDVALIDITY to hold the server to).
    pub fn check_bin(&self, folder_id: i64) -> Result<Option<BinCheck>> {
        self.store.batch(|b| {
            let folder = b.folder(folder_id)?;
            if !emptiable(&folder) {
                return Err(crate::Error::Other(NOT_BIN.into()));
            }
            let Some(uidvalidity) = folder.uidvalidity else {
                return Ok(None);
            };
            let mut seen = b.uids(folder.id)?;
            seen.sort_unstable();
            // Everything there when it was read: under its UIDNEXT, and every cached message
            // whatever the counter says.
            let below = seen
                .iter()
                .map(|u| u.saturating_add(1))
                .chain(folder.uidnext)
                .max()
                .unwrap_or(0);
            Ok(Some(BinCheck {
                folder_id,
                uidvalidity,
                below,
                seen,
            }))
        })
    }

    /// Empty the Trash or Spam that `check` saw: everything in it goes for good, cached
    /// here or not, but for mail a queued restore or "not spam" takes out and mail that
    /// came into view after the check (a restore the server refused, taken back since):
    /// the user was not asked about those. Returns how many cached messages went.
    pub fn empty_folder(&self, check: &BinCheck) -> Result<usize> {
        // Read and changed under one lock: a sync cannot slip a message in between.
        self.store.batch(|b| {
            let folder = b.folder(check.folder_id)?;
            if !emptiable(&folder) {
                return Err(crate::Error::Other(NOT_BIN.into()));
            }
            // Rebuilt on the server since: the UIDs name other mail now.
            if folder.uidvalidity != Some(check.uidvalidity) {
                return Err(crate::Error::Other(BIN_CHANGED.into()));
            }
            let below = check.below;
            if below <= 1 {
                return Ok(0);
            }
            let seen: HashSet<u32> = check.seen.iter().copied().collect();
            let cached: HashSet<u32> = b.uids(folder.id)?.into_iter().collect();
            let arrived = cached.iter().filter(|u| !seen.contains(u));
            // A given-up restore whose message was back in view at the check is the user's
            // to empty with the rest; any other queued one keeps its message.
            let queued = b
                .removing(folder.account_id, &folder.remote_name)?
                .into_iter()
                .filter(|u| !(cached.contains(u) && seen.contains(u)))
                .collect::<Vec<u32>>();
            // Asked for and never received: mail on the server this device could not show.
            let holes = b.fetch_holes(folder.id)?;
            let keep: Vec<u32> = arrived
                .copied()
                .chain(queued)
                .chain(holes)
                .filter(|u| *u < below)
                .collect::<std::collections::BTreeSet<u32>>()
                .into_iter()
                .collect();
            let gone: Vec<u32> = cached
                .iter()
                .copied()
                .filter(|u| *u < below && seen.contains(u))
                .collect();
            for u in &gone {
                b.delete(folder.id, *u)?;
            }
            b.enqueue(
                folder.account_id,
                &Op::Empty {
                    folder: folder.remote_name.clone(),
                    below,
                    uidvalidity: Some(check.uidvalidity),
                    keep,
                },
            )?;
            Ok(gone.len())
        })
    }

    /// Gmail: one MOVE into Trash or Spam removes the message from all labels, so every local
    /// copy goes; the copy in `dest` arrives with the next sync.
    fn gmail_leave_everything(
        plan: &mut Vec<Change>,
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
        Self::enqueue_move(plan, m, src, dest, Self::other_copies(group, m, folders));
        for c in group {
            plan.push(Change::Delete(c.folder_id, c.uid));
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
        let mut plan = Vec::new();
        for group in groups {
            let Some(first) = group.first() else { continue };
            if first.account_id != dest.account_id || group.iter().any(|m| m.folder_id == dest.id) {
                continue;
            }
            if gmail {
                if matches!(dest.role, FolderRole::Trash | FolderRole::Junk) {
                    moved += Self::gmail_leave_everything(&mut plan, &group, &folders, &dest)?;
                    continue;
                }
                let source = group.iter().find_map(|m| {
                    let f = Self::folder_of(&folders, m)?;
                    let usable = !matches!(f.role, FolderRole::Sent | FolderRole::Drafts)
                        && (restore || !binned(m));
                    usable.then_some((m, f))
                });
                let Some((m, src)) = source else { continue };
                Self::enqueue_move(&mut plan, m, src, &dest, Vec::new());
                if src.role != FolderRole::All {
                    plan.push(Change::Delete(m.folder_id, m.uid));
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
                plan.push(Change::Delete(m.folder_id, m.uid));
                Self::enqueue_move(&mut plan, m, src, &dest, Vec::new());
                moved += 1;
            }
        }
        self.commit(plan)?;
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

/// One local change an action makes, applied with the op that carries it to the server.
enum Change {
    Delete(i64, u32),
    Flags(i64, u32, Flags),
    Enqueue(i64, Op),
}

/// Given-up local changes of one folder to take back during its sync.
#[derive(Default, Clone)]
struct Undo {
    restore: HashSet<u32>,
    refresh: HashSet<u32>,
}

const REBUILT: &str = "the folder was rebuilt on the server, so this change no longer applies";
const NOT_BIN: &str = "only Trash and Spam can be emptied";
const GONE: &str = "the message is no longer in that folder on the server";
const BIN_CHANGED: &str = "the folder was rebuilt on the server since it was checked; check again";

/// One message in Trash or Spam, as the server knows it (see [Actions::bin_copies]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BinCopy {
    pub folder_id: i64,
    pub uidvalidity: u32,
    pub uid: u32,
}

/// What a read of Trash or Spam from the server showed (see [Actions::check_bin]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BinCheck {
    pub folder_id: i64,
    pub uidvalidity: u32,
    /// Every message on the server under this UID was there when the folder was read.
    pub below: u32,
    /// The messages cached then: the ones the user was shown.
    pub seen: Vec<u32>,
}

/// Trash or Spam. Roles come from the server's special-use attributes, or are guessed
/// only for folders where system folders sit (see `assign_roles`): never a folder of the
/// user's own further down.
fn emptiable(f: &Folder) -> bool {
    matches!(f.role, FolderRole::Trash | FolderRole::Junk)
}

/// A refusal that will not change on a retry: the folder was rebuilt, or the server says
/// the target does not exist. (async-imap prints known response codes as `Some(TryCreate)`
/// and keeps unknown ones in the text as `[NONEXISTENT]`.)
fn refused(e: &crate::Error) -> bool {
    let m = e.to_string().to_ascii_lowercase();
    [REBUILT, NOT_BIN, GONE, "trycreate", "[nonexistent]"]
        .iter()
        .any(|s| m.contains(&s.to_ascii_lowercase()))
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
            "removing a message from {}",
            crate::provider::imap::decode_folder_name(folder)
        ),
        Op::Empty { folder, .. } => format!(
            "emptying {}",
            crate::provider::imap::decode_folder_name(folder)
        ),
    }
}
