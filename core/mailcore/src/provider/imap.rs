//! IMAP over TLS with async-imap on tokio. LOGIN or XOAUTH2.

use super::{FetchedMessage, FlagChange, FolderState, IdleOutcome, Provider, RemoteFolder};
use crate::error::{Error, Result};
use crate::model::{Flags, FolderRole};
use rustls::pki_types::CertificateDer;
use std::collections::{BTreeMap, HashSet};
use std::sync::Arc;
use std::time::Duration;
use tokio::net::TcpStream;
use tokio_rustls::client::TlsStream;
use tokio_rustls::TlsConnector;

use super::watchdog::{keepalive, Armed, Watchdog};

type Session = async_imap::Session<TlsStream<Watchdog<TcpStream>>>;

pub enum Credential {
    Password(String),
    /// Bearer access token for SASL XOAUTH2.
    AccessToken(String),
}

pub struct ImapProvider {
    session: Option<Session>,
    selected: Option<String>,
    host: String,
    /// The server speaks Gmail's IMAP extensions (X-GM-EXT-1).
    gmail: bool,
    /// Off only while IDLE, when silence is the point.
    armed: Armed,
    /// RFC 6851 MOVE; without it a move is COPY, \Deleted and EXPUNGE.
    can_move: bool,
    /// UID EXPUNGE (RFC 4315): expunge one message, not every \Deleted one.
    uidplus: bool,
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

/// Is `host` this machine? Local bridges (Proton Bridge) listen there with a self-signed
/// certificate; nothing else may skip certificate checks.
pub fn is_loopback(host: &str) -> bool {
    host.eq_ignore_ascii_case("localhost")
        || host
            .trim_matches(|c| c == '[' || c == ']')
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_loopback())
}

/// Certificate checks for a local bridge: any certificate is accepted, but the handshake
/// signatures are still verified against it. Only ever used for loopback hosts.
#[derive(Debug)]
struct LocalBridgeVerifier(Arc<rustls::crypto::CryptoProvider>);

impl rustls::client::danger::ServerCertVerifier for LocalBridgeVerifier {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> std::result::Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> std::result::Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> std::result::Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

/// Public web PKI roots plus any extra certificates the caller trusts on purpose; or, for a
/// local bridge on a loopback host, any certificate.
/// How long one step of connecting may take before it counts as no answer.
#[cfg(not(test))]
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
#[cfg(test)]
const CONNECT_TIMEOUT: Duration = Duration::from_secs(2);

async fn within<T>(what: &str, f: impl std::future::Future<Output = T>) -> Result<T> {
    tokio::time::timeout(CONNECT_TIMEOUT, f).await.map_err(|_| {
        Error::Io(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            format!("{what} timed out"),
        ))
    })
}

/// Only a NO or BAD answer to LOGIN means the server refused the credentials. A dropped
/// connection or a garbled reply is not a verdict on the password and must not park the
/// account.
fn login_error(e: async_imap::error::Error) -> Error {
    use async_imap::error::Error as E;
    match e {
        E::No(_) | E::Bad(_) | E::Validate(_) => Error::Auth(e.to_string()),
        E::Io(io) => Error::Io(io),
        other => Error::Imap(other.to_string()),
    }
}

fn tls_connector(
    host: &str,
    local_bridge: bool,
    extra_roots: &[CertificateDer<'static>],
) -> Result<TlsConnector> {
    if local_bridge {
        if !is_loopback(host) {
            return Err(Error::Tls(format!(
                "a self-signed certificate is only accepted from this computer, not from {host}"
            )));
        }
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let config = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(LocalBridgeVerifier(provider)))
            .with_no_client_auth();
        return Ok(TlsConnector::from(Arc::new(config)));
    }
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    for cert in extra_roots {
        roots
            .add(cert.clone())
            .map_err(|e| Error::Tls(format!("extra root: {e}")))?;
    }
    let config = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    Ok(TlsConnector::from(Arc::new(config)))
}

/// How to reach a server: TLS or STARTTLS, and whether it is a local bridge.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Transport {
    pub security: crate::model::Security,
    pub local_bridge: bool,
}

/// Folder names travel in IMAP's modified UTF-7 (RFC 3501 5.1.3): `&BBoEPgRABDcEOAQ9BDA-` is
/// "Корзина". Decode for display; commands keep the raw name. Malformed input stays as is.
pub fn decode_folder_name(raw: &str) -> String {
    use base64::Engine;
    let engine = base64::engine::GeneralPurpose::new(
        &base64::alphabet::IMAP_MUTF7,
        base64::engine::general_purpose::NO_PAD,
    );
    let mut out = String::with_capacity(raw.len());
    let mut rest = raw;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        let after = &rest[i + 1..];
        let Some(end) = after.find('-') else {
            return raw.to_string();
        };
        let chunk = &after[..end];
        if chunk.is_empty() {
            out.push('&');
        } else {
            let Ok(bytes) = engine.decode(chunk) else {
                return raw.to_string();
            };
            if bytes.len() % 2 != 0 {
                return raw.to_string();
            }
            let units: Vec<u16> = bytes
                .chunks(2)
                .map(|p| u16::from_be_bytes([p[0], p[1]]))
                .collect();
            match String::from_utf16(&units) {
                Ok(s) => out.push_str(&s),
                Err(_) => return raw.to_string(),
            }
        }
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    out
}

/// Map special-use attributes and well-known names to a role.
/// Run [command] and collect what [take] picks from its untagged responses.
///
/// async-imap's own readers for SEARCH, LIST and FETCH stop at the tagged reply without
/// looking at it, and at a closed stream they return what they have so far. A NO to
/// `UID SEARCH ALL`, or a connection lost halfway through it, would then read as "the folder
/// is empty" and the sync would delete the whole cache. Here a NO or BAD is an error and a
/// stream that ends early is a lost connection.
async fn checked<T>(
    s: &mut Session,
    command: &str,
    take: impl FnMut(&async_imap::imap_proto::Response<'_>) -> Option<T>,
) -> Result<Vec<T>> {
    match checked_partial(s, command, take).await? {
        (out, None) => Ok(out),
        (_, Some(refused)) => Err(refused),
    }
}

/// Like [checked], but a NO or BAD comes back next to what arrived before it (a server
/// may deliver every message of a FETCH it can and refuse only one).
async fn checked_partial<T>(
    s: &mut Session,
    command: &str,
    mut take: impl FnMut(&async_imap::imap_proto::Response<'_>) -> Option<T>,
) -> Result<(Vec<T>, Option<Error>)> {
    use async_imap::imap_proto::{Response, Status};
    let tag = s.run_command(command).await?;
    let verb = command.split(' ').take(2).collect::<Vec<_>>().join(" ");
    let mut out = Vec::new();
    loop {
        let Some(resp) = s.read_response().await? else {
            return Err(Error::Io(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                format!("the connection closed during {verb}"),
            )));
        };
        match resp.parsed() {
            Response::Done {
                tag: done,
                status,
                code,
                information,
            } if *done == tag => {
                return match status {
                    Status::Ok => Ok((out, None)),
                    // The same wording async-imap uses, so diagnose() and the outbox read
                    // both alike.
                    Status::No => Ok((
                        out,
                        Some(Error::Imap(format!(
                            "no response: code: {code:?}, info: {information:?}"
                        ))),
                    )),
                    Status::Bad => Ok((
                        out,
                        Some(Error::Imap(format!(
                            "bad response: code: {code:?}, info: {information:?}"
                        ))),
                    )),
                    other => Err(Error::Io(std::io::Error::other(format!(
                        "{verb}: {other:?} {information:?}"
                    )))),
                };
            }
            // The server says goodbye mid-command: the connection is going away.
            Response::Data {
                status: Status::Bye,
                information,
                ..
            } => {
                return Err(Error::Io(std::io::Error::new(
                    std::io::ErrorKind::ConnectionAborted,
                    format!("the server closed the connection: {information:?}"),
                )))
            }
            other => {
                if let Some(v) = take(other) {
                    out.push(v);
                }
            }
        }
    }
}

/// UIDs from `* SEARCH` lines.
fn search_ids(r: &async_imap::imap_proto::Response<'_>) -> Option<Vec<u32>> {
    use async_imap::imap_proto::{MailboxDatum, Response};
    match r {
        Response::MailboxData(MailboxDatum::Search(ids)) => Some(ids.clone()),
        _ => None,
    }
}

fn flags_from(names: &[std::borrow::Cow<'_, str>]) -> Flags {
    let mut f = Flags::default();
    for n in names {
        f = match n.to_ascii_lowercase().as_str() {
            "\\seen" => f.with(Flags::SEEN),
            "\\flagged" => f.with(Flags::FLAGGED),
            "\\answered" => f.with(Flags::ANSWERED),
            "\\draft" => f.with(Flags::DRAFT),
            "\\deleted" => f.with(Flags::DELETED),
            _ => f,
        };
    }
    f
}

/// One FETCH response, as far as it carries these items.
#[derive(Default)]
struct FetchParts {
    uid: Option<u32>,
    flags: Option<Flags>,
    size: Option<u32>,
    body: Option<Vec<u8>>,
    gm_msgid: Option<u64>,
}

fn fetch_parts(r: &async_imap::imap_proto::Response<'_>) -> Option<FetchParts> {
    use async_imap::imap_proto::{AttributeValue, Response};
    let Response::Fetch(_, attrs) = r else {
        return None;
    };
    let mut p = FetchParts::default();
    for a in attrs {
        match a {
            AttributeValue::Uid(u) => p.uid = Some(*u),
            AttributeValue::Flags(f) => p.flags = Some(flags_from(f)),
            AttributeValue::Rfc822Size(n) => p.size = Some(*n),
            AttributeValue::GmailMsgId(id) => p.gm_msgid = Some(*id),
            AttributeValue::BodySection {
                section: None,
                data: Some(d),
                ..
            }
            | AttributeValue::Rfc822(Some(d)) => p.body = Some(d.to_vec()),
            _ => {}
        }
    }
    Some(p)
}

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
        Self::connect_trusting(host, port, user, cred, &[]).await
    }

    /// Like `connect`, but also trusts `extra_roots`: a private CA, a local bridge's
    /// self-signed certificate, or a test server. Nothing else loosens verification.
    pub async fn connect_trusting(
        host: &str,
        port: u16,
        user: &str,
        cred: Credential,
        extra_roots: &[CertificateDer<'static>],
    ) -> Result<ImapProvider> {
        Self::connect_with(host, port, Transport::default(), extra_roots, user, cred).await
    }

    /// The general form: TLS from the first byte or STARTTLS, trusted roots, local bridge.
    pub async fn connect_with(
        host: &str,
        port: u16,
        transport: Transport,
        extra_roots: &[CertificateDer<'static>],
        user: &str,
        cred: Credential,
    ) -> Result<ImapProvider> {
        let connector = tls_connector(host, transport.local_bridge, extra_roots)?;
        let tcp = within("connecting", TcpStream::connect((host, port)))
            .await?
            .map_err(Error::Io)?;
        keepalive(&tcp);
        let armed = Armed::new();
        let tcp = Watchdog::new(tcp, armed.clone());
        let domain = rustls::pki_types::ServerName::try_from(host.to_string())
            .map_err(|e| Error::Tls(e.to_string()))?;
        let client = match transport.security {
            crate::model::Security::Tls => {
                let tls = within("the TLS handshake", connector.connect(domain, tcp))
                    .await?
                    .map_err(|e| Error::Tls(e.to_string()))?;
                let mut client = async_imap::Client::new(tls);
                // Consume the server greeting.
                let _greeting = within("the greeting", client.read_response())
                    .await?
                    .map_err(|e| Error::Imap(e.to_string()))?;
                client
            }
            crate::model::Security::StartTls => {
                let mut plain = async_imap::Client::new(tcp);
                // A TLS-only port (993) says nothing in plain text: say which setting to change
                // instead of waiting for the server to give up.
                let no_greeting = || {
                    Error::Tls(
                        "no greeting in plain text: the port may expect TLS instead of STARTTLS"
                            .into(),
                    )
                };
                let _greeting = tokio::time::timeout(CONNECT_TIMEOUT, plain.read_response())
                    .await
                    .map_err(|_| no_greeting())?
                    .map_err(|e| {
                        if e.kind() == std::io::ErrorKind::TimedOut {
                            no_greeting()
                        } else {
                            Error::Imap(e.to_string())
                        }
                    })?;
                within("STARTTLS", plain.run_command_and_check_ok("STARTTLS", None))
                    .await?
                    .map_err(|e| Error::Tls(format!("STARTTLS refused: {e}")))?;
                let tls = within(
                    "the TLS handshake",
                    connector.connect(domain, plain.into_inner()),
                )
                .await?
                .map_err(|e| Error::Tls(e.to_string()))?;
                // No greeting after STARTTLS: the session continues.
                async_imap::Client::new(tls)
            }
        };
        let session = match cred {
            Credential::Password(p) => within("signing in", client.login(user, &p))
                .await?
                .map_err(|(e, _)| login_error(e))?,
            Credential::AccessToken(t) => within(
                "signing in",
                client.authenticate(
                    "XOAUTH2",
                    XOAuth2 {
                        user: user.to_string(),
                        token: t,
                    },
                ),
            )
            .await?
            .map_err(|(e, _)| login_error(e))?,
        };
        let mut session = session;
        let (gmail, can_move, uidplus) = match session.capabilities().await {
            Ok(c) => (
                c.has_str("X-GM-EXT-1"),
                c.has_str("MOVE"),
                c.has_str("UIDPLUS"),
            ),
            // The connection died right after LOGIN: say so rather than hand back a
            // session that answers everything with nothing.
            Err(async_imap::error::Error::Io(e)) => return Err(Error::Io(e)),
            // Unknown: assume the modern commands; a server without them says NO.
            Err(_) => (false, true, true),
        };
        Ok(ImapProvider {
            session: Some(session),
            selected: None,
            host: host.to_string(),
            gmail,
            armed,
            can_move,
            uidplus,
        })
    }

    /// A command that failed on the connection itself leaves a stream async-imap still
    /// writes to but no longer reads: later commands would "succeed" with empty answers.
    /// Drop the session so they fail plainly instead.
    fn after<T>(&mut self, r: Result<T>) -> Result<T> {
        if let Err(Error::Io(_)) = &r {
            self.session = None;
            self.selected = None;
        }
        r
    }

    fn s(&mut self) -> Result<&mut Session> {
        self.session
            .as_mut()
            .ok_or_else(|| Error::Imap("session closed".into()))
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn is_gmail(&self) -> bool {
        self.gmail
    }

    /// UIDs in the selected folder whose Message-ID header is [message_id] (no brackets).
    pub async fn find_message_id(&mut self, message_id: &str) -> Result<Vec<u32>> {
        let query = format!(
            "HEADER Message-ID \"<{}>\"",
            message_id.replace(['"', '\\'], "")
        );
        let r: Result<Vec<u32>> = async {
            let s = self.s()?;
            let mut v: Vec<u32> = checked(s, &format!("UID SEARCH {query}"), search_ids)
                .await?
                .into_iter()
                .flatten()
                .collect();
            v.sort_unstable();
            v.dedup();
            Ok(v)
        }
        .await;
        self.after(r)
    }
}

impl Provider for ImapProvider {
    async fn list_folders(&mut self) -> Result<Vec<RemoteFolder>> {
        let r: Result<Vec<RemoteFolder>> = async {
            use async_imap::imap_proto::{MailboxDatum, Response};
            let s = self.s()?;
            let folders = checked(s, "LIST \"\" \"*\"", |r| match r {
                Response::MailboxData(MailboxDatum::List {
                    name_attributes,
                    name,
                    ..
                }) => {
                    let attrs = format!("{name_attributes:?}");
                    let selectable = !attrs.to_lowercase().contains("noselect");
                    Some(RemoteFolder {
                        name: name.to_string(),
                        // Roles match on the readable name ("Корзина"), commands use the
                        // raw one.
                        role: role_for(&decode_folder_name(name), &attrs),
                        selectable,
                    })
                }
                _ => None,
            })
            .await?;
            // Every server has an INBOX. A list without one is not the folder list.
            if !folders.iter().any(|f| f.name.eq_ignore_ascii_case("INBOX")) {
                return Err(Error::Imap(format!(
                    "the folder list came back without INBOX ({} folders)",
                    folders.len()
                )));
            }
            Ok(folders)
        }
        .await;
        self.after(r)
    }

    async fn select(&mut self, folder: &str) -> Result<FolderState> {
        let r: Result<FolderState> = async {
            let s = self.s()?;
            let mb = s.select(folder).await?;
            // Every SELECT answer carries UIDVALIDITY. Without it the stream ended (async-imap
            // then returns an empty mailbox as if all went well): a dead connection, not a
            // folder whose UIDs changed.
            let Some(uidvalidity) = mb.uid_validity else {
                return Err(Error::Io(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    format!("no answer to SELECT {folder}"),
                )));
            };
            self.selected = Some(folder.to_string());
            Ok(FolderState {
                uidvalidity,
                uidnext: mb.uid_next.unwrap_or(1),
                exists: mb.exists,
                highest_modseq: mb.highest_modseq,
            })
        }
        .await;
        self.after(r)
    }

    async fn uids(&mut self) -> Result<Vec<u32>> {
        let r: Result<Vec<u32>> = async {
            let s = self.s()?;
            let mut v: Vec<u32> = checked(s, "UID SEARCH ALL", search_ids)
                .await?
                .into_iter()
                .flatten()
                .collect();
            v.sort_unstable();
            v.dedup();
            Ok(v)
        }
        .await;
        self.after(r)
    }

    async fn fetch(&mut self, uids: &[u32]) -> Result<Vec<FetchedMessage>> {
        let gmail = self.gmail;
        let r: Result<Vec<FetchedMessage>> = async {
            if uids.is_empty() {
                return Ok(vec![]);
            }
            let query = if gmail {
                "(UID FLAGS RFC822.SIZE X-GM-MSGID BODY.PEEK[])"
            } else {
                "(UID FLAGS RFC822.SIZE BODY.PEEK[])"
            };
            let s = self.s()?;
            let mut out = Vec::with_capacity(uids.len());
            for chunk in uids.chunks(25) {
                let set = chunk
                    .iter()
                    .map(|u| u.to_string())
                    .collect::<Vec<_>>()
                    .join(",");
                let wanted: HashSet<u32> = chunk.iter().copied().collect();
                // A NO for the batch may be about one broken message: keep what came, ask
                // for the rest one by one, and leave out only what the server cannot give,
                // so newer mail still arrives.
                let (mut lines, refused) =
                    checked_partial(s, &format!("UID FETCH {set} {query}"), fetch_parts).await?;
                if let Some(e) = refused {
                    log::warn!("FETCH {set} refused ({e}); asking one by one");
                    let came: HashSet<u32> = lines
                        .iter()
                        .filter(|p| p.body.is_some())
                        .filter_map(|p| p.uid)
                        .collect();
                    for uid in chunk.iter().filter(|u| !came.contains(u)) {
                        match checked_partial(s, &format!("UID FETCH {uid} {query}"), fetch_parts)
                            .await?
                        {
                            (more, None) => lines.extend(more),
                            (_, Some(e)) => log::warn!("UID {uid} cannot be fetched: {e}"),
                        }
                    }
                }
                // A server may split one message over several FETCH lines, and another
                // session's flag change may arrive in between as an extra FETCH: merge by
                // UID, keep only what was asked for, and only messages that came with a body.
                let mut parts: BTreeMap<u32, FetchParts> = BTreeMap::new();
                for p in lines {
                    let Some(uid) = p.uid.filter(|u| wanted.contains(u)) else {
                        continue;
                    };
                    let e = parts.entry(uid).or_default();
                    e.uid = Some(uid);
                    e.flags = p.flags.or(e.flags);
                    e.size = p.size.or(e.size);
                    e.gm_msgid = p.gm_msgid.or(e.gm_msgid);
                    if p.body.is_some() {
                        e.body = p.body;
                    }
                }
                for (uid, p) in parts {
                    let Some(raw) = p.body else { continue };
                    out.push(FetchedMessage {
                        uid,
                        flags: p.flags.unwrap_or_default(),
                        size: p.size.unwrap_or(raw.len() as u32),
                        raw,
                        gm_msgid: p.gm_msgid,
                    });
                }
            }
            Ok(out)
        }
        .await;
        self.after(r)
    }

    async fn fetch_flags(
        &mut self,
        uid_set: &str,
        since_modseq: Option<u64>,
    ) -> Result<Vec<FlagChange>> {
        let r: Result<Vec<FlagChange>> = async {
            let s = self.s()?;
            let query = match since_modseq {
                Some(m) => format!("(UID FLAGS) (CHANGEDSINCE {m})"),
                None => "(UID FLAGS)".to_string(),
            };
            let mut by_uid: BTreeMap<u32, Flags> = BTreeMap::new();
            for p in checked(s, &format!("UID FETCH {uid_set} {query}"), fetch_parts).await? {
                if let (Some(uid), Some(flags)) = (p.uid, p.flags) {
                    by_uid.insert(uid, flags);
                }
            }
            Ok(by_uid
                .into_iter()
                .map(|(uid, flags)| FlagChange { uid, flags })
                .collect())
        }
        .await;
        self.after(r)
    }

    async fn store_flags(&mut self, uid: u32, add: Flags, remove: Flags) -> Result<()> {
        // A checked command, not uid_store(): async-imap ends that stream at the tagged
        // reply without looking at it, so a NO would pass for success and the op would be
        // dropped as done.
        let r: Result<()> = async {
            let s = self.s()?;
            if add.0 != 0 {
                s.run_command_and_check_ok(format!(
                    "UID STORE {uid} +FLAGS.SILENT {}",
                    add.imap_atoms()
                ))
                .await?;
            }
            if remove.0 != 0 {
                s.run_command_and_check_ok(format!(
                    "UID STORE {uid} -FLAGS.SILENT {}",
                    remove.imap_atoms()
                ))
                .await?;
            }
            Ok(())
        }
        .await;
        self.after(r)
    }

    async fn move_to(&mut self, uid: u32, dest: &str) -> Result<()> {
        if !self.can_move {
            self.copy_to(uid, dest).await?;
            return self.delete(uid).await;
        }
        let r: Result<()> = async {
            self.s()?.uid_mv(uid.to_string(), dest).await?;
            Ok(())
        }
        .await;
        self.after(r)
    }

    fn moves_by_copy(&self) -> bool {
        !self.can_move
    }

    async fn copy_to(&mut self, uid: u32, dest: &str) -> Result<()> {
        let r: Result<()> = async {
            self.s()?.uid_copy(uid.to_string(), dest).await?;
            Ok(())
        }
        .await;
        self.after(r)
    }

    async fn delete(&mut self, uid: u32) -> Result<()> {
        let uidplus = self.uidplus;
        let r: Result<()> = async {
            let s = self.s()?;
            s.run_command_and_check_ok(format!("UID STORE {uid} +FLAGS.SILENT (\\Deleted)"))
                .await?;
            if uidplus {
                s.run_command_and_check_ok(format!("UID EXPUNGE {uid}"))
                    .await?;
                return Ok(());
            }
            // Without UIDPLUS, EXPUNGE takes every \Deleted message in the folder, and other
            // clients (mutt, Thunderbird's "mark as deleted") leave some there on purpose.
            // Expunge only when ours is the only one; otherwise it stays marked, which every
            // client (this one too) treats as gone.
            let marked: Vec<u32> = checked(s, "UID SEARCH DELETED", search_ids)
                .await?
                .into_iter()
                .flatten()
                .collect();
            if marked.iter().all(|u| *u == uid) {
                s.run_command_and_check_ok("EXPUNGE").await?;
            }
            Ok(())
        }
        .await;
        self.after(r)
    }

    async fn append(&mut self, folder: &str, raw: &[u8], flags: Flags) -> Result<()> {
        let r: Result<()> = async {
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
        .await;
        self.after(r)
    }

    async fn idle(&mut self, timeout: Duration) -> Result<IdleOutcome> {
        let session = self
            .session
            .take()
            .ok_or_else(|| Error::Imap("session closed".into()))?;
        let mut handle = session.idle();
        handle.init().await?;
        self.armed.set(false);
        let (wait, _stop) = handle.wait_with_timeout(timeout);
        let waited = wait.await;
        self.armed.set(true);
        let outcome = match waited? {
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
    fn folder_names_decode_from_modified_utf7() {
        assert_eq!(decode_folder_name("INBOX"), "INBOX");
        assert_eq!(decode_folder_name("&BBoEPgRABDcEOAQ9BDA-"), "Корзина");
        assert_eq!(
            decode_folder_name("Projects/&BCEERwQ1BEIEMA-"),
            "Projects/Счета"
        );
        assert_eq!(decode_folder_name("R&-D"), "R&D");
        assert_eq!(decode_folder_name("&Jjo-!"), "☺!");
        assert_eq!(decode_folder_name("broken&AAA"), "broken&AAA");
    }

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
        assert_eq!(
            role_for(
                &decode_folder_name("&BB4EQgQ,BEAEMAQyBDsENQQ9BD0ESwQ1-"),
                "[]"
            ),
            FolderRole::Sent
        );
        assert_eq!(role_for("Projects/2026", "[]"), FolderRole::Other);
    }
}
