//! Secrets live in the OS credential store, never in SQLite.

use crate::error::{Error, Result};

const SERVICE: &str = "dev.zonda.mail";

fn entry(email: &str, kind: &str) -> Result<keyring::Entry> {
    keyring::Entry::new(SERVICE, &format!("{kind}:{email}"))
        .map_err(|e| Error::Secrets(e.to_string()))
}

pub fn set(email: &str, kind: &str, value: &str) -> Result<()> {
    entry(email, kind)?
        .set_password(value)
        .map_err(|e| Error::Secrets(e.to_string()))
}

pub fn get(email: &str, kind: &str) -> Result<Option<String>> {
    match entry(email, kind)?.get_password() {
        Ok(v) => Ok(Some(v)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(Error::Secrets(e.to_string())),
    }
}

pub fn delete(email: &str, kind: &str) -> Result<()> {
    match entry(email, kind)?.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(Error::Secrets(e.to_string())),
    }
}

#[cfg(test)]
mod tests {
    /// Touches the real OS keychain; run explicitly with `cargo test -- --ignored keychain`.
    #[test]
    #[ignore]
    fn keychain_roundtrip() {
        let email = "roundtrip@test.invalid";
        super::set(email, "password", "s3cret").unwrap();
        assert_eq!(
            super::get(email, "password").unwrap().as_deref(),
            Some("s3cret")
        );
        super::delete(email, "password").unwrap();
        assert_eq!(super::get(email, "password").unwrap(), None);
    }
}
