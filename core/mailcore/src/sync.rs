//! Sync engine: provider → store, outbox → provider, events out.

use crate::error::Result;
use crate::model::{Account, Flags, FolderRole, Op};
use crate::provider::parse::parse_rfc822;
use crate::provider::Provider;
use crate::storage::Store;
use chrono::Utc;
use std::collections::HashSet;
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
}

#[derive(Debug, Clone)]
pub struct SyncOptions {
    /// Folder roles to sync. Empty = every selectable folder.
    pub roles: Vec<FolderRole>,
    /// On first sync of a folder, only fetch this many most-recent messages.
    pub initial_window: usize,
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
            ],
            initial_window: 200,
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
            let folder = self.store.upsert_folder(account.id, &rf.name, rf.role)?;
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
                Err(e) => self.emit(SyncEvent::Error {
                    account_id: account.id,
                    message: format!("{}: {e}", folder.remote_name),
                }),
            }
        }
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

        let first_sync = folder.uidvalidity.is_none();
        if let Some(v) = folder.uidvalidity {
            if v != state.uidvalidity {
                self.store.reset_folder(folder.id)?;
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

        // Flags: full pass or CHANGEDSINCE when the server supports CONDSTORE.
        let flag_changes = provider
            .fetch_flags(
                folder
                    .highest_modseq
                    .filter(|_| state.highest_modseq.is_some()),
            )
            .await?;
        let local: HashSet<u32> = self.store.uids(folder.id)?.into_iter().collect();
        for fc in flag_changes {
            if local.contains(&fc.uid) {
                self.store.set_flags_by_uid(folder.id, fc.uid, fc.flags)?;
            }
        }

        // New messages: everything above what we have, windowed on first sync.
        let known_max = self.store.max_uid(folder.id)?.unwrap_or(0);
        let mut new_uids: Vec<u32> = remote_uids
            .into_iter()
            .filter(|u| *u > known_max && !local.contains(u))
            .collect();
        if first_sync && new_uids.len() > opts.initial_window {
            new_uids = new_uids.split_off(new_uids.len() - opts.initial_window);
        }
        let mut fetched = 0;
        let now = Utc::now();
        for chunk in new_uids.chunks(50) {
            for fm in provider.fetch(chunk).await? {
                let parsed = parse_rfc822(&fm.raw, now);
                let id = self.store.upsert_message(
                    account.id,
                    folder.id,
                    fm.uid,
                    fm.flags,
                    fm.size as u64,
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
                fetched += 1;
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
    pub fn mark_read(&self, thread_id: i64, read: bool) -> Result<()> {
        for m in self.store.thread_messages(thread_id)? {
            let folder = self
                .store
                .folders(m.account_id)?
                .into_iter()
                .find(|f| f.id == m.folder_id);
            let Some(folder) = folder else { continue };
            let new_flags = if read {
                m.flags.with(Flags::SEEN)
            } else {
                m.flags.without(Flags::SEEN)
            };
            if new_flags != m.flags {
                self.store.set_flags_by_uid(m.folder_id, m.uid, new_flags)?;
                let (add, remove) = if read {
                    (Flags::SEEN, Flags::default())
                } else {
                    (Flags::default(), Flags::SEEN)
                };
                self.store.enqueue(
                    m.account_id,
                    &Op::SetFlags {
                        folder: folder.remote_name,
                        uid: m.uid,
                        add,
                        remove,
                    },
                )?;
            }
        }
        Ok(())
    }

    pub fn star(&self, thread_id: i64, on: bool) -> Result<()> {
        for m in self.store.thread_messages(thread_id)? {
            let folder = self
                .store
                .folders(m.account_id)?
                .into_iter()
                .find(|f| f.id == m.folder_id);
            let Some(folder) = folder else { continue };
            let new_flags = if on {
                m.flags.with(Flags::FLAGGED)
            } else {
                m.flags.without(Flags::FLAGGED)
            };
            if new_flags != m.flags {
                self.store.set_flags_by_uid(m.folder_id, m.uid, new_flags)?;
                let (add, remove) = if on {
                    (Flags::FLAGGED, Flags::default())
                } else {
                    (Flags::default(), Flags::FLAGGED)
                };
                self.store.enqueue(
                    m.account_id,
                    &Op::SetFlags {
                        folder: folder.remote_name,
                        uid: m.uid,
                        add,
                        remove,
                    },
                )?;
            }
        }
        Ok(())
    }

    /// Flag the message with this Message-ID as answered, locally and on the server.
    pub fn mark_answered(&self, account_id: i64, message_id: &str) -> Result<()> {
        let folders = self.store.folders(account_id)?;
        for m in self.store.messages_by_message_id(account_id, message_id)? {
            let Some(folder) = folders.iter().find(|f| f.id == m.folder_id) else {
                continue;
            };
            if m.flags.contains(Flags::ANSWERED) {
                continue;
            }
            self.store
                .set_flags_by_uid(m.folder_id, m.uid, m.flags.with(Flags::ANSWERED))?;
            self.store.enqueue(
                account_id,
                &Op::SetFlags {
                    folder: folder.remote_name.clone(),
                    uid: m.uid,
                    add: Flags::ANSWERED,
                    remove: Flags::default(),
                },
            )?;
        }
        Ok(())
    }

    /// Move every inbox message of the thread to the archive folder (Archive, else Gmail All Mail).
    pub fn archive(&self, thread_id: i64) -> Result<()> {
        self.move_thread(thread_id, &[FolderRole::Archive, FolderRole::All])
    }

    pub fn trash(&self, thread_id: i64) -> Result<()> {
        self.move_thread(thread_id, &[FolderRole::Trash])
    }

    fn move_thread(&self, thread_id: i64, dest_roles: &[FolderRole]) -> Result<()> {
        for m in self.store.thread_messages(thread_id)? {
            let folders = self.store.folders(m.account_id)?;
            let Some(src) = folders.iter().find(|f| f.id == m.folder_id) else {
                continue;
            };
            if src.role != FolderRole::Inbox {
                continue;
            }
            let Some(dest) = dest_roles
                .iter()
                .find_map(|r| folders.iter().find(|f| f.role == *r))
            else {
                return Err(crate::error::Error::NotFound("archive folder".into()));
            };
            self.store.delete_by_uid(m.folder_id, m.uid)?;
            self.store.enqueue(
                m.account_id,
                &Op::Move {
                    folder: src.remote_name.clone(),
                    uid: m.uid,
                    dest: dest.remote_name.clone(),
                },
            )?;
        }
        Ok(())
    }
}
