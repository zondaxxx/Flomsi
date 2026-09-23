//! mailctl: drive mailcore from a terminal.
//!
//!   mailctl add-imap --email you@gmail.com --host imap.gmail.com
//!   mailctl sync
//!   mailctl ls "from:anna is:unread"
//!   mailctl show 12
//!   mailctl save 345 1 --dir ~/Downloads
//!   mailctl send --account 1 --to a@x.dev --subject Hi --text Hello --attach report.pdf
//!   mailctl archive 12
//!   mailctl idle

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use mailcore::{AuthKind, Core, FolderRole, NewAccount, ProviderKind, SyncOptions};
use std::path::PathBuf;
use std::time::Duration;

#[derive(Parser)]
#[command(name = "mailctl", about = "mail_ core CLI")]
struct Cli {
    /// Data directory (default: ~/.mail_)
    #[arg(long, global = true)]
    data_dir: Option<PathBuf>,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Add an IMAP account (password or app password, prompted)
    AddImap {
        #[arg(long)]
        email: String,
        #[arg(long)]
        host: String,
        #[arg(long, default_value_t = 993)]
        port: u16,
        #[arg(long, default_value = "")]
        smtp_host: String,
        #[arg(long, default_value_t = 465)]
        smtp_port: u16,
        #[arg(long, default_value = "")]
        name: String,
    },
    /// Connect and log in once without saving anything (password from prompt or $MAIL_PASSWORD)
    TestLogin {
        #[arg(long)]
        email: String,
        #[arg(long)]
        host: String,
        #[arg(long, default_value_t = 993)]
        port: u16,
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
    let core = Core::open(&data_dir(&cli)).context("open core")?;

    match cli.cmd {
        Cmd::AddImap {
            email,
            host,
            port,
            smtp_host,
            smtp_port,
            name,
        } => {
            let password =
                rpassword::prompt_password(format!("password / app password for {email}: "))?;
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
                },
                &password,
            )?;
            println!("added account #{} {} (secret in keychain)", a.id, a.email);
        }
        Cmd::TestLogin { email, host, port } => {
            let password = password_for(&email)?;
            match Core::check_login(&host, port, &email, &password).await {
                Ok(()) => println!("login ok: {email} via {host}:{port}"),
                Err(e) => {
                    println!("login failed: {e}");
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
                        mailcore::SyncEvent::Error { message, .. } => {
                            eprintln!("  error: {message}")
                        }
                        mailcore::SyncEvent::OutboxReplayed { ops, .. } => {
                            eprintln!("  outbox: {ops} ops replayed")
                        }
                        _ => {}
                    }
                }
            });
            let results = match account {
                Some(id) => vec![(
                    core.store().account(id)?,
                    core.sync_account(id, &opts).await,
                )],
                None => core.sync_all(&opts).await?,
            };
            for (a, r) in results {
                match r {
                    Ok(rep) => println!(
                        "{}: {} folders, +{} messages, -{} removed, {} ops",
                        a.email, rep.folders, rep.fetched, rep.removed, rep.ops_replayed
                    ),
                    Err(e) => println!("{}: FAILED: {e}", a.email),
                }
            }
            printer.abort();
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
        Cmd::Archive { thread } => {
            core.actions().archive(thread)?;
            println!("archived #{thread} (queued for next sync)");
        }
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
            core.send(account.id, &draft).await?;
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
            core.send(a.id, &draft).await?;
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
