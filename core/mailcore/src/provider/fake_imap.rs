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
    /// X-GM-MSGID: the same number for a message's copy in every Gmail label.
    pub gm: u64,
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
    /// Behave like Gmail: X-GM-EXT-1, labels as folders over one message store.
    pub gmail: bool,
    next_gm: u64,
    /// Hang in the middle of the next body FETCH, like a server that stopped answering.
    pub stall_fetch: bool,
    /// An older server: no MOVE and no UIDPLUS, so moves are COPY + \Deleted + EXPUNGE.
    pub old_server: bool,
    /// Answer every UID STORE with a NO that may pass (a flaky server).
    pub refuse_store: bool,
}

/// Marks a reply the server sends only in part before going silent.
const STALLED: &[u8] = b"\0stall\0";

pub const GMAIL_ALL: &str = "[Gmail]/All Mail";
pub const GMAIL_TRASH: &str = "[Gmail]/Trash";
pub const GMAIL_SPAM: &str = "[Gmail]/Spam";

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
        self.next_gm += 1;
        let gm = self.next_gm;
        self.put(name, raw, flags.iter().map(|f| f.to_string()).collect(), gm)
    }

    fn put(&mut self, name: &str, raw: &[u8], flags: Vec<String>, gm: u64) -> u32 {
        let b = self.boxes.get_mut(name).expect("mailbox exists");
        let uid = b.next_uid;
        b.next_uid += 1;
        b.msgs.push(FakeMsg {
            uid,
            flags,
            raw: raw.to_vec(),
            gm,
        });
        self.version += 1;
        uid
    }

    /// Gmail's folder tree: INBOX plus `[Gmail]/…` special-use boxes under a `\\Noselect` parent.
    pub fn gmail_setup(&mut self) {
        self.gmail = true;
        self.add_box("INBOX", None);
        self.add_box("[Gmail]", Some("\\Noselect"));
        self.add_box(GMAIL_ALL, Some("\\All"));
        self.add_box("[Gmail]/Sent Mail", Some("\\Sent"));
        self.add_box(GMAIL_SPAM, Some("\\Junk"));
        self.add_box(GMAIL_TRASH, Some("\\Trash"));
    }

    /// One Gmail message: a copy in All Mail and in each label box, one X-GM-MSGID.
    pub fn deliver_gmail(&mut self, labels: &[&str], raw: &[u8], flags: &[&str]) -> u64 {
        self.next_gm += 1;
        let gm = self.next_gm;
        let flags: Vec<String> = flags.iter().map(|f| f.to_string()).collect();
        self.put(GMAIL_ALL, raw, flags.clone(), gm);
        for l in labels {
            self.put(l, raw, flags.clone(), gm);
        }
        gm
    }

    /// Boxes holding a copy of Gmail message `gm`.
    pub fn where_is(&self, gm: u64) -> Vec<String> {
        self.boxes
            .iter()
            .filter(|(_, b)| b.msgs.iter().any(|m| m.gm == gm))
            .map(|(n, _)| n.clone())
            .collect()
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
        Self::start_mode(user, password, false).await
    }

    /// A server on a plain port that wants STARTTLS before anything else, the way
    /// port 143 and Proton Bridge work.
    pub async fn start_starttls(user: &str, password: &str) -> FakeImap {
        Self::start_mode(user, password, true).await
    }

    async fn start_mode(user: &str, password: &str, starttls: bool) -> FakeImap {
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
                    if starttls {
                        let mut tcp = tcp;
                        if plain_until_starttls(&mut tcp, &state)
                            .await
                            .unwrap_or(false)
                        {
                            if let Ok(tls) = acceptor.accept(tcp).await {
                                let _ = serve(tls, state, creds, false).await;
                            }
                        }
                    } else if let Ok(tls) = acceptor.accept(tcp).await {
                        let _ = serve(tls, state, creds, true).await;
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

/// Remove the \Deleted messages [which] allows; the untagged EXPUNGE lines, highest
/// sequence number first so each stays valid.
fn expunge(b: &mut FakeBox, which: impl Fn(&FakeMsg) -> bool) -> Vec<u8> {
    let mut out = Vec::new();
    let mut seqs = Vec::new();
    for (i, m) in b.msgs.iter().enumerate() {
        if m.flags.iter().any(|f| f == "\\Deleted") && which(m) {
            seqs.push(i + 1);
        }
    }
    for seq in seqs.iter().rev() {
        b.msgs.remove(seq - 1);
        out.extend_from_slice(format!("* {seq} EXPUNGE\r\n").as_bytes());
    }
    out
}

/// Gmail's MOVE: the message already left `src` (All Mail keeps it, except into Trash or
/// Spam). Into All Mail it only drops the source label; into Trash or Spam it leaves every
/// label; into another label it adds that label.
fn gmail_move(st: &mut FakeState, src: &str, dest: &str, m: FakeMsg) {
    if src == GMAIL_ALL && dest != GMAIL_TRASH && dest != GMAIL_SPAM {
        let all = st.boxes.get_mut(GMAIL_ALL).expect("All Mail");
        all.msgs.push(m.clone());
        all.msgs.sort_by_key(|x| x.uid);
    }
    if dest == GMAIL_ALL {
        return;
    }
    if dest == GMAIL_TRASH || dest == GMAIL_SPAM {
        for b in st.boxes.values_mut() {
            b.msgs.retain(|x| x.gm != m.gm);
        }
    }
    if !st.boxes[dest].msgs.iter().any(|x| x.gm == m.gm) {
        st.put(dest, &m.raw.clone(), m.flags.clone(), m.gm);
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

fn fetch_line(seq: usize, m: &FakeMsg, body: bool, gm: bool) -> Vec<u8> {
    let mut out =
        format!("* {seq} FETCH (UID {} FLAGS ({})", m.uid, m.flags.join(" ")).into_bytes();
    if gm {
        out.extend_from_slice(format!(" X-GM-MSGID {}", m.gm).as_bytes());
    }
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

/// The plain part of a STARTTLS session: a greeting, then only CAPABILITY, NOOP and
/// STARTTLS. `true` once the client asked for TLS and the stream should be upgraded.
async fn plain_until_starttls(
    tcp: &mut tokio::net::TcpStream,
    state: &Arc<Mutex<FakeState>>,
) -> io::Result<bool> {
    let caps = "IMAP4rev1 STARTTLS LOGINDISABLED";
    tcp.write_all(format!("* OK [CAPABILITY {caps}] fake plain\r\n").as_bytes())
        .await?;
    loop {
        // One byte at a time, so nothing past the command line is buffered and lost
        // when the stream turns into TLS.
        let mut line = Vec::new();
        loop {
            let mut b = [0u8; 1];
            if tcp.read(&mut b).await? == 0 {
                return Ok(false);
            }
            line.push(b[0]);
            if b[0] == b'\n' {
                break;
            }
        }
        let line = String::from_utf8_lossy(&line)
            .trim_end_matches(['\r', '\n'])
            .to_string();
        let (tag, rest) = line.split_once(' ').unwrap_or((line.as_str(), ""));
        let cmd = rest
            .split(' ')
            .next()
            .unwrap_or_default()
            .to_ascii_uppercase();
        state.lock().unwrap().log.push(if cmd == "LOGIN" {
            "LOGIN …".into()
        } else {
            rest.to_string()
        });
        let reply = match cmd.as_str() {
            "STARTTLS" => {
                tcp.write_all(format!("{tag} OK Begin TLS negotiation now\r\n").as_bytes())
                    .await?;
                return Ok(true);
            }
            "CAPABILITY" => format!("* CAPABILITY {caps}\r\n{tag} OK CAPABILITY completed\r\n"),
            "NOOP" => format!("{tag} OK NOOP completed\r\n"),
            "LOGOUT" => {
                tcp.write_all(format!("* BYE\r\n{tag} OK LOGOUT completed\r\n").as_bytes())
                    .await?;
                return Ok(false);
            }
            _ => format!("{tag} NO [PRIVACYREQUIRED] STARTTLS first\r\n"),
        };
        tcp.write_all(reply.as_bytes()).await?;
    }
}

async fn serve<S>(
    stream: S,
    state: Arc<Mutex<FakeState>>,
    creds: (String, String),
    greet: bool,
) -> io::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (r, w) = tokio::io::split(stream);
    let mut r = BufReader::new(r);
    let w: Writer<S> = Arc::new(tokio::sync::Mutex::new(w));
    let caps = {
        let st = state.lock().unwrap();
        if st.old_server {
            "IMAP4rev1 IDLE"
        } else if st.gmail {
            "IMAP4rev1 IDLE MOVE UIDPLUS X-GM-EXT-1"
        } else {
            "IMAP4rev1 IDLE MOVE UIDPLUS"
        }
    };
    if greet {
        send(
            &w,
            format!("* OK [CAPABILITY {caps}] fake ready\r\n").as_bytes(),
        )
        .await?;
    }
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
                let reply = format!("* CAPABILITY {caps}\r\n{}", ok("CAPABILITY"));
                send(&w, reply.as_bytes()).await?;
            }
            "NOOP" => send(&w, ok("NOOP").as_bytes()).await?,
            "EXPUNGE" => {
                let reply = {
                    let mut st = state.lock().unwrap();
                    let out = match selected.as_ref().and_then(|n| st.boxes.get_mut(n)) {
                        Some(b) => expunge(b, |_| true),
                        None => Vec::new(),
                    };
                    st.version += 1;
                    [out, ok("EXPUNGE").into_bytes()].concat()
                };
                send(&w, &reply).await?;
            }
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
                    let old_server = st.old_server;
                    let refuse_store = st.refuse_store;
                    let b = st.boxes.get_mut(&name).expect("selected box");
                    let max = b.msgs.iter().map(|m| m.uid).max().unwrap_or(0);
                    match sub.as_str() {
                        "SEARCH" => {
                            // `HEADER Message-ID "<id>"` narrows to that message; anything
                            // else is ALL.
                            let wanted = args
                                .iter()
                                .position(|a| a.eq_ignore_ascii_case("Message-ID"))
                                .and_then(|i| args.get(i + 1))
                                .map(|v| unquote(v).to_ascii_lowercase());
                            let deleted_only =
                                args.iter().any(|a| a.eq_ignore_ascii_case("DELETED"));
                            let uids: Vec<String> = b
                                .msgs
                                .iter()
                                .filter(|m| {
                                    !deleted_only || m.flags.iter().any(|f| f == "\\Deleted")
                                })
                                .filter(|m| {
                                    wanted.as_ref().is_none_or(|w| {
                                        String::from_utf8_lossy(&m.raw)
                                            .to_ascii_lowercase()
                                            .lines()
                                            .any(|l| {
                                                l.starts_with("message-id:")
                                                    && l.contains(w.as_str())
                                            })
                                    })
                                })
                                .map(|m| m.uid.to_string())
                                .collect();
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
                            let gm = items.contains("X-GM-MSGID");
                            let mut out = Vec::new();
                            if max > 0 {
                                for (i, m) in b.msgs.iter().enumerate() {
                                    if in_set(&set, m.uid, max) {
                                        out.extend(fetch_line(i + 1, m, body, gm));
                                    }
                                }
                            }
                            if body && st.stall_fetch {
                                // Half a response, then nothing: the connection stays open.
                                out.truncate(out.len() / 2);
                                STALLED.to_vec().into_iter().chain(out).collect()
                            } else {
                                out.extend_from_slice(ok("FETCH").as_bytes());
                                out
                            }
                        }
                        "STORE" if refuse_store => {
                            format!("{tag} NO [UNAVAILABLE] try again later\r\n").into_bytes()
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
                                    out.extend(fetch_line(i + 1, m, false, false));
                                }
                            }
                            if st.gmail {
                                // Gmail: flags belong to the message, in every label.
                                let changed: Vec<(u64, Vec<String>)> = st.boxes[&name]
                                    .msgs
                                    .iter()
                                    .filter(|m| in_set(&set, m.uid, max))
                                    .map(|m| (m.gm, m.flags.clone()))
                                    .collect();
                                for bx in st.boxes.values_mut() {
                                    for m in bx.msgs.iter_mut() {
                                        if let Some((_, f)) =
                                            changed.iter().find(|(g, _)| *g == m.gm)
                                        {
                                            m.flags = f.clone();
                                        }
                                    }
                                }
                            }
                            st.version += 1;
                            out.extend_from_slice(ok("STORE").as_bytes());
                            out
                        }
                        "MOVE" if old_server => {
                            format!("{tag} BAD unknown command MOVE\r\n").into_bytes()
                        }
                        "COPY" => {
                            let dest = unquote(args.get(3).map(String::as_str).unwrap_or(""));
                            let copies: Vec<FakeMsg> = b
                                .msgs
                                .iter()
                                .filter(|m| in_set(&set, m.uid, max))
                                .cloned()
                                .collect();
                            match st.boxes.get_mut(&dest) {
                                None => {
                                    format!("{tag} NO [TRYCREATE] no such mailbox\r\n").into_bytes()
                                }
                                Some(d) => {
                                    for mut m in copies {
                                        m.uid = d.next_uid;
                                        d.next_uid += 1;
                                        d.msgs.push(m);
                                    }
                                    st.version += 1;
                                    ok("COPY").into_bytes()
                                }
                            }
                        }
                        "EXPUNGE" if old_server => {
                            format!("{tag} BAD unknown command UID EXPUNGE\r\n").into_bytes()
                        }
                        "EXPUNGE" => {
                            let out = expunge(b, |m| in_set(&set, m.uid, max));
                            st.version += 1;
                            [out, ok("EXPUNGE").into_bytes()].concat()
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
                            if !st.boxes.contains_key(&dest) {
                                // Nothing moved: put the source back as it was.
                                let src = st.boxes.get_mut(&name).expect("selected box");
                                src.msgs.extend(moving.into_iter().map(|(_, m)| m));
                                src.msgs.sort_by_key(|m| m.uid);
                                out = format!("{tag} NO [TRYCREATE] no such mailbox\r\n")
                                    .into_bytes();
                            } else if st.gmail {
                                for (_, m) in moving {
                                    gmail_move(&mut st, &name, &dest, m);
                                }
                                st.version += 1;
                                out.extend_from_slice(ok("MOVE").as_bytes());
                            } else {
                                let d = st.boxes.get_mut(&dest).expect("checked");
                                for (_, mut m) in moving {
                                    m.uid = d.next_uid;
                                    d.next_uid += 1;
                                    d.msgs.push(m);
                                }
                                st.version += 1;
                                out.extend_from_slice(ok("MOVE").as_bytes());
                            }
                            out
                        }
                        _ => format!("{tag} BAD unsupported UID command\r\n").into_bytes(),
                    }
                };
                if let Some(rest) = reply.strip_prefix(STALLED) {
                    send(&w, rest).await?;
                    std::future::pending::<()>().await;
                }
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
    use crate::provider::imap::{Credential, ImapProvider, Transport};
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
                imap_security: Default::default(),
                smtp_security: None,
                local_bridge: false,
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

    /// Sync, then return the INBOX copy of PLAIN ("Design review").
    async fn synced(
        fake: &FakeImap,
    ) -> (
        Arc<Store>,
        SyncEngine,
        crate::model::Account,
        ImapProvider,
        crate::model::Message,
    ) {
        let (store, engine, account) = setup(fake);
        let mut p = connect(fake, "secret").await.unwrap();
        engine
            .sync_account(&account, &mut p, &SyncOptions::default())
            .await
            .unwrap();
        let review = store
            .messages_by_message_id(account.id, "review@studio.dev")
            .unwrap()
            .into_iter()
            .find(|m| m.uid > 0 && m.flags.contains(Flags::SEEN))
            .unwrap();
        (store, engine, account, p, review)
    }

    #[tokio::test]
    async fn an_old_server_without_move_moves_without_touching_other_deleted_mail() {
        let fake = server().await;
        fake.with(|s| {
            s.old_server = true;
            // Another client's "mark as deleted" message, still undeletable there.
            s.deliver("INBOX", LATER, &["\\Deleted"]);
        });
        let (store, engine, account, mut p, review) = synced(&fake).await;
        assert_eq!(
            Actions { store: &store }.archive(review.thread_id).unwrap(),
            1
        );
        let report = engine
            .sync_account(&account, &mut p, &SyncOptions::default())
            .await
            .unwrap();
        assert_eq!(report.ops_replayed, 1, "{:?}", report.errors);
        fake.with(|s| {
            assert_eq!(
                s.msgs("Archive").iter().filter(|m| m.raw == PLAIN).count(),
                1
            );
            // No plain EXPUNGE while someone else's \Deleted mail is there: ours stays
            // marked instead, and theirs survives.
            assert!(s.msgs("INBOX").iter().any(|m| m.raw == LATER));
            let ours = s.msgs("INBOX").iter().find(|m| m.raw == PLAIN).unwrap();
            assert!(ours.flags.iter().any(|f| f == "\\Deleted"));
        });
        // Marked deleted counts as gone here.
        let inbox: Vec<String> = store
            .threads(&crate::search::Query::parse(""), 10)
            .unwrap()
            .into_iter()
            .map(|t| t.subject)
            .collect();
        assert!(!inbox.contains(&"Design review".to_string()), "{inbox:?}");
        assert!(!inbox.contains(&"CI passed".to_string()), "{inbox:?}");
    }

    #[tokio::test]
    async fn an_old_server_move_expunges_when_ours_is_the_only_deleted_one() {
        let fake = server().await;
        fake.with(|s| s.old_server = true);
        let (store, engine, account, mut p, review) = synced(&fake).await;
        Actions { store: &store }.archive(review.thread_id).unwrap();
        engine
            .sync_account(&account, &mut p, &SyncOptions::default())
            .await
            .unwrap();
        fake.with(|s| {
            assert!(s.msgs("INBOX").iter().all(|m| m.raw != PLAIN));
            assert_eq!(
                s.msgs("Archive").iter().filter(|m| m.raw == PLAIN).count(),
                1
            );
        });
    }

    #[tokio::test]
    async fn a_move_by_copy_never_copies_twice() {
        let fake = server().await;
        fake.with(|s| {
            s.old_server = true;
            s.refuse_store = true; // the COPY works, marking the original fails
        });
        let (store, engine, account, mut p, review) = synced(&fake).await;
        Actions { store: &store }.archive(review.thread_id).unwrap();
        engine
            .sync_account(&account, &mut p, &SyncOptions::default())
            .await
            .unwrap();
        fake.with(|s| s.refuse_store = false);
        engine
            .sync_account(&account, &mut p, &SyncOptions::default())
            .await
            .unwrap();
        fake.with(|s| {
            assert_eq!(
                s.msgs("Archive").iter().filter(|m| m.raw == PLAIN).count(),
                1
            );
            assert_eq!(
                s.log.iter().filter(|l| l.starts_with("UID COPY")).count(),
                1
            );
            assert!(s.msgs("INBOX").iter().all(|m| m.raw != PLAIN));
        });
        assert!(store.pending_ops(account.id).unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_change_never_lands_on_another_message_after_a_rebuild() {
        let fake = server().await;
        let (store, engine, account, mut p, review) = synced(&fake).await;
        Actions { store: &store }
            .star(review.thread_id, true)
            .unwrap();
        // The server renumbers INBOX before the change goes out: UID 1 now names nothing
        // we meant (or something else entirely).
        fake.with(|s| s.renumber("INBOX"));
        let report = engine
            .sync_account(&account, &mut p, &SyncOptions::default())
            .await
            .unwrap();
        assert!(
            report
                .errors
                .iter()
                .any(|e| e.contains("rebuilt on the server")),
            "{:?}",
            report.errors
        );
        fake.with(|s| {
            assert!(s
                .msgs("INBOX")
                .iter()
                .all(|m| !m.flags.iter().any(|f| f == "\\Flagged")));
        });
        assert!(store.pending_ops(account.id).unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_waiting_change_survives_the_sync_and_gives_way_when_given_up() {
        let fake = server().await;
        fake.with(|s| s.refuse_store = true);
        let (store, engine, account, mut p, review) = synced(&fake).await;
        Actions { store: &store }
            .star(review.thread_id, true)
            .unwrap();
        let starred = |store: &Store| {
            store
                .messages_by_message_id(account.id, "review@studio.dev")
                .unwrap()
                .iter()
                .any(|m| m.flags.contains(Flags::FLAGGED))
        };
        assert!(starred(&store));
        // The server says "later": the star stays here instead of flickering off.
        for _ in 0..3 {
            engine
                .sync_account(&account, &mut p, &SyncOptions::default())
                .await
                .unwrap();
            assert!(starred(&store));
        }
        // After the last attempt the server's state wins, and the user is told.
        let mut last = None;
        for _ in 3..crate::storage::MAX_ATTEMPTS {
            last = Some(
                engine
                    .sync_account(&account, &mut p, &SyncOptions::default())
                    .await
                    .unwrap(),
            );
        }
        let report = last.unwrap();
        assert!(
            report
                .errors
                .iter()
                .any(|e| e.contains("changing a message's flags")),
            "{:?}",
            report.errors
        );
        engine
            .sync_account(&account, &mut p, &SyncOptions::default())
            .await
            .unwrap();
        assert!(!starred(&store));
    }

    #[tokio::test]
    async fn a_move_the_server_refuses_puts_the_message_back() {
        let fake = server().await;
        fake.with(|s| s.add_box("Gone", None));
        let (store, engine, account, mut p, review) = synced(&fake).await;
        let gone = store
            .folders(account.id)
            .unwrap()
            .into_iter()
            .find(|f| f.remote_name == "Gone")
            .unwrap();
        let moved = Actions { store: &store }
            .move_to_folder(review.thread_id, gone.id)
            .unwrap();
        assert_eq!(moved, 1);
        fake.with(|s| {
            s.boxes.remove("Gone");
        });
        let report = engine
            .sync_account(&account, &mut p, &SyncOptions::default())
            .await
            .unwrap();
        assert!(
            report
                .errors
                .iter()
                .any(|e| e.contains("moving a message to Gone")),
            "{:?}",
            report.errors
        );
        // Back in the inbox in the same sync, not ten syncs later.
        let inbox = store
            .folder_by_role(account.id, FolderRole::Inbox)
            .unwrap()
            .unwrap();
        let copies = store
            .messages_by_message_id(account.id, "review@studio.dev")
            .unwrap();
        assert!(
            copies.iter().any(|m| m.folder_id == inbox.id),
            "the message came back to the inbox: {copies:?}"
        );
        assert!(store
            .threads(&crate::search::Query::parse(""), 10)
            .unwrap()
            .iter()
            .any(|t| t.subject == "Design review"));
        assert!(store.pending_ops(account.id).unwrap().is_empty());
    }

    #[tokio::test]
    async fn an_inbox_only_sync_still_takes_back_a_refused_move_elsewhere() {
        let fake = server().await;
        fake.with(|s| {
            s.add_box("Gone", None);
            s.deliver("Trash", LATER, &["\\Seen"]);
        });
        let (store, engine, account, mut p, _) = synced(&fake).await;
        let ci = store
            .messages_by_message_id(account.id, "ci@github.com")
            .unwrap()[0]
            .clone();
        let gone = store
            .folders(account.id)
            .unwrap()
            .into_iter()
            .find(|f| f.remote_name == "Gone")
            .unwrap();
        // Out of the trash into a folder that is deleted on the web meanwhile.
        assert_eq!(
            Actions { store: &store }
                .move_to_folder(ci.thread_id, gone.id)
                .unwrap(),
            1
        );
        fake.with(|s| {
            s.boxes.remove("Gone");
        });
        // The push after an action syncs only the inbox; Trash is synced anyway, because
        // it has something to take back.
        let inbox_only = SyncOptions {
            roles: vec![FolderRole::Inbox],
            ..SyncOptions::default()
        };
        let report = engine
            .sync_account(&account, &mut p, &inbox_only)
            .await
            .unwrap();
        assert!(
            report
                .errors
                .iter()
                .any(|e| e.contains("moving a message to Gone")),
            "{:?}",
            report.errors
        );
        let trash = store
            .folder_by_role(account.id, FolderRole::Trash)
            .unwrap()
            .unwrap();
        assert!(store
            .messages_by_message_id(account.id, "ci@github.com")
            .unwrap()
            .iter()
            .any(|m| m.folder_id == trash.id));
        assert!(store.given_up_ops(account.id).unwrap().is_empty());
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
                    imap_security: Default::default(),
                    smtp_security: None,
                    local_bridge: false,
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

    const OLD: &[u8] = b"From: Bank <no-reply@bank.example>\r\nTo: z@gmail.com\r\nSubject: Statement\r\nMessage-ID: <stmt@bank.example>\r\nDate: Sun, 20 Sep 2026 09:00:00 +0300\r\n\r\nYour statement is ready.\r\n";

    struct Gmail {
        fake: FakeImap,
        store: Arc<Store>,
        engine: SyncEngine,
        account: crate::model::Account,
        invoice: u64,
        statement: u64,
    }

    async fn gmail() -> Gmail {
        let fake = FakeImap::start("z@gmail.com", "secret").await;
        let (invoice, statement) = fake.with(|s| {
            s.gmail_setup();
            s.add_box("Receipts", None);
            s.deliver_gmail(&["INBOX"], PLAIN, &["\\Seen"]);
            let invoice = s.deliver_gmail(&["INBOX"], INVOICE_EML, &[]);
            let statement = s.deliver_gmail(&[], OLD, &["\\Seen"]); // archived
            s.deliver_gmail(&["[Gmail]/Sent Mail"], REPLY, &["\\Seen"]);
            (invoice, statement)
        });
        let store = Arc::new(Store::open_in_memory().unwrap());
        let account = store
            .add_account(&NewAccount {
                kind: ProviderKind::Gmail,
                email: "z@gmail.com".into(),
                display_name: String::new(),
                imap_host: "localhost".into(),
                imap_port: fake.port,
                smtp_host: String::new(),
                smtp_port: 0,
                auth: AuthKind::Password,
                imap_security: Default::default(),
                smtp_security: None,
                local_bridge: false,
            })
            .unwrap();
        let engine = SyncEngine::new(store.clone());
        let g = Gmail {
            fake,
            store,
            engine,
            account,
            invoice,
            statement,
        };
        g.sync().await;
        g
    }

    impl Gmail {
        async fn sync(&self) -> crate::sync::SyncReport {
            let mut p = ImapProvider::connect_trusting(
                "localhost",
                self.fake.port,
                "z@gmail.com",
                Credential::Password("secret".into()),
                std::slice::from_ref(&self.fake.cert),
            )
            .await
            .unwrap();
            assert!(p.is_gmail());
            let r = self
                .engine
                .sync_account(&self.account, &mut p, &SyncOptions::default())
                .await
                .unwrap();
            p.logout().await.unwrap();
            r
        }

        fn subjects(&self, q: &str) -> Vec<String> {
            self.store
                .threads(&crate::search::Query::parse(q), 20)
                .unwrap()
                .into_iter()
                .map(|t| t.subject)
                .collect()
        }

        fn thread_of(&self, message_id: &str) -> i64 {
            self.store
                .messages_by_message_id(self.account.id, message_id)
                .unwrap()[0]
                .thread_id
        }
    }

    #[tokio::test]
    async fn gmail_shows_one_row_per_message() {
        let g = gmail().await;
        let review = g.thread_of("review@studio.dev");
        // PLAIN sits in INBOX and All Mail, REPLY in Sent and All Mail: still two messages.
        assert_eq!(g.store.thread(review).unwrap().msg_count, 2);
        assert_eq!(g.store.thread_messages(review).unwrap().len(), 2);
        assert_eq!(g.store.unread_count(Some(g.account.id)).unwrap(), 1);
        let mut inbox = g.subjects("");
        inbox.sort();
        assert_eq!(inbox, vec!["Design review", "Invoice for September"]);
        assert_eq!(g.subjects("in:archive"), vec!["Statement"]);
        let copies = g
            .store
            .messages_by_message_id(g.account.id, "inv@studio.dev")
            .unwrap();
        assert_eq!(copies.len(), 2);
        assert!(g.store.dedup_key(copies[0].id).unwrap().starts_with("gm:"));
        // The [Gmail] container is known but never offered as a target.
        let parent = g
            .store
            .folders(g.account.id)
            .unwrap()
            .into_iter()
            .find(|f| f.remote_name == "[Gmail]")
            .unwrap();
        assert!(!parent.selectable);
    }

    #[tokio::test]
    async fn gmail_archive_delete_and_labels_follow_gmail_rules() {
        let g = gmail().await;
        let actions = Actions { store: &g.store };

        // Archive = drop the Inbox label; the All Mail copy stays.
        actions.archive(g.thread_of("inv@studio.dev")).unwrap();
        g.sync().await;
        g.fake
            .with(|s| assert_eq!(s.where_is(g.invoice), vec![GMAIL_ALL]));
        assert!(!g
            .subjects("")
            .contains(&"Invoice for September".to_string()));
        let mut archived = g.subjects("in:archive");
        archived.sort();
        assert_eq!(archived, vec!["Invoice for September", "Statement"]);
        assert_eq!(
            g.store
                .thread(g.thread_of("inv@studio.dev"))
                .unwrap()
                .msg_count,
            1
        );

        // A label from All Mail only adds the label.
        let receipts = g
            .store
            .folders(g.account.id)
            .unwrap()
            .into_iter()
            .find(|f| f.remote_name == "Receipts")
            .unwrap();
        assert_eq!(
            actions
                .move_to_folder(g.thread_of("inv@studio.dev"), receipts.id)
                .unwrap(),
            1
        );
        g.sync().await;
        g.fake.with(|s| {
            let mut at = s.where_is(g.invoice);
            at.sort();
            assert_eq!(at, vec!["Receipts", GMAIL_ALL]);
        });
        assert!(g
            .subjects("in:archive")
            .contains(&"Invoice for September".to_string()));

        // Delete from the archive: one MOVE takes it out of every label.
        actions.trash(g.thread_of("stmt@bank.example")).unwrap();
        g.sync().await;
        g.fake
            .with(|s| assert_eq!(s.where_is(g.statement), vec![GMAIL_TRASH]));
        assert!(!g.subjects("in:archive").contains(&"Statement".to_string()));
        assert_eq!(g.subjects("in:trash"), vec!["Statement"]);
    }

    #[tokio::test]
    async fn gmail_flags_go_once_per_message() {
        let g = gmail().await;
        let before = g.fake.with(|s| s.log.len());
        Actions { store: &g.store }
            .mark_read(g.thread_of("review@studio.dev"), false)
            .unwrap();
        g.sync().await;
        let stores = g.fake.with(|s| {
            s.log[before..]
                .iter()
                .filter(|l| l.to_ascii_uppercase().starts_with("UID STORE"))
                .count()
        });
        assert_eq!(stores, 2, "one STORE per message, not per label copy");
        assert!(g
            .store
            .messages_by_message_id(g.account.id, "review@studio.dev")
            .unwrap()
            .iter()
            .all(|m| !m.flags.contains(Flags::SEEN)));
        assert_eq!(g.store.unread_count(Some(g.account.id)).unwrap(), 2);
    }

    #[tokio::test]
    async fn a_rebuilt_folder_downloads_a_window_not_everything() {
        let fake = FakeImap::start("z@x.dev", "secret").await;
        fake.with(|s| {
            s.add_box("INBOX", None);
            for i in 0..260 {
                let raw = format!(
                    "From: a@x.dev\r\nSubject: n{i}\r\nMessage-ID: <n{i}@x.dev>\r\nDate: Mon, 21 Sep 2026 10:00:00 +0300\r\n\r\nbody\r\n"
                );
                s.deliver("INBOX", raw.as_bytes(), &[]);
            }
        });
        let (_store, engine, account) = setup(&fake);
        let opts = SyncOptions::default();
        let mut p = connect(&fake, "secret").await.unwrap();
        let first = engine.sync_account(&account, &mut p, &opts).await.unwrap();
        assert_eq!(first.fetched, 200);
        fake.with(|s| {
            assert!(
                !s.log.iter().any(|l| l.contains("1:* (UID FLAGS)")),
                "no full flag listing on an empty cache"
            );
        });
        fake.with(|s| s.renumber("INBOX"));
        let again = engine.sync_account(&account, &mut p, &opts).await.unwrap();
        p.logout().await.unwrap();
        assert_eq!(again.fetched, 200);
    }

    #[tokio::test]
    async fn trash_and_spam_keep_their_own_conversations() {
        let g = gmail().await;
        let deleted_reply = b"From: Anna Sokolova <anna@studio.dev>\r\nTo: z@gmail.com\r\nSubject: Re: Design review\r\nMessage-ID: <deleted@studio.dev>\r\nIn-Reply-To: <review@studio.dev>\r\nReferences: <review@studio.dev>\r\nDate: Mon, 21 Sep 2026 11:00:00 +0300\r\n\r\nnever mind\r\n";
        let spam = b"From: Prize <win@spam.example>\r\nTo: z@gmail.com\r\nSubject: Re: Design review\r\nMessage-ID: <spam@spam.example>\r\nDate: Mon, 21 Sep 2026 12:00:00 +0300\r\n\r\nclaim now\r\n";
        g.fake.with(|s| {
            s.deliver(GMAIL_TRASH, deleted_reply, &["\\Seen"]);
            s.deliver(GMAIL_SPAM, spam, &[]);
        });
        g.sync().await;
        let review = g.thread_of("review@studio.dev");
        assert_eq!(g.store.thread(review).unwrap().msg_count, 2);
        assert!(g
            .store
            .thread_messages(review)
            .unwrap()
            .iter()
            .all(|m| m.message_id.as_deref() != Some("deleted@studio.dev")));
        assert_eq!(g.subjects("in:trash"), vec!["Re: Design review"]);
        assert_eq!(g.subjects("in:junk"), vec!["Re: Design review"]);
        assert_ne!(g.thread_of("spam@spam.example"), review);
    }

    #[tokio::test]
    async fn a_stale_inbox_uid_does_not_lose_a_gmail_delete() {
        let g = gmail().await;
        // Archived on the phone; this device has not synced since.
        g.fake.with(|s| {
            let uid = s
                .msgs("INBOX")
                .iter()
                .find(|m| m.gm == g.invoice)
                .unwrap()
                .uid;
            s.remove("INBOX", uid);
        });
        Actions { store: &g.store }
            .trash(g.thread_of("inv@studio.dev"))
            .unwrap();
        g.sync().await;
        g.fake
            .with(|s| assert_eq!(s.where_is(g.invoice), vec![GMAIL_TRASH]));
        assert_eq!(g.subjects("in:trash"), vec!["Invoice for September"]);
    }

    #[tokio::test]
    async fn a_conversation_restores_from_trash() {
        let g = gmail().await;
        let actions = Actions { store: &g.store };
        actions.trash(g.thread_of("stmt@bank.example")).unwrap();
        g.sync().await;
        let inbox = g
            .store
            .folder_by_role(g.account.id, FolderRole::Inbox)
            .unwrap()
            .unwrap();
        assert_eq!(
            actions
                .move_to_folder(g.thread_of("stmt@bank.example"), inbox.id)
                .unwrap(),
            1
        );
        g.sync().await;
        g.fake.with(|s| {
            let mut at = s.where_is(g.statement);
            at.sort();
            assert_eq!(at, vec!["INBOX".to_string()]);
        });
        assert!(g.subjects("").contains(&"Statement".to_string()));
    }

    #[tokio::test]
    async fn older_roots_join_replies_and_holes_fill_in() {
        let fake = FakeImap::start("z@x.dev", "secret").await;
        fake.with(|s| {
            s.add_box("INBOX", None);
            s.add_box("&BBoEPgRABDcEOAQ9BDA-", None); // "Корзина", no special-use flag
            s.deliver("INBOX", PLAIN, &[]);
            for i in 0..55 {
                let raw = format!(
                    "From: a@x.dev\r\nSubject: filler {i}\r\nMessage-ID: <f{i}@x.dev>\r\nDate: Mon, 21 Sep 2026 10:00:00 +0300\r\n\r\nx\r\n"
                );
                s.deliver("INBOX", raw.as_bytes(), &[]);
            }
            s.deliver("INBOX", REPLY, &[]);
        });
        let (store, engine, account) = setup(&fake);
        let opts = SyncOptions::default();
        let mut p = connect(&fake, "secret").await.unwrap();
        engine.sync_account(&account, &mut p, &opts).await.unwrap();
        let review = store
            .messages_by_message_id(account.id, "review@studio.dev")
            .unwrap()[0]
            .thread_id;
        assert_eq!(
            store.thread(review).unwrap().msg_count,
            2,
            "root and reply in one thread"
        );
        assert!(store
            .folder_by_role(account.id, FolderRole::Trash)
            .unwrap()
            .is_some());

        let inbox = store
            .folder_by_role(account.id, FolderRole::Inbox)
            .unwrap()
            .unwrap();
        store.delete_by_uid(inbox.id, 5).unwrap(); // a lost row
        let again = engine.sync_account(&account, &mut p, &opts).await.unwrap();
        p.logout().await.unwrap();
        assert_eq!(again.fetched, 1);
        assert!(store.uids(inbox.id).unwrap().contains(&5));
    }

    #[tokio::test]
    async fn archive_without_an_archive_folder_is_a_no_op_outside_the_inbox() {
        let fake = FakeImap::start("z@x.dev", "secret").await;
        fake.with(|s| {
            s.add_box("INBOX", None);
            s.add_box("Sent", Some("\\Sent"));
            s.deliver("Sent", REPLY, &["\\Seen"]);
        });
        let (store, engine, account) = setup(&fake);
        let mut p = connect(&fake, "secret").await.unwrap();
        engine
            .sync_account(&account, &mut p, &SyncOptions::default())
            .await
            .unwrap();
        p.logout().await.unwrap();
        let thread = store
            .messages_by_message_id(account.id, "reply@x.dev")
            .unwrap()[0]
            .thread_id;
        assert_eq!(Actions { store: &store }.archive(thread).unwrap(), 0);
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
    async fn a_server_that_stops_mid_fetch_fails_the_sync_instead_of_hanging() {
        let fake = server().await;
        fake.with(|s| s.stall_fetch = true);
        let (_store, engine, account) = setup(&fake);
        let mut p = connect(&fake, "secret").await.unwrap();
        let started = Instant::now();
        let report = engine
            .sync_account(&account, &mut p, &SyncOptions::default())
            .await;
        let elapsed = started.elapsed();
        assert!(elapsed < Duration::from_secs(15), "{elapsed:?}");
        // The folder that hung is reported, in words the classifier knows.
        let errors = match report {
            Ok(r) => r.errors,
            Err(e) => vec![e.to_string()],
        };
        assert!(
            errors.iter().any(|e| e.contains("stopped answering")),
            "{errors:?}"
        );
        let d = crate::diagnose::diagnose(&errors[0], "localhost");
        assert_ne!(d.kind, crate::diagnose::ErrorKind::Auth);
    }

    #[tokio::test]
    async fn a_pause_between_commands_is_not_a_stall() {
        let fake = server().await;
        let mut p = connect(&fake, "secret").await.unwrap();
        p.select("INBOX").await.unwrap();
        // Local work (or a suspended phone) between two commands, longer than the limit.
        tokio::time::sleep(crate::provider::watchdog::STALL + Duration::from_secs(1)).await;
        assert_eq!(p.uids().await.unwrap(), vec![1, 2]);
        p.logout().await.unwrap();
    }

    #[tokio::test]
    async fn after_a_stall_nothing_pretends_to_succeed() {
        let fake = server().await;
        fake.with(|s| s.stall_fetch = true);
        let mut p = connect(&fake, "secret").await.unwrap();
        p.select("INBOX").await.unwrap();
        assert!(matches!(p.fetch(&[1]).await, Err(Error::Io(_))));
        // The dead session is gone: a flag change fails instead of "succeeding" empty.
        let r = p.store_flags(1, Flags::SEEN, Flags::default()).await;
        assert!(r.is_err(), "{r:?}");
        assert!(p.list_folders().await.is_err());
    }

    #[tokio::test]
    async fn idle_outlasts_the_stall_watchdog() {
        let fake = server().await;
        let mut p = connect(&fake, "secret").await.unwrap();
        p.select("INBOX").await.unwrap();
        // Longer than the watchdog's limit: silence during IDLE is expected.
        let quiet = crate::provider::watchdog::STALL + Duration::from_secs(1);
        assert_eq!(p.idle(quiet).await.unwrap(), IdleOutcome::Timeout);
        // And the watchdog is back on afterwards: the session still works.
        assert_eq!(p.uids().await.unwrap(), vec![1, 2]);
        p.logout().await.unwrap();
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

    #[tokio::test]
    async fn starttls_upgrades_before_the_password_leaves() {
        let fake = FakeImap::start_starttls("z@x.dev", "secret").await;
        fake.with(|s| {
            s.add_box("INBOX", None);
            s.deliver("INBOX", PLAIN, &[]);
        });
        let starttls = Transport {
            security: crate::model::Security::StartTls,
            local_bridge: false,
        };
        let mut p = ImapProvider::connect_with(
            "localhost",
            fake.port,
            starttls,
            std::slice::from_ref(&fake.cert),
            "z@x.dev",
            Credential::Password("secret".into()),
        )
        .await
        .unwrap();
        let names: Vec<String> = p
            .list_folders()
            .await
            .unwrap()
            .into_iter()
            .map(|f| f.name)
            .collect();
        assert_eq!(names, ["INBOX"]);
        p.logout().await.unwrap();
        let log = fake.with(|s| s.log.clone());
        let tls_at = log.iter().position(|l| l == "STARTTLS").unwrap();
        let login_at = log.iter().position(|l| l == "LOGIN …").unwrap();
        assert!(tls_at < login_at, "{log:?}");

        // A wrong password still reads as a sign-in failure, not a TLS one.
        let wrong = ImapProvider::connect_with(
            "localhost",
            fake.port,
            starttls,
            std::slice::from_ref(&fake.cert),
            "z@x.dev",
            Credential::Password("nope".into()),
        )
        .await;
        assert!(matches!(wrong, Err(Error::Auth(_))));

        // STARTTLS still checks the certificate.
        let untrusted = ImapProvider::connect_with(
            "localhost",
            fake.port,
            starttls,
            &[],
            "z@x.dev",
            Credential::Password("secret".into()),
        )
        .await;
        assert!(
            matches!(untrusted, Err(Error::Tls(_))),
            "{:?}",
            untrusted.err()
        );
    }

    #[tokio::test]
    async fn starttls_on_a_tls_port_says_so_instead_of_hanging() {
        let fake = server().await; // TLS from the first byte, like 993
        let started = Instant::now();
        let r = ImapProvider::connect_with(
            "localhost",
            fake.port,
            Transport {
                security: crate::model::Security::StartTls,
                local_bridge: false,
            },
            std::slice::from_ref(&fake.cert),
            "z@x.dev",
            Credential::Password("secret".into()),
        )
        .await;
        match r.err() {
            Some(Error::Tls(m)) => assert!(m.contains("may expect TLS instead of STARTTLS"), "{m}"),
            other => panic!("{other:?}"),
        }
        assert!(started.elapsed() < Duration::from_secs(10));
        // Nothing was sent in the clear, so no password either.
        assert!(fake.with(|s| s.log.is_empty()));
    }

    #[tokio::test]
    async fn a_local_bridge_is_trusted_only_on_this_computer() {
        let fake = server().await;
        let bridge = Transport {
            security: crate::model::Security::Tls,
            local_bridge: true,
        };
        for host in ["localhost", "127.0.0.1"] {
            let mut p = ImapProvider::connect_with(
                host,
                fake.port,
                bridge,
                &[],
                "z@x.dev",
                Credential::Password("secret".into()),
            )
            .await
            .unwrap_or_else(|e| panic!("{host}: {e}"));
            p.logout().await.unwrap();
        }
        let remote = ImapProvider::connect_with(
            "imap.example.com",
            993,
            bridge,
            &[],
            "z@x.dev",
            Credential::Password("secret".into()),
        )
        .await;
        match remote.err() {
            Some(Error::Tls(m)) => assert!(m.contains("only accepted from this computer"), "{m}"),
            other => panic!("{other:?}"),
        }
        assert!(crate::provider::imap::is_loopback("::1"));
        assert!(crate::provider::imap::is_loopback("[::1]"));
        assert!(!crate::provider::imap::is_loopback("127.0.0.1.nip.io"));
    }
}
