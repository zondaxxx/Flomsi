//! RFC 822 → ParsedMessage via mail-parser.

use crate::model::{Address, AttachmentMeta, ParsedMessage};
use crate::threading::parse_message_ids;
use chrono::{DateTime, Utc};
use mail_parser::{Addr, HeaderValue, MessageParser, MessagePart, MimeHeaders};

fn addr(a: &Addr) -> Option<Address> {
    let address = a.address.as_ref()?.to_string();
    Some(Address {
        name: a.name.as_ref().map(|n| n.to_string()),
        addr: address,
    })
}

fn addresses(h: &HeaderValue) -> Vec<Address> {
    match h {
        HeaderValue::Address(mail_parser::Address::List(list)) => {
            list.iter().filter_map(addr).collect()
        }
        HeaderValue::Address(mail_parser::Address::Group(groups)) => groups
            .iter()
            .flat_map(|g| g.addresses.iter())
            .filter_map(addr)
            .collect(),
        _ => Vec::new(),
    }
}

fn ids(h: &HeaderValue) -> Vec<String> {
    match h {
        HeaderValue::Text(t) => parse_message_ids(t),
        HeaderValue::TextList(l) => l.iter().flat_map(|t| parse_message_ids(t)).collect(),
        _ => Vec::new(),
    }
}

/// Collapse whitespace and cut to `n` chars for list previews.
pub fn snippet(text: &str, n: usize) -> String {
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut s: String = collapsed.chars().take(n).collect();
    if collapsed.chars().count() > n {
        s.push('…');
    }
    s
}

/// MIME type of a part as `type/subtype`, lowercased.
fn mime_of(part: &MessagePart) -> String {
    if part.is_message() {
        return "message/rfc822".to_string();
    }
    part.content_type()
        .map(|ct| match ct.subtype() {
            Some(sub) => format!("{}/{}", ct.ctype(), sub),
            None => ct.ctype().to_string(),
        })
        .unwrap_or_else(|| "application/octet-stream".to_string())
        .to_ascii_lowercase()
}

/// File name for a part: the declared one, else the nested message's subject, else a
/// generic name with an extension guessed from the MIME type.
fn name_of(part: &MessagePart, mime: &str, i: usize) -> String {
    if let Some(n) = part
        .attachment_name()
        .map(str::trim)
        .filter(|n| !n.is_empty())
    {
        return n.to_string();
    }
    if let Some(sub) = part.message().and_then(|m| m.subject()) {
        return format!("{}.eml", sub.trim());
    }
    let ext = mime_guess::get_mime_extensions_str(mime)
        .and_then(|e| e.first())
        .map(|e| format!(".{e}"))
        .unwrap_or_default();
    format!("attachment-{}{ext}", i + 1)
}

/// Every non-body part in parser order. A part counts as inline when it has a Content-ID
/// that the HTML body actually references.
pub fn attachment_list(msg: &mail_parser::Message, html: Option<&str>) -> Vec<AttachmentMeta> {
    msg.attachments()
        .enumerate()
        .map(|(i, part)| {
            let mime = mime_of(part);
            let content_id = part
                .content_id()
                .map(|c| {
                    c.trim()
                        .trim_start_matches('<')
                        .trim_end_matches('>')
                        .to_string()
                })
                .filter(|c| !c.is_empty());
            let inline = match (&content_id, html) {
                (Some(cid), Some(h)) => h.contains(&format!("cid:{cid}")),
                _ => false,
            };
            AttachmentMeta {
                idx: i as u32,
                name: name_of(part, &mime, i),
                mime,
                size: part.contents().len() as u64,
                content_id,
                inline,
            }
        })
        .collect()
}

/// One part's metadata and decoded bytes, found by its position in parser order.
pub fn extract_attachment(raw: &[u8], idx: u32) -> Option<(AttachmentMeta, Vec<u8>)> {
    let msg = MessageParser::default().parse(raw)?;
    let html = msg.body_html(0).map(|h| h.to_string());
    let meta = attachment_list(&msg, html.as_deref())
        .into_iter()
        .find(|a| a.idx == idx)?;
    let bytes = msg.attachments().nth(idx as usize)?.contents().to_vec();
    Some((meta, bytes))
}

/// Content-ID → (MIME type, bytes) for every part that carries a Content-ID.
pub fn content_id_parts(raw: &[u8]) -> Vec<(String, String, Vec<u8>)> {
    let Some(msg) = MessageParser::default().parse(raw) else {
        return Vec::new();
    };
    attachment_list(&msg, None)
        .into_iter()
        .zip(msg.attachments())
        .filter_map(|(meta, part)| Some((meta.content_id?, meta.mime, part.contents().to_vec())))
        .collect()
}

/// Message-ID of a raw message, reading headers only.
pub fn raw_message_id(raw: &[u8]) -> Option<String> {
    MessageParser::default()
        .parse_headers(raw)
        .and_then(|m| m.message_id().map(|s| s.to_string()))
}

pub fn parse_rfc822(raw: &[u8], fallback_date: DateTime<Utc>) -> ParsedMessage {
    let Some(msg) = MessageParser::default().parse(raw) else {
        return ParsedMessage {
            message_id: None,
            in_reply_to: None,
            references: vec![],
            subject: String::new(),
            from: Address {
                name: None,
                addr: String::new(),
            },
            to: vec![],
            cc: vec![],
            date: fallback_date,
            snippet: String::new(),
            has_attachment: false,
            attachments: Vec::new(),
            text: None,
            html: None,
        };
    };

    let from = addresses(msg.header("From").unwrap_or(&HeaderValue::Empty))
        .into_iter()
        .next()
        .unwrap_or(Address {
            name: None,
            addr: String::new(),
        });
    let to = addresses(msg.header("To").unwrap_or(&HeaderValue::Empty));
    let cc = addresses(msg.header("Cc").unwrap_or(&HeaderValue::Empty));

    let date = msg
        .date()
        .and_then(|d| DateTime::parse_from_rfc3339(&d.to_rfc3339()).ok())
        .map(|d| d.with_timezone(&Utc))
        .unwrap_or(fallback_date);

    let text = msg.body_text(0).map(|t| t.to_string());
    let html = msg.body_html(0).map(|h| h.to_string());
    let preview_src = text.clone().unwrap_or_default();
    let attachments = attachment_list(&msg, html.as_deref());
    let has_attachment = attachments.iter().any(|a| !a.inline);

    ParsedMessage {
        message_id: msg.message_id().map(|s| s.to_string()),
        in_reply_to: ids(msg.header("In-Reply-To").unwrap_or(&HeaderValue::Empty))
            .into_iter()
            .last(),
        references: ids(msg.header("References").unwrap_or(&HeaderValue::Empty)),
        subject: msg.subject().unwrap_or("").to_string(),
        from,
        to,
        cc,
        date,
        snippet: snippet(&preview_src, 120),
        has_attachment,
        attachments,
        text,
        html,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_simple_message() {
        let raw = b"From: Anna Sokolova <anna@studio.dev>\r\nTo: Z <z@x.dev>\r\nSubject: Re: Design review\r\nMessage-ID: <b@studio.dev>\r\nIn-Reply-To: <a@x.dev>\r\nReferences: <a@x.dev>\r\nDate: Tue, 22 Sep 2026 09:12:00 +0300\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nMoving it to 15:00,\r\nthe glass prototype needs one more pass.\r\n";
        let m = parse_rfc822(raw, Utc::now());
        assert_eq!(m.from.addr, "anna@studio.dev");
        assert_eq!(m.from.name.as_deref(), Some("Anna Sokolova"));
        assert_eq!(m.subject, "Re: Design review");
        assert_eq!(m.message_id.as_deref(), Some("b@studio.dev"));
        assert_eq!(m.references, vec!["a@x.dev"]);
        assert_eq!(m.in_reply_to.as_deref(), Some("a@x.dev"));
        assert!(m.snippet.starts_with("Moving it to 15:00, the glass"));
        assert_eq!(m.date.to_rfc3339(), "2026-09-22T06:12:00+00:00");
        assert!(!m.has_attachment);
    }

    #[test]
    fn lists_attachments_and_inline_images() {
        use crate::testdata::*;
        let m = parse_rfc822(INVOICE_EML, Utc::now());
        assert_eq!(m.attachments.len(), 2);
        let logo = m
            .attachments
            .iter()
            .find(|a| a.mime == "image/png")
            .unwrap();
        assert_eq!(logo.content_id.as_deref(), Some("logo@studio.dev"));
        assert!(logo.inline);
        assert_eq!(logo.size, PNG_SIGNATURE.len() as u64);
        let pdf = m
            .attachments
            .iter()
            .find(|a| a.mime == "application/pdf")
            .unwrap();
        assert_eq!(pdf.name, "Счёт.pdf");
        assert!(!pdf.inline);
        assert!(m.has_attachment);

        let (meta, bytes) = extract_attachment(INVOICE_EML, pdf.idx).unwrap();
        assert_eq!(&meta, pdf);
        assert_eq!(bytes, PDF_BYTES);
        assert_eq!(
            content_id_parts(INVOICE_EML),
            vec![(
                "logo@studio.dev".to_string(),
                "image/png".to_string(),
                PNG_SIGNATURE.to_vec()
            )]
        );
        assert_eq!(
            raw_message_id(INVOICE_EML).as_deref(),
            Some("inv@studio.dev")
        );
    }

    #[test]
    fn inline_image_alone_is_not_an_attachment() {
        let raw = String::from_utf8_lossy(crate::testdata::INVOICE_EML);
        let cut = raw.find("--MIX\r\nContent-Type: application/pdf").unwrap();
        let only_inline = format!("{}--MIX--\r\n", &raw[..cut]);
        let m = parse_rfc822(only_inline.as_bytes(), Utc::now());
        assert_eq!(m.attachments.len(), 1);
        assert!(m.attachments[0].inline);
        assert!(!m.has_attachment);
    }

    #[test]
    fn forwarded_message_part_is_named_after_its_subject() {
        let raw = b"From: a@x.dev\r\nSubject: Fwd\r\nContent-Type: multipart/mixed; boundary=B\r\n\r\n--B\r\nContent-Type: text/plain\r\n\r\nsee below\r\n--B\r\nContent-Type: message/rfc822\r\n\r\nFrom: b@x.dev\r\nSubject: Old thread\r\n\r\nhello\r\n--B--\r\n";
        let m = parse_rfc822(raw, Utc::now());
        assert_eq!(m.attachments.len(), 1);
        assert_eq!(m.attachments[0].name, "Old thread.eml");
        assert_eq!(m.attachments[0].mime, "message/rfc822");
        assert!(m.has_attachment);
    }
}
