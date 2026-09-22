//! File names for attachments written to disk.

use std::path::{Path, PathBuf};

/// A name that is safe as a single path component on macOS, Windows, iOS and Android:
/// no directories, no reserved characters, no leading dots, bounded length.
pub fn safe_file_name(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or(name);
    let cleaned: String = base
        .chars()
        .map(|c| match c {
            ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            c if c.is_control() => '_',
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
}
