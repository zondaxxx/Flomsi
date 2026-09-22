//! Conversation threading helpers (JWZ-lite): References / In-Reply-To first,
//! normalized subject as a fallback.

const REPLY_PREFIXES: &[&str] = &[
    "re:",
    "fwd:",
    "fw:",
    "aw:",
    "wg:",
    "sv:",
    "vs:",
    "ответ:",
    "пересл:",
    "отв:",
];

/// Strip reply/forward prefixes and bracketed counters like `Re[2]:`, lowercase, collapse whitespace.
pub fn normalize_subject(subject: &str) -> String {
    let mut s = subject.trim().to_lowercase();
    loop {
        let before = s.clone();
        for p in REPLY_PREFIXES {
            if let Some(rest) = s.strip_prefix(p) {
                s = rest.trim_start().to_string();
            }
        }
        // "re[2]:" / "re (3):"
        if s.starts_with("re[") || s.starts_with("re (") {
            if let Some(idx) = s.find(':') {
                s = s[idx + 1..].trim_start().to_string();
            }
        }
        if s == before {
            break;
        }
    }
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// True when the subject carries a reply/forward prefix.
pub fn is_reply(subject: &str) -> bool {
    normalize_subject(subject) != subject.trim().to_lowercase()
}

/// Split a `References:` or `In-Reply-To:` header into bare message ids (without angle brackets).
pub fn parse_message_ids(header: &str) -> Vec<String> {
    header
        .split(|c: char| c.is_whitespace() || c == ',')
        .filter(|t| !t.is_empty())
        .map(|t| t.trim_matches(|c| c == '<' || c == '>').to_string())
        .filter(|t| t.contains('@'))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_nested_prefixes() {
        assert_eq!(
            normalize_subject("Re: Fwd: RE: Design review"),
            "design review"
        );
        assert_eq!(normalize_subject("Re[2]: hello"), "hello");
        assert_eq!(normalize_subject("Ответ: Ключи"), "ключи");
        assert_eq!(normalize_subject("  plain   subject "), "plain subject");
    }

    #[test]
    fn detects_reply() {
        assert!(is_reply("Re: x"));
        assert!(!is_reply("x"));
    }

    #[test]
    fn parses_ids() {
        let ids = parse_message_ids("<a@x.dev> <b@y.dev>,<c@z.dev>");
        assert_eq!(ids, vec!["a@x.dev", "b@y.dev", "c@z.dev"]);
    }
}
