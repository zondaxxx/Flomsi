//! Turn a raw error from a sign-in or sync into something a person can act on: what kind
//! of problem it is, a one-line title, and a concrete hint for the providers people use most.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    /// The server refused the credentials. Retrying the same password can lock the account.
    Auth,
    /// Could not reach the server (DNS, refused, timeout, dropped connection).
    Network,
    /// TLS failed: untrusted or expired certificate, wrong port for TLS.
    Tls,
    /// The server answered with an error that is not about credentials.
    Server,
    /// Something local: database, keychain, disk.
    Local,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Diagnosis {
    pub kind: ErrorKind,
    pub title: String,
    pub hint: Option<String>,
}

fn has(s: &str, needles: &[&str]) -> bool {
    needles.iter().any(|n| s.contains(n))
}

/// `message` is the error as shown by the core (`auth: …`, `io: …`, `tls: …`, `smtp: …`),
/// `host` the IMAP or SMTP host involved.
pub fn diagnose(message: &str, host: &str) -> Diagnosis {
    let m = message.to_ascii_lowercase();
    let h = host.to_ascii_lowercase();
    let gmail = has(&h, &["gmail", "googlemail", "google"]);
    let yandex = has(&h, &["yandex", "ya.ru"]);
    let mailru = has(&h, &["mail.ru", "bk.ru", "inbox.ru", "list.ru"]);
    let outlook = has(&h, &["outlook", "office365", "hotmail", "live.com"]);
    let icloud = has(&h, &["mail.me.com", "icloud"]);

    let auth_words = [
        "authenticationfailed",
        "invalid credentials",
        "authentication failed",
        "login failed",
        "authenticate failed",
        "application-specific password",
        "incorrect username or password",
        "invalid login",
        "bad credentials",
    ];
    // Errors may arrive prefixed with the account or folder (`a@b.c: auth: …`).
    let tagged = |tag: &str| m.starts_with(tag) || m.contains(&format!(": {tag}"));
    // lettre prints SMTP replies as `permanent error (535): …`; a bare "535" could be a
    // port, a line number or a UID.
    let smtp_auth = has(&m, &["error (535)", "error (534)"]);
    // A broken connection is never a verdict on the password, whatever its text says.
    let io = tagged("io:");
    let is_auth = !io && (tagged("auth:") || has(&m, &auth_words) || smtp_auth);

    if m.contains("is already added") {
        return Diagnosis {
            kind: ErrorKind::Local,
            title: "This address is already added".into(),
            hint: Some("To use a new password, open Settings → Accounts.".into()),
        };
    }
    if has(&m, &["no password stored", "no access token"]) {
        return Diagnosis {
            kind: ErrorKind::Auth,
            title: "No password saved for this account".into(),
            hint: Some("Enter the password again; the keychain entry is missing.".into()),
        };
    }

    // A busy or rate-limiting server may answer LOGIN with NO; that is not a verdict on the
    // password, and treating it as one would stop the account for good.
    let server_reply = tagged("imap:") || tagged("smtp:") || tagged("auth:");
    if has(
        &m,
        &[
            "[unavailable]",
            "[inuse]",
            "too many simultaneous",
            "too many connections",
            "bandwidth limit",
            "try again later",
            "transient error",
        ],
    ) || (server_reply && has(&m, &["temporar"]))
    {
        return Diagnosis {
            kind: ErrorKind::Server,
            title: "The server is busy right now".into(),
            hint: Some("It will be tried again in a few minutes.".into()),
        };
    }

    if !io
        && has(
            &m,
            &[
                "webalert",
                "log in via your web browser",
                "please log in via",
            ],
        )
    {
        return Diagnosis {
            kind: ErrorKind::Auth,
            title: "Google blocked this sign-in".into(),
            hint: Some(
                "Open Gmail in a browser once and confirm it was you, then retry with an app password."
                    .into(),
            ),
        };
    }
    if !io
        && yandex
        && has(
            &m,
            &[
                "imap is disabled",
                "does not have access rights",
                "access denied",
            ],
        )
    {
        return Diagnosis {
            kind: ErrorKind::Auth,
            title: "IMAP is turned off for this Yandex mailbox".into(),
            hint: Some(
                "In Yandex Mail open Settings → Mail clients, allow IMAP, then use an app password from id.yandex.ru."
                    .into(),
            ),
        };
    }
    if is_auth {
        let (title, hint) = if gmail {
            (
                "Gmail needs an app password",
                "Turn on 2-Step Verification, create an app password at myaccount.google.com/apppasswords and paste its 16 letters here. Your normal Google password does not work over IMAP.",
            )
        } else if yandex {
            (
                "Yandex rejected the password",
                "Use an app password from id.yandex.ru (Security → App passwords) and make sure IMAP is allowed in Yandex Mail settings.",
            )
        } else if mailru {
            (
                "Mail.ru rejected the password",
                "Mail.ru needs a password for external apps: Settings → Security → Passwords for external applications.",
            )
        } else if outlook {
            (
                "Outlook no longer accepts passwords here",
                "Microsoft turned off password sign-in over IMAP for Outlook.com; signing in with a Microsoft account is not supported yet.",
            )
        } else if icloud {
            (
                "iCloud needs an app-specific password",
                "Create one at account.apple.com → Sign-In and Security → App-Specific Passwords.",
            )
        } else {
            (
                "The server rejected the name or password",
                "Check the address and password. Many providers want an app password for mail apps.",
            )
        };
        return Diagnosis {
            kind: ErrorKind::Auth,
            title: title.into(),
            hint: Some(hint.into()),
        };
    }

    let network: [(&[&str], &str, &str); 5] = [
        (
            &[
                "failed to lookup address",
                "nodename nor servname",
                "name or service not known",
                "no such host",
                "dns",
            ],
            "Can't find that server",
            "Check the server name.",
        ),
        (
            &["connection refused"],
            "Nothing answers on that port",
            "Check the port: 993 for IMAP over TLS, 465 or 587 for SMTP.",
        ),
        (
            &["timed out", "timeout", "deadline", "stopped answering"],
            "The server did not answer in time",
            "Check the connection and try again.",
        ),
        (
            &[
                "network is unreachable",
                "no route to host",
                "not connected",
                "offline",
            ],
            "No network",
            "Check the connection and try again.",
        ),
        (
            &[
                "connection reset",
                "broken pipe",
                "unexpected eof",
                "connection closed",
                "eof",
            ],
            "The connection dropped",
            "Try again; if it keeps happening, check the port and TLS settings.",
        ),
    ];
    for (needles, title, hint) in network {
        if has(&m, needles) {
            return Diagnosis {
                kind: ErrorKind::Network,
                title: title.into(),
                hint: Some(hint.into()),
            };
        }
    }

    if tagged("tls:")
        || has(
            &m,
            &[
                "certificate",
                "unknownissuer",
                "handshake",
                "corrupt message",
                "invalidcontenttype",
                "wrong version number",
                "starttls is not supported",
                "tls error",
            ],
        )
    {
        let (title, hint) = if has(&m, &["expired"]) {
            (
                "The server's certificate has expired",
                "The provider has to renew it; nothing to fix on this side.",
            )
        } else if has(
            &m,
            &[
                "unknownissuer",
                "not valid for name",
                "notvalidforname",
                "certificate",
            ],
        ) {
            (
                "The server's certificate is not trusted",
                "Check the server name. Local bridges (Proton) need the bridge preset.",
            )
        } else {
            (
                "Secure connection failed",
                "The port may expect STARTTLS instead of TLS, or the other way round.",
            )
        };
        return Diagnosis {
            kind: ErrorKind::Tls,
            title: title.into(),
            hint: Some(hint.into()),
        };
    }

    // Local trouble is reported by the core itself, never inside a server's reply.
    if !server_reply
        && has(
            &m,
            &[
                "database",
                "secrets:",
                "keychain",
                "keyring",
                "disk",
                "permission denied",
            ],
        )
    {
        return Diagnosis {
            kind: ErrorKind::Local,
            title: "Flomsi could not use its local storage".into(),
            hint: Some("Check free disk space and that the keychain is unlocked.".into()),
        };
    }

    Diagnosis {
        kind: ErrorKind::Server,
        title: "The server reported an error".into(),
        hint: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_specific_sign_in_failures() {
        let d = diagnose(
            "auth: NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)",
            "imap.gmail.com",
        );
        assert_eq!(d.kind, ErrorKind::Auth);
        assert!(d.title.contains("app password"), "{d:?}");

        let d = diagnose(
            "auth: NO [ALERT] Please log in via your web browser",
            "imap.gmail.com",
        );
        assert_eq!(d.title, "Google blocked this sign-in");

        let d = diagnose(
            "auth: NO [AUTHORIZATIONFAILED] LOGIN failure: IMAP is disabled",
            "imap.yandex.ru",
        );
        assert!(d.title.contains("IMAP is turned off"), "{d:?}");

        assert!(diagnose("auth: NO Authentication failed", "imap.mail.ru")
            .title
            .contains("Mail.ru"));
        assert!(
            diagnose("auth: NO AUTHENTICATE failed.", "outlook.office365.com")
                .title
                .contains("Outlook")
        );
        assert!(diagnose(
            "auth: NO [AUTHENTICATIONFAILED] Authentication failed",
            "imap.mail.me.com"
        )
        .title
        .contains("iCloud"));
        let smtp = diagnose(
            "smtp: permanent error (535): 5.7.8 Username and Password not accepted",
            "smtp.gmail.com",
        );
        assert_eq!(smtp.kind, ErrorKind::Auth);
    }

    #[test]
    fn network_tls_and_the_rest() {
        let dns = diagnose(
            "io: failed to lookup address information: nodename nor servname provided",
            "imap.exmaple.com",
        );
        assert_eq!(dns.kind, ErrorKind::Network);
        assert_eq!(dns.title, "Can't find that server");
        assert_eq!(
            diagnose("io: Connection refused (os error 61)", "h").title,
            "Nothing answers on that port"
        );
        let tls = diagnose("tls: invalid peer certificate: UnknownIssuer", "h");
        assert_eq!(tls.kind, ErrorKind::Tls);
        assert!(tls.title.contains("not trusted"));
        assert_eq!(
            diagnose("imap: NO [OVERQUOTA] mailbox is full", "h").kind,
            ErrorKind::Server
        );
        // Prefixed by the account, as sync reports it.
        assert_eq!(
            diagnose("z@x.dev: auth: NO LOGIN failed", "h").kind,
            ErrorKind::Auth
        );
        let missing = diagnose("secrets: no password stored for z@x.dev", "h");
        assert_eq!(missing.kind, ErrorKind::Auth);
        assert_eq!(missing.title, "No password saved for this account");
        let dup = diagnose(
            "z@x.dev is already added\n\nStack backtrace:\n  0: harness.rs:535",
            "h",
        );
        assert_eq!(
            (dup.kind, dup.title.as_str()),
            (ErrorKind::Local, "This address is already added")
        );
        assert_eq!(
            diagnose("database: disk I/O error", "h").kind,
            ErrorKind::Local
        );
    }

    #[test]
    fn only_a_refusal_counts_as_a_wrong_password() {
        // Numbers are not reply codes.
        let tls = diagnose(
            "tls: invalid peer certificate: certificate expired: verification time 1790535000",
            "imap.example.com",
        );
        assert_eq!(tls.kind, ErrorKind::Tls);
        assert_eq!(
            diagnose("io: connection refused 10.0.0.1:5350", "h").kind,
            ErrorKind::Network
        );
        // A real SMTP refusal still is.
        assert_eq!(
            diagnose(
                "smtp: permanent error (534): 5.7.9 Application-specific password required",
                "smtp.gmail.com"
            )
            .kind,
            ErrorKind::Auth
        );
        // Busy servers answer LOGIN with NO, but the password may be fine.
        for busy in [
            "auth: NO [UNAVAILABLE] Temporary System Problem. Try again later",
            "auth: NO [ALERT] Too many simultaneous connections. (Failure)",
            "smtp: transient error (454): 4.7.0 Temporary authentication failure",
        ] {
            assert_eq!(
                diagnose(busy, "imap.gmail.com").kind,
                ErrorKind::Server,
                "{busy}"
            );
        }
        // DNS trouble is the network even when it says "temporary".
        assert_eq!(
            diagnose(
                "io: failed to lookup address information: Temporary failure in name resolution",
                "h"
            )
            .kind,
            ErrorKind::Network
        );
        // A TLS client on a plain port, or the other way round.
        assert_eq!(
            diagnose(
                "smtp: tls error: received corrupt message of type InvalidContentType",
                "h"
            )
            .kind,
            ErrorKind::Tls
        );
        assert_eq!(
            diagnose(
                "tls: no greeting in plain text: the port may expect TLS instead of STARTTLS",
                "h"
            )
            .hint
            .as_deref(),
            Some("The port may expect STARTTLS instead of TLS, or the other way round.")
        );
        // A dropped connection is the network, even if a quoted reply mentions a login.
        assert_eq!(
            diagnose(
                "io: connection reset while reading LOGIN failed reply",
                "imap.gmail.com"
            )
            .kind,
            ErrorKind::Network
        );
        // A server's own words about disks are the server's problem.
        assert_eq!(
            diagnose("imap: NO [OVERQUOTA] disk quota exceeded", "h").kind,
            ErrorKind::Server
        );
    }
}
