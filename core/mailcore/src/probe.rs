//! What a server says about itself (`mailctl probe`): its capabilities, every folder with
//! the attributes it sent and the role Flomsi gives it, and each folder's counters. Nothing
//! is stored and nothing is changed: folders are opened read-only.

use crate::error::Result;
use crate::model::{display_name, FolderRole};
use crate::provider::imap::{Credential, ImapProvider, Transport};
use crate::provider::{FolderState, Provider};
use std::time::{Duration, Instant};

#[derive(Debug)]
pub struct ProbeReport {
    /// Connecting, TLS and signing in.
    pub connected_in: Duration,
    pub capabilities: Vec<String>,
    pub folders: Vec<ProbedFolder>,
}

#[derive(Debug)]
pub struct ProbedFolder {
    /// As the server spells it (modified UTF-7).
    pub name: String,
    /// As people see it.
    pub display: String,
    pub delimiter: Option<String>,
    pub attributes: Vec<String>,
    pub role: FolderRole,
    pub selectable: bool,
    /// EXAMINE's answer, or why it failed; None when not asked or not selectable.
    pub state: Option<std::result::Result<FolderState, String>>,
}

impl ProbeReport {
    pub fn has(&self, capability: &str) -> bool {
        self.capabilities
            .iter()
            .any(|c| c.eq_ignore_ascii_case(capability))
    }
}

/// Sign in, list every folder and, with [examine], open each one read-only.
pub async fn probe(
    host: &str,
    port: u16,
    transport: Transport,
    email: &str,
    password: &str,
    examine: bool,
) -> Result<ProbeReport> {
    let started = Instant::now();
    let mut p = ImapProvider::connect_with(
        host,
        port,
        transport,
        &[],
        email,
        Credential::Password(password.to_string()),
    )
    .await?;
    let connected_in = started.elapsed();
    let report = run(&mut p, examine, connected_in).await;
    let _ = p.logout().await;
    report
}

async fn run(p: &mut ImapProvider, examine: bool, connected_in: Duration) -> Result<ProbeReport> {
    let capabilities = p.capabilities().to_vec();
    let mut folders = Vec::new();
    for d in p.list_detailed().await? {
        let f = d.folder;
        let state = if examine && f.selectable {
            match p.examine(&f.name).await {
                Ok(s) => Some(Ok(s)),
                // The connection is gone: later folders would fail the same way.
                Err(crate::Error::Io(e)) => return Err(crate::Error::Io(e)),
                Err(e) => Some(Err(e.to_string())),
            }
        } else {
            None
        };
        folders.push(ProbedFolder {
            display: display_name(&f.name, f.delimiter.as_deref()),
            name: f.name,
            delimiter: f.delimiter,
            attributes: d.attributes,
            role: f.role,
            selectable: f.selectable,
            state,
        });
    }
    Ok(ProbeReport {
        connected_in,
        capabilities,
        folders,
    })
}

#[cfg(test)]
mod tests {
    use crate::provider::fake_imap::FakeImap;
    use crate::provider::imap::Transport;
    use crate::testdata::INVOICE_EML;

    #[tokio::test]
    async fn probe_reports_folders_roles_and_counters_without_changing_anything() {
        let fake = FakeImap::start("z@x.dev", "secret").await;
        fake.with(|s| {
            s.gmail = true;
            s.condstore = true;
            s.add_box("INBOX", None);
            s.add_box("[Gmail]/All Mail", Some("\\All"));
            s.add_box("[Gmail]/&BBoEPgRABDcEOAQ9BDA-", Some("\\Trash"));
            s.deliver("INBOX", INVOICE_EML, &[]);
            s.deliver("INBOX", INVOICE_EML, &["\\Seen"]);
        });
        let bridge = Transport {
            security: crate::model::Security::Tls,
            local_bridge: true,
        };
        let r = super::probe("localhost", fake.port, bridge, "z@x.dev", "secret", true)
            .await
            .unwrap();
        assert!(
            r.has("X-GM-EXT-1") && r.has("condstore"),
            "{:?}",
            r.capabilities
        );
        let inbox = r.folders.iter().find(|f| f.name == "INBOX").unwrap();
        let state = inbox.state.as_ref().unwrap().as_ref().unwrap();
        assert_eq!(state.exists, 2);
        assert_eq!(state.uidnext, 3);
        assert!(state.highest_modseq.is_some());
        let trash = r
            .folders
            .iter()
            .find(|f| f.role == crate::FolderRole::Trash)
            .unwrap();
        assert_eq!(trash.display, "Корзина");
        assert_eq!(trash.attributes, vec!["\\Trash".to_string()]);
        let all = r
            .folders
            .iter()
            .find(|f| f.name == "[Gmail]/All Mail")
            .unwrap();
        assert_eq!(all.role, crate::FolderRole::All);
        // Read-only: EXAMINE, never SELECT, and no flags touched.
        let log = fake.with(|s| s.log.clone());
        assert!(log.iter().any(|l| l.starts_with("EXAMINE")), "{log:?}");
        assert!(!log.iter().any(|l| l.starts_with("SELECT")), "{log:?}");
        assert!(!log.iter().any(|l| l.contains("STORE")), "{log:?}");
    }
}
