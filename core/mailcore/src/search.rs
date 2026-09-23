//! Search query language: `from:anna has:attachment is:unread before:2026-09 in:inbox #work "exact phrase"`.

use crate::model::FolderRole;
use chrono::NaiveDate;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Query {
    pub text: Vec<String>,
    pub from: Option<String>,
    pub to: Option<String>,
    pub subject: Option<String>,
    pub has_attachment: bool,
    pub unread: Option<bool>,
    pub starred: bool,
    pub before: Option<NaiveDate>,
    pub after: Option<NaiveDate>,
    pub folder: Option<FolderRole>,
    pub label: Option<String>,
    pub account: Option<String>,
    /// `in:snoozed`: threads whose snooze has not ended yet.
    pub snoozed: bool,
}

impl Query {
    pub fn parse(input: &str) -> Query {
        let mut q = Query::default();
        for tok in tokenize(input) {
            if let Some(tag) = tok.strip_prefix('#') {
                if !tag.is_empty() {
                    q.label = Some(tag.to_string());
                    continue;
                }
            }
            match tok.split_once(':') {
                Some(("from", v)) => q.from = Some(v.to_string()),
                Some(("to", v)) => q.to = Some(v.to_string()),
                Some(("subject", v)) => q.subject = Some(v.to_string()),
                Some(("has", "attachment")) | Some(("has", "file")) => q.has_attachment = true,
                Some(("is", "unread")) => q.unread = Some(true),
                Some(("is", "read")) => q.unread = Some(false),
                Some(("is", "starred")) | Some(("is", "flagged")) => q.starred = true,
                Some(("before", v)) => q.before = parse_date(v),
                Some(("after", v)) => q.after = parse_date(v),
                Some(("in", "snoozed")) => q.snoozed = true,
                Some(("in", v)) => q.folder = FolderRole::parse(v),
                Some(("label", v)) => q.label = Some(v.to_string()),
                Some(("account", v)) => q.account = Some(v.to_string()),
                _ => q.text.push(tok),
            }
        }
        q
    }

    pub fn is_empty(&self) -> bool {
        *self == Query::default()
    }

    /// FTS5 MATCH expression for the free-text part, or None when there is none.
    pub fn fts_expression(&self) -> Option<String> {
        if self.text.is_empty() {
            return None;
        }
        let parts: Vec<String> = self
            .text
            .iter()
            .map(|t| {
                let escaped = t.replace('"', "\"\"");
                if t.contains(' ') {
                    format!("\"{escaped}\"")
                } else {
                    format!("\"{escaped}\"*")
                }
            })
            .collect();
        Some(parts.join(" "))
    }
}

impl Query {
    /// The query as IMAP SEARCH criteria for looking on the server, or None when it names
    /// nothing to look for (words, a sender or recipient, a subject, a date): a server is
    /// never asked for a whole mailbox. Non-ASCII goes as a `{n+}` literal where the server
    /// takes LITERAL+, otherwise as quoted UTF-8 after `CHARSET UTF-8`, which servers
    /// generally accept.
    pub fn imap_criteria(&self, literal_plus: bool) -> Option<String> {
        let mut parts = Vec::new();
        let mut utf8 = false;
        // A value as an IMAP string, or None when nothing is left of it.
        let mut value = |v: &str| -> Option<String> {
            let v: String = v.chars().filter(|c| !c.is_control()).collect();
            if v.trim().is_empty() {
                return None;
            }
            utf8 |= !v.is_ascii();
            Some(imap_string(&v, literal_plus))
        };
        for t in &self.text {
            if let Some(v) = value(t) {
                parts.push(format!("TEXT {v}"));
            }
        }
        if let Some(v) = self.from.as_deref().and_then(&mut value) {
            parts.push(format!("FROM {v}"));
        }
        // As the list does: the address in To or Cc.
        if let Some(v) = self.to.as_deref().and_then(&mut value) {
            parts.push(format!("OR TO {v} CC {v}"));
        }
        if let Some(v) = self.subject.as_deref().and_then(&mut value) {
            parts.push(format!("SUBJECT {v}"));
        }
        // The Date header, as the list compares, not the day the server received it.
        if let Some(d) = self.before {
            parts.push(format!("SENTBEFORE {}", d.format("%-d-%b-%Y")));
        }
        if let Some(d) = self.after {
            parts.push(format!("SENTSINCE {}", d.format("%-d-%b-%Y")));
        }
        if parts.is_empty() {
            return None;
        }
        match self.unread {
            Some(true) => parts.push("UNSEEN".into()),
            Some(false) => parts.push("SEEN".into()),
            None => {}
        }
        if self.starred {
            parts.push("FLAGGED".into());
        }
        let criteria = parts.join(" ");
        Some(if utf8 {
            format!("CHARSET UTF-8 {criteria}")
        } else {
            criteria
        })
    }
}

fn imap_string(v: &str, literal_plus: bool) -> String {
    // LITERAL- servers take non-synchronizing literals up to 4096 bytes.
    if !v.is_ascii() && literal_plus && v.len() <= 4096 {
        return format!("{{{}+}}\r\n{v}", v.len());
    }
    format!("\"{}\"", v.replace('\\', "\\\\").replace('"', "\\\""))
}

/// `2026-09-22`, `2026-09` (first of month) or `2026`.
fn parse_date(v: &str) -> Option<NaiveDate> {
    let parts: Vec<&str> = v.split('-').collect();
    let y: i32 = parts
        .first()?
        .parse()
        .ok()
        .filter(|y| (1..=9999).contains(y))?;
    let m: u32 = parts.get(1).and_then(|s| s.parse().ok()).unwrap_or(1);
    let d: u32 = parts.get(2).and_then(|s| s.parse().ok()).unwrap_or(1);
    NaiveDate::from_ymd_opt(y, m, d)
}

/// Whitespace tokenizer that keeps quoted phrases together (quotes removed).
fn tokenize(input: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_quotes = false;
    for ch in input.chars() {
        match ch {
            '"' => in_quotes = !in_quotes,
            c if c.is_whitespace() && !in_quotes => {
                if !cur.is_empty() {
                    out.push(std::mem::take(&mut cur));
                }
            }
            c => cur.push(c),
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_operators() {
        let q = Query::parse("from:anna has:attachment is:unread before:2026-09 in:inbox #work glass \"design review\"");
        assert_eq!(q.from.as_deref(), Some("anna"));
        assert!(q.has_attachment);
        assert_eq!(q.unread, Some(true));
        assert_eq!(q.before, NaiveDate::from_ymd_opt(2026, 9, 1));
        assert_eq!(q.folder, Some(FolderRole::Inbox));
        assert_eq!(q.label.as_deref(), Some("work"));
        assert_eq!(q.text, vec!["glass", "design review"]);
        assert_eq!(q.fts_expression().unwrap(), "\"glass\"* \"design review\"");
    }

    #[test]
    fn empty_query() {
        assert!(Query::parse("   ").is_empty());
        assert!(Query::parse("").fts_expression().is_none());
    }

    #[test]
    fn server_criteria_name_what_to_look_for() {
        let q = Query::parse("from:anna invoice before:2026-09-22 is:unread");
        assert_eq!(
            q.imap_criteria(false).as_deref(),
            Some(r#"TEXT "invoice" FROM "anna" SENTBEFORE 22-Sep-2026 UNSEEN"#)
        );
        // Nothing to look for: the server is not asked for everything.
        assert_eq!(
            Query::parse("is:unread in:inbox").imap_criteria(false),
            None
        );
        assert_eq!(Query::parse("").imap_criteria(false), None);
        // Quotes cannot end the string early.
        assert_eq!(
            Query::parse(r#"subject:a"b"#)
                .imap_criteria(false)
                .as_deref(),
            Some(r#"SUBJECT "ab""#)
        );
        let q = Query::parse("счёт");
        assert_eq!(
            q.imap_criteria(false).as_deref(),
            Some("CHARSET UTF-8 TEXT \"счёт\"")
        );
        assert_eq!(
            q.imap_criteria(true).as_deref(),
            Some("CHARSET UTF-8 TEXT {8+}\r\nсчёт")
        );
    }
}
