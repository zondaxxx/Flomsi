//! mailctl: drive mailcore from a terminal.
//!
//!   mailctl probe --email you@fastmail.com --host imap.fastmail.com
//!   mailctl add-imap --email you@gmail.com --host imap.gmail.com --smtp-host smtp.gmail.com
//!   mailctl sync
//!   mailctl folders
//!   mailctl ls "from:anna is:unread"
//!   mailctl show 12
//!   mailctl save 345 1 --dir ~/Downloads
//!   mailctl send --account 1 --to a@x.dev --subject Hi --text Hello --attach report.pdf
//!   mailctl archive 12
//!   mailctl idle

use anyhow::{Context, Result};
use clap::{Parser, Subcommand, ValueEnum};
use mailcore::{AuthKind, Core, FolderRole, NewAccount, ProviderKind, Security, SyncOptions};
use std::path::PathBuf;
use std::time::{Duration, Instant};

#[derive(Parser)]
#[command(name = "mailctl", about = "Flomsi core CLI")]
struct Cli {
    /// Data directory (default: ~/.mail_)
    #[arg(long, global = true)]
    data_dir: Option<PathBuf>,
    /// Write the IMAP conversation to FILE (appended; passwords masked, message bodies cut
    /// to their first 200 bytes)
    #[arg(long, global = true, value_name = "FILE")]
    wire: Option<PathBuf>,
    #[command(subcommand)]
    cmd: Cmd,
}

/// Where to reach a server; shared by the commands that sign in without an account.
#[derive(clap::Args)]
struct Server {
    #[arg(long)]
    email: String,
    #[arg(long)]
    host: String,
    /// 993 for IMAP, 465 for SMTP unless given
    #[arg(long)]
    port: Option<u16>,
    /// Plain connection upgraded with STARTTLS (IMAP 143/1143). SMTP picks it by port
    /// (all but 465) unless given
    #[arg(long)]
    starttls: bool,
    /// Accept a self-signed certificate from a bridge on this machine (Proton Bridge)
    #[arg(long)]
    local_bridge: bool,
}

impl Server {
    fn security(&self) -> Security {
        if self.starttls {
            Security::StartTls
        } else {
            Security::Tls
        }
    }
}

#[derive(Clone, Copy, ValueEnum)]
enum MissingRole {
    Archive,
    Trash,
}

#[derive(Subcommand)]
enum Cmd {
    /// Add an IMAP account (password from $MAIL_PASSWORD or a prompt). IMAP and SMTP
    /// sign-in are checked before anything is saved.
    AddImap {
        #[arg(long)]
        email: String,
        #[arg(long)]
        host: String,
        #[arg(long, default_value_t = 993)]
        port: u16,
        /// IMAP over a plain connection upgraded with STARTTLS (143, 1143)
        #[arg(long)]
        starttls: bool,
        #[arg(long, default_value = "")]
        smtp_host: String,
        #[arg(long, default_value_t = 465)]
        smtp_port: u16,
        /// SMTP with STARTTLS (587, 1025); without it, TLS on 465 and STARTTLS elsewhere
        #[arg(long)]
        smtp_starttls: bool,
        /// Accept a self-signed certificate from a bridge on this machine (Proton Bridge)
        #[arg(long)]
        local_bridge: bool,
        #[arg(long, default_value = "")]
        name: String,
        /// Save without signing in first
        #[arg(long)]
        no_check: bool,
    },
    /// Sign in to IMAP once without saving anything
    TestLogin {
        #[command(flatten)]
        server: Server,
    },
    /// Sign in to SMTP once without sending or saving anything
    CheckSmtp {
        #[command(flatten)]
        server: Server,
    },
    /// Show what an IMAP server says about itself: capabilities, folders with their
    /// attributes and roles, and each folder's counters (opened read-only)
    Probe {
        #[command(flatten)]
        server: Server,
        /// Only list folders, do not open them
        #[arg(long)]
        quick: bool,
    },
    /// Folders known for an account (or all): role, cached messages, last sync
    Folders {
        #[arg(long)]
        account: Option<i64>,
    },
    /// Create the Archive or Trash folder an account is missing
    CreateFolder {
        #[arg(long)]
        account: i64,
        role: MissingRole,
    },
    /// List accounts
    Accounts,
    /// Remove an account and its secrets
    Remove { id: i64 },
    /// Sync one account or all
    Sync {
        #[arg(long)]
        account: Option<i64>,
        /// Only the inbox
        #[arg(long)]
        inbox_only: bool,
    },
    /// List threads (unified inbox by default)
    Ls {
        query: Option<String>,
        #[arg(long, default_value_t = 30)]
        limit: u32,
    },
    /// Show a thread (message ids and attachment numbers are what `save` takes)
    Show { thread: i64 },
    /// Save an attachment of a message; fetches the message from the server if needed
    Save {
        message: i64,
        /// Attachment number as printed by `show`
        idx: u32,
        #[arg(long, default_value = ".")]
        dir: PathBuf,
    },
    /// Archive a thread (local first, replayed on next sync)
    Archive { thread: i64 },
    /// Mark a thread read / unread
    Read {
        thread: i64,
        #[arg(long)]
        unread: bool,
    },
    /// Star / unstar a thread
    Star {
        thread: i64,
        #[arg(long)]
        off: bool,
    },
    /// Reply to a thread (quoted original appended)
    Reply {
        thread: i64,
        #[arg(long)]
        text: String,
        #[arg(long)]
        all: bool,
        /// Files to attach (repeatable)
        #[arg(long)]
        attach: Vec<PathBuf>,
    },
    /// Send a new message from an account
    Send {
        #[arg(long)]
        account: i64,
        #[arg(long)]
        to: Vec<String>,
        #[arg(long)]
        subject: String,
        #[arg(long)]
        text: String,
        /// Files to attach (repeatable)
        #[arg(long)]
        attach: Vec<PathBuf>,
    },
    /// Wait in IMAP IDLE for new mail, then sync
    Idle {
        #[arg(long)]
        account: i64,
        #[arg(long, default_value_t = 1500)]
        timeout_secs: u64,
    },
}

fn data_dir(cli: &Cli) -> PathBuf {
    cli.data_dir.clone().unwrap_or_else(|| {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
        PathBuf::from(home).join(".mail_")
    })
}

/// SMTP security when none is given: TLS from the first byte on 465, STARTTLS elsewhere.
fn by_port(port: u16) -> Security {
    if port == 465 {
        Security::Tls
    } else {
        Security::StartTls
    }
}

/// `--data-dir X ` when one was given, so a printed command acts on the same profile.
static DATA_DIR_ARG: std::sync::OnceLock<String> = std::sync::OnceLock::new();

/// Print what went wrong the way the app says it, then the raw error.
fn explain(e: &mailcore::Error, host: &str) {
    if let mailcore::Error::NoFolder {
        account_id,
        role,
        gmail: false,
    } = e
    {
        println!("  {e}");
        println!(
            "  create it with: mailctl {}create-folder --account {account_id} {}",
            DATA_DIR_ARG.get().map(String::as_str).unwrap_or(""),
            role.as_str()
        );
        return;
    }
    let d = mailcore::diagnose::diagnose(&e.to_string(), host);
    println!("  {}", d.title);
    if let Some(h) = d.hint {
        println!("  {h}");
    }
    println!("  ({e})");
}

fn seconds(d: Duration) -> String {
    if d < Duration::from_secs(1) {
        format!("{} ms", d.as_millis())
    } else {
        format!("{:.1} s", d.as_secs_f64())
    }
}

/// `$MAIL_PASSWORD` for scripts, an interactive prompt otherwise.
fn password_for(email: &str) -> Result<String> {
    if let Ok(p) = std::env::var("MAIL_PASSWORD") {
        return Ok(p);
    }
    Ok(rpassword::prompt_password(format!(
        "password / app password for {email}: "
    ))?)
}

fn attachments(paths: &[PathBuf]) -> Result<Vec<mailcore::compose::DraftAttachment>> {
    paths
        .iter()
        .map(|p| {
            mailcore::compose::DraftAttachment::from_path(p)
                .with_context(|| format!("attach {}", p.display()))
        })
        .collect()
}

fn human_size(bytes: u64) -> String {
    match bytes {
        b if b < 1024 => format!("{b} B"),
        b if b < 1024 * 1024 => format!("{} KB", b.div_ceil(1024)),
        b => format!("{:.1} MB", b as f64 / (1024.0 * 1024.0)),
    }
}

fn fmt_date(d: chrono::DateTime<chrono::Utc>) -> String {
    let local = d.with_timezone(&chrono::Local);
    let today = chrono::Local::now().date_naive();
    if local.date_naive() == today {
        local.format("%H:%M").to_string()
    } else {
        local.format("%d %b").to_string()
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    // RUST_LOG works as usual, except that async-imap stays silent: at trace it prints every
    // command, LOGIN with the password included.
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn"))
        .add_directive("async_imap=off".parse().expect("static directive"));
    tracing_subscriber::fmt().with_env_filter(filter).init();
    let cli = Cli::parse();
    if let Some(dir) = &cli.data_dir {
        let _ = DATA_DIR_ARG.set(format!("--data-dir {} ", dir.display()));
    }
    if let Some(file) = &cli.wire {
        mailcore::provider::wire::record_to(file)
            .with_context(|| format!("--wire {}", file.display()))?;
        eprintln!(
            "recording the IMAP conversation to {} (passwords masked; addresses, subjects and \
             the start of each message are in it)",
            file.display()
        );
    }
    let core = Core::open(&data_dir(&cli)).context("open core")?;

    match cli.cmd {
        Cmd::AddImap {
            email,
            host,
            port,
            starttls,
            smtp_host,
            smtp_port,
            smtp_starttls,
            local_bridge,
            name,
            no_check,
        } => {
            let password = password_for(&email)?;
            let imap_security = if starttls {
                Security::StartTls
            } else {
                Security::Tls
            };
            // Unset means by port when sending, the way mail apps do: TLS on 465, else STARTTLS.
            let smtp_choice = smtp_starttls.then_some(Security::StartTls);
            let smtp_security = smtp_choice.unwrap_or_else(|| by_port(smtp_port));
            if !no_check {
                let transport = mailcore::Transport {
                    security: imap_security,
                    local_bridge,
                };
                let t = Instant::now();
                if let Err(e) = Core::check_login(&host, port, transport, &email, &password).await {
                    println!("IMAP sign-in failed, nothing saved:");
                    explain(&e, &host);
                    std::process::exit(2);
                }
                println!("IMAP ok: {host}:{port} ({})", seconds(t.elapsed()));
                if smtp_host.is_empty() {
                    println!("no --smtp-host: this account will not be able to send");
                } else {
                    let t = Instant::now();
                    if let Err(e) = Core::check_smtp(
                        &smtp_host,
                        smtp_port,
                        smtp_security,
                        local_bridge,
                        &email,
                        &password,
                    )
                    .await
                    {
                        println!("SMTP sign-in failed, nothing saved:");
                        explain(&e, &smtp_host);
                        std::process::exit(2);
                    }
                    println!(
                        "SMTP ok: {smtp_host}:{smtp_port} ({})",
                        seconds(t.elapsed())
                    );
                }
            }
            let a = core.add_account(
                &NewAccount {
                    kind: if host.contains("gmail") {
                        ProviderKind::Gmail
                    } else {
                        ProviderKind::Imap
                    },
                    email: email.clone(),
                    display_name: name,
                    imap_host: host,
                    imap_port: port,
                    smtp_host,
                    smtp_port,
                    auth: AuthKind::Password,
                    imap_security,
                    smtp_security: smtp_choice,
                    local_bridge,
                },
                &password,
            )?;
            println!("added account #{} {} (secret in keychain)", a.id, a.email);
        }
        Cmd::TestLogin { server } => {
            let password = password_for(&server.email)?;
            let port = server.port.unwrap_or(993);
            let transport = mailcore::Transport {
                security: server.security(),
                local_bridge: server.local_bridge,
            };
            let t = Instant::now();
            match Core::check_login(&server.host, port, transport, &server.email, &password).await {
                Ok(()) => println!(
                    "login ok: {} via {}:{port} ({})",
                    server.email,
                    server.host,
                    seconds(t.elapsed())
                ),
                Err(e) => {
                    println!("login failed:");
                    explain(&e, &server.host);
                    std::process::exit(2);
                }
            }
        }
        Cmd::CheckSmtp { server } => {
            let password = password_for(&server.email)?;
            let port = server.port.unwrap_or(465);
            let security = if server.starttls {
                Security::StartTls
            } else {
                by_port(port)
            };
            let t = Instant::now();
            match Core::check_smtp(
                &server.host,
                port,
                security,
                server.local_bridge,
                &server.email,
                &password,
            )
            .await
            {
                Ok(()) => println!(
                    "smtp ok: {} via {}:{port} ({})",
                    server.email,
                    server.host,
                    seconds(t.elapsed())
                ),
                Err(e) => {
                    println!("smtp failed:");
                    explain(&e, &server.host);
                    std::process::exit(2);
                }
            }
        }
        Cmd::Probe { server, quick } => {
            let password = password_for(&server.email)?;
            let port = server.port.unwrap_or(993);
            let transport = mailcore::Transport {
                security: server.security(),
                local_bridge: server.local_bridge,
            };
            let r = match mailcore::probe::probe(
                &server.host,
                port,
                transport,
                &server.email,
                &password,
                !quick,
            )
            .await
            {
                Ok(r) => r,
                Err(e) => {
                    println!("probe failed:");
                    explain(&e, &server.host);
                    std::process::exit(2);
                }
            };
            print_probe(&r, &server.host, port);
        }
        Cmd::Folders { account } => {
            let accounts = match account {
                Some(id) => vec![core.store().account(id)?],
                None => core.store().accounts()?,
            };
            for a in accounts {
                println!("#{} {}", a.id, a.email);
                let counts = core.store().cached_counts(a.id)?;
                for f in core.store().folders(a.id)? {
                    let synced = f
                        .last_sync_at
                        .map(fmt_date)
                        .unwrap_or_else(|| "never".into());
                    println!(
                        "  {:<10} {:<34} {:>6} cached  synced {:<6}{}",
                        if f.role == FolderRole::Other {
                            ""
                        } else {
                            f.role.as_str()
                        },
                        truncate(&f.display_name(), 34),
                        counts.get(&f.id).copied().unwrap_or(0),
                        synced,
                        if f.selectable {
                            ""
                        } else {
                            "  (holds no mail)"
                        }
                    );
                }
            }
        }
        Cmd::CreateFolder { account, role } => {
            let role = match role {
                MissingRole::Archive => FolderRole::Archive,
                MissingRole::Trash => FolderRole::Trash,
            };
            let host = core.store().account(account)?.imap_host;
            match core.create_role_folder(account, role).await {
                Ok(name) => println!("{} folder: {name}", role.as_str()),
                Err(e) => {
                    println!("could not create it:");
                    explain(&e, &host);
                    std::process::exit(2);
                }
            }
        }
        Cmd::Accounts => {
            for a in core.store().accounts()? {
                let unread = core.store().unread_count(Some(a.id))?;
                println!(
                    "#{:<3} {:<32} {:<10} {}:{}  unread {}",
                    a.id,
                    a.email,
                    a.kind.as_str(),
                    a.imap_host,
                    a.imap_port,
                    unread
                );
            }
        }
        Cmd::Remove { id } => {
            core.remove_account(id)?;
            println!("removed #{id}");
        }
        Cmd::Sync {
            account,
            inbox_only,
        } => {
            let mut opts = SyncOptions::default();
            if inbox_only {
                opts.roles = vec![FolderRole::Inbox];
            }
            let mut rx = core.subscribe();
            let printer = tokio::spawn(async move {
                while let Ok(ev) = rx.recv().await {
                    match ev {
                        mailcore::SyncEvent::Folder {
                            folder,
                            fetched,
                            removed,
                            ..
                        } => {
                            eprintln!("  {folder}: +{fetched} -{removed}")
                        }
                        mailcore::SyncEvent::OutboxReplayed { ops, .. } => {
                            eprintln!("  outbox: {ops} ops replayed")
                        }
                        _ => {}
                    }
                }
            });
            let accounts = match account {
                Some(id) => vec![core.store().account(id)?],
                None => core.store().accounts()?,
            };
            let mut failed = false;
            for a in accounts {
                let t = Instant::now();
                let r = core.sync_account(a.id, &opts).await;
                let took = seconds(t.elapsed());
                match r {
                    Ok(rep) => {
                        println!(
                            "{}: {} folders, +{} messages, -{} removed, {} ops in {took}",
                            a.email, rep.folders, rep.fetched, rep.removed, rep.ops_replayed
                        );
                        for e in &rep.errors {
                            failed = true;
                            println!("  error: {e}");
                        }
                    }
                    Err(e) => {
                        failed = true;
                        println!("{}: FAILED after {took}", a.email);
                        explain(&e, &a.imap_host);
                    }
                }
            }
            printer.abort();
            if failed {
                std::process::exit(1);
            }
        }
        Cmd::Ls { query, limit } => {
            let threads = core.threads(query.as_deref().unwrap_or(""), limit)?;
            if threads.is_empty() {
                println!("(no threads — run `mailctl sync` first?)");
            }
            for t in threads {
                let mark = if t.unread_count > 0 { "●" } else { " " };
                let star = if t.starred { "*" } else { " " };
                let who = t
                    .participants
                    .iter()
                    .take(2)
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(", ");
                let count = if t.msg_count > 1 {
                    format!(" ({})", t.msg_count)
                } else {
                    String::new()
                };
                println!(
                    "{mark}{star} #{:<5} {:>6}  {:<28} {}{}\n          {}",
                    t.id,
                    fmt_date(t.last_date),
                    truncate(&who, 28),
                    truncate(&t.subject, 60),
                    count,
                    truncate(&t.snippet, 80)
                );
            }
        }
        Cmd::Show { thread } => {
            let t = core.store().thread(thread)?;
            println!(
                "{}\n{}",
                t.subject,
                "─".repeat(t.subject.chars().count().max(20))
            );
            for m in core.store().thread_messages(thread)? {
                let (text, html) = core.store().body(m.id)?;
                println!(
                    "\n#{} from: {} <{}>\ndate: {}\nto:   {}",
                    m.id,
                    m.from.display(),
                    m.from.addr,
                    m.date.with_timezone(&chrono::Local),
                    m.to.iter()
                        .map(|a| a.addr.clone())
                        .collect::<Vec<_>>()
                        .join(", ")
                );
                for a in core.store().attachments(m.id)?.iter().filter(|a| !a.inline) {
                    println!(
                        "📎 [{}] {}  {}  {}",
                        a.idx,
                        a.name,
                        a.mime,
                        human_size(a.size)
                    );
                }
                println!();
                match text {
                    Some(t) => println!("{}", t.trim()),
                    None => println!("[html only, {} bytes]", html.map(|h| h.len()).unwrap_or(0)),
                }
            }
        }
        Cmd::Save { message, idx, dir } => {
            let path = core.save_attachment(message, idx, &dir).await?;
            println!("saved {}", path.display());
        }
        Cmd::Archive { thread } => match core.actions().archive(thread) {
            Ok(0) => println!("#{thread} is not in the inbox"),
            Ok(n) => println!("archived #{thread}: {n} message(s), queued for next sync"),
            Err(e @ mailcore::Error::NoFolder { .. }) => {
                println!("not archived:");
                explain(&e, "");
                std::process::exit(2);
            }
            Err(e) => return Err(e.into()),
        },
        Cmd::Read { thread, unread } => {
            core.actions().mark_read(thread, !unread)?;
            println!(
                "#{thread} marked {}",
                if unread { "unread" } else { "read" }
            );
        }
        Cmd::Star { thread, off } => {
            core.actions().star(thread, !off)?;
            println!("#{thread} {}", if off { "unstarred" } else { "starred" });
        }
        Cmd::Reply {
            thread,
            text,
            all,
            attach,
        } => {
            let (account, mut draft) = core.reply_draft(thread, all)?;
            draft.text = format!("{text}{}", draft.text);
            draft.attachments = attachments(&attach)?;
            if let Some(w) = core.send(account.id, &draft).await?.warning {
                eprintln!("{w}");
            }
            println!(
                "sent reply to {} via {}",
                draft
                    .to
                    .iter()
                    .map(|a| a.addr.clone())
                    .collect::<Vec<_>>()
                    .join(", "),
                account.email
            );
        }
        Cmd::Send {
            account,
            to,
            subject,
            text,
            attach,
        } => {
            let a = core.store().account(account)?;
            let mut draft = mailcore::compose::Draft::new(mailcore::Address {
                name: if a.display_name.is_empty() {
                    None
                } else {
                    Some(a.display_name.clone())
                },
                addr: a.email.clone(),
            });
            draft.to = to
                .iter()
                .map(|s| mailcore::Address {
                    name: None,
                    addr: s.trim().to_string(),
                })
                .collect();
            draft.subject = subject;
            draft.text = text;
            draft.attachments = attachments(&attach)?;
            if let Some(w) = core.send(a.id, &draft).await?.warning {
                eprintln!("{w}");
            }
            println!("sent to {} via {}", to.join(", "), a.email);
        }
        Cmd::Idle {
            account,
            timeout_secs,
        } => {
            println!("idling on inbox of #{account} (up to {timeout_secs}s)…");
            let outcome = core
                .wait_for_change(account, Duration::from_secs(timeout_secs))
                .await?;
            println!("idle: {outcome:?}");
            let rep = core
                .sync_account(
                    account,
                    &SyncOptions {
                        roles: vec![FolderRole::Inbox],
                        ..SyncOptions::default()
                    },
                )
                .await?;
            println!("+{} messages", rep.fetched);
        }
    }
    Ok(())
}

fn yes(b: bool) -> &'static str {
    if b {
        "yes"
    } else {
        "no"
    }
}

fn print_probe(r: &mailcore::probe::ProbeReport, host: &str, port: u16) {
    println!("{host}:{port}: signed in in {}", seconds(r.connected_in));
    println!("capabilities: {}", r.capabilities.join(" "));
    println!(
        "  MOVE {}  UIDPLUS {}  CONDSTORE {}  IDLE {}  SPECIAL-USE {}  CREATE-SPECIAL-USE {}  Gmail {}",
        yes(r.has("MOVE")),
        yes(r.has("UIDPLUS")),
        yes(r.has("CONDSTORE")),
        yes(r.has("IDLE")),
        yes(r.has("SPECIAL-USE")),
        yes(r.has("CREATE-SPECIAL-USE")),
        yes(r.has("X-GM-EXT-1")),
    );
    let delimiters: std::collections::BTreeSet<&str> = r
        .folders
        .iter()
        .filter_map(|f| f.delimiter.as_deref())
        .collect();
    println!(
        "{} folders, delimiter {:?}",
        r.folders.len(),
        delimiters.into_iter().collect::<Vec<_>>()
    );
    for f in &r.folders {
        let role = if f.role == FolderRole::Other {
            ""
        } else {
            f.role.as_str()
        };
        let shown = if f.display == f.name {
            f.name.clone()
        } else {
            format!("{}  [{}]", f.display, f.name)
        };
        println!("  {role:<8} {shown}");
        let mut detail = format!("           {}", f.attributes.join(" "));
        match &f.state {
            Some(Ok(s)) => detail.push_str(&format!(
                "  exists {}  uidvalidity {}  uidnext {}{}",
                s.exists,
                s.uidvalidity,
                s.uidnext,
                s.highest_modseq
                    .map(|m| format!("  modseq {m}"))
                    .unwrap_or_default()
            )),
            Some(Err(e)) => detail.push_str(&format!("  EXAMINE failed: {e}")),
            None if !f.selectable => detail.push_str("  (holds no mail)"),
            None => {}
        }
        println!("{detail}");
    }
    for (role, what) in [
        (FolderRole::Sent, "Sent"),
        (FolderRole::Trash, "Trash"),
        (FolderRole::Drafts, "Drafts"),
        (FolderRole::Junk, "Junk"),
    ] {
        if !r.folders.iter().any(|f| f.role == role) {
            println!("no {what} folder found");
        }
    }
    if !r
        .folders
        .iter()
        .any(|f| matches!(f.role, FolderRole::Archive | FolderRole::All))
    {
        if r.has("X-GM-EXT-1") {
            println!("All Mail is hidden from IMAP: Archive needs “Show in IMAP” turned on for it");
        } else {
            println!("no Archive folder: the app offers to create one on the first Archive");
        }
    }
}

fn truncate(s: &str, n: usize) -> String {
    let count = s.chars().count();
    if count <= n {
        s.to_string()
    } else {
        let mut t: String = s.chars().take(n - 1).collect();
        t.push('…');
        t
    }
}
