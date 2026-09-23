//! A small SMTP server for tests: STARTTLS or implicit TLS, AUTH PLAIN/LOGIN, MAIL, RCPT,
//! DATA. It records each delivered envelope and message so tests can check what `smtp::send`
//! and the MIME builder produce on the wire.

use base64::Engine;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use std::io;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio_rustls::TlsAcceptor;

#[derive(Debug, Clone)]
pub struct Delivered {
    pub from: String,
    pub to: Vec<String>,
    pub data: Vec<u8>,
}

pub struct FakeSmtp {
    pub port: u16,
    pub cert: CertificateDer<'static>,
    pub delivered: Arc<Mutex<Vec<Delivered>>>,
}

#[derive(Clone)]
struct Ctx {
    acceptor: TlsAcceptor,
    user: String,
    pass: String,
    delivered: Arc<Mutex<Vec<Delivered>>>,
}

impl FakeSmtp {
    pub async fn start(user: &str, pass: &str, implicit_tls: bool) -> FakeSmtp {
        let ck = rcgen::generate_simple_self_signed(vec!["localhost".to_string()]).unwrap();
        let cert = ck.cert.der().clone();
        let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(ck.signing_key.serialize_der()));
        let config = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![cert.clone()], key)
            .unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let delivered = Arc::new(Mutex::new(Vec::new()));
        let ctx = Ctx {
            acceptor: TlsAcceptor::from(Arc::new(config)),
            user: user.to_string(),
            pass: pass.to_string(),
            delivered: delivered.clone(),
        };
        tokio::spawn(async move {
            while let Ok((tcp, _)) = listener.accept().await {
                let ctx = ctx.clone();
                tokio::spawn(async move {
                    let _ = if implicit_tls {
                        match ctx.acceptor.accept(tcp).await {
                            Ok(tls) => session(tls, &ctx, true).await,
                            Err(e) => Err(e),
                        }
                    } else {
                        plain_then_starttls(tcp, &ctx).await
                    };
                });
            }
        });
        FakeSmtp {
            port,
            cert,
            delivered,
        }
    }
}

/// Before STARTTLS the server offers only EHLO, STARTTLS and QUIT.
async fn plain_then_starttls(tcp: TcpStream, ctx: &Ctx) -> io::Result<()> {
    let mut r = BufReader::new(tcp);
    r.get_mut().write_all(b"220 fake.test ESMTP\r\n").await?;
    loop {
        let mut line = String::new();
        if r.read_line(&mut line).await? == 0 {
            return Ok(());
        }
        let verb = line
            .split_whitespace()
            .next()
            .unwrap_or("")
            .to_ascii_uppercase();
        let w = r.get_mut();
        match verb.as_str() {
            "EHLO" | "HELO" => {
                w.write_all(b"250-fake.test\r\n250-STARTTLS\r\n250 8BITMIME\r\n")
                    .await?
            }
            "STARTTLS" => {
                w.write_all(b"220 2.0.0 Ready to start TLS\r\n").await?;
                let tls = ctx.acceptor.accept(r.into_inner()).await?;
                return session(tls, ctx, false).await;
            }
            "QUIT" => {
                w.write_all(b"221 2.0.0 Bye\r\n").await?;
                return Ok(());
            }
            _ => {
                w.write_all(b"530 5.7.0 Must issue a STARTTLS command first\r\n")
                    .await?
            }
        }
    }
}

fn address(arg: &str) -> String {
    match (arg.find('<'), arg.find('>')) {
        (Some(a), Some(b)) if a < b => arg[a + 1..b].to_string(),
        _ => String::new(),
    }
}

fn b64(s: &str) -> String {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(s.trim())
        .unwrap_or_default();
    String::from_utf8_lossy(&bytes).into_owned()
}

async fn session<S>(stream: S, ctx: &Ctx, greet: bool) -> io::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let mut r = BufReader::new(stream);
    if greet {
        r.get_mut().write_all(b"220 fake.test ESMTP\r\n").await?;
    }
    let (mut authed, mut from, mut to) = (false, String::new(), Vec::new());
    loop {
        let mut line = String::new();
        if r.read_line(&mut line).await? == 0 {
            return Ok(());
        }
        let line = line.trim_end_matches(['\r', '\n']).to_string();
        let mut parts = line.splitn(2, ' ');
        let verb = parts.next().unwrap_or("").to_ascii_uppercase();
        let arg = parts.next().unwrap_or("").to_string();
        let reply: Vec<u8> = match verb.as_str() {
            "EHLO" | "HELO" => {
                b"250-fake.test\r\n250-AUTH PLAIN LOGIN\r\n250-8BITMIME\r\n250-SMTPUTF8\r\n250 SIZE 35882577\r\n".to_vec()
            }
            "AUTH" => {
                let mut a = arg.split_whitespace();
                let mech = a.next().unwrap_or("").to_ascii_uppercase();
                let (user, pass) = match mech.as_str() {
                    "PLAIN" => {
                        let initial = match a.next() {
                            Some(x) => x.to_string(),
                            None => {
                                r.get_mut().write_all(b"334 \r\n").await?;
                                let mut l = String::new();
                                r.read_line(&mut l).await?;
                                l
                            }
                        };
                        let decoded = b64(&initial);
                        let mut f = decoded.split('\0').skip(1);
                        (
                            f.next().unwrap_or("").to_string(),
                            f.next().unwrap_or("").to_string(),
                        )
                    }
                    "LOGIN" => {
                        r.get_mut().write_all(b"334 VXNlcm5hbWU6\r\n").await?;
                        let mut u = String::new();
                        r.read_line(&mut u).await?;
                        r.get_mut().write_all(b"334 UGFzc3dvcmQ6\r\n").await?;
                        let mut p = String::new();
                        r.read_line(&mut p).await?;
                        (b64(&u), b64(&p))
                    }
                    _ => (String::new(), String::new()),
                };
                if user == ctx.user && pass == ctx.pass {
                    authed = true;
                    b"235 2.7.0 Authentication successful\r\n".to_vec()
                } else {
                    b"535 5.7.8 Authentication credentials invalid\r\n".to_vec()
                }
            }
            "MAIL" if !authed => b"530 5.7.0 Authentication required\r\n".to_vec(),
            "MAIL" => {
                from = address(&arg);
                to.clear();
                b"250 2.1.0 OK\r\n".to_vec()
            }
            "RCPT" => {
                to.push(address(&arg));
                b"250 2.1.5 OK\r\n".to_vec()
            }
            "DATA" => {
                r.get_mut()
                    .write_all(b"354 End data with <CR><LF>.<CR><LF>\r\n")
                    .await?;
                let mut data = Vec::new();
                loop {
                    let mut l = Vec::new();
                    if r.read_until(b'\n', &mut l).await? == 0 {
                        return Ok(());
                    }
                    if l == b".\r\n" {
                        break;
                    }
                    // Undo dot-stuffing.
                    let l = if l.starts_with(b"..") { &l[1..] } else { &l[..] };
                    data.extend_from_slice(l);
                }
                ctx.delivered.lock().unwrap().push(Delivered {
                    from: std::mem::take(&mut from),
                    to: std::mem::take(&mut to),
                    data,
                });
                b"250 2.0.0 Queued\r\n".to_vec()
            }
            "RSET" => {
                from.clear();
                to.clear();
                b"250 2.0.0 OK\r\n".to_vec()
            }
            "NOOP" => b"250 2.0.0 OK\r\n".to_vec(),
            "QUIT" => {
                r.get_mut().write_all(b"221 2.0.0 Bye\r\n").await?;
                return Ok(());
            }
            _ => b"502 5.5.2 Command not recognized\r\n".to_vec(),
        };
        let w = r.get_mut();
        w.write_all(&reply).await?;
        w.flush().await?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::compose::{Draft, OutgoingFile};
    use crate::model::Address;
    use crate::provider::parse::{extract_attachment, parse_rfc822};
    use crate::smtp::{send_trusting, SmtpConfig, SmtpCredential};
    use crate::testdata::PDF_BYTES;

    fn addr(a: &str) -> Address {
        Address {
            name: None,
            addr: a.to_string(),
        }
    }

    fn config(port: u16, pass: &str, implicit_tls: bool) -> SmtpConfig {
        SmtpConfig {
            host: "localhost".into(),
            port,
            user: "z@x.dev".into(),
            cred: SmtpCredential::Password(pass.into()),
            implicit_tls,
            local_bridge: false,
        }
    }

    fn draft() -> Draft {
        let mut d = Draft::new(Address {
            name: Some("Z".into()),
            addr: "z@x.dev".into(),
        });
        d.to = vec![addr("anna@studio.dev")];
        d.cc = vec![addr("bob@x.dev")];
        d.bcc = vec![addr("hidden@x.dev")];
        d.subject = "Счёт за сентябрь".into();
        d.text = "See attached.\n.\nA line that starts with a dot survives.".into();
        d
    }

    #[tokio::test]
    async fn starttls_delivers_envelope_body_and_attachment() {
        let server = FakeSmtp::start("z@x.dev", "secret", false).await;
        let file = OutgoingFile {
            name: "Счёт.pdf".into(),
            mime: "application/pdf".into(),
            bytes: PDF_BYTES.to_vec(),
        };
        let message = draft().to_mime(&[file]).unwrap();
        send_trusting(
            &config(server.port, "secret", false),
            message,
            std::slice::from_ref(&server.cert),
        )
        .await
        .unwrap();

        let got = server.delivered.lock().unwrap().clone();
        assert_eq!(got.len(), 1);
        let d = &got[0];
        assert_eq!(d.from, "z@x.dev");
        assert_eq!(d.to, vec!["anna@studio.dev", "bob@x.dev", "hidden@x.dev"]);
        // Bcc goes in the envelope only, never into the headers everyone receives.
        assert!(!String::from_utf8_lossy(&d.data).contains("hidden@x.dev"));

        let parsed = parse_rfc822(&d.data, chrono::Utc::now());
        assert_eq!(parsed.subject, "Счёт за сентябрь");
        // On the wire lines end in CRLF (RFC 5322); the lone "." line survives dot-stuffing.
        assert_eq!(
            parsed
                .text
                .map(|t| t.trim().replace("\r\n", "\n"))
                .as_deref(),
            Some("See attached.\n.\nA line that starts with a dot survives.")
        );
        assert_eq!(parsed.attachments.len(), 1);
        assert_eq!(parsed.attachments[0].name, "Счёт.pdf");
        assert_eq!(extract_attachment(&d.data, 0).unwrap().1, PDF_BYTES);
    }

    #[tokio::test]
    async fn implicit_tls_rejects_wrong_password_and_untrusted_certificates() {
        let server = FakeSmtp::start("z@x.dev", "secret", true).await;
        let cert = std::slice::from_ref(&server.cert);

        let ok = send_trusting(
            &config(server.port, "secret", true),
            draft().to_mime(&[]).unwrap(),
            cert,
        )
        .await;
        assert!(ok.is_ok(), "{ok:?}");

        let wrong = send_trusting(
            &config(server.port, "nope", true),
            draft().to_mime(&[]).unwrap(),
            cert,
        )
        .await;
        let err = wrong.unwrap_err().to_string();
        assert!(
            err.contains("535") || err.to_lowercase().contains("auth"),
            "{err}"
        );

        let untrusted = crate::smtp::send(
            &config(server.port, "secret", true),
            draft().to_mime(&[]).unwrap(),
        )
        .await;
        assert!(untrusted.is_err());
        assert_eq!(server.delivered.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn check_signs_in_without_sending() {
        for implicit in [false, true] {
            let server = FakeSmtp::start("z@x.dev", "secret", implicit).await;
            let cert = std::slice::from_ref(&server.cert);
            crate::smtp::check(&config(server.port, "secret", implicit), cert)
                .await
                .unwrap_or_else(|e| panic!("implicit={implicit}: {e}"));
            let wrong = crate::smtp::check(&config(server.port, "nope", implicit), cert)
                .await
                .unwrap_err()
                .to_string();
            let d = crate::diagnose::diagnose(&wrong, "localhost");
            assert_eq!(d.kind, crate::diagnose::ErrorKind::Auth, "{wrong}");
            assert!(server.delivered.lock().unwrap().is_empty());
        }

        // A bridge on this computer is trusted without adding its certificate, whatever
        // name the certificate carries (it says localhost, the account says 127.0.0.1).
        let server = FakeSmtp::start("z@x.dev", "secret", false).await;
        let mut cfg = config(server.port, "secret", false);
        cfg.local_bridge = true;
        crate::smtp::check(&cfg, &[]).await.unwrap();
        cfg.host = "127.0.0.1".into();
        crate::smtp::check(&cfg, &[]).await.unwrap();
        cfg.host = "smtp.example.com".into();
        let far = crate::smtp::check(&cfg, &[]).await.unwrap_err().to_string();
        assert!(far.contains("only accepted from this computer"), "{far}");
    }
}
