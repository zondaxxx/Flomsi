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
            // `background: #fff url(bg.png) no-repeat` is how most newsletters set a
            // background; keep only its colour (the image and the rest never load).
            if k == "background" {
                let colour = css_colour(v).filter(|c| safe_css_value(c))?;
                return Some(format!("background-color: {colour}"));
            }
            if v.is_empty() || !safe_css_value(v) {
                return None;
            }
            if !ALLOWED.contains(&k.as_str()) {
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

/// The colour in a `background` shorthand: a `#hex`, `rgb()`/`rgba()`/`hsl()`/`hsla()` or a
/// colour keyword; None when there is none.
fn css_colour(v: &str) -> Option<String> {
    let lower = v.trim().to_ascii_lowercase();
    for f in ["rgba(", "rgb(", "hsla(", "hsl("] {
        if let Some(i) = lower.find(f) {
            let end = lower[i..].find(')')? + i + 1;
            return Some(lower[i..end].to_string());
        }
    }
    lower
        .split_whitespace()
        .find(|t| {
            (t.starts_with('#') && matches!(t.len(), 4 | 5 | 7 | 9))
                || (t.chars().all(|c| c.is_ascii_alphabetic())
                    && !matches!(
                        *t,
                        "none"
                            | "repeat"
                            | "no"
                            | "center"
                            | "top"
                            | "bottom"
                            | "left"
                            | "right"
                            | "fixed"
                            | "scroll"
                            | "cover"
                            | "contain"
                            | "auto"
                            | "inherit"
                            | "initial"
                            | "unset"
                            | "transparent"
                    )
                    && !t.starts_with("repeat")
                    && !t.contains("repeat"))
        })
        .map(str::to_string)
}

/// True when the (sanitized) message sets its own text or background colours: such mail is
/// designed for a light page and is shown on one, whatever the app's theme.
pub fn has_own_colours(html: &str) -> bool {
    let mut found = false;
    for_each_tag_attr(html, |name, value| {
        let name = name.to_ascii_lowercase();
        let value = value.to_ascii_lowercase();
        if matches!(name.as_str(), "bgcolor" | "color")
            || (name == "style" && (value.contains("color:") || value.contains("color :")))
        {
            found = true;
        }
    });
    found
}

/// Every attribute of every tag in serializer output (double-quoted values, which may hold
/// `>`), as (name, raw value).
fn for_each_tag_attr(html: &str, mut visit: impl FnMut(&str, &str)) {
    for_each_tag_attr_named(html, |_, name, value| visit(name, value));
}

/// Like [for_each_tag_attr], with the tag's name first.
fn for_each_tag_attr_named(html: &str, mut visit: impl FnMut(&str, &str, &str)) {
    let b = html.as_bytes();
    let mut i = 0;
    while let Some(off) = html[i..].find('<') {
        let mut j = i + off + 1;
        // Tag name
        let tag_start = j;
        while j < b.len() && !b[j].is_ascii_whitespace() && b[j] != b'>' {
            j += 1;
        }
        let tag = &html[tag_start..j];
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
                visit(tag, name, &html[v0..v1]);
            }
        }
        i = (j + 1).min(b.len());
        if i >= b.len() {
            break;
        }
    }
}

/// Width and height from the header of a PNG, GIF, JPEG, WebP or BMP, without decoding it.
pub fn image_dimensions(b: &[u8]) -> Option<(u32, u32)> {
    let be32 =
        |i: usize| -> Option<u32> { Some(u32::from_be_bytes(b.get(i..i + 4)?.try_into().ok()?)) };
    let le16 = |i: usize| -> Option<u32> {
        Some(u16::from_le_bytes(b.get(i..i + 2)?.try_into().ok()?) as u32)
    };
    let be16 = |i: usize| -> Option<u32> {
        Some(u16::from_be_bytes(b.get(i..i + 2)?.try_into().ok()?) as u32)
    };
    let le24 = |i: usize| -> Option<u32> {
        let p = b.get(i..i + 3)?;
        Some(p[0] as u32 | (p[1] as u32) << 8 | (p[2] as u32) << 16)
    };
    if b.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Some((be32(16)?, be32(20)?));
    }
    if b.starts_with(b"GIF87a") || b.starts_with(b"GIF89a") {
        return gif_dimensions(b);
    }
    if b.starts_with(b"BM") {
        let w = i32::from_le_bytes(b.get(18..22)?.try_into().ok()?);
        let h = i32::from_le_bytes(b.get(22..26)?.try_into().ok()?);
        return Some((w.unsigned_abs(), h.unsigned_abs()));
    }
    if b.len() > 30 && &b[0..4] == b"RIFF" && &b[8..12] == b"WEBP" {
        return match &b[12..16] {
            b"VP8 " => Some((le16(26)? & 0x3fff, le16(28)? & 0x3fff)),
            b"VP8L" => {
                let v = u32::from_le_bytes(b.get(21..25)?.try_into().ok()?);
                Some(((v & 0x3fff) + 1, ((v >> 14) & 0x3fff) + 1))
            }
            b"VP8X" => Some((le24(24)? + 1, le24(27)? + 1)),
            _ => None,
        };
    }
    if b.starts_with(&[0xFF, 0xD8]) {
        // Walk the markers to the first frame header (SOF0..SOF15 except DHT/JPG/DAC).
        let mut i = 2;
        while i + 9 < b.len() {
            if b[i] != 0xFF {
                return None;
            }
            let marker = b[i + 1];
            if marker == 0xFF {
                i += 1;
                continue;
            }
            // Markers without a length (stuffing, TEM, RSTn, SOI, EOI) never come before the
            // frame header in a real file; reading one as a length lets a crafted file jump
            // past its real size to a fake one.
            if matches!(marker, 0x00 | 0x01 | 0xD0..=0xD9) {
                return None;
            }
            let len = be16(i + 2)? as usize;
            if matches!(marker, 0xC0..=0xCF) && !matches!(marker, 0xC4 | 0xC8 | 0xCC) {
                return Some((be16(i + 7)?, be16(i + 5)?));
            }
            i += 2 + len;
        }
        return None;
    }
    None
}

/// A GIF's canvas as decoders draw it: the logical screen grown to hold every frame (a 1x1
/// screen may carry a 20000x20000 frame, and the decoder then allocates for the frame).
/// None when the file has no frame or ends inside the header.
fn gif_dimensions(b: &[u8]) -> Option<(u32, u32)> {
    let le16 = |i: usize| -> Option<u32> {
        Some(u16::from_le_bytes(b.get(i..i + 2)?.try_into().ok()?) as u32)
    };
    // Skip data sub-blocks: length bytes until a zero one. None when the file ends first.
    let skip_blocks = |mut i: usize| -> Option<usize> {
        loop {
            let n = *b.get(i)? as usize;
            i += 1;
            if n == 0 {
                return Some(i);
            }
            i += n;
        }
    };
    let (mut w, mut h) = (le16(6)?, le16(8)?);
    let flags = *b.get(10)?;
    let mut i = 13;
    if flags & 0x80 != 0 {
        i += 3 * (1usize << ((flags & 7) + 1));
    }
    let mut frames = 0;
    loop {
        match b.get(i) {
            Some(0x2C) => {
                let (left, top) = (le16(i + 1)?, le16(i + 3)?);
                let (fw, fh) = (le16(i + 5)?, le16(i + 7)?);
                w = w.max(left + fw);
                h = h.max(top + fh);
                frames += 1;
                let local = *b.get(i + 9)?;
                i += 10;
                if local & 0x80 != 0 {
                    i += 3 * (1usize << ((local & 7) + 1));
                }
                // LZW minimum code size, then the image data.
                match skip_blocks(i + 1) {
                    Some(next) => i = next,
                    None => break,
                }
            }
            Some(0x21) => match skip_blocks(i + 2) {
                Some(next) => i = next,
                None => break,
            },
            // The trailer, the end of a cut file, or bytes that are not GIF blocks.
            _ => break,
        }
    }
    (frames > 0).then_some((w, h))
}

/// Inline images larger than this in pixels stay blocked: a small file can declare a huge
/// canvas and take gigabytes to decode.
pub const MAX_INLINE_PIXELS: u64 = 25_000_000;
pub const MAX_INLINE_SIDE: u32 = 8192;

fn decodable(bytes: &[u8]) -> bool {
    match image_dimensions(bytes) {
        Some((w, h)) => {
            w <= MAX_INLINE_SIDE
                && h <= MAX_INLINE_SIDE
                && (w as u64) * (h as u64) <= MAX_INLINE_PIXELS
        }
        // Unknown header: SVG is not an inline type anyway; an unreadable bitmap is refused.
        None => false,
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
    let cleaned = match body_colours(html) {
        Some(style) => format!("<div style=\"{style}\">{cleaned}</div>"),
        None => cleaned,
    };
    gate_images(&cleaned, opts.load_remote_images)
}

/// A colour that can be written into an attribute as is: `#` and hex digits, a keyword, or
/// `rgb()`/`hsl()` of numbers. No quotes, angle brackets or ampersands can get through.
fn plain_colour(c: String) -> Option<String> {
    let ok = match c.strip_prefix('#') {
        Some(hex) => {
            matches!(hex.len(), 3 | 4 | 6 | 8) && hex.chars().all(|c| c.is_ascii_hexdigit())
        }
        None => c.chars().all(|ch| {
            ch.is_ascii_alphanumeric()
                || matches!(ch, ' ' | '%' | '.' | ',' | '(' | ')' | '-' | '/')
        }),
    };
    (ok && safe_css_value(&c)).then_some(c)
}

/// A colour from an HTML attribute (`bgcolor`, `text`): `#hex`, a keyword, `rgb()`, or the
/// bare hex digits old mail uses.
fn attr_colour(v: &str) -> Option<String> {
    let v = v.trim();
    if matches!(v.len(), 3 | 6) && v.chars().all(|c| c.is_ascii_hexdigit()) {
        return Some(format!("#{}", v.to_ascii_lowercase()));
    }
    css_colour(v).and_then(plain_colour)
}

/// The page and text colours a message sets on `<body>` (bgcolor, text, style), which go
/// with the body tag when it is cleaned: kept as a wrapper's style, so light text keeps
/// its dark page.
fn body_colours(html: &str) -> Option<String> {
    let (mut bg, mut fg) = (None, None);
    for_each_tag_attr_named(html, |tag, name, value| {
        if !tag.eq_ignore_ascii_case("body") {
            return;
        }
        match name.to_ascii_lowercase().as_str() {
            "bgcolor" if bg.is_none() => bg = attr_colour(value),
            "text" if fg.is_none() => fg = attr_colour(value),
            "style" => {
                for decl in value.split(';') {
                    let Some((k, v)) = decl.split_once(':') else {
                        continue;
                    };
                    match k.trim().to_ascii_lowercase().as_str() {
                        "background" | "background-color" if bg.is_none() => {
                            bg = css_colour(v).and_then(plain_colour)
                        }
                        "color" if fg.is_none() => fg = css_colour(v).and_then(plain_colour),
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    });
    let decls: Vec<String> = [("background-color", bg), ("color", fg)]
        .into_iter()
        .filter_map(|(k, v)| Some(format!("{k}: {}", v?)))
        .collect();
    (!decls.is_empty()).then(|| decls.join("; "))
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
            is_inline_image_type(mime)
                && bytes.len() <= MAX_INLINE_IMAGE
                && bytes.len() <= budget
                && decodable(bytes)
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

    /// A PNG header declaring `w`×`h`, padded to `len` bytes (enough for the checks here).
    fn png(w: u32, h: u32, len: usize) -> Vec<u8> {
        let mut v = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        v.extend_from_slice(&w.to_be_bytes());
        v.extend_from_slice(&h.to_be_bytes());
        v.resize(len.max(v.len()), 0);
        v
    }

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
            "logo@studio.dev" => Some(("image/PNG".into(), png(1, 1, 24))),
            "vec@x" => Some(("image/svg+xml".into(), b"<svg/>".to_vec())),
            _ => None,
        });
        assert!(
            html.contains(r#"src="data:image/png;base64,iVBORw0KGgo"#),
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
            Some(("image/png".into(), png(10, 10, MAX_INLINE_IMAGE + 1)))
        });
        assert_eq!(unresolved, 1);
        assert!(!html.contains("base64"));
    }

    #[test]
    fn a_small_file_with_a_huge_canvas_stays_blocked() {
        let clean = sanitize(
            r#"<img src="cid:bomb@x"><img src="cid:wide@x"><img src="cid:ok@x">"#,
            SanitizeOptions::default(),
        );
        let (html, unresolved) = inline_cid_images(&clean.html, |cid| match cid {
            // 20 000 × 20 000 in a few hundred bytes: 1.6 GB once decoded.
            "bomb@x" => Some(("image/png".into(), png(20_000, 20_000, 300))),
            "wide@x" => Some(("image/png".into(), png(9_000, 10, 300))),
            _ => Some(("image/png".into(), png(1200, 800, 300))),
        });
        assert_eq!(unresolved, 2);
        assert_eq!(html.matches("base64,").count(), 1);
    }

    /// A one-frame GIF: logical screen, then an image descriptor (left, top, width, height)
    /// with a minimal LZW block, then the trailer.
    fn gif(screen: (u16, u16), frame: (u16, u16, u16, u16)) -> Vec<u8> {
        let mut b = b"GIF89a".to_vec();
        b.extend_from_slice(&screen.0.to_le_bytes());
        b.extend_from_slice(&screen.1.to_le_bytes());
        b.extend_from_slice(&[0, 0, 0]);
        // A graphic control extension first, as animated GIFs have.
        b.extend_from_slice(&[0x21, 0xF9, 0x04, 0, 0, 0, 0, 0]);
        b.push(0x2C);
        for v in [frame.0, frame.1, frame.2, frame.3] {
            b.extend_from_slice(&v.to_le_bytes());
        }
        b.extend_from_slice(&[0, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B]);
        b
    }

    #[test]
    fn image_headers_give_their_size() {
        assert_eq!(image_dimensions(&png(640, 480, 40)), Some((640, 480)));
        assert_eq!(
            image_dimensions(&gif((320, 240), (0, 0, 320, 240))),
            Some((320, 240))
        );
        // A tiny screen with a huge frame: the decoder draws the frame, so that counts.
        let bomb = gif((1, 1), (0, 0, 20000, 20000));
        assert_eq!(image_dimensions(&bomb), Some((20000, 20000)));
        assert!(!decodable(&bomb));
        // A header with no frame is not an image to show.
        assert_eq!(
            image_dimensions(b"GIF89a\x40\x01\xf0\x00\x00\x00\x00"),
            None
        );
        // JPEG: SOI, an APP0 segment, then SOF0 with height 100 and width 200.
        let mut jpeg = vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00];
        jpeg.extend_from_slice(&[
            0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x64, 0x00, 0xC8, 0x03, 0, 0,
        ]);
        assert_eq!(image_dimensions(&jpeg), Some((200, 100)));
        // A marker without a length before the frame: never in a real file, refused.
        let mut odd = vec![0xFF, 0xD8, 0xFF, 0xD0];
        odd.extend_from_slice(&jpeg[2..]);
        assert_eq!(image_dimensions(&odd), None);
        let mut bmp = b"BM".to_vec();
        bmp.resize(18, 0);
        bmp.extend_from_slice(&50i32.to_le_bytes());
        bmp.extend_from_slice(&(-70i32).to_le_bytes());
        assert_eq!(image_dimensions(&bmp), Some((50, 70)));
        assert_eq!(image_dimensions(b"not an image"), None);
    }

    #[test]
    fn a_dark_page_set_on_body_stays_with_its_light_text() {
        let s = sanitize(
            r##"<html><body bgcolor="#111111" text="#eeeeee"><p>Night mode</p></body></html>"##,
            SanitizeOptions::default(),
        );
        assert!(
            s.html
                .starts_with(r#"<div style="background-color: #111111; color: #eeeeee">"#),
            "{}",
            s.html
        );
        assert!(has_own_colours(&s.html));
        let s = sanitize(
            r#"<body style="background: #000 url(x.png); color: white"><p>x</p></body>"#,
            SanitizeOptions::default(),
        );
        assert!(
            s.html
                .starts_with(r#"<div style="background-color: #000; color: white">"#),
            "{}",
            s.html
        );
        // Nothing on body, nothing added; nothing that could escape the attribute.
        let s = sanitize("<p>plain</p>", SanitizeOptions::default());
        assert_eq!(s.html, "<p>plain</p>");
        for body in [
            r#"<body bgcolor='red" onload="x'><p>x</p></body>"#,
            r#"<body bgcolor='#"onload='><p>x</p></body>"#,
            r#"<body style='color: #a"b'><p>x</p></body>"#,
            r#"<body bgcolor='#a"b'><p>x</p></body>"#,
            r#"<body text='rgb(1,2,3)"><script>'><p>x</p></body>"#,
        ] {
            let s = sanitize(body, SanitizeOptions::default());
            assert!(
                !s.html.contains("onload")
                    && !s.html.contains("<script")
                    && !s.html.contains("#a\""),
                "{body} -> {}",
                s.html
            );
            assert!(
                s.html.ends_with("<p>x</p>") || s.html.ends_with("</div>"),
                "{}",
                s.html
            );
        }
    }

    #[test]
    fn newsletters_keep_their_backgrounds_and_are_told_apart() {
        let s = sanitize(
            r##"<table bgcolor="#f4f4f4"><tr><td style="background: #ffffff url(x.png) no-repeat; color: #333">Hi</td></tr></table>"##,
            SanitizeOptions::default(),
        );
        assert!(s.html.contains("background-color: #ffffff"), "{}", s.html);
        assert!(!s.html.contains("url"), "{}", s.html);
        assert!(has_own_colours(&s.html));
        let plain = sanitize("<p>Just text, colour: none</p>", SanitizeOptions::default());
        assert!(!has_own_colours(&plain.html));
        let font = sanitize(r#"<font color="red">x</font>"#, SanitizeOptions::default());
        assert!(has_own_colours(&font.html));
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
            Some(("image/png".into(), png(800, 600, 4 * 1024 * 1024)))
        });
        assert_eq!(unresolved, 5);
        assert_eq!(out.matches("base64,").count(), 5);
    }
}
