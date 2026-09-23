//! Provider abstraction. One trait, several backends. IMAP first.

pub mod imap;
pub mod parse;
pub mod watchdog;

#[cfg(test)]
pub(crate) mod fake_imap;

use crate::error::Result;
use crate::model::{Flags, FolderRole};
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct RemoteFolder {
    pub name: String,
    pub role: FolderRole,
    pub selectable: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct FolderState {
    pub uidvalidity: u32,
    pub uidnext: u32,
    pub exists: u32,
    pub highest_modseq: Option<u64>,
}

#[derive(Debug, Clone)]
pub struct FetchedMessage {
    pub uid: u32,
    pub flags: Flags,
    pub size: u32,
    pub raw: Vec<u8>,
    /// Gmail's stable message id (X-GM-MSGID), shared by the copies in every label.
    pub gm_msgid: Option<u64>,
}

#[derive(Debug, Clone, Copy)]
pub struct FlagChange {
    pub uid: u32,
    pub flags: Flags,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdleOutcome {
    Changed,
    Timeout,
}

#[allow(async_fn_in_trait)]
pub trait Provider {
    async fn list_folders(&mut self) -> Result<Vec<RemoteFolder>>;
    async fn select(&mut self, folder: &str) -> Result<FolderState>;
    /// All UIDs currently in the selected folder.
    async fn uids(&mut self) -> Result<Vec<u32>>;
    /// Full messages for the given UIDs of the selected folder.
    async fn fetch(&mut self, uids: &[u32]) -> Result<Vec<FetchedMessage>>;
    /// Flags for the UIDs in `uid_set` (e.g. `1:*`, `120:4500`), or only those changed since
    /// `modseq` when the server supports CONDSTORE.
    async fn fetch_flags(
        &mut self,
        uid_set: &str,
        since_modseq: Option<u64>,
    ) -> Result<Vec<FlagChange>>;
    async fn store_flags(&mut self, uid: u32, add: Flags, remove: Flags) -> Result<()>;
    async fn move_to(&mut self, uid: u32, dest: &str) -> Result<()>;
    /// True when the server has no MOVE: a move is then [copy_to](Self::copy_to) followed
    /// by [delete](Self::delete), two steps the outbox keeps apart so a COPY never repeats.
    fn moves_by_copy(&self) -> bool {
        false
    }
    async fn copy_to(&mut self, uid: u32, dest: &str) -> Result<()>;
    /// Mark the message deleted and expunge it, and only it.
    async fn delete(&mut self, uid: u32) -> Result<()>;
    /// Store a raw RFC 822 message in `folder` (used to keep a copy of sent mail).
    async fn append(&mut self, folder: &str, raw: &[u8], flags: Flags) -> Result<()>;
    /// Block until the selected folder changes or the timeout passes.
    async fn idle(&mut self, timeout: Duration) -> Result<IdleOutcome>;
    async fn logout(&mut self) -> Result<()>;
}
