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
    #[serde(default)]
    pub attachments: Vec<DraftAttachment>,
}

/// A file going out with a draft. Bytes are read only at send time.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DraftAttachment {
    pub name: String,
    pub mime: String,
    pub size: u64,
    pub source: AttachmentSource,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum AttachmentSource {
    /// A file on this device.
    File { path: String },
    /// A part of a stored message; forwarding keeps the original attachments this way.
    Message { message_id: i64, idx: u32 },
}

impl DraftAttachment {
    /// Describe a local file: name, size and a MIME type guessed from the extension.
    pub fn from_path(path: &std::path::Path) -> Result<DraftAttachment> {
        let meta = std::fs::metadata(path)?;
        if !meta.is_file() {
            return Err(Error::Other(format!("{} is not a file", path.display())));
        }
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "attachment".to_string());
        Ok(DraftAttachment {
            mime: mime_guess::from_path(path)
                .first_or_octet_stream()
                .essence_str()
                .to_string(),
            name,
            size: meta.len(),
            source: AttachmentSource::File {
                path: path.to_string_lossy().into_owned(),
            },
        })
    }
}

/// A draft kept on this device while it is written. `kind` is the UI's hint for how it
/// started: `fresh`, `reply` or `forward`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SavedDraft {
    pub id: i64,
    pub account_id: i64,
    pub kind: String,
    pub draft: Draft,
    pub updated_at: DateTime<Utc>,
}

/// An attachment with its bytes loaded, ready to be encoded.
#[derive(Debug, Clone)]
pub struct OutgoingFile {
    pub name: String,
    pub mime: String,
    pub bytes: Vec<u8>,
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
            attachments: vec![],
        }
    }

    pub fn forward(original: &Message, me: &Address) -> Draft {
        Draft {
            from: me.clone(),
            subject: forward_subject(&original.subject),
            ..Default::default()
        }
    }

    /// Serialize to RFC 5322 bytes ready for SMTP / IMAP APPEND. `files` are the loaded
    /// attachments; with any, the body becomes the first part of a multipart/mixed message.
    pub fn to_mime(&self, files: &[OutgoingFile]) -> Result<lettre::Message> {
        use lettre::message::header::ContentType;
        use lettre::message::{Attachment, Mailbox, MultiPart, SinglePart};
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
        if files.is_empty() {
            return b
                .header(ContentType::TEXT_PLAIN)
                .body(self.text.clone())
                .map_err(|e| Error::Parse(format!("mime: {e}")));
        }
        let mut mixed = MultiPart::mixed().singlepart(SinglePart::plain(self.text.clone()));
        for f in files {
            let ct = ContentType::parse(&f.mime)
                .unwrap_or_else(|_| ContentType::parse("application/octet-stream").unwrap());
            mixed = mixed.singlepart(Attachment::new(f.name.clone()).body(f.bytes.clone(), ct));
        }
        b.multipart(mixed)
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
        let bytes = d.to_mime(&[]).unwrap().formatted();
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

    #[test]
    fn mime_carries_attachments() {
        use crate::provider::parse::{extract_attachment, parse_rfc822};
        let mut d = Draft::new(Address {
            name: None,
            addr: "me@x.dev".into(),
        });
        d.to = vec![Address {
            name: None,
            addr: "a@x.dev".into(),
        }];
        d.subject = "Invoice".into();
        d.text = "See attached.".into();
        let file = OutgoingFile {
            name: "Счёт.pdf".into(),
            mime: "application/pdf".into(),
            bytes: crate::testdata::PDF_BYTES.to_vec(),
        };
        let bytes = d.to_mime(&[file]).unwrap().formatted();
        let parsed = parse_rfc822(&bytes, Utc::now());
        assert_eq!(parsed.text.as_deref().map(str::trim), Some("See attached."));
        assert_eq!(parsed.attachments.len(), 1);
        assert_eq!(parsed.attachments[0].name, "Счёт.pdf");
        assert_eq!(parsed.attachments[0].mime, "application/pdf");
        let (_, got) = extract_attachment(&bytes, 0).unwrap();
        assert_eq!(got, crate::testdata::PDF_BYTES);
    }

    #[test]
    fn describes_local_files() {
        let p = std::env::temp_dir().join(format!("mailcore-draft-{}.pdf", std::process::id()));
        std::fs::write(&p, b"%PDF").unwrap();
        let a = DraftAttachment::from_path(&p).unwrap();
        assert_eq!(a.mime, "application/pdf");
        assert_eq!(a.size, 4);
        assert!(a.name.ends_with(".pdf"));
        std::fs::remove_file(&p).unwrap();
        assert!(DraftAttachment::from_path(&std::env::temp_dir()).is_err());
    }
}
