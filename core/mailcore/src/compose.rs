//! Drafts: building replies/forwards with correct threading headers, quoting, MIME.

use crate::error::{Error, Result};
use crate::model::{Address, Message};
use crate::threading::normalize_subject;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Draft {
    pub from: Address,
    pub to: Vec<Address>,
    pub cc: Vec<Address>,
    pub bcc: Vec<Address>,
    pub subject: String,
    pub text: String,
    pub in_reply_to: Option<String>,
    pub references: Vec<String>,
}

impl Draft {
    pub fn new(from: Address) -> Draft {
        Draft {
            from,
            ..Default::default()
        }
    }

    /// Reply to `original`. `reply_all` keeps every other recipient in To/Cc.
    pub fn reply(
        original: &Message,
        original_message_id: Option<&str>,
        references: &[String],
        me: &Address,
        reply_all: bool,
    ) -> Draft {
        let to = vec![original.from.clone()];
        let mut cc = Vec::new();
        if reply_all {
            for a in original.to.iter().chain(original.cc.iter()) {
                if a.addr.eq_ignore_ascii_case(&me.addr)
                    || to.iter().any(|t| t.addr.eq_ignore_ascii_case(&a.addr))
                {
                    continue;
                }
                cc.push(a.clone());
            }
        }
        let mut refs: Vec<String> = references.to_vec();
        if let Some(id) = original_message_id {
            if !refs.iter().any(|r| r == id) {
                refs.push(id.to_string());
            }
        }
        Draft {
            from: me.clone(),
            to,
            cc,
            bcc: vec![],
            subject: reply_subject(&original.subject),
            text: String::new(),
            in_reply_to: original_message_id.map(|s| s.to_string()),
            references: refs,
        }
    }

    pub fn forward(original: &Message, me: &Address) -> Draft {
        Draft {
            from: me.clone(),
            subject: forward_subject(&original.subject),
            ..Default::default()
        }
    }

    /// Serialize to RFC 5322 bytes ready for SMTP / IMAP APPEND.
    pub fn to_mime(&self) -> Result<lettre::Message> {
        use lettre::message::header::ContentType;
        use lettre::message::Mailbox;
        fn mailbox(a: &Address) -> Result<Mailbox> {
            let addr: lettre::Address = a
                .addr
                .parse()
                .map_err(|e| Error::Parse(format!("address {}: {e}", a.addr)))?;
            Ok(Mailbox::new(a.name.clone().filter(|n| !n.is_empty()), addr))
        }
        let mut b = lettre::Message::builder()
            .from(mailbox(&self.from)?)
            .subject(self.subject.clone());
        for a in &self.to {
            b = b.to(mailbox(a)?);
        }
        for a in &self.cc {
            b = b.cc(mailbox(a)?);
        }
        for a in &self.bcc {
            b = b.bcc(mailbox(a)?);
        }
        if let Some(irt) = &self.in_reply_to {
            b = b.in_reply_to(format!("<{irt}>"));
        }
        if !self.references.is_empty() {
            b = b.references(
                self.references
                    .iter()
                    .map(|r| format!("<{r}>"))
                    .collect::<Vec<_>>()
                    .join(" "),
            );
        }
        b.header(ContentType::TEXT_PLAIN)
            .body(self.text.clone())
            .map_err(|e| Error::Parse(format!("mime: {e}")))
    }
}

pub fn reply_subject(subject: &str) -> String {
    format!("Re: {}", strip_prefixes(subject.trim()))
}

pub fn forward_subject(subject: &str) -> String {
    format!("Fwd: {}", strip_prefixes(subject.trim()))
}

/// Keep original casing but drop leading Re:/Fwd: chains.
fn strip_prefixes(s: &str) -> String {
    let norm = normalize_subject(s);
    let lower = s.to_lowercase();
    match lower.find(&norm) {
        Some(i) if !norm.is_empty() => s[i..].to_string(),
        _ => s.to_string(),
    }
}

/// `> ` quote of the original, with the usual attribution line.
pub fn quote(text: &str, from: &Address, date: DateTime<Utc>) -> String {
    let mut out = format!(
        "On {}, {} wrote:\n",
        date.format("%a, %d %b %Y at %H:%M"),
        from.display()
    );
    for line in text.lines() {
        out.push_str("> ");
        out.push_str(line);
        out.push('\n');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Flags;
    use chrono::TimeZone;

    fn msg() -> Message {
        Message {
            id: 1,
            account_id: 1,
            folder_id: 1,
            uid: 1,
            message_id: Some("orig@studio.dev".into()),
            thread_id: 1,
            subject: "Re: Fwd: Design review".into(),
            from: Address {
                name: Some("Anna".into()),
                addr: "anna@studio.dev".into(),
            },
            to: vec![
                Address {
                    name: None,
                    addr: "me@x.dev".into(),
                },
                Address {
                    name: Some("Bob".into()),
                    addr: "bob@x.dev".into(),
                },
            ],
            cc: vec![Address {
                name: None,
                addr: "cc@x.dev".into(),
            }],
            date: Utc.with_ymd_and_hms(2026, 9, 22, 9, 12, 0).unwrap(),
            snippet: String::new(),
            flags: Flags::default(),
            has_attachment: false,
            size: 0,
        }
    }

    #[test]
    fn subjects() {
        assert_eq!(reply_subject("Design review"), "Re: Design review");
        assert_eq!(reply_subject("Re: Design review"), "Re: Design review");
        assert_eq!(reply_subject("Fwd: Re: Design review"), "Re: Design review");
        assert_eq!(forward_subject("Re: Design review"), "Fwd: Design review");
    }

    #[test]
    fn reply_all_recipients_and_threading() {
        let me = Address {
            name: Some("Z".into()),
            addr: "me@x.dev".into(),
        };
        let d = Draft::reply(
            &msg(),
            Some("orig@studio.dev"),
            &["root@studio.dev".to_string()],
            &me,
            true,
        );
        assert_eq!(d.to[0].addr, "anna@studio.dev");
        assert_eq!(
            d.cc.iter().map(|a| a.addr.as_str()).collect::<Vec<_>>(),
            vec!["bob@x.dev", "cc@x.dev"]
        );
        assert_eq!(d.in_reply_to.as_deref(), Some("orig@studio.dev"));
        assert_eq!(d.references, vec!["root@studio.dev", "orig@studio.dev"]);
        assert_eq!(d.subject, "Re: Design review");
        let solo = Draft::reply(&msg(), None, &[], &me, false);
        assert!(solo.cc.is_empty());
    }

    #[test]
    fn mime_has_headers() {
        let me = Address {
            name: Some("Z".into()),
            addr: "me@x.dev".into(),
        };
        let mut d = Draft::reply(&msg(), Some("orig@studio.dev"), &[], &me, false);
        d.text = "Works for me.".into();
        let bytes = d.to_mime().unwrap().formatted();
        let s = String::from_utf8(bytes).unwrap();
        assert!(s.contains("From: \"Z\" <me@x.dev>") || s.contains("From: Z <me@x.dev>"));
        assert!(s.contains("In-Reply-To: <orig@studio.dev>"));
        assert!(s.contains("References: <orig@studio.dev>"));
        assert!(s.contains("Works for me."));
    }

    #[test]
    fn quoting() {
        let q = quote(
            "a\nb",
            &Address {
                name: Some("Anna".into()),
                addr: "a@x".into(),
            },
            Utc.with_ymd_and_hms(2026, 9, 22, 9, 12, 0).unwrap(),
        );
        assert_eq!(q, "On Tue, 22 Sep 2026 at 09:12, Anna wrote:\n> a\n> b\n");
    }
}
