//! Just enough HTTPS for OAuth token endpoints: one POST of a form, the answer's status and
//! body. Over the same rustls and web PKI roots as IMAP, so no second TLS stack is linked.

use crate::error::{Error, Result};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_rustls::TlsConnector;

const TIMEOUT: Duration = Duration::from_secs(30);

/// Tests trust their own token servers' certificates on top of the web roots.
#[cfg(test)]
pub(crate) static TEST_ROOTS: std::sync::Mutex<Vec<rustls::pki_types::CertificateDer<'static>>> =
    std::sync::Mutex::new(Vec::new());
/// Token answers are a few kilobytes; anything far bigger is not one.
const MAX_BODY: usize = 1024 * 1024;

pub struct Response {
    pub status: u16,
    pub body: String,
}

/// POST `form` (already `application/x-www-form-urlencoded`) to an https [url].
pub async fn post_form(url: &str, form: &str) -> Result<Response> {
    let u = url::Url::parse(url).map_err(|e| Error::Other(format!("{url}: {e}")))?;
    if u.scheme() != "https" {
        return Err(Error::Other(format!("{url}: only https is used")));
    }
    let host = u
        .host_str()
        .ok_or_else(|| Error::Other(format!("{url}: no host")))?
        .to_string();
    let port = u.port().unwrap_or(443);
    let path = match u.query() {
        Some(q) => format!("{}?{q}", u.path()),
        None => u.path().to_string(),
    };
    let request = format!(
        "POST {path} HTTP/1.1\r\nHost: {host}\r\nUser-Agent: Flomsi\r\nAccept: application/json\r\n\
         Content-Type: application/x-www-form-urlencoded\r\nContent-Length: {}\r\n\
         Connection: close\r\n\r\n{form}",
        form.len()
    );
    let raw = tokio::time::timeout(TIMEOUT, exchange(&host, port, request.as_bytes()))
        .await
        .map_err(|_| {
            Error::Io(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                format!("{host} did not answer"),
            ))
        })??;
    parse(&raw)
}

async fn exchange(host: &str, port: u16, request: &[u8]) -> Result<Vec<u8>> {
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    #[cfg(test)]
    for c in TEST_ROOTS.lock().unwrap().iter() {
        let _ = roots.add(c.clone());
    }
    let config = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .map_err(|e| Error::Tls(e.to_string()))?
    .with_root_certificates(roots)
    .with_no_client_auth();
    let name = rustls::pki_types::ServerName::try_from(host.to_string())
        .map_err(|e| Error::Tls(e.to_string()))?;
    let tcp = TcpStream::connect((host, port)).await?;
    let mut tls = TlsConnector::from(Arc::new(config))
        .connect(name, tcp)
        .await
        .map_err(|e| Error::Tls(e.to_string()))?;
    tls.write_all(request).await?;
    tls.flush().await?;
    let mut out = Vec::new();
    let mut buf = [0u8; 8192];
    // Read the answer and no further: how a connection ends after it is not ours to rely
    // on. Google and Microsoft close theirs with bytes that don't decrypt (through some
    // networks at least), which a read to the end reports as an error after the whole
    // answer has come.
    while !complete(&out) {
        let n = match tls.read(&mut buf).await {
            Ok(n) => n,
            // Servers that close without close_notify: what came is the answer.
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => 0,
            Err(e) => {
                // The records that decrypted before the one that didn't are still held by
                // rustls: when they finish the answer, the answer stands.
                let reader = &mut tls.get_mut().1;
                loop {
                    match std::io::Read::read(&mut reader.reader(), &mut buf) {
                        Ok(k) if k > 0 => out.extend_from_slice(&buf[..k]),
                        _ => break,
                    }
                }
                if complete(&out) {
                    break;
                }
                return Err(e.into());
            }
        };
        if n == 0 {
            break;
        }
        out.extend_from_slice(&buf[..n]);
        if out.len() > MAX_BODY {
            return Err(Error::Other("the answer is too long".into()));
        }
    }
    Ok(out)
}

/// The whole answer is here: its headers, and a body of the length they give, or chunks up
/// to the last one. An answer with neither is read until the server closes.
fn complete(raw: &[u8]) -> bool {
    let Some(split) = raw.windows(4).position(|w| w == b"\r\n\r\n") else {
        return false;
    };
    let head = String::from_utf8_lossy(&raw[..split]).to_ascii_lowercase();
    let body = &raw[split + 4..];
    let status: u16 = head
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    if status == 204 || status == 304 || (100..200).contains(&status) {
        return true;
    }
    let header = |name: &str| {
        head.lines()
            .find_map(|l| l.strip_prefix(name).map(|v| v.trim().to_string()))
    };
    if header("transfer-encoding:").is_some_and(|v| v.contains("chunked")) {
        return chunked_end(body).is_some();
    }
    match header("content-length:").and_then(|v| v.parse::<usize>().ok()) {
        Some(len) => body.len() >= len,
        None => false,
    }
}

/// Where a chunked body ends (after the last chunk and its trailers), once all of it is here.
fn chunked_end(mut body: &[u8]) -> Option<usize> {
    let start = body.len();
    loop {
        let end = body.windows(2).position(|w| w == b"\r\n")?;
        let size_text = String::from_utf8_lossy(&body[..end]);
        let size = usize::from_str_radix(size_text.split(';').next()?.trim(), 16).ok()?;
        body = &body[end + 2..];
        if size == 0 {
            // Trailers, if any, end with an empty line.
            let t = body.windows(2).position(|w| w == b"\r\n")?;
            if t == 0 {
                return Some(start - body.len() + 2);
            }
            let rest = body.windows(4).position(|w| w == b"\r\n\r\n")?;
            return Some(start - body.len() + rest + 4);
        }
        if body.len() < size + 2 {
            return None;
        }
        body = &body[size + 2..];
    }
}

/// Status line, headers, and a body that may be chunked.
fn parse(raw: &[u8]) -> Result<Response> {
    let split = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or_else(|| Error::Other("an answer without headers".into()))?;
    let head = String::from_utf8_lossy(&raw[..split]);
    let mut body = &raw[split + 4..];
    let status = head
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| Error::Other(format!("not an HTTP answer: {head}")))?;
    let chunked = head.lines().any(|l| {
        let l = l.to_ascii_lowercase();
        l.starts_with("transfer-encoding:") && l.contains("chunked")
    });
    let mut decoded = Vec::new();
    if chunked {
        loop {
            let end = body
                .windows(2)
                .position(|w| w == b"\r\n")
                .ok_or_else(|| Error::Other("a cut chunked answer".into()))?;
            let size_text = String::from_utf8_lossy(&body[..end]);
            let size = usize::from_str_radix(size_text.split(';').next().unwrap_or("").trim(), 16)
                .map_err(|_| Error::Other("a bad chunk size".into()))?;
            body = &body[end + 2..];
            if size == 0 {
                break;
            }
            if body.len() < size {
                return Err(Error::Other("a cut chunked answer".into()));
            }
            decoded.extend_from_slice(&body[..size]);
            body = body.get(size + 2..).unwrap_or(&[]);
        }
    } else {
        decoded.extend_from_slice(body);
    }
    Ok(Response {
        status,
        body: String::from_utf8_lossy(&decoded).into_owned(),
    })
}

#[cfg(test)]
mod tests {
    use super::{complete, parse, post_form, TEST_ROOTS};
    use std::sync::Arc;

    #[test]
    fn an_answer_is_complete_by_its_length_or_its_last_chunk() {
        let head = b"HTTP/1.1 400 Bad Request\r\nContent-Length: 7\r\n\r\n";
        assert!(!complete(head));
        assert!(!complete(&[&head[..], b"{\"a\":"].concat()));
        assert!(complete(&[&head[..], b"{\"a\":1}"].concat()));
        let chunked =
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3\r\n:1}\r\n";
        assert!(!complete(chunked));
        assert!(!complete(&[&chunked[..], b"0\r\n"].concat()));
        assert!(complete(&[&chunked[..], b"0\r\n\r\n"].concat()));
        assert!(complete(&[&chunked[..], b"0\r\nX-T: 1\r\n\r\n"].concat()));
        assert!(complete(b"HTTP/1.1 204 No Content\r\n\r\n"));
        assert!(!complete(
            b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nno length"
        ));
        assert!(!complete(b"HTTP/1.1 200 OK\r\nContent-Len"));
    }

    /// A server that answers in full, then puts bytes on the wire that are no TLS record and
    /// keeps the connection open, as Google's front ends do through some networks: the
    /// answer is what counts, and nothing waits for the end.
    #[tokio::test]
    async fn an_answer_counts_whatever_follows_it_on_the_wire() {
        use rustls::pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer};
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let ck = rcgen::generate_simple_self_signed(vec!["localhost".to_string()]).unwrap();
        let cert = ck.cert.der().clone();
        let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(ck.signing_key.serialize_der()));
        TEST_ROOTS.lock().unwrap().push(cert.clone());
        let config = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![cert], key)
            .unwrap();
        let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let mut tls = acceptor.accept(tcp).await.unwrap();
            let mut buf = vec![0u8; 4096];
            let _ = tls.read(&mut buf).await;
            let body = r#"{"error":"invalid_grant"}"#;
            let reply = format!(
                "HTTP/1.1 400 Bad Request\r\nContent-Length: {}\r\n\r\n{body}",
                body.len()
            );
            tls.write_all(reply.as_bytes()).await.unwrap();
            tls.flush().await.unwrap();
            // Past the TLS layer: a record header with bytes that decrypt to nothing.
            let tcp = tls.get_mut().0;
            tcp.write_all(&[23, 3, 3, 0, 32]).await.unwrap();
            tcp.write_all(&[0xAB; 32]).await.unwrap();
            tcp.flush().await.unwrap();
            tokio::time::sleep(std::time::Duration::from_secs(60)).await;
        });
        let r = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            post_form(&format!("https://localhost:{port}/token"), "code=x"),
        )
        .await
        .expect("waited for the connection to end")
        .unwrap();
        assert_eq!(r.status, 400);
        assert_eq!(r.body, r#"{"error":"invalid_grant"}"#);
    }

    #[test]
    fn plain_and_chunked_answers_read_the_same() {
        let plain = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"a\":1}";
        let r = parse(plain).unwrap();
        assert_eq!((r.status, r.body.as_str()), (200, "{\"a\":1}"));
        let chunked = b"HTTP/1.1 400 Bad Request\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3;x=y\r\n:1}\r\n0\r\n\r\n";
        let r = parse(chunked).unwrap();
        assert_eq!((r.status, r.body.as_str()), (400, "{\"a\":1}"));
        assert!(parse(b"garbage").is_err());
    }
}
