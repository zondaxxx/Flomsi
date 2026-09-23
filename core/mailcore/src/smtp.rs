//! Outgoing mail over SMTP. 465 = implicit TLS, 587 = STARTTLS. Password or XOAUTH2.

use crate::error::{Error, Result};
use lettre::transport::smtp::authentication::{Credentials, Mechanism};
use lettre::transport::smtp::client::{Certificate, Tls, TlsParameters};
use lettre::transport::smtp::extension::ClientId;
use lettre::{AsyncSmtpTransport, AsyncTransport, Tokio1Executor};
use rustls::pki_types::CertificateDer;

pub enum SmtpCredential {
    Password(String),
    AccessToken(String),
}

pub struct SmtpConfig {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub cred: SmtpCredential,
    /// TLS from the first byte (port 465). Otherwise STARTTLS is required (587).
    pub implicit_tls: bool,
    /// Accept a self-signed certificate on 127.0.0.1 (local bridges).
    pub local_bridge: bool,
}

impl SmtpConfig {
    pub fn new(host: String, port: u16, user: String, cred: SmtpCredential) -> SmtpConfig {
        SmtpConfig {
            implicit_tls: port == 465,
            local_bridge: false,
            host,
            port,
            user,
            cred,
        }
    }
}

pub async fn send(cfg: &SmtpConfig, message: lettre::Message) -> Result<()> {
    send_trusting(cfg, message, &[]).await
}

/// Like `send`, also trusting `extra_roots` (a private CA, a local bridge, tests).
pub async fn send_trusting(
    cfg: &SmtpConfig,
    message: lettre::Message,
    extra_roots: &[CertificateDer<'static>],
) -> Result<()> {
    let mailer = transport(cfg, extra_roots)?;
    mailer
        .send(message)
        .await
        .map_err(|e| Error::Other(format!("smtp: {e}")))?;
    Ok(())
}

/// Connect, start TLS and authenticate without sending anything: the "check" step when an
/// account is added or its password changes.
pub async fn check(cfg: &SmtpConfig, extra_roots: &[CertificateDer<'static>]) -> Result<()> {
    let ok = transport(cfg, extra_roots)?
        .test_connection()
        .await
        .map_err(|e| Error::Other(format!("smtp: {e}")))?;
    if ok {
        Ok(())
    } else {
        Err(Error::Other(
            "smtp: the server closed the connection".into(),
        ))
    }
}

fn transport(
    cfg: &SmtpConfig,
    extra_roots: &[CertificateDer<'static>],
) -> Result<AsyncSmtpTransport<Tokio1Executor>> {
    let mut params = TlsParameters::builder(cfg.host.clone());
    if cfg.local_bridge {
        if !crate::provider::imap::is_loopback(&cfg.host) {
            return Err(Error::Tls(format!(
                "a self-signed certificate is only accepted from this computer, not from {}",
                cfg.host
            )));
        }
        // Like LocalBridgeVerifier on the IMAP side: the name is not checked either, since
        // Proton Bridge's certificate names 127.0.0.1 and people may type localhost.
        params = params
            .dangerous_accept_invalid_certs(true)
            .dangerous_accept_invalid_hostnames(true);
    }
    for der in extra_roots {
        let cert = Certificate::from_der(der.to_vec()).map_err(|e| Error::Tls(e.to_string()))?;
        params = params.add_root_certificate(cert);
    }
    let tls = params.build().map_err(|e| Error::Tls(e.to_string()))?;
    let (secret, mechanism) = match &cfg.cred {
        SmtpCredential::Password(p) => (p.clone(), vec![Mechanism::Plain, Mechanism::Login]),
        SmtpCredential::AccessToken(t) => (t.clone(), vec![Mechanism::Xoauth2]),
    };
    let builder = AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(&cfg.host)
        .port(cfg.port)
        .tls(if cfg.implicit_tls {
            Tls::Wrapper(tls)
        } else {
            Tls::Required(tls)
        })
        .credentials(Credentials::new(cfg.user.clone(), secret))
        .authentication(mechanism)
        // EHLO names this computer by default ("Someones-MacBook-Pro.local"), and the name
        // ends up in the Received header of every message. An address literal is what mail
        // apps send instead.
        .hello_name(ClientId::Ipv4(std::net::Ipv4Addr::LOCALHOST));
    Ok(builder.build())
}

/// Well-known SMTP endpoints for the IMAP hosts we recognise.
pub fn guess_smtp(imap_host: &str) -> Option<(String, u16)> {
    let h = imap_host.to_lowercase();
    let (host, port) = match h.as_str() {
        "imap.gmail.com" => ("smtp.gmail.com", 465),
        "imap.mail.me.com" => ("smtp.mail.me.com", 587),
        "outlook.office365.com" => ("smtp.office365.com", 587),
        "imap.yandex.ru" => ("smtp.yandex.ru", 465),
        "imap.yandex.com" => ("smtp.yandex.com", 465),
        "imap.fastmail.com" => ("smtp.fastmail.com", 465),
        "imap.mail.ru" => ("smtp.mail.ru", 465),
        _ => {
            if let Some(rest) = h.strip_prefix("imap.") {
                return Some((format!("smtp.{rest}"), 587));
            }
            return None;
        }
    };
    Some((host.to_string(), port))
}

#[cfg(test)]
mod tests {
    #[test]
    fn guesses() {
        assert_eq!(
            super::guess_smtp("imap.gmail.com"),
            Some(("smtp.gmail.com".into(), 465))
        );
        assert_eq!(
            super::guess_smtp("imap.example.org"),
            Some(("smtp.example.org".into(), 587))
        );
        assert_eq!(super::guess_smtp("mail.example.org"), None);
    }
}
