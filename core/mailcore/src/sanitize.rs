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

/// Walk `<img … src="…">` in serializer output (lowercase attribute names, double quotes).
/// `edit` returns a replacement for the whole ` src="…"` attribute, or None to keep it.
fn for_each_img_src(html: &str, mut edit: impl FnMut(&str) -> Option<String>) -> String {
    let mut out = String::with_capacity(html.len());
    let mut rest = html;
    while let Some(i) = rest.find("<img") {
        out.push_str(&rest[..i]);
        let tag_end = rest[i..].find('>').map(|e| i + e + 1).unwrap_or(rest.len());
        let tag = &rest[i..tag_end];
        let replaced = tag.find(" src=\"").and_then(|s| {
            let v0 = s + " src=\"".len();
            let v1 = v0 + tag[v0..].find('"')?;
            edit(&tag[v0..v1]).map(|attr| format!("{}{}{}", &tag[..s], attr, &tag[v1 + 1..]))
        });
        out.push_str(replaced.as_deref().unwrap_or(tag));
        rest = &rest[tag_end..];
    }
    out.push_str(rest);
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
    let out = for_each_img_src(html, |value| {
        let id = cid_of(value)?;
        match lookup(&id).filter(|(mime, _)| is_inline_image_type(mime)) {
            Some((mime, bytes)) => Some(format!(
                " src=\"data:{};base64,{}\"",
                mime.to_ascii_lowercase(),
                base64::engine::general_purpose::STANDARD.encode(bytes)
            )),
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
}
