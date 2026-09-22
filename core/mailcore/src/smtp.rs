//! Outgoing mail over SMTP. 465 = implicit TLS, 587 = STARTTLS. Password or XOAUTH2.

use crate::error::{Error, Result};
use lettre::transport::smtp::authentication::{Credentials, Mechanism};
use lettre::transport::smtp::client::{Tls, TlsParameters};
use lettre::{AsyncSmtpTransport, AsyncTransport, Tokio1Executor};

pub enum SmtpCredential {
    Password(String),
    AccessToken(String),
}

pub struct SmtpConfig {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub cred: SmtpCredential,
}

pub async fn send(cfg: &SmtpConfig, message: lettre::Message) -> Result<()> {
    let tls = TlsParameters::new(cfg.host.clone()).map_err(|e| Error::Tls(e.to_string()))?;
    let (secret, mechanism) = match &cfg.cred {
        SmtpCredential::Password(p) => (p.clone(), vec![Mechanism::Plain, Mechanism::Login]),
        SmtpCredential::AccessToken(t) => (t.clone(), vec![Mechanism::Xoauth2]),
    };
    let builder = AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(&cfg.host)
        .port(cfg.port)
        .tls(if cfg.port == 465 {
            Tls::Wrapper(tls)
        } else {
            Tls::Required(tls)
        })
        .credentials(Credentials::new(cfg.user.clone(), secret))
        .authentication(mechanism);
    let mailer = builder.build();
    mailer
        .send(message)
        .await
        .map_err(|e| Error::Other(format!("smtp: {e}")))?;
    Ok(())
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
