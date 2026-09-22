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

/// `2026-09-22`, `2026-09` (first of month) or `2026`.
fn parse_date(v: &str) -> Option<NaiveDate> {
    let parts: Vec<&str> = v.split('-').collect();
    let y: i32 = parts.first()?.parse().ok()?;
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
}
