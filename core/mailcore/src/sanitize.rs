//! HTML mail sanitizing. Every HTML body goes through here before any renderer sees it.
//!
//! Policy: no scripts, styles, forms, iframes or event handlers; links are rewritten to
//! open externally and never carry javascript:; remote images are blocked by default
//! (replaced with a placeholder attribute so the UI can offer "load images"); `cid:`
//! images are kept so inline attachments can be resolved locally.

use ammonia::Builder;
use std::borrow::Cow;
use std::collections::HashSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SanitizeOptions {
    /// Allow http(s) images to load. Default false: they become `data-blocked-src`.
    pub load_remote_images: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sanitized {
    pub html: String,
    /// Number of remote images that were blocked.
    pub blocked_images: usize,
}

fn builder<'a>() -> Builder<'a> {
    let mut b = Builder::default();
    let tags: HashSet<&str> = [
        "a",
        "abbr",
        "b",
        "blockquote",
        "br",
        "caption",
        "code",
        "col",
        "colgroup",
        "dd",
        "del",
        "div",
        "dl",
        "dt",
        "em",
        "font",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "hr",
        "i",
        "img",
        "ins",
        "kbd",
        "li",
        "ol",
        "p",
        "pre",
        "q",
        "s",
        "small",
        "span",
        "strike",
        "strong",
        "sub",
        "sup",
        "table",
        "tbody",
        "td",
        "tfoot",
        "th",
        "thead",
        "tr",
        "u",
        "ul",
        "center",
    ]
    .into_iter()
    .collect();
    b.tags(tags);
    b.generic_attributes(
        [
            "title",
            "dir",
            "lang",
            "align",
            "valign",
            "width",
            "height",
            "colspan",
            "rowspan",
            "cellpadding",
            "cellspacing",
            "border",
            "bgcolor",
            "color",
        ]
        .into_iter()
        .collect(),
    );
    b.tag_attributes(
        [
            ("a", ["href", "name"].into_iter().collect()),
            (
                "img",
                ["src", "alt", "width", "height"].into_iter().collect(),
            ),
            ("font", ["face", "size", "color"].into_iter().collect()),
        ]
        .into_iter()
        .collect(),
    );
    b.url_schemes(["http", "https", "mailto", "cid"].into_iter().collect());
    b.link_rel(Some("noopener noreferrer"));
    // Keep a curated subset of inline style so newsletters stay readable but can't escape the box.
    b.attribute_filter(filter_attr);
    b
}

fn filter_attr<'v>(_element: &str, attr: &str, value: &'v str) -> Option<Cow<'v, str>> {
    if attr != "style" {
        return Some(Cow::Borrowed(value));
    }
    const ALLOWED: &[&str] = &[
        "color",
        "background-color",
        "font-weight",
        "font-style",
        "font-size",
        "text-align",
        "text-decoration",
        "padding",
        "margin",
        "border",
        "border-radius",
        "width",
        "max-width",
        "line-height",
        "font-family",
        "vertical-align",
    ];
    let kept: Vec<String> = value
        .split(';')
        .filter_map(|decl| {
            let (k, v) = decl.split_once(':')?;
            let k = k.trim().to_ascii_lowercase();
            let v = v.trim();
            let lv = v.to_ascii_lowercase();
            if !ALLOWED.contains(&k.as_str())
                || lv.contains("url(")
                || lv.contains("expression")
                || lv.contains("javascript")
            {
                return None;
            }
            Some(format!("{k}: {v}"))
        })
        .collect();
    if kept.is_empty() {
        None
    } else {
        Some(Cow::Owned(kept.join("; ")))
    }
}

pub fn sanitize(html: &str, opts: SanitizeOptions) -> Sanitized {
    let mut b = builder();
    let mut generic = b_generic();
    generic.insert("style");
    b.generic_attributes(generic);
    let cleaned = b.clean(html).to_string();
    if opts.load_remote_images {
        return Sanitized {
            html: cleaned,
            blocked_images: 0,
        };
    }
    block_remote_images(&cleaned)
}

fn b_generic() -> HashSet<&'static str> {
    [
        "title",
        "dir",
        "lang",
        "align",
        "valign",
        "width",
        "height",
        "colspan",
        "rowspan",
        "cellpadding",
        "cellspacing",
        "border",
        "bgcolor",
        "color",
    ]
    .into_iter()
    .collect()
}

/// Rewrite `<img src="http…">` to `<img data-blocked-src="http…">`. Runs on already-clean markup.
fn block_remote_images(html: &str) -> Sanitized {
    let mut out = String::with_capacity(html.len());
    let mut blocked = 0;
    let mut rest = html;
    while let Some(i) = rest.find("<img") {
        out.push_str(&rest[..i]);
        let tag_end = rest[i..].find('>').map(|e| i + e + 1).unwrap_or(rest.len());
        let tag = &rest[i..tag_end];
        let lowered = tag.to_ascii_lowercase();
        if lowered.contains("src=\"http://") || lowered.contains("src=\"https://") {
            blocked += 1;
            out.push_str(&tag.replacen("src=\"", "data-blocked-src=\"", 1));
        } else {
            out.push_str(tag);
        }
        rest = &rest[tag_end..];
    }
    out.push_str(rest);
    Sanitized {
        html: out,
        blocked_images: blocked,
    }
}

/// Very small HTML → text for previews and the plain reading mode.
pub fn html_to_text(html: &str) -> String {
    let mut b = Builder::empty();
    b.tags(
        [
            "br",
            "p",
            "div",
            "li",
            "tr",
            "h1",
            "h2",
            "h3",
            "h4",
            "blockquote",
        ]
        .into_iter()
        .collect(),
    );
    let skeleton = b.clean(html).to_string();
    let mut text = String::with_capacity(skeleton.len());
    let mut in_tag = false;
    for ch in skeleton.chars() {
        match ch {
            '<' => {
                in_tag = true;
                text.push('\n');
            }
            '>' => in_tag = false,
            c if !in_tag => text.push(c),
            _ => {}
        }
    }
    let decoded = text
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'");
    let mut lines: Vec<String> = decoded
        .lines()
        .map(|l| l.split_whitespace().collect::<Vec<_>>().join(" "))
        .collect();
    lines.dedup_by(|a, b| a.is_empty() && b.is_empty());
    lines.join("\n").trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_scripts_and_handlers() {
        let s = sanitize(
            r#"<p onclick="x()">hi<script>alert(1)</script><a href="javascript:evil()">l</a></p>"#,
            SanitizeOptions::default(),
        );
        assert!(!s.html.contains("script"));
        assert!(!s.html.contains("onclick"));
        assert!(!s.html.contains("javascript:"));
        assert!(s.html.contains("<p>hi"));
    }

    #[test]
    fn blocks_remote_images_keeps_cid() {
        let s = sanitize(
            r#"<img src="https://t.example/pixel.gif"><img src="cid:logo@x">"#,
            SanitizeOptions::default(),
        );
        assert_eq!(s.blocked_images, 1);
        assert!(s
            .html
            .contains("data-blocked-src=\"https://t.example/pixel.gif\""));
        assert!(s.html.contains("src=\"cid:logo@x\""));
        let loaded = sanitize(
            r#"<img src="https://t.example/a.png">"#,
            SanitizeOptions {
                load_remote_images: true,
            },
        );
        assert_eq!(loaded.blocked_images, 0);
        assert!(loaded.html.contains("src=\"https://t.example/a.png\""));
    }

    #[test]
    fn style_allowlist() {
        let s = sanitize(
            r#"<div style="color: red; position: fixed; background: url(x)">a</div>"#,
            SanitizeOptions::default(),
        );
        assert!(s.html.contains("color: red"));
        assert!(!s.html.contains("position"));
        assert!(!s.html.contains("url("));
    }

    #[test]
    fn links_open_safely() {
        let s = sanitize(
            r#"<a href="https://x.dev">x</a>"#,
            SanitizeOptions::default(),
        );
        assert!(s.html.contains("rel=\"noopener noreferrer\""));
    }

    #[test]
    fn text_extraction() {
        let t = html_to_text("<div>Hello<br>world</div><p>&amp; more</p><style>p{}</style>");
        assert_eq!(t, "Hello\nworld\n\n& more");
    }
}
