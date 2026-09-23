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
    // Relative and protocol-relative URLs (`/p.gif`, `//tracker/p.gif`) have no base to
    // resolve against and would slip past the remote-image gate: drop them.
    b.url_relative(ammonia::UrlRelative::Deny);
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
            if !ALLOWED.contains(&k.as_str()) || v.is_empty() || !safe_css_value(v) {
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

/// A CSS value made only of plain tokens: words, numbers with units, #hex, commas, quotes and
/// parentheses for rgb()/hsl(). Anything that could fetch, escape or open a rule is refused:
/// backslash escapes (`u\72l(`), braces, `@`, comments, angle brackets, and any `url`,
/// `image`, `expression` or `javascript` even with spaces inside.
fn safe_css_value(v: &str) -> bool {
    let plain = v.chars().all(|c| {
        c.is_ascii_alphanumeric()
            || matches!(
                c,
                ' ' | '#' | '%' | '.' | ',' | '(' | ')' | '-' | '+' | '"' | '\''
            )
    });
    let squeezed: String = v
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect::<String>()
        .to_ascii_lowercase();
    plain
        && !["url", "image", "expression", "javascript", "var(", "attr("]
            .iter()
            .any(|w| squeezed.contains(w))
}

pub fn sanitize(html: &str, opts: SanitizeOptions) -> Sanitized {
    let mut b = builder();
    let mut generic = b_generic();
    generic.insert("style");
    b.generic_attributes(generic);
    let cleaned = b.clean(html).to_string();
    gate_images(&cleaned, opts.load_remote_images)
}

/// An allow-list for `<img src>`: `cid:` parts (resolved locally later) always show; http(s)
/// only after "Load images". Anything else becomes `data-blocked-src` and is counted.
fn gate_images(html: &str, load_remote: bool) -> Sanitized {
    let mut blocked = 0;
    let html = for_each_img_src(html, |src| {
        let s = src.trim().to_ascii_lowercase();
        let remote = s.starts_with("https://") || s.starts_with("http://");
        if s.starts_with("cid:") || (remote && load_remote) {
            return None;
        }
        blocked += 1;
        Some(format!(" data-blocked-src=\"{src}\""))
    });
    Sanitized {
        html,
        blocked_images: blocked,
    }
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

/// Inline images bigger than this stay blocked instead of being embedded as data: URIs.
pub const MAX_INLINE_IMAGE: usize = 5 * 1024 * 1024;
/// And all inline images of one message together.
pub const MAX_INLINE_TOTAL: usize = 20 * 1024 * 1024;

/// Bitmap types that may be embedded as data: URIs. SVG stays out: it is a document format.
const INLINE_IMAGE_TYPES: &[&str] = &[
    "image/png",
    "image/jpeg",
    "image/jpg",
    "image/pjpeg",
    "image/gif",
    "image/webp",
    "image/bmp",
];

pub fn is_inline_image_type(mime: &str) -> bool {
    INLINE_IMAGE_TYPES.contains(&mime.to_ascii_lowercase().as_str())
}

fn percent_decode(s: &str) -> String {
    fn hex(c: u8) -> Option<u8> {
        (c as char).to_digit(16).map(|d| d as u8)
    }
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let (Some(h), Some(l)) = (hex(b[i + 1]), hex(b[i + 2])) {
                out.push(h << 4 | l);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The `cid:` targets of `<img>` tags in sanitized markup.
pub fn cid_refs(html: &str) -> Vec<String> {
    let mut out = Vec::new();
    for_each_img_src(html, |value| {
        if let Some(id) = cid_of(value) {
            out.push(id);
        }
        None
    });
    out
}

fn cid_of(src: &str) -> Option<String> {
    let v = src.trim();
    if v.len() > 4 && v[..4].eq_ignore_ascii_case("cid:") {
        Some(percent_decode(
            &v[4..].replace("&amp;", "&").replace("&quot;", "\""),
        ))
    } else {
        None
    }
}

/// Walk every `<img …>` in serializer output and let `edit` replace its `src` attribute
/// (given its value; return the whole replacement attribute, or None to keep it).
/// Attributes are parsed properly: serialized values are double-quoted and may contain
/// `>`, so the tag does not end at the first `>`.
fn for_each_img_src(html: &str, mut edit: impl FnMut(&str) -> Option<String>) -> String {
    let b = html.as_bytes();
    let mut out = String::with_capacity(html.len());
    let mut copied = 0;
    let mut i = 0;
    while let Some(off) = html[i..].find("<img") {
        let start = i + off;
        let mut j = start + 4;
        if j < b.len() && !(b[j].is_ascii_whitespace() || b[j] == b'>' || b[j] == b'/') {
            i = j; // `<imgx`: not an img tag
            continue;
        }
        // Parse ` name="value"` / ` name=value` / ` name` pairs until `>`.
        let mut src: Option<(usize, usize, usize)> = None; // (attr start, value start, value end)
        while j < b.len() && b[j] != b'>' {
            if b[j].is_ascii_whitespace() || b[j] == b'/' {
                j += 1;
                continue;
            }
            let name_start = j;
            while j < b.len() && !matches!(b[j], b'=' | b'>' | b'/') && !b[j].is_ascii_whitespace()
            {
                j += 1;
            }
            let name = &html[name_start..j];
            if j < b.len() && b[j] == b'=' {
                j += 1;
                let (v0, v1) = if j < b.len() && (b[j] == b'"' || b[j] == b'\'') {
                    let q = b[j];
                    let v0 = j + 1;
                    let v1 = html[v0..]
                        .find(q as char)
                        .map(|k| v0 + k)
                        .unwrap_or(b.len());
                    j = (v1 + 1).min(b.len());
                    (v0, v1)
                } else {
                    let v0 = j;
                    while j < b.len() && b[j] != b'>' && !b[j].is_ascii_whitespace() {
                        j += 1;
                    }
                    (v0, j)
                };
                if name.eq_ignore_ascii_case("src") && src.is_none() {
                    src = Some((name_start, v0, v1));
                }
            }
        }
        let tag_end = (j + 1).min(b.len());
        if let Some((a0, v0, v1)) = src {
            if let Some(replacement) = edit(&html[v0..v1]) {
                // Attribute end: past the closing quote when quoted.
                let a1 = if v1 < b.len() && (b[v1] == b'"' || b[v1] == b'\'') {
                    v1 + 1
                } else {
                    v1
                };
                out.push_str(&html[copied..a0]);
                out.push_str(replacement.trim_start());
                copied = a1;
            }
        }
        i = tag_end;
    }
    out.push_str(&html[copied..]);
    out
}

/// Swap `src="cid:…"` for data: URIs. `lookup` maps a Content-ID to (MIME type, bytes).
/// Images that cannot be resolved (or are not bitmaps) become `data-blocked-src`, like
/// blocked remote images; the second value is how many.
pub fn inline_cid_images(
    html: &str,
    lookup: impl Fn(&str) -> Option<(String, Vec<u8>)>,
) -> (String, usize) {
    use base64::Engine;
    let mut unresolved = 0;
    // One large image referenced many times must not multiply into gigabytes of data URIs.
    let mut budget = MAX_INLINE_TOTAL;
    let out = for_each_img_src(html, |value| {
        let id = cid_of(value)?;
        match lookup(&id).filter(|(mime, bytes)| {
            is_inline_image_type(mime) && bytes.len() <= MAX_INLINE_IMAGE && bytes.len() <= budget
        }) {
            Some((mime, bytes)) => {
                budget -= bytes.len();
                Some(format!(
                    " src=\"data:{};base64,{}\"",
                    mime.to_ascii_lowercase(),
                    base64::engine::general_purpose::STANDARD.encode(bytes)
                ))
            }
            None => {
                unresolved += 1;
                Some(format!(" data-blocked-src=\"{value}\""))
            }
        }
    });
    (out, unresolved)
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

    #[test]
    fn resolves_cid_images_and_blocks_the_rest() {
        let clean = sanitize(
            r#"<p>x</p><img src="cid:logo%40studio.dev" alt="l"><img src="cid:missing@x"><img src="cid:vec@x"><img src="https://t.example/p.gif">"#,
            SanitizeOptions::default(),
        );
        assert_eq!(
            cid_refs(&clean.html),
            vec!["logo@studio.dev", "missing@x", "vec@x"]
        );
        let (html, unresolved) = inline_cid_images(&clean.html, |cid| match cid {
            "logo@studio.dev" => Some(("image/PNG".into(), vec![1, 2, 3])),
            "vec@x" => Some(("image/svg+xml".into(), b"<svg/>".to_vec())),
            _ => None,
        });
        assert!(
            html.contains(r#"src="data:image/png;base64,AQID""#),
            "{html}"
        );
        assert!(html.contains(r#"data-blocked-src="cid:missing@x""#));
        assert!(html.contains(r#"data-blocked-src="cid:vec@x""#));
        assert!(html.contains(r#"data-blocked-src="https://t.example/p.gif""#));
        assert_eq!(unresolved, 2);
        assert!(cid_refs(&html).is_empty());
    }

    #[test]
    fn relative_and_protocol_relative_urls_never_load() {
        let clean = sanitize(
            r#"<img src="//tracker.example/p.gif"><img src="/pixel.gif"><a href="//evil.example/x">x</a><img src="https://cdn.example/a.png">"#,
            SanitizeOptions::default(),
        );
        assert!(!clean.html.contains("tracker.example"), "{}", clean.html);
        assert!(!clean.html.contains("pixel.gif"), "{}", clean.html);
        assert!(!clean.html.contains("evil.example"), "{}", clean.html);
        assert!(clean
            .html
            .contains(r#"data-blocked-src="https://cdn.example/a.png""#));
        assert_eq!(clean.blocked_images, 1);

        let loaded = sanitize(
            r#"<img src="//tracker.example/p.gif"><img src="https://cdn.example/a.png">"#,
            SanitizeOptions {
                load_remote_images: true,
            },
        );
        assert!(!loaded.html.contains("tracker.example"));
        assert!(loaded.html.contains(r#" src="https://cdn.example/a.png""#));
        assert_eq!(loaded.blocked_images, 0);
    }

    #[test]
    fn oversized_inline_images_stay_blocked() {
        let clean = sanitize(r#"<img src="cid:big@x">"#, SanitizeOptions::default());
        let (html, unresolved) = inline_cid_images(&clean.html, |_| {
            Some(("image/png".into(), vec![0; MAX_INLINE_IMAGE + 1]))
        });
        assert_eq!(unresolved, 1);
        assert!(!html.contains("base64"));
    }

    #[test]
    fn a_gt_inside_another_attribute_does_not_hide_src() {
        let clean = sanitize(
            r#"<img alt="x>" src="https://t.example/p.gif"><img title='a>b' src="https://t.example/q.gif">"#,
            SanitizeOptions::default(),
        );
        assert!(
            !clean.html.contains(r#" src="https://t.example"#),
            "{}",
            clean.html
        );
        assert_eq!(clean.blocked_images, 2, "{}", clean.html);
    }

    #[test]
    fn css_cannot_fetch_or_escape() {
        let styled = |css: &str| {
            sanitize(
                &format!(r#"<p style="{css}">x</p>"#),
                SanitizeOptions::default(),
            )
            .html
        };
        for bad in [
            "color: red} body {background: url (https://t.example/p.gif)",
            "background-color: u\\72l(https://t.example/p.gif)",
            "border: 1px solid; background-color: URL ( 'https://t.example' )",
            "color: expression(alert(1))",
            "font-family: x; color: red /* */",
            "color: var(--x)",
        ] {
            let html = styled(bad);
            assert!(!html.contains("t.example"), "{bad} -> {html}");
            assert!(!html.contains("expression"), "{bad} -> {html}");
        }
        let ok = styled(
            "color: rgb(1, 2, 3); font-family: 'IBM Plex Sans', sans-serif; padding: 4px 8%",
        );
        assert!(ok.contains("color: rgb(1, 2, 3)"), "{ok}");
        assert!(ok.contains("font-family"), "{ok}");
        assert!(ok.contains("padding: 4px 8%"), "{ok}");
    }

    #[test]
    fn inline_images_share_one_budget() {
        let html = sanitize(
            &r#"<img src="cid:logo@x">"#.repeat(10),
            SanitizeOptions::default(),
        )
        .html;
        let (out, unresolved) = inline_cid_images(&html, |_| {
            Some(("image/png".into(), vec![0; 4 * 1024 * 1024]))
        });
        assert_eq!(unresolved, 5);
        assert_eq!(out.matches("base64,").count(), 5);
    }
}
