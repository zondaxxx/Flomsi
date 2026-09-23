//! A transcript of the IMAP conversation, for looking at what a real server says
//! (`mailctl --wire FILE`). It sits above TLS, so it sees the protocol in the clear,
//! and never writes a password: everything the client sends for a LOGIN or AUTHENTICATE,
//! literals and continuation lines included, is masked until the server answers that
//! command. Message bodies are left out beyond a short head.

use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

/// Literals longer than this are replaced by their size.
const KEEP_LITERAL: usize = 200;

static RECORD_TO: Mutex<Option<PathBuf>> = Mutex::new(None);

/// Record every IMAP connection opened from now on into [path] (appended). Fails when
/// the file cannot be written, so a transcript is never silently missing.
pub fn record_to(path: &Path) -> io::Result<()> {
    drop(open(path)?);
    if let Ok(mut p) = RECORD_TO.lock() {
        *p = Some(path.to_path_buf());
    }
    Ok(())
}

/// Addresses, subjects and the start of every message end up in the file: readable by its
/// owner only, and never written through a link someone else placed there.
fn open(path: &Path) -> io::Result<std::fs::File> {
    if std::fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink()) {
        return Err(io::Error::other(format!(
            "{} is a symbolic link; give a plain file",
            path.display()
        )));
    }
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let file = options.open(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(file)
}

/// The transcript for a new connection, when recording is on.
pub fn new_transcript() -> Option<Arc<Mutex<Transcript>>> {
    let path = RECORD_TO.lock().ok()?.clone()?;
    match open(&path) {
        Ok(file) => Some(Arc::new(Mutex::new(Transcript::to_writer(file)))),
        Err(e) => {
            log::warn!("cannot record to {}: {e}", path.display());
            None
        }
    }
}

/// One direction of the conversation, split into lines and literals.
#[derive(Default)]
struct Side {
    line: Vec<u8>,
    /// Bytes still to come in the current literal, and how many of them are written.
    literal_left: usize,
    literal_shown: usize,
    /// The literal is part of a LOGIN or AUTHENTICATE: none of it is written.
    literal_hidden: bool,
    /// A literal announced with `{n}`: its bytes follow only after the server's `+`.
    pending_literal: Option<usize>,
}

pub struct Transcript {
    out: Box<dyn Write + Send>,
    client: Side,
    server: Side,
    /// The tag of a LOGIN or AUTHENTICATE the server has not answered yet: until it does,
    /// whatever the client sends is secret (literals, tokens, answers to challenges).
    secret_tag: Option<String>,
}

impl Transcript {
    fn to_writer(out: impl Write + Send + 'static) -> Transcript {
        Transcript {
            out: Box::new(out),
            client: Side::default(),
            server: Side::default(),
            secret_tag: None,
        }
    }

    fn feed(&mut self, from_client: bool, mut bytes: &[u8]) {
        while !bytes.is_empty() {
            let side = if from_client {
                &mut self.client
            } else {
                &mut self.server
            };
            if side.literal_left > 0 {
                let n = side.literal_left.min(bytes.len());
                let show = if side.literal_hidden {
                    0
                } else {
                    n.min(KEEP_LITERAL.saturating_sub(side.literal_shown))
                };
                if show > 0 {
                    let _ = self.out.write_all(&bytes[..show]);
                }
                side.literal_shown += show;
                side.literal_left -= n;
                if side.literal_left == 0
                    && !side.literal_hidden
                    && side.literal_shown >= KEEP_LITERAL
                {
                    let _ = writeln!(self.out, "\n   […]");
                }
                bytes = &bytes[n..];
                continue;
            }
            match bytes.iter().position(|b| *b == b'\n') {
                Some(i) => {
                    side.line.extend_from_slice(&bytes[..=i]);
                    bytes = &bytes[i + 1..];
                    let line = std::mem::take(&mut side.line);
                    self.line(from_client, &line);
                }
                None => {
                    side.line.extend_from_slice(bytes);
                    bytes = &[];
                }
            }
        }
    }

    fn line(&mut self, from_client: bool, raw: &[u8]) {
        let text = String::from_utf8_lossy(raw);
        let text = text.trim_end_matches(['\r', '\n']);
        // `{123}` or `{123+}` at the end: a literal of that many bytes follows.
        let literal = literal_len(text);
        if from_client {
            let shown = self.mask(text);
            let _ = writeln!(self.out, "C: {shown}");
            match literal {
                // LITERAL+: the bytes follow at once.
                Some((n, true)) => self.start_literal(true, n),
                Some((n, false)) => self.client.pending_literal = Some(n),
                None => {}
            }
            return;
        }
        let _ = writeln!(self.out, "S: {text}");
        if text.starts_with('+') {
            if let Some(n) = self.client.pending_literal.take() {
                self.start_literal(true, n);
            }
        } else if !text.starts_with('*') {
            // A tagged answer ends the command: a literal it refused never comes, and the
            // client's words are no longer secret once LOGIN or AUTHENTICATE is answered.
            self.client.pending_literal = None;
            let tag = text.split(' ').next().unwrap_or("");
            if self.secret_tag.as_deref() == Some(tag) {
                self.secret_tag = None;
            }
        }
        if let Some((n, _)) = literal {
            self.start_literal(false, n);
        }
    }

    fn start_literal(&mut self, from_client: bool, n: usize) {
        let hidden = from_client && self.secret_tag.is_some();
        let side = if from_client {
            &mut self.client
        } else {
            &mut self.server
        };
        side.literal_left = n;
        side.literal_shown = 0;
        side.literal_hidden = hidden;
        if hidden {
            let _ = writeln!(self.out, "   [{n} bytes, masked]");
        } else if n > KEEP_LITERAL {
            let _ = writeln!(self.out, "   [{n} bytes, first {KEEP_LITERAL} shown]");
        }
    }

    fn mask(&mut self, line: &str) -> String {
        if self.secret_tag.is_some() {
            return "*** (masked)".into();
        }
        let mut words = line.splitn(3, ' ');
        let tag = words.next().unwrap_or("");
        let verb = words.next().unwrap_or("");
        match verb.to_ascii_uppercase().as_str() {
            "LOGIN" => {
                self.secret_tag = Some(tag.to_string());
                format!("{tag} LOGIN *** (masked)")
            }
            "AUTHENTICATE" => {
                self.secret_tag = Some(tag.to_string());
                let mechanism = words.next().unwrap_or("").split(' ').next().unwrap_or("");
                format!("{tag} AUTHENTICATE {mechanism} *** (masked)")
            }
            _ => line.to_string(),
        }
    }
}

/// The size of the literal a line announces, and whether it is LITERAL+ (`{n+}`).
fn literal_len(line: &str) -> Option<(usize, bool)> {
    let body = line.strip_suffix('}')?;
    let open = body.rfind('{')?;
    let n = &body[open + 1..];
    let plus = n.ends_with('+');
    Some((n.trim_end_matches('+').parse().ok()?, plus))
}

/// A stream that copies what passes through into a [Transcript].
#[derive(Debug)]
pub struct Tap<S> {
    inner: S,
    transcript: Option<Arc<Mutex<Transcript>>>,
}

impl std::fmt::Debug for Transcript {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Transcript")
    }
}

impl<S> Tap<S> {
    pub fn new(inner: S, transcript: Option<Arc<Mutex<Transcript>>>) -> Tap<S> {
        Tap { inner, transcript }
    }

    fn record(&self, from_client: bool, bytes: &[u8]) {
        if let Some(t) = &self.transcript {
            if let Ok(mut t) = t.lock() {
                t.feed(from_client, bytes);
            }
        }
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for Tap<S> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        let before = buf.filled().len();
        let r = Pin::new(&mut this.inner).poll_read(cx, buf);
        if let (Poll::Ready(Ok(())), Some(_)) = (&r, &this.transcript) {
            let new = buf.filled()[before..].to_vec();
            this.record(false, &new);
        }
        r
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for Tap<S> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        data: &[u8],
    ) -> Poll<io::Result<usize>> {
        let this = self.get_mut();
        let r = Pin::new(&mut this.inner).poll_write(cx, data);
        if let Poll::Ready(Ok(n)) = r {
            this.record(true, &data[..n]);
        }
        r
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_shutdown(cx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Clone, Default)]
    struct Shared(Arc<Mutex<Vec<u8>>>);
    impl Write for Shared {
        fn write(&mut self, b: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(b);
            Ok(b.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn passwords_never_reach_the_transcript_and_bodies_are_cut() {
        let out = Shared::default();
        let mut t = Transcript::to_writer(out.clone());
        // Split across writes the way a socket delivers them.
        t.feed(true, b"a1 LOGIN \"z@x.dev\" \"hunter2");
        t.feed(true, b"-secret\"\r\n");
        t.feed(false, b"a1 OK LOGIN completed\r\n");
        t.feed(true, b"a2 AUTHENTICATE XOAUTH2\r\n");
        t.feed(false, b"+ \r\n");
        t.feed(true, b"dXNlcj16QHguZGV2AWF1dGg9QmVhcmVyIHRva2Vu\r\n");
        // A refused token: the server challenges with its error and the client answers
        // again (an old client sends the token once more).
        t.feed(false, b"+ eyJzdGF0dXMiOiI0MDAifQ==\r\n");
        t.feed(true, b"dXNlcj16QHguZGV2AWF1dGg9QmVhcmVyIHRva2Vu\r\n");
        t.feed(
            false,
            b"a2 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n",
        );
        let body = "x".repeat(1000);
        t.feed(
            false,
            format!("* 1 FETCH (UID 7 BODY[] {{{}}}\r\n{body})\r\n", body.len()).as_bytes(),
        );
        t.feed(false, b"a3 OK FETCH completed\r\n");
        // A password sent as a literal, after the user name as one.
        t.feed(true, b"a4 LOGIN {7}\r\n");
        t.feed(false, b"+ Ready\r\n");
        t.feed(true, b"z@x.dev {13}\r\n");
        t.feed(false, b"+ Ready\r\n");
        t.feed(true, b"literal-pass!\r\n");
        t.feed(false, b"a4 OK LOGIN completed\r\n");
        t.feed(true, b"a5 SELECT INBOX\r\n");
        // An APPEND the server refuses before its literal: the next command is a command.
        t.feed(true, b"a6 APPEND Sent {5000}\r\n");
        t.feed(false, b"a6 NO [TRYCREATE] no such mailbox\r\n");
        t.feed(true, b"a7 NOOP\r\n");
        let text = String::from_utf8(out.0.lock().unwrap().clone()).unwrap();
        assert!(!text.contains("hunter2"), "{text}");
        assert!(!text.contains("dXNlcj16"), "{text}");
        assert!(!text.contains("literal-pass"), "{text}");
        assert!(text.contains("C: a5 SELECT INBOX"), "{text}");
        assert!(text.contains("C: a7 NOOP"), "{text}");
        assert!(text.contains("C: a1 LOGIN *** (masked)"), "{text}");
        assert!(
            text.contains("C: a2 AUTHENTICATE XOAUTH2 *** (masked)"),
            "{text}"
        );
        assert!(text.contains("[1000 bytes, first 200 shown]"), "{text}");
        assert!(
            text.len() < 1100,
            "the body was not cut: {} bytes",
            text.len()
        );
        assert!(text.contains("S: a3 OK FETCH completed"), "{text}");
    }

    #[cfg(unix)]
    #[test]
    fn the_transcript_is_for_its_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("flomsi-wire-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("wire.txt");
        std::fs::write(&file, b"").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
        drop(super::open(&file).unwrap());
        let mode = std::fs::metadata(&file).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let link = dir.join("link.txt");
        std::os::unix::fs::symlink(&file, &link).unwrap();
        assert!(super::open(&link).is_err());
        assert!(super::record_to(&dir.join("missing/wire.txt")).is_err());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
