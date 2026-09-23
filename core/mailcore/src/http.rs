//! Just enough HTTPS for OAuth token endpoints: one POST of a form, the answer's status and
//! body. Over the same rustls and web PKI roots as IMAP, so no second TLS stack is linked.

use crate::error::{Error, Result};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_rustls::TlsConnector;

const TIMEOUT: Duration = Duration::from_secs(30);

/// Tests trust their own token server's certificate on top of the web roots.
#[cfg(test)]
pub(crate) static TEST_ROOT: std::sync::Mutex<Option<rustls::pki_types::CertificateDer<'static>>> =
    std::sync::Mutex::new(None);
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
    if let Some(c) = TEST_ROOT.lock().unwrap().clone() {
        let _ = roots.add(c);
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
    loop {
        let n = match tls.read(&mut buf).await {
            Ok(n) => n,
            // Servers that close without close_notify: what came is the answer.
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => 0,
            Err(e) => return Err(e.into()),
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
    use super::parse;

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
