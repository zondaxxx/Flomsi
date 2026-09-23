//! File names for attachments written to disk.

use std::path::{Path, PathBuf};

/// A name that is safe as a single path component on macOS, Windows, iOS and Android:
/// no directories, no reserved characters, no leading dots, bounded length.
pub fn safe_file_name(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or(name);
    let cleaned: String = base
        .chars()
        // A direction override (U+202E) turns "invoice" + U+202E + "fdp.exe" into what reads as "invoiceexe.pdf";
        // zero-width and other invisible characters hide the real extension the same way.
        .filter(|c| !invisible(*c))
        .map(|c| match c {
            ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            // Line and paragraph separators break a one-line label and hide what follows.
            c if c.is_control() || matches!(c, '\u{2028}' | '\u{2029}' | '\u{0085}') => '_',
            c => c,
        })
        .collect();
    let trimmed = cleaned
        .trim()
        .trim_start_matches('.')
        .trim_end_matches(['.', ' ']);
    let name = if trimmed.is_empty() {
        "attachment"
    } else {
        trimmed
    };
    // CON, NUL, COM1, COM¹, CONOUT$… name devices on Windows, with any extension.
    let reserved = {
        let stem = name
            .split('.')
            .next()
            .unwrap_or("")
            .trim_end()
            .to_ascii_uppercase();
        let chars: Vec<char> = stem.chars().collect();
        matches!(
            stem.as_str(),
            "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
        ) || (chars.len() == 4
            && (stem.starts_with("COM") || stem.starts_with("LPT"))
            && matches!(chars[3], '1'..='9' | '¹' | '²' | '³'))
    };
    let name = if reserved {
        format!("_{name}")
    } else {
        name.to_string()
    };
    let name = name.as_str();
    if name.chars().count() <= 150 {
        return name.to_string();
    }
    // Keep the extension when shortening.
    let (stem, ext) = split_ext(name);
    let keep: String = stem
        .chars()
        .take(150 - ext.chars().count().min(20))
        .collect();
    format!("{keep}{ext}")
}

/// Characters that change how a name is shown without being seen: direction marks and
/// overrides, zero-width joiners and spaces, the byte-order mark, invisible operators.
pub(crate) fn invisible(c: char) -> bool {
    matches!(
        c,
        '\u{00AD}'
            | '\u{061C}'
            | '\u{180E}'
            | '\u{200B}'..='\u{200F}'
            | '\u{202A}'..='\u{202E}'
            | '\u{2060}'..='\u{2064}'
            | '\u{2066}'..='\u{206F}'
            | '\u{FEFF}'
            | '\u{FFF9}'..='\u{FFFB}'
    )
}

/// The extension of a file that can run code or open a browser on double-click, lower
/// case, or None. Decided by the name as it will be saved (after [safe_file_name]), never
/// by the MIME type the sender claimed.
pub fn risky_extension(name: &str) -> Option<String> {
    let safe = safe_file_name(name);
    let ext = safe.rsplit_once('.')?.1.trim().to_ascii_lowercase();
    const RISKY: &[&str] = &[
        // Windows programs, scripts and shortcuts
        "exe",
        "com",
        "bat",
        "cmd",
        "msi",
        "msp",
        "mst",
        "scr",
        "pif",
        "cpl",
        "js",
        "jse",
        "vbs",
        "vbe",
        "wsf",
        "wsh",
        "ws",
        "hta",
        "ps1",
        "psm1",
        "psd1",
        "lnk",
        "url",
        "reg",
        "inf",
        "scf",
        "chm",
        "appref-ms",
        "application",
        "gadget",
        "msc",
        "settingcontent-ms",
        "library-ms",
        "search-ms",
        "iso",
        "img",
        "vhd",
        "vhdx",
        "rdp",
        "msix",
        "msixbundle",
        "appx",
        "appxbundle",
        "appinstaller",
        "msu",
        "diagcab",
        "searchconnector-ms",
        "website",
        "vsto",
        "theme",
        "themepack",
        "deskthemepack",
        "wsc",
        "sct",
        "xll",
        "xla",
        "xlsb",
        "xlm",
        "iqy",
        "slk",
        "one",
        "onepkg",
        // macOS and Unix
        "app",
        "pkg",
        "mpkg",
        "dmg",
        "command",
        "terminal",
        "tool",
        "sh",
        "workflow",
        "scpt",
        "scptd",
        "applescript",
        "fileloc",
        "webloc",
        "inetloc",
        // Cross-platform
        "jar",
        "jnlp",
        "apk",
        "xpi",
        "py",
        "pyw",
        "pyz",
        "pyzw",
        // Documents that run macros, and pages that run scripts from disk
        "docm",
        "dotm",
        "xlsm",
        "xltm",
        "xlam",
        "pptm",
        "potm",
        "ppam",
        "ppsm",
        "sldm",
        "html",
        "htm",
        "xhtml",
        "xht",
        "svg",
        "shtml",
        "mht",
        "mhtml",
    ];
    RISKY.contains(&ext.as_str()).then_some(ext)
}

/// Mark a file written from a mail as coming from the internet, so the system checks it
/// before running it: the quarantine attribute on macOS (Gatekeeper asks before an app or
/// script opens), the Zone.Identifier stream on Windows (SmartScreen, Office Protected
/// View). Best effort: a file system without either keeps the file unmarked.
pub fn mark_from_internet(path: &Path) {
    #[cfg(target_os = "macos")]
    {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        let secs = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        // flags;time;agent;event — 0083 marks it downloaded and not yet approved.
        let value = format!("0083;{secs:x};Flomsi;");
        if let (Ok(p), Ok(name)) = (
            CString::new(path.as_os_str().as_bytes()),
            CString::new("com.apple.quarantine"),
        ) {
            // SAFETY: valid NUL-terminated strings and a buffer of the given length.
            unsafe {
                libc::setxattr(
                    p.as_ptr(),
                    name.as_ptr(),
                    value.as_ptr().cast(),
                    value.len(),
                    0,
                    0,
                );
            }
        }
    }
    #[cfg(windows)]
    {
        let mut stream = path.as_os_str().to_owned();
        stream.push(":Zone.Identifier");
        let _ = std::fs::write(stream, "[ZoneTransfer]\r\nZoneId=3\r\n");
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    let _ = path;
}

fn split_ext(name: &str) -> (&str, &str) {
    match name.rfind('.') {
        Some(i) if i > 0 && name.len() - i <= 12 => (&name[..i], &name[i..]),
        _ => (name, ""),
    }
}

/// `dir/name`, or `dir/stem (1).ext`, `dir/stem (2).ext`… when taken.
pub fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let first = dir.join(name);
    if !first.exists() {
        return first;
    }
    let (stem, ext) = split_ext(name);
    (1..)
        .map(|n| dir.join(format!("{stem} ({n}){ext}")))
        .find(|p| !p.exists())
        .expect("unbounded range")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_single_safe_components() {
        assert_eq!(safe_file_name("../../etc/passwd"), "passwd");
        assert_eq!(safe_file_name("C:\\Users\\x\\report.pdf"), "report.pdf");
        assert_eq!(safe_file_name("a:b?c.txt"), "a_b_c.txt");
        assert_eq!(safe_file_name("..."), "attachment");
        assert_eq!(safe_file_name(".hidden"), "hidden");
        assert_eq!(safe_file_name("Счёт №12.pdf"), "Счёт №12.pdf");
        let long = format!("{}.pdf", "x".repeat(400));
        let s = safe_file_name(&long);
        assert!(s.ends_with(".pdf") && s.chars().count() <= 150);
    }

    #[test]
    fn unique_paths_count_up() {
        let dir = std::env::temp_dir().join(format!("mailcore-files-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let a = unique_path(&dir, "report.pdf");
        std::fs::write(&a, b"1").unwrap();
        let b = unique_path(&dir, "report.pdf");
        assert_eq!(b.file_name().unwrap(), "report (1).pdf");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn hidden_characters_cannot_disguise_an_extension() {
        // "invoice" + RIGHT-TO-LEFT OVERRIDE + "fdp.exe" displays as "invoiceexe.pdf".
        assert_eq!(safe_file_name("invoice\u{202E}fdp.exe"), "invoicefdp.exe");
        assert_eq!(
            safe_file_name("report\u{200B}.pdf\u{2066}.js"),
            "report.pdf.js"
        );
        assert_eq!(
            risky_extension("invoice\u{202E}fdp.exe").as_deref(),
            Some("exe")
        );
        assert_eq!(risky_extension("scan.pdf.lnk").as_deref(), Some("lnk"));
        assert_eq!(risky_extension("Report.DOCM").as_deref(), Some("docm"));
        assert_eq!(risky_extension("page.html").as_deref(), Some("html"));
        assert_eq!(risky_extension("photo.jpg"), None);
        assert_eq!(risky_extension("Счёт.pdf"), None);
        assert_eq!(risky_extension("README"), None);
        // Windows types that run code or reach out on open.
        for name in [
            "Invoice.rdp",
            "update.msix",
            "report.xll",
            "notes.one",
            "docs.searchConnector-ms",
            "tool.pyw",
            "app.jnlp",
            "KB123.msu",
        ] {
            assert!(risky_extension(name).is_some(), "{name}");
        }
        // A line separator would cut the name in a one-line label before its extension.
        assert_eq!(
            safe_file_name("invoice.pdf\u{2028}.one"),
            "invoice.pdf_.one"
        );
        assert_eq!(safe_file_name("a\u{2029}b.txt"), "a_b.txt");
    }

    #[test]
    fn windows_device_names_are_renamed() {
        assert_eq!(safe_file_name("CON"), "_CON");
        assert_eq!(safe_file_name("nul.txt"), "_nul.txt");
        assert_eq!(safe_file_name("com1.log"), "_com1.log");
        assert_eq!(safe_file_name("LPT9"), "_LPT9");
        assert_eq!(safe_file_name("COM0.txt"), "COM0.txt");
        assert_eq!(safe_file_name("console.txt"), "console.txt");
        assert_eq!(safe_file_name("COM¹.txt"), "_COM¹.txt");
        assert_eq!(safe_file_name("lpt³"), "_lpt³");
        assert_eq!(safe_file_name("CONOUT$.log"), "_CONOUT$.log");
        assert_eq!(safe_file_name("conin$"), "_conin$");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn saved_files_carry_the_quarantine_mark() {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        let dir = std::env::temp_dir().join(format!("mailcore-qtn-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("tool.command");
        std::fs::write(&f, b"#!/bin/sh\n").unwrap();
        mark_from_internet(&f);
        let p = CString::new(f.as_os_str().as_bytes()).unwrap();
        let name = CString::new("com.apple.quarantine").unwrap();
        let mut buf = [0u8; 128];
        // SAFETY: valid strings and buffer.
        let n = unsafe {
            libc::getxattr(
                p.as_ptr(),
                name.as_ptr(),
                buf.as_mut_ptr().cast(),
                buf.len(),
                0,
                0,
            )
        };
        assert!(n > 0, "no quarantine attribute");
        assert!(String::from_utf8_lossy(&buf[..n as usize]).contains(";Flomsi;"));
        let _ = std::fs::remove_dir_all(dir);
    }
}
