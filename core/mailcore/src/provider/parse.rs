//! RFC 822 → ParsedMessage via mail-parser.

use crate::model::{Address, ParsedMessage};
use crate::threading::parse_message_ids;
use chrono::{DateTime, Utc};
use mail_parser::{Addr, HeaderValue, MessageParser, MimeHeaders};

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
    let has_attachment = msg
        .attachments()
        .any(|a| a.attachment_name().is_some() || !a.is_message());

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
}
