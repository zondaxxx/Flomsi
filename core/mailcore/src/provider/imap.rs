//! IMAP over TLS with async-imap on tokio. LOGIN or XOAUTH2.

use super::{FetchedMessage, FlagChange, FolderState, IdleOutcome, Provider, RemoteFolder};
use crate::error::{Error, Result};
use crate::model::{Flags, FolderRole};
use async_imap::types::Flag;
use futures::TryStreamExt;
use std::sync::Arc;
use std::time::Duration;
use tokio::net::TcpStream;
use tokio_rustls::client::TlsStream;
use tokio_rustls::TlsConnector;

type Session = async_imap::Session<TlsStream<TcpStream>>;

pub enum Credential {
    Password(String),
    /// Bearer access token for SASL XOAUTH2.
    AccessToken(String),
}

pub struct ImapProvider {
    session: Option<Session>,
    selected: Option<String>,
    host: String,
}

struct XOAuth2 {
    user: String,
    token: String,
}

impl async_imap::Authenticator for XOAuth2 {
    type Response = String;
    fn process(&mut self, _data: &[u8]) -> Self::Response {
        format!("user={}\x01auth=Bearer {}\x01\x01", self.user, self.token)
    }
}

fn tls_connector() -> TlsConnector {
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let config = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    TlsConnector::from(Arc::new(config))
}

fn to_flags<'a>(it: impl Iterator<Item = Flag<'a>>) -> Flags {
    let mut f = Flags::default();
    for flag in it {
        f = match flag {
            Flag::Seen => f.with(Flags::SEEN),
            Flag::Flagged => f.with(Flags::FLAGGED),
            Flag::Answered => f.with(Flags::ANSWERED),
            Flag::Draft => f.with(Flags::DRAFT),
            Flag::Deleted => f.with(Flags::DELETED),
            _ => f,
        };
    }
    f
}

/// Map special-use attributes and well-known names to a role.
fn role_for(name: &str, attrs_debug: &str) -> FolderRole {
    let a = attrs_debug.to_lowercase();
    if a.contains("sent") {
        return FolderRole::Sent;
    }
    if a.contains("drafts") {
        return FolderRole::Drafts;
    }
    if a.contains("trash") {
        return FolderRole::Trash;
    }
    if a.contains("junk") {
        return FolderRole::Junk;
    }
    if a.contains("archive") {
        return FolderRole::Archive;
    }
    if a.contains("\\all") || a.contains("all") && a.contains("extension") {
        return FolderRole::All;
    }
    if a.contains("flagged") {
        return FolderRole::Starred;
    }
    let n = name.to_lowercase();
    let last = n.rsplit(['/', '.']).next().unwrap_or(&n);
    match last {
        "inbox" => FolderRole::Inbox,
        "sent" | "sent mail" | "sent messages" | "sent items" | "отправленные" => {
            FolderRole::Sent
        }
        "drafts" | "черновики" => FolderRole::Drafts,
        "trash" | "deleted messages" | "deleted items" | "bin" | "корзина" | "удалённые" => {
            FolderRole::Trash
        }
        "junk" | "spam" | "junk e-mail" | "спам" => FolderRole::Junk,
        "archive" | "архив" => FolderRole::Archive,
        "all mail" => FolderRole::All,
        "starred" | "flagged" => FolderRole::Starred,
        _ => FolderRole::Other,
    }
}

impl ImapProvider {
    pub async fn connect(
        host: &str,
        port: u16,
        user: &str,
        cred: Credential,
    ) -> Result<ImapProvider> {
        let tcp = TcpStream::connect((host, port)).await?;
        let domain = rustls::pki_types::ServerName::try_from(host.to_string())
            .map_err(|e| Error::Tls(e.to_string()))?;
        let tls = tls_connector()
            .connect(domain, tcp)
            .await
            .map_err(|e| Error::Tls(e.to_string()))?;
        let mut client = async_imap::Client::new(tls);
        // Consume the server greeting.
        let _greeting = client
            .read_response()
            .await
            .map_err(|e| Error::Imap(e.to_string()))?;
        let session = match cred {
            Credential::Password(p) => client
                .login(user, &p)
                .await
                .map_err(|e| Error::Auth(e.0.to_string()))?,
            Credential::AccessToken(t) => client
                .authenticate(
                    "XOAUTH2",
                    XOAuth2 {
                        user: user.to_string(),
                        token: t,
                    },
                )
                .await
                .map_err(|e| Error::Auth(e.0.to_string()))?,
        };
        Ok(ImapProvider {
            session: Some(session),
            selected: None,
            host: host.to_string(),
        })
    }

    fn s(&mut self) -> Result<&mut Session> {
        self.session
            .as_mut()
            .ok_or_else(|| Error::Imap("session closed".into()))
    }

    pub fn host(&self) -> &str {
        &self.host
    }
}

impl Provider for ImapProvider {
    async fn list_folders(&mut self) -> Result<Vec<RemoteFolder>> {
        let s = self.s()?;
        let names: Vec<async_imap::types::Name> =
            s.list(Some(""), Some("*")).await?.try_collect().await?;
        Ok(names
            .iter()
            .map(|n| {
                let attrs = format!("{:?}", n.attributes());
                let selectable = !attrs.to_lowercase().contains("noselect");
                RemoteFolder {
                    name: n.name().to_string(),
                    role: role_for(n.name(), &attrs),
                    selectable,
                }
            })
            .collect())
    }

    async fn select(&mut self, folder: &str) -> Result<FolderState> {
        let s = self.s()?;
        let mb = s.select(folder).await?;
        self.selected = Some(folder.to_string());
        Ok(FolderState {
            uidvalidity: mb.uid_validity.unwrap_or(0),
            uidnext: mb.uid_next.unwrap_or(1),
            exists: mb.exists,
            highest_modseq: mb.highest_modseq,
        })
    }

    async fn uids(&mut self) -> Result<Vec<u32>> {
        let s = self.s()?;
        let set = s.uid_search("ALL").await?;
        let mut v: Vec<u32> = set.into_iter().collect();
        v.sort_unstable();
        Ok(v)
    }

    async fn fetch(&mut self, uids: &[u32]) -> Result<Vec<FetchedMessage>> {
        if uids.is_empty() {
            return Ok(vec![]);
        }
        let s = self.s()?;
        let mut out = Vec::with_capacity(uids.len());
        for chunk in uids.chunks(25) {
            let set = chunk
                .iter()
                .map(|u| u.to_string())
                .collect::<Vec<_>>()
                .join(",");
            let fetches: Vec<async_imap::types::Fetch> = s
                .uid_fetch(&set, "(UID FLAGS RFC822.SIZE BODY.PEEK[])")
                .await?
                .try_collect()
                .await?;
            for f in fetches {
                let Some(uid) = f.uid else { continue };
                out.push(FetchedMessage {
                    uid,
                    flags: to_flags(f.flags()),
                    size: f.size.unwrap_or(0),
                    raw: f.body().map(|b| b.to_vec()).unwrap_or_default(),
                });
            }
        }
        Ok(out)
    }

    async fn fetch_flags(&mut self, since_modseq: Option<u64>) -> Result<Vec<FlagChange>> {
        let s = self.s()?;
        let query = match since_modseq {
            Some(m) => format!("(UID FLAGS) (CHANGEDSINCE {m})"),
            None => "(UID FLAGS)".to_string(),
        };
        let fetches: Vec<async_imap::types::Fetch> =
            s.uid_fetch("1:*", &query).await?.try_collect().await?;
        Ok(fetches
            .iter()
            .filter_map(|f| {
                f.uid.map(|uid| FlagChange {
                    uid,
                    flags: to_flags(f.flags()),
                })
            })
            .collect())
    }

    async fn store_flags(&mut self, uid: u32, add: Flags, remove: Flags) -> Result<()> {
        let s = self.s()?;
        if add.0 != 0 {
            let _: Vec<_> = s
                .uid_store(
                    uid.to_string(),
                    format!("+FLAGS.SILENT {}", add.imap_atoms()),
                )
                .await?
                .try_collect()
                .await?;
        }
        if remove.0 != 0 {
            let _: Vec<_> = s
                .uid_store(
                    uid.to_string(),
                    format!("-FLAGS.SILENT {}", remove.imap_atoms()),
                )
                .await?
                .try_collect()
                .await?;
        }
        Ok(())
    }

    async fn move_to(&mut self, uid: u32, dest: &str) -> Result<()> {
        let s = self.s()?;
        s.uid_mv(uid.to_string(), dest).await?;
        Ok(())
    }

    async fn append(&mut self, folder: &str, raw: &[u8], flags: Flags) -> Result<()> {
        let s = self.s()?;
        let atoms = flags.imap_atoms();
        let flag_str = if flags.0 == 0 {
            None
        } else {
            Some(atoms.as_str())
        };
        s.append(folder, flag_str, None, raw).await?;
        Ok(())
    }

    async fn idle(&mut self, timeout: Duration) -> Result<IdleOutcome> {
        let session = self
            .session
            .take()
            .ok_or_else(|| Error::Imap("session closed".into()))?;
        let mut handle = session.idle();
        handle.init().await?;
        let (wait, _stop) = handle.wait_with_timeout(timeout);
        let outcome = match wait.await? {
            async_imap::extensions::idle::IdleResponse::NewData(_) => IdleOutcome::Changed,
            _ => IdleOutcome::Timeout,
        };
        self.session = Some(handle.done().await?);
        Ok(outcome)
    }

    async fn logout(&mut self) -> Result<()> {
        if let Some(mut s) = self.session.take() {
            let _ = s.logout().await;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roles_from_names_and_attrs() {
        assert_eq!(role_for("INBOX", "[]"), FolderRole::Inbox);
        assert_eq!(
            role_for("[Gmail]/Sent Mail", "[Extension(\"\\\\Sent\")]"),
            FolderRole::Sent
        );
        assert_eq!(
            role_for("[Gmail]/All Mail", "[Extension(\"\\\\All\")]"),
            FolderRole::All
        );
        assert_eq!(role_for("Отправленные", "[]"), FolderRole::Sent);
        assert_eq!(role_for("Projects/2026", "[]"), FolderRole::Other);
    }
}
