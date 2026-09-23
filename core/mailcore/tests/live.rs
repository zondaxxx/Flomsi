//! Against real servers: Dovecot for IMAP, mailpit for SMTP, both on this machine with
//! self-signed certificates (reached as a local bridge). CI starts them (see the `live` job
//! in .github/workflows/ci.yml); elsewhere these tests do nothing unless FLOMSI_LIVE=1.
//!
//! Dovecot listens with TLS on 10993 and STARTTLS on 10143 and knows the users below with
//! PASSWORD; it has Sent, Drafts, Trash and Junk marked special-use and no Archive.
//! mailpit takes any login over STARTTLS on 1025 and answers its API on 8025.

use mailcore::compose::Draft;
use mailcore::provider::imap::{Credential, ImapProvider, Transport};
use mailcore::provider::{IdleOutcome, Provider};
use mailcore::{
    Address, AuthKind, Core, Error, Flags, FolderRole, NewAccount, ProviderKind, Security,
    SyncOptions,
};
use std::path::PathBuf;
use std::time::Duration;

const PASSWORD: &str = "Live-Pw-9431";
const IMAPS: u16 = 10993;
const IMAP_STARTTLS: u16 = 10143;
const SMTP: u16 = 1025;
const MAILPIT_API: u16 = 8025;

fn live() -> bool {
    let on = std::env::var("FLOMSI_LIVE").is_ok_and(|v| v == "1");
    if !on {
        eprintln!("skipped: set FLOMSI_LIVE=1 with Dovecot and mailpit running");
    }
    on
}

fn bridge(security: Security) -> Transport {
    Transport {
        security,
        local_bridge: true,
    }
}

async fn imap(user: &str) -> ImapProvider {
    ImapProvider::connect_with(
        "localhost",
        IMAPS,
        bridge(Security::Tls),
        &[],
        user,
        Credential::Password(PASSWORD.into()),
    )
    .await
    .unwrap_or_else(|e| panic!("sign in as {user}: {e}"))
}

fn message(id: &str, subject: &str) -> Vec<u8> {
    format!(
        "From: Anna Sokolova <anna@studio.test>\r\nTo: you@flomsi.test\r\nSubject: {subject}\r\n\
         Message-ID: <{id}@studio.test>\r\nDate: Wed, 23 Sep 2026 10:00:00 +0300\r\n\
         Content-Type: text/plain; charset=utf-8\r\n\r\n{subject}, in a few words.\r\n"
    )
    .into_bytes()
}

/// A fresh core with the account at the live Dovecot, secrets in memory.
fn core_for(user: &str, tag: &str) -> (Core, PathBuf, i64) {
    mailcore::secrets::keep_in_memory();
    let dir = std::env::temp_dir().join(format!("flomsi-live-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let core = Core::open(&dir).unwrap();
    let a = core
        .add_account(
            &NewAccount {
                kind: ProviderKind::Imap,
                email: user.into(),
                display_name: "Live".into(),
                imap_host: "localhost".into(),
                imap_port: IMAPS,
                smtp_host: "localhost".into(),
                smtp_port: SMTP,
                auth: AuthKind::Password,
                imap_security: Security::Tls,
                smtp_security: None,
                local_bridge: true,
            },
            PASSWORD,
        )
        .unwrap();
    (core, dir, a.id)
}

async fn sync(core: &Core, account: i64) {
    let r = core
        .sync_account(account, &SyncOptions::default())
        .await
        .unwrap();
    assert!(r.errors.is_empty(), "{:?}", r.errors);
}

/// UIDs and flags in [folder] as the server has them.
async fn on_server(user: &str, folder: &str) -> Vec<(u32, Flags)> {
    let mut p = imap(user).await;
    p.select(folder).await.unwrap();
    let mut v: Vec<(u32, Flags)> = p
        .fetch_flags("1:*", None)
        .await
        .unwrap()
        .into_iter()
        .map(|c| (c.uid, c.flags))
        .collect();
    v.sort_by_key(|x| x.0);
    p.logout().await.unwrap();
    v
}

#[tokio::test]
async fn roles_actions_and_a_missing_archive() {
    if !live() {
        return;
    }
    let user = "roles@flomsi.test";
    let mut p = imap(user).await;
    for (id, subject) in [
        ("one", "Design review"),
        ("two", "Invoice 42"),
        ("three", "Lunch?"),
    ] {
        p.append("INBOX", &message(id, subject), Flags::default())
            .await
            .unwrap();
    }
    p.append("Junk", &message("spam", "You won"), Flags::default())
        .await
        .unwrap();
    p.logout().await.unwrap();

    let (core, dir, account) = core_for(user, "roles");
    sync(&core, account).await;
    let roles: Vec<FolderRole> = core
        .store()
        .folders(account)
        .unwrap()
        .iter()
        .map(|f| f.role)
        .collect();
    for role in [
        FolderRole::Inbox,
        FolderRole::Sent,
        FolderRole::Drafts,
        FolderRole::Trash,
        FolderRole::Junk,
    ] {
        assert!(roles.contains(&role), "{role:?} missing from {roles:?}");
    }
    let threads = core.threads("", 10).unwrap();
    assert_eq!(threads.len(), 3, "the inbox, spam kept apart");
    let by_subject = |s: &str| threads.iter().find(|t| t.subject == s).unwrap().id;

    core.actions()
        .star(by_subject("Design review"), true)
        .unwrap();
    core.actions()
        .mark_read(by_subject("Invoice 42"), true)
        .unwrap();
    sync(&core, account).await;
    let flags = on_server(user, "INBOX").await;
    assert!(flags[0].1.contains(Flags::FLAGGED), "{flags:?}");
    assert!(flags[1].1.contains(Flags::SEEN), "{flags:?}");
    assert!(!flags[2].1.contains(Flags::SEEN), "{flags:?}");

    // No Archive on this server: say so, make one, then archive into it.
    match core.actions().archive(by_subject("Design review")) {
        Err(Error::NoFolder {
            role: FolderRole::Archive,
            gmail: false,
            ..
        }) => {}
        other => panic!("{other:?}"),
    }
    let name = core
        .create_role_folder(account, FolderRole::Archive)
        .await
        .unwrap();
    assert_eq!(name, "Archive");
    assert_eq!(
        core.actions().archive(by_subject("Design review")).unwrap(),
        1
    );
    assert_eq!(core.actions().trash(by_subject("Lunch?")).unwrap(), 1);
    sync(&core, account).await;
    assert_eq!(on_server(user, "INBOX").await.len(), 1);
    let archived = on_server(user, "Archive").await;
    assert_eq!(archived.len(), 1);
    assert!(
        archived[0].1.contains(Flags::FLAGGED),
        "the star went along"
    );
    assert_eq!(on_server(user, "Trash").await.len(), 1);
    // Nothing came back from the server that the actions took away.
    let left: Vec<String> = core
        .threads("", 10)
        .unwrap()
        .into_iter()
        .map(|t| t.subject)
        .collect();
    assert_eq!(left, vec!["Invoice 42".to_string()]);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[tokio::test]
async fn starttls_probe_and_a_transcript_without_the_password() {
    if !live() {
        return;
    }
    let user = "probe@flomsi.test";
    let wire = std::env::temp_dir().join(format!("flomsi-live-wire-{}.txt", std::process::id()));
    let _ = std::fs::remove_file(&wire);
    mailcore::provider::wire::record_to(&wire).unwrap();
    let r = mailcore::probe::probe(
        "localhost",
        IMAP_STARTTLS,
        bridge(Security::StartTls),
        user,
        PASSWORD,
        true,
    )
    .await
    .unwrap();
    eprintln!("capabilities: {:?}", r.capabilities);
    for c in ["IDLE", "MOVE", "UIDPLUS", "CONDSTORE", "SPECIAL-USE"] {
        assert!(r.has(c), "{c} missing from {:?}", r.capabilities);
    }
    let sent = r.folders.iter().find(|f| f.name == "Sent").unwrap();
    assert_eq!(sent.role, FolderRole::Sent);
    assert!(
        sent.attributes.iter().any(|a| a == "\\Sent"),
        "{:?}",
        sent.attributes
    );
    let inbox = r.folders.iter().find(|f| f.name == "INBOX").unwrap();
    let state = inbox.state.as_ref().unwrap().as_ref().unwrap();
    assert!(state.uidvalidity > 0);
    assert!(
        state.highest_modseq.is_some(),
        "Dovecot answers HIGHESTMODSEQ"
    );

    let text = std::fs::read_to_string(&wire).unwrap();
    assert!(text.contains("LOGIN *** (masked)"), "{text}");
    assert!(
        !text.contains(PASSWORD),
        "the password reached the transcript"
    );
    assert!(text.contains("S: * LIST"), "{text}");
}

#[tokio::test]
async fn send_files_one_copy_in_sent_and_keeps_bcc_off_the_message() {
    if !live() {
        return;
    }
    let user = "send@flomsi.test";
    let (core, dir, account) = core_for(user, "send");
    sync(&core, account).await;
    let subject = format!("Flomsi live {}", std::process::id());
    let mut d = Draft::new(Address {
        name: Some("Live".into()),
        addr: user.into(),
    });
    d.to = vec![Address {
        name: None,
        addr: "anna@studio.test".into(),
    }];
    d.bcc = vec![Address {
        name: None,
        addr: "hidden@studio.test".into(),
    }];
    d.subject = subject.clone();
    d.text = "Sent from the live test.".into();
    let report = core.send(account, &d).await.unwrap();
    assert!(report.warning.is_none(), "{:?}", report.warning);

    let sent = on_server(user, "Sent").await;
    assert_eq!(sent.len(), 1, "one copy in Sent");
    assert!(sent[0].1.contains(Flags::SEEN));

    let list = http_get("/api/v1/messages").await;
    let list: serde_json::Value = serde_json::from_str(&list).unwrap();
    let m = list["messages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["Subject"] == subject.as_str())
        .unwrap_or_else(|| panic!("not in mailpit: {list}"));
    let to: Vec<&str> = m["To"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|a| a["Address"].as_str())
        .collect();
    assert_eq!(to, vec!["anna@studio.test"]);
    let raw = http_get(&format!(
        "/api/v1/message/{}/raw",
        m["ID"].as_str().unwrap()
    ))
    .await;
    // mailpit puts Bcc, Return-Path and Received above what it was sent (to show the
    // envelope); what the client sent starts at its From line.
    let head = raw.split("\r\n\r\n").next().unwrap_or("");
    let sent = &head[head.find("\r\nFrom: ").unwrap_or(0)..];
    let headers = sent.to_string();
    assert!(!headers.contains("hidden@studio.test"), "{headers}");
    assert!(
        !headers.to_ascii_lowercase().contains("\nbcc:"),
        "{headers}"
    );
    // The hidden copy still went out, by the envelope alone.
    let bcc: Vec<&str> = m["Bcc"]
        .as_array()
        .map(|a| a.iter().filter_map(|a| a["Address"].as_str()).collect())
        .unwrap_or_default();
    assert_eq!(bcc, vec!["hidden@studio.test"], "{m}");
    assert!(headers.contains("Message-ID: <"), "{headers}");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[tokio::test]
async fn idle_wakes_when_mail_arrives() {
    if !live() {
        return;
    }
    let user = "idle@flomsi.test";
    let (core, dir, account) = core_for(user, "idle");
    sync(&core, account).await;
    let deliver = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(2)).await;
        let mut p = imap(user).await;
        p.append(
            "INBOX",
            &message("late", "Arrived while idle"),
            Flags::default(),
        )
        .await
        .unwrap();
        p.logout().await.unwrap();
    });
    let outcome = tokio::time::timeout(
        Duration::from_secs(60),
        core.wait_for_change(account, Duration::from_secs(45)),
    )
    .await
    .expect("IDLE did not return")
    .unwrap();
    deliver.await.unwrap();
    assert_eq!(outcome, IdleOutcome::Changed);
    let r = core
        .sync_account(
            account,
            &SyncOptions {
                roles: vec![FolderRole::Inbox],
                ..SyncOptions::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(r.fetched, 1);
    std::fs::remove_dir_all(&dir).unwrap();
}

/// A GET to mailpit's API; the body as text.
async fn http_get(path: &str) -> String {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut s = tokio::net::TcpStream::connect(("127.0.0.1", MAILPIT_API))
        .await
        .unwrap();
    s.write_all(
        format!("GET {path} HTTP/1.0\r\nHost: localhost\r\nAccept: */*\r\n\r\n").as_bytes(),
    )
    .await
    .unwrap();
    let mut out = Vec::new();
    s.read_to_end(&mut out).await.unwrap();
    let text = String::from_utf8_lossy(&out).into_owned();
    let (head, body) = text.split_once("\r\n\r\n").unwrap_or((&text, ""));
    assert!(
        head.starts_with("HTTP/1.") && head.contains(" 200 "),
        "{head}"
    );
    body.to_string()
}
