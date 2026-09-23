//! A small IMAP server over TLS, for tests. It speaks enough of RFC 3501 plus MOVE and IDLE to
//! drive async-imap through the real provider and a full sync: LOGIN, LIST, SELECT, UID SEARCH,
//! UID FETCH, UID STORE, UID MOVE, APPEND, IDLE, LOGOUT. The mailbox tree is shared, so a test
//! can deliver mail, drop messages or bump UIDVALIDITY between syncs and then check what the
//! client did on the server.

use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use std::collections::BTreeMap;
use std::io;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;

#[derive(Clone, Debug)]
pub struct FakeMsg {
    pub uid: u32,
    pub flags: Vec<String>,
    pub raw: Vec<u8>,
}

#[derive(Debug)]
pub struct FakeBox {
    /// Special-use attribute such as `\Sent`.
    pub special: Option<&'static str>,
    pub uidvalidity: u32,
    pub next_uid: u32,
    pub msgs: Vec<FakeMsg>,
}

#[derive(Debug, Default)]
pub struct FakeState {
    pub boxes: BTreeMap<String, FakeBox>,
    /// Bumped on every change; IDLE sessions watch it.
    pub version: u64,
    /// Commands as received (LOGIN arguments left out).
    pub log: Vec<String>,
}

impl FakeState {
    pub fn add_box(&mut self, name: &str, special: Option<&'static str>) {
        self.boxes.insert(
            name.to_string(),
            FakeBox {
                special,
                uidvalidity: 1,
                next_uid: 1,
                msgs: vec![],
            },
        );
        self.version += 1;
    }

    pub fn deliver(&mut self, name: &str, raw: &[u8], flags: &[&str]) -> u32 {
        let b = self.boxes.get_mut(name).expect("mailbox exists");
        let uid = b.next_uid;
        b.next_uid += 1;
        b.msgs.push(FakeMsg {
            uid,
            flags: flags.iter().map(|f| f.to_string()).collect(),
            raw: raw.to_vec(),
        });
        self.version += 1;
        uid
    }

    pub fn remove(&mut self, name: &str, uid: u32) {
        self.boxes
            .get_mut(name)
            .expect("mailbox exists")
            .msgs
            .retain(|m| m.uid != uid);
        self.version += 1;
    }

    /// New UIDVALIDITY and fresh UIDs for everything in the box, as after a server rebuild.
    pub fn renumber(&mut self, name: &str) {
        let b = self.boxes.get_mut(name).expect("mailbox exists");
        b.uidvalidity += 1;
        b.next_uid = 100;
        for m in &mut b.msgs {
            m.uid = b.next_uid;
            b.next_uid += 1;
        }
        self.version += 1;
    }

    pub fn msgs(&self, name: &str) -> &[FakeMsg] {
        &self.boxes[name].msgs
    }
}

pub struct FakeImap {
    pub port: u16,
    /// The server's self-signed certificate; clients must trust it explicitly.
    pub cert: CertificateDer<'static>,
    pub state: Arc<Mutex<FakeState>>,
}

impl FakeImap {
    pub async fn start(user: &str, password: &str) -> FakeImap {
        let ck = rcgen::generate_simple_self_signed(vec!["localhost".to_string()]).unwrap();
        let cert = ck.cert.der().clone();
        let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(ck.signing_key.serialize_der()));
        let config = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![cert.clone()], key)
            .unwrap();
        let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let state = Arc::new(Mutex::new(FakeState::default()));
        let shared = state.clone();
        let creds = (user.to_string(), password.to_string());
        tokio::spawn(async move {
            while let Ok((tcp, _)) = listener.accept().await {
                let (acceptor, state, creds) = (acceptor.clone(), shared.clone(), creds.clone());
                tokio::spawn(async move {
                    if let Ok(tls) = acceptor.accept(tcp).await {
                        let _ = serve(tls, state, creds).await;
                    }
                });
            }
        });
        FakeImap { port, cert, state }
    }

    pub fn with<T>(&self, f: impl FnOnce(&mut FakeState) -> T) -> T {
        f(&mut self.state.lock().unwrap())
    }
}

type Writer<S> = Arc<tokio::sync::Mutex<tokio::io::WriteHalf<S>>>;

async fn send<S: AsyncWrite>(w: &Writer<S>, bytes: &[u8]) -> io::Result<()> {
    let mut w = w.lock().await;
    w.write_all(bytes).await?;
    w.flush().await
}

/// Split a command's arguments: quoted strings and parenthesised lists stay whole.
fn tokenize(s: &str) -> Vec<String> {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b' ' => i += 1,
            b'"' => {
                let mut j = i + 1;
                while j < b.len() && b[j] != b'"' {
                    j += if b[j] == b'\\' { 2 } else { 1 };
                }
                out.push(s[i..(j + 1).min(b.len())].to_string());
                i = j + 1;
            }
            b'(' => {
                let (mut depth, mut j) = (0, i);
                while j < b.len() {
                    match b[j] {
                        b'(' => depth += 1,
                        b')' => {
                            depth -= 1;
                            if depth == 0 {
                                break;
                            }
                        }
                        _ => {}
                    }
                    j += 1;
                }
                out.push(s[i..(j + 1).min(b.len())].to_string());
                i = j + 1;
            }
            _ => {
                let j = s[i..].find(' ').map(|k| i + k).unwrap_or(b.len());
                out.push(s[i..j].to_string());
                i = j;
            }
        }
    }
    out
}

fn unquote(s: &str) -> String {
    match s.strip_prefix('"').and_then(|x| x.strip_suffix('"')) {
        Some(inner) => inner.replace("\\\"", "\"").replace("\\\\", "\\"),
        None => s.to_string(),
    }
}

fn flag_list(s: &str) -> Vec<String> {
    s.trim_matches(|c| c == '(' || c == ')')
        .split_whitespace()
        .map(str::to_string)
        .collect()
}

/// `1,3,5:7` or `2:*` against the UIDs present.
fn in_set(set: &str, uid: u32, max: u32) -> bool {
    set.split(',').any(|part| {
        let num = |x: &str| {
            if x == "*" {
                max
            } else {
                x.parse().unwrap_or(0)
            }
        };
        match part.split_once(':') {
            Some((a, b)) => {
                let (a, b) = (num(a), num(b));
                (a.min(b)..=a.max(b)).contains(&uid)
            }
            None => num(part) == uid,
        }
    })
}

fn fetch_line(seq: usize, m: &FakeMsg, body: bool) -> Vec<u8> {
    let mut out =
        format!("* {seq} FETCH (UID {} FLAGS ({})", m.uid, m.flags.join(" ")).into_bytes();
    if body {
        out.extend_from_slice(
            format!(
                " RFC822.SIZE {} BODY[] {{{}}}\r\n",
                m.raw.len(),
                m.raw.len()
            )
            .as_bytes(),
        );
        out.extend_from_slice(&m.raw);
    }
    out.extend_from_slice(b")\r\n");
    out
}

async fn serve<S>(
    stream: S,
    state: Arc<Mutex<FakeState>>,
    creds: (String, String),
) -> io::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (r, w) = tokio::io::split(stream);
    let mut r = BufReader::new(r);
    let w: Writer<S> = Arc::new(tokio::sync::Mutex::new(w));
    send(
        &w,
        b"* OK [CAPABILITY IMAP4rev1 IDLE MOVE UIDPLUS] fake ready\r\n",
    )
    .await?;
    let mut selected: Option<String> = None;
    loop {
        let mut line = String::new();
        if r.read_line(&mut line).await? == 0 {
            return Ok(());
        }
        let line = line.trim_end_matches(['\r', '\n']).to_string();
        let (tag, rest) = line.split_once(' ').unwrap_or((line.as_str(), ""));
        let args = tokenize(rest);
        let cmd = args
            .first()
            .map(|a| a.to_ascii_uppercase())
            .unwrap_or_default();
        {
            let mut st = state.lock().unwrap();
            let logged = if cmd == "LOGIN" {
                "LOGIN …".to_string()
            } else {
                rest.to_string()
            };
            st.log.push(logged);
        }
        let ok = |what: &str| format!("{tag} OK {what} completed\r\n");
        match cmd.as_str() {
            "LOGIN" => {
                let good = args.get(1).map(|u| unquote(u)) == Some(creds.0.clone())
                    && args.get(2).map(|p| unquote(p)) == Some(creds.1.clone());
                let reply = if good {
                    ok("LOGIN")
                } else {
                    format!("{tag} NO [AUTHENTICATIONFAILED] Invalid credentials\r\n")
                };
                send(&w, reply.as_bytes()).await?;
            }
            "CAPABILITY" => {
                let reply = format!(
                    "* CAPABILITY IMAP4rev1 IDLE MOVE UIDPLUS\r\n{}",
                    ok("CAPABILITY")
                );
                send(&w, reply.as_bytes()).await?;
            }
            "NOOP" => send(&w, ok("NOOP").as_bytes()).await?,
            "LIST" => {
                let mut reply = String::new();
                for (name, b) in &state.lock().unwrap().boxes {
                    let attrs = match b.special {
                        Some(sp) => format!("\\HasNoChildren {sp}"),
                        None => "\\HasNoChildren".to_string(),
                    };
                    reply.push_str(&format!("* LIST ({attrs}) \"/\" \"{name}\"\r\n"));
                }
                reply.push_str(&ok("LIST"));
                send(&w, reply.as_bytes()).await?;
            }
            "SELECT" | "EXAMINE" => {
                let name = unquote(args.get(1).map(String::as_str).unwrap_or(""));
                let reply = match state.lock().unwrap().boxes.get(&name) {
                    None => format!("{tag} NO no such mailbox\r\n"),
                    Some(b) => {
                        selected = Some(name.clone());
                        format!(
                            "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n* {} EXISTS\r\n* 0 RECENT\r\n* OK [UIDVALIDITY {}] UIDs valid\r\n* OK [UIDNEXT {}] next\r\n{tag} OK [READ-WRITE] SELECT completed\r\n",
                            b.msgs.len(),
                            b.uidvalidity,
                            b.next_uid
                        )
                    }
                };
                send(&w, reply.as_bytes()).await?;
            }
            "UID" => {
                let Some(name) = selected.clone() else {
                    send(&w, format!("{tag} BAD no mailbox selected\r\n").as_bytes()).await?;
                    continue;
                };
                let sub = args
                    .get(1)
                    .map(|a| a.to_ascii_uppercase())
                    .unwrap_or_default();
                let set = args.get(2).cloned().unwrap_or_default();
                let reply: Vec<u8> = {
                    let mut st = state.lock().unwrap();
                    let b = st.boxes.get_mut(&name).expect("selected box");
                    let max = b.msgs.iter().map(|m| m.uid).max().unwrap_or(0);
                    match sub.as_str() {
                        "SEARCH" => {
                            let uids: Vec<String> =
                                b.msgs.iter().map(|m| m.uid.to_string()).collect();
                            let mut out = format!("* SEARCH {}", uids.join(" "))
                                .trim_end()
                                .to_string();
                            out.push_str("\r\n");
                            out.push_str(&ok("SEARCH"));
                            out.into_bytes()
                        }
                        "FETCH" => {
                            let items = args[3..].join(" ").to_ascii_uppercase();
                            let body = items.contains("BODY.PEEK[]") || items.contains("BODY[]");
                            let mut out = Vec::new();
                            if max > 0 {
                                for (i, m) in b.msgs.iter().enumerate() {
                                    if in_set(&set, m.uid, max) {
                                        out.extend(fetch_line(i + 1, m, body));
                                    }
                                }
                            }
                            out.extend_from_slice(ok("FETCH").as_bytes());
                            out
                        }
                        "STORE" => {
                            let op = args
                                .get(3)
                                .map(|a| a.to_ascii_uppercase())
                                .unwrap_or_default();
                            let flags = flag_list(args.get(4).map(String::as_str).unwrap_or(""));
                            let mut out = Vec::new();
                            for (i, m) in b.msgs.iter_mut().enumerate() {
                                if !in_set(&set, m.uid, max) {
                                    continue;
                                }
                                if op.starts_with('+') {
                                    for f in &flags {
                                        if !m.flags.contains(f) {
                                            m.flags.push(f.clone());
                                        }
                                    }
                                } else if op.starts_with('-') {
                                    m.flags.retain(|f| !flags.contains(f));
                                } else {
                                    m.flags = flags.clone();
                                }
                                if !op.contains("SILENT") {
                                    out.extend(fetch_line(i + 1, m, false));
                                }
                            }
                            st.version += 1;
                            out.extend_from_slice(ok("STORE").as_bytes());
                            out
                        }
                        "MOVE" => {
                            let dest = unquote(args.get(3).map(String::as_str).unwrap_or(""));
                            let mut moving = Vec::new();
                            let mut kept = Vec::new();
                            for (i, m) in b.msgs.drain(..).enumerate() {
                                if in_set(&set, m.uid, max) {
                                    moving.push((i, m));
                                } else {
                                    kept.push(m);
                                }
                            }
                            b.msgs = kept;
                            let mut out = Vec::new();
                            // Expunge from the highest sequence number down so each stays valid.
                            for (i, _) in moving.iter().rev() {
                                out.extend_from_slice(
                                    format!("* {} EXPUNGE\r\n", i + 1).as_bytes(),
                                );
                            }
                            match st.boxes.get_mut(&dest) {
                                Some(d) => {
                                    for (_, mut m) in moving {
                                        m.uid = d.next_uid;
                                        d.next_uid += 1;
                                        d.msgs.push(m);
                                    }
                                    st.version += 1;
                                    out.extend_from_slice(ok("MOVE").as_bytes());
                                }
                                None => {
                                    out = format!("{tag} NO [TRYCREATE] no such mailbox\r\n")
                                        .into_bytes();
                                }
                            }
                            out
                        }
                        _ => format!("{tag} BAD unsupported UID command\r\n").into_bytes(),
                    }
                };
                send(&w, &reply).await?;
            }
            "APPEND" => {
                let name = unquote(args.get(1).map(String::as_str).unwrap_or(""));
                let flags = args
                    .iter()
                    .find(|a| a.starts_with('('))
                    .map(|a| flag_list(a))
                    .unwrap_or_default();
                let len: usize = args
                    .last()
                    .and_then(|a| a.strip_prefix('{'))
                    .and_then(|a| a.strip_suffix('}'))
                    .and_then(|n| n.parse().ok())
                    .unwrap_or(0);
                send(&w, b"+ Ready for literal data\r\n").await?;
                let mut raw = vec![0u8; len];
                r.read_exact(&mut raw).await?;
                let mut end = String::new();
                r.read_line(&mut end).await?;
                let reply = {
                    let mut st = state.lock().unwrap();
                    if st.boxes.contains_key(&name) {
                        let flags: Vec<&str> = flags.iter().map(String::as_str).collect();
                        let uid = st.deliver(&name, &raw, &flags);
                        let v = st.boxes[&name].uidvalidity;
                        format!("{tag} OK [APPENDUID {v} {uid}] APPEND completed\r\n")
                    } else {
                        format!("{tag} NO [TRYCREATE] no such mailbox\r\n")
                    }
                };
                send(&w, reply.as_bytes()).await?;
            }
            "IDLE" => {
                send(&w, b"+ idling\r\n").await?;
                let name = selected.clone().unwrap_or_default();
                fn count(st: &FakeState, name: &str) -> usize {
                    st.boxes.get(name).map(|b| b.msgs.len()).unwrap_or(0)
                }
                let (start, mut seen) = {
                    let st = state.lock().unwrap();
                    (st.version, count(&st, &name))
                };
                // A watcher writes EXISTS while the main loop waits for DONE; it is stopped by a
                // flag rather than aborted, so it never leaves half a line on the wire.
                let stop = Arc::new(AtomicBool::new(false));
                let watcher = {
                    let (stop, state, w) = (stop.clone(), state.clone(), w.clone());
                    tokio::spawn(async move {
                        let mut version = start;
                        while !stop.load(Ordering::SeqCst) {
                            tokio::time::sleep(Duration::from_millis(40)).await;
                            let update = {
                                let st = state.lock().unwrap();
                                if st.version == version {
                                    None
                                } else {
                                    version = st.version;
                                    Some(count(&st, &name))
                                }
                            };
                            if let Some(n) = update.filter(|n| *n != seen) {
                                seen = n;
                                if send(&w, format!("* {n} EXISTS\r\n").as_bytes())
                                    .await
                                    .is_err()
                                {
                                    return;
                                }
                            }
                        }
                    })
                };
                let mut done = String::new();
                r.read_line(&mut done).await?;
                stop.store(true, Ordering::SeqCst);
                let _ = watcher.await;
                send(&w, ok("IDLE").as_bytes()).await?;
            }
            "LOGOUT" => {
                send(
                    &w,
                    format!("* BYE fake closing\r\n{}", ok("LOGOUT")).as_bytes(),
                )
                .await?;
                return Ok(());
            }
            _ => send(&w, format!("{tag} BAD unknown command\r\n").as_bytes()).await?,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{AuthKind, Flags, FolderRole, NewAccount, ProviderKind};
    use crate::provider::imap::{Credential, ImapProvider};
    use crate::provider::{IdleOutcome, Provider};
    use crate::storage::Store;
    use crate::sync::{Actions, SyncEngine, SyncOptions};
    use crate::testdata::INVOICE_EML;
    use crate::Error;
    use std::time::Instant;

    const PLAIN: &[u8] = b"From: Anna Sokolova <anna@studio.dev>\r\nTo: z@x.dev\r\nSubject: Design review\r\nMessage-ID: <review@studio.dev>\r\nDate: Mon, 21 Sep 2026 10:00:00 +0300\r\n\r\nMoving it to 15:00.\r\n";
    const REPLY: &[u8] = b"From: Z <z@x.dev>\r\nTo: anna@studio.dev\r\nSubject: Re: Design review\r\nMessage-ID: <reply@x.dev>\r\nIn-Reply-To: <review@studio.dev>\r\nReferences: <review@studio.dev>\r\nDate: Mon, 21 Sep 2026 10:05:00 +0300\r\n\r\nWorks for me.\r\n";
    const LATER: &[u8] = b"From: GitHub <noreply@github.com>\r\nTo: z@x.dev\r\nSubject: CI passed\r\nMessage-ID: <ci@github.com>\r\nDate: Wed, 23 Sep 2026 08:00:00 +0300\r\n\r\nAll six jobs green.\r\n";

    async fn server() -> FakeImap {
        let fake = FakeImap::start("z@x.dev", "secret").await;
        fake.with(|s| {
            s.add_box("INBOX", None);
            s.add_box("Sent", Some("\\Sent"));
            s.add_box("Archive", Some("\\Archive"));
            s.add_box("Trash", Some("\\Trash"));
            s.deliver("INBOX", PLAIN, &["\\Seen"]);
            s.deliver("INBOX", INVOICE_EML, &[]);
            s.deliver("Sent", REPLY, &["\\Seen"]);
        });
        fake
    }

    async fn connect(fake: &FakeImap, password: &str) -> crate::Result<ImapProvider> {
        ImapProvider::connect_trusting(
            "localhost",
            fake.port,
            "z@x.dev",
            Credential::Password(password.to_string()),
            std::slice::from_ref(&fake.cert),
        )
        .await
    }

    fn setup(fake: &FakeImap) -> (Arc<Store>, SyncEngine, crate::model::Account) {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let account = store
            .add_account(&NewAccount {
                kind: ProviderKind::Imap,
                email: "z@x.dev".into(),
                display_name: "Z".into(),
                imap_host: "localhost".into(),
                imap_port: fake.port,
                smtp_host: String::new(),
                smtp_port: 0,
                auth: AuthKind::Password,
            })
            .unwrap();
        (store.clone(), SyncEngine::new(store), account)
    }

    #[tokio::test]
    async fn full_sync_then_local_actions_reach_the_server() {
        let fake = server().await;
        let (store, engine, account) = setup(&fake);
        let opts = SyncOptions::default();

        // First sync: three messages over three folders, one thread across INBOX and Sent.
        let mut p = connect(&fake, "secret").await.unwrap();
        let report = engine.sync_account(&account, &mut p, &opts).await.unwrap();
        p.logout().await.unwrap();
        assert_eq!(report.fetched, 3);
        let inbox = store
            .folder_by_role(account.id, FolderRole::Inbox)
            .unwrap()
            .unwrap();
        assert_eq!(inbox.uidvalidity, Some(1));
        assert_eq!(store.uids(inbox.id).unwrap(), vec![1, 2]);
        assert_eq!(store.unread_count(Some(account.id)).unwrap(), 1);

        let review = &store
            .messages_by_message_id(account.id, "review@studio.dev")
            .unwrap()[0];
        assert_eq!(store.thread(review.thread_id).unwrap().msg_count, 2);

        let invoice = store
            .messages_by_message_id(account.id, "inv@studio.dev")
            .unwrap()[0]
            .clone();
        assert!(invoice.has_attachment);
        assert_eq!(store.attachments(invoice.id).unwrap().len(), 2);
        assert_eq!(store.raw(invoice.id).unwrap().as_deref(), Some(INVOICE_EML));

        // Local-first: read + archive the invoice; meanwhile the server gets new mail and
        // loses the plain message.
        let actions = Actions { store: &store };
        actions.mark_read(invoice.thread_id, true).unwrap();
        actions.archive(invoice.thread_id).unwrap();
        fake.with(|s| {
            s.deliver("INBOX", LATER, &[]);
            s.remove("INBOX", 1);
        });

        let mut p = connect(&fake, "secret").await.unwrap();
        let report = engine.sync_account(&account, &mut p, &opts).await.unwrap();
        p.logout().await.unwrap();
        assert_eq!(report.ops_replayed, 2);

        fake.with(|s| {
            assert_eq!(
                s.msgs("INBOX").iter().map(|m| m.uid).collect::<Vec<_>>(),
                vec![3]
            );
            let archived = &s.msgs("Archive")[0];
            assert_eq!(archived.raw, INVOICE_EML);
            assert!(archived.flags.contains(&"\\Seen".to_string()));
        });
        assert_eq!(store.uids(inbox.id).unwrap(), vec![3]);
        let archive = store
            .folder_by_role(account.id, FolderRole::Archive)
            .unwrap()
            .unwrap();
        assert_eq!(store.uids(archive.id).unwrap(), vec![1]);
        let moved = &store
            .messages_by_message_id(account.id, "inv@studio.dev")
            .unwrap()[0];
        assert_eq!(moved.folder_id, archive.id);
        assert!(moved.flags.contains(Flags::SEEN));
    }

    #[tokio::test]
    async fn move_to_a_custom_folder_reaches_the_server() {
        let fake = server().await;
        fake.with(|s| s.add_box("Projects/2026", None));
        let (store, engine, account) = setup(&fake);
        let opts = SyncOptions::default();
        let mut p = connect(&fake, "secret").await.unwrap();
        engine.sync_account(&account, &mut p, &opts).await.unwrap();

        // The reply lives in Sent and stays there; the INBOX copy moves.
        let review = store
            .messages_by_message_id(account.id, "review@studio.dev")
            .unwrap()[0]
            .clone();
        let projects = store
            .folders(account.id)
            .unwrap()
            .into_iter()
            .find(|f| f.remote_name == "Projects/2026")
            .unwrap();
        let moved = Actions { store: &store }
            .move_to_folder(review.thread_id, projects.id)
            .unwrap();
        assert_eq!(moved, 1);
        let report = engine.sync_account(&account, &mut p, &opts).await.unwrap();
        p.logout().await.unwrap();
        assert_eq!(report.ops_replayed, 1);

        fake.with(|s| {
            assert_eq!(s.msgs("Projects/2026").len(), 1);
            assert_eq!(s.msgs("Projects/2026")[0].raw, PLAIN);
            assert_eq!(s.msgs("Sent").len(), 1);
            assert!(s.msgs("INBOX").iter().all(|m| m.raw != PLAIN));
        });
    }

    #[tokio::test]
    async fn removing_one_account_keeps_the_other_syncing() {
        let first = server().await;
        let second = FakeImap::start("b@y.dev", "pw").await;
        second.with(|s| {
            s.add_box("INBOX", None);
            for i in 0..3 {
                let raw = format!(
                    "From: b@y.dev\r\nTo: b@y.dev\r\nSubject: Travel {i}\r\nMessage-ID: <t{i}@y.dev>\r\nDate: Mon, 21 Sep 2026 10:0{i}:00 +0300\r\n\r\nboarding pass\r\n"
                );
                s.deliver("INBOX", raw.as_bytes(), &[]);
            }
        });
        let store = Arc::new(Store::open_in_memory().unwrap());
        let engine = SyncEngine::new(store.clone());
        let add = |email: &str, port: u16| {
            store
                .add_account(&NewAccount {
                    kind: ProviderKind::Imap,
                    email: email.into(),
                    display_name: String::new(),
                    imap_host: "localhost".into(),
                    imap_port: port,
                    smtp_host: String::new(),
                    smtp_port: 0,
                    auth: AuthKind::Password,
                })
                .unwrap()
        };
        let a = add("z@x.dev", first.port);
        let b = add("b@y.dev", second.port);
        let opts = SyncOptions::default();

        let mut pa = connect(&first, "secret").await.unwrap();
        engine.sync_account(&a, &mut pa, &opts).await.unwrap();
        let mut pb = ImapProvider::connect_trusting(
            "localhost",
            second.port,
            "b@y.dev",
            Credential::Password("pw".into()),
            std::slice::from_ref(&second.cert),
        )
        .await
        .unwrap();
        engine.sync_account(&b, &mut pb, &opts).await.unwrap();
        pb.logout().await.unwrap();

        // The second account held the highest message ids; SQLite hands them out again.
        store.delete_account(b.id).unwrap();
        first.with(|s| s.deliver("INBOX", LATER, &[]));
        let report = engine.sync_account(&a, &mut pa, &opts).await.unwrap();
        pa.logout().await.unwrap();
        assert_eq!(report.fetched, 1);

        let search = |q: &str| store.threads(&crate::search::Query::parse(q), 10).unwrap();
        assert_eq!(search("green").len(), 1);
        assert!(search("boarding").is_empty());
    }

    #[tokio::test]
    async fn uidvalidity_change_rebuilds_the_folder() {
        let fake = server().await;
        let (store, engine, account) = setup(&fake);
        let opts = SyncOptions::default();
        let mut p = connect(&fake, "secret").await.unwrap();
        engine.sync_account(&account, &mut p, &opts).await.unwrap();

        fake.with(|s| s.renumber("INBOX"));
        engine.sync_account(&account, &mut p, &opts).await.unwrap();
        p.logout().await.unwrap();

        let inbox = store
            .folder_by_role(account.id, FolderRole::Inbox)
            .unwrap()
            .unwrap();
        assert_eq!(inbox.uidvalidity, Some(2));
        assert_eq!(store.uids(inbox.id).unwrap(), vec![100, 101]);
        assert_eq!(
            store
                .messages_by_message_id(account.id, "inv@studio.dev")
                .unwrap()
                .len(),
            1
        );
    }

    #[tokio::test]
    async fn idle_waits_for_mail_and_times_out_quietly() {
        let fake = server().await;
        let mut p = connect(&fake, "secret").await.unwrap();
        p.select("INBOX").await.unwrap();

        // Nothing happens: IDLE must sit out the whole timeout, not return early.
        let t0 = Instant::now();
        assert_eq!(
            p.idle(Duration::from_millis(500)).await.unwrap(),
            IdleOutcome::Timeout
        );
        assert!(
            t0.elapsed() >= Duration::from_millis(450),
            "{:?}",
            t0.elapsed()
        );

        // New mail during IDLE wakes it long before the timeout.
        let state = fake.state.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(200)).await;
            state.lock().unwrap().deliver("INBOX", LATER, &[]);
        });
        let t1 = Instant::now();
        assert_eq!(
            p.idle(Duration::from_secs(20)).await.unwrap(),
            IdleOutcome::Changed
        );
        assert!(t1.elapsed() < Duration::from_secs(5), "{:?}", t1.elapsed());

        // The session is usable afterwards.
        assert_eq!(p.uids().await.unwrap(), vec![1, 2, 3]);
        p.logout().await.unwrap();
    }

    #[tokio::test]
    async fn append_login_failure_and_untrusted_certificates() {
        let fake = server().await;
        let mut p = connect(&fake, "secret").await.unwrap();
        let raw = b"From: z@x.dev\r\nTo: a@x.dev\r\nSubject: hi\r\n\r\nbody\r\n";
        p.append("Sent", raw, Flags::SEEN).await.unwrap();
        p.logout().await.unwrap();
        fake.with(|s| {
            let sent = s.msgs("Sent").last().unwrap();
            assert_eq!(sent.raw, raw);
            assert_eq!(sent.flags, vec!["\\Seen".to_string()]);
        });

        assert!(matches!(connect(&fake, "wrong").await, Err(Error::Auth(_))));

        // The server's self-signed certificate is refused unless trusted on purpose.
        let untrusted = ImapProvider::connect(
            "localhost",
            fake.port,
            "z@x.dev",
            Credential::Password("secret".into()),
        )
        .await;
        assert!(matches!(untrusted, Err(Error::Tls(_))));
    }
}
