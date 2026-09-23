//! Secrets live in the OS credential store, never in SQLite.

use crate::error::Result;
use std::path::Path;
use std::sync::RwLock;

/// The service every install used before profiles, and still the one of a data directory
/// that already held mail then.
const LEGACY_SERVICE: &str = "dev.zonda.mail";

/// Names a data directory's profile; kept inside the directory, so it moves with it (an
/// iOS update moves the app's container to a new path).
const PROFILE_FILE: &str = "secrets-profile";

/// The profile secrets belong to: one per data directory, so a `mailctl --data-dir` test
/// profile never reads or replaces the app's password for the same address.
static PROFILE: RwLock<Option<String>> = RwLock::new(None);

/// The profile of [data_dir], chosen once and written there: a directory that already has
/// a database keeps the shared service it has been using (None); a new one gets its own
/// random id.
fn profile_id(data_dir: &Path) -> Option<String> {
    let file = data_dir.join(PROFILE_FILE);
    if let Ok(text) = std::fs::read_to_string(&file) {
        let id = text.trim();
        return (!id.is_empty() && id != "shared").then(|| id.to_string());
    }
    let id = if data_dir.join("mail.sqlite").exists() {
        None
    } else {
        Some(format!("{:012x}", rand::random::<u64>() & 0xffff_ffff_ffff))
    };
    let _ = std::fs::create_dir_all(data_dir);
    let _ = std::fs::write(&file, id.as_deref().unwrap_or("shared"));
    id
}

/// Tie secrets to the profile of [data_dir]. Call before the database is created there.
pub fn use_profile(data_dir: &Path) {
    let id = profile_id(data_dir);
    if let Ok(mut p) = PROFILE.write() {
        *p = id;
    }
}

fn service_for(profile: Option<&str>) -> String {
    match profile {
        Some(id) => format!("{LEGACY_SERVICE}.{id}"),
        None => LEGACY_SERVICE.to_string(),
    }
}

fn service() -> String {
    service_for(PROFILE.read().ok().and_then(|p| p.clone()).as_deref())
}

/// Secrets kept in memory instead of the OS store: in unit tests always, elsewhere after
/// [keep_in_memory]. Nothing outlives the process.
static IN_MEMORY: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(cfg!(test));

/// Keep this process's secrets in memory only: for integration tests and CI machines, which
/// have no keychain and must never touch a developer's.
pub fn keep_in_memory() {
    IN_MEMORY.store(true, std::sync::atomic::Ordering::SeqCst);
}

fn in_memory() -> bool {
    IN_MEMORY.load(std::sync::atomic::Ordering::SeqCst)
}

mod keychain {
    use crate::error::{Error, Result};

    fn entry(service: &str, user: &str) -> Result<keyring::Entry> {
        keyring::Entry::new(service, user).map_err(|e| Error::Secrets(e.to_string()))
    }

    pub fn read(service: &str, user: &str) -> Result<Option<String>> {
        match entry(service, user)?.get_password() {
            Ok(v) => Ok(Some(v)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(Error::Secrets(e.to_string())),
        }
    }

    pub fn write(service: &str, user: &str, value: &str) -> Result<()> {
        entry(service, user)?
            .set_password(value)
            .map_err(|e| Error::Secrets(e.to_string()))
    }

    pub fn remove(service: &str, user: &str) -> Result<()> {
        match entry(service, user)?.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(Error::Secrets(e.to_string())),
        }
    }
}

/// The in-memory store. The service is left out of the key: tests run side by side in one
/// process and each `Core::open` switches the profile under the others.
mod memory {
    use std::collections::HashMap;
    use std::sync::Mutex;

    static MEMORY: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);

    fn with<T>(f: impl FnOnce(&mut HashMap<String, String>) -> T) -> T {
        let mut m = MEMORY.lock().unwrap_or_else(|p| p.into_inner());
        f(m.get_or_insert_with(HashMap::new))
    }

    pub fn read(user: &str) -> Option<String> {
        with(|m| m.get(user).cloned())
    }

    pub fn write(user: &str, value: &str) {
        with(|m| m.insert(user.to_string(), value.to_string()));
    }

    pub fn remove(user: &str) {
        with(|m| m.remove(user));
    }
}

mod store {
    use super::{in_memory, keychain, memory};
    use crate::error::Result;

    pub fn read(service: &str, user: &str) -> Result<Option<String>> {
        if in_memory() {
            return Ok(memory::read(user));
        }
        keychain::read(service, user)
    }

    pub fn write(service: &str, user: &str, value: &str) -> Result<()> {
        if in_memory() {
            memory::write(user, value);
            return Ok(());
        }
        keychain::write(service, user, value)
    }

    pub fn remove(service: &str, user: &str) -> Result<()> {
        if in_memory() {
            memory::remove(user);
            return Ok(());
        }
        keychain::remove(service, user)
    }
}

fn user(email: &str, kind: &str) -> String {
    format!("{kind}:{email}")
}

fn read(service: &str, email: &str, kind: &str) -> Result<Option<String>> {
    store::read(service, &user(email, kind))
}

fn remove(service: &str, email: &str, kind: &str) -> Result<()> {
    store::remove(service, &user(email, kind))
}

pub fn set(email: &str, kind: &str, value: &str) -> Result<()> {
    store::write(&service(), &user(email, kind), value)
}

pub fn get(email: &str, kind: &str) -> Result<Option<String>> {
    read(&service(), email, kind)
}

/// Removes the profile's secret, and only this profile's.
pub fn delete(email: &str, kind: &str) -> Result<()> {
    remove(&service(), email, kind)
}

#[cfg(test)]
mod tests {
    use super::{profile_id, service_for};

    #[test]
    fn each_data_directory_has_its_own_secrets() {
        let root = std::env::temp_dir().join(format!("flomsi-profiles-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let (a, b) = (root.join("a"), root.join("b"));
        let first = service_for(profile_id(&a).as_deref());
        let second = service_for(profile_id(&b).as_deref());
        assert_ne!(first, second);
        assert!(first.starts_with("dev.zonda.mail."), "{first}");
        // Kept in the directory: the same after a move (an iOS update moves the container).
        let moved = root.join("a-moved");
        std::fs::rename(&a, &moved).unwrap();
        assert_eq!(service_for(profile_id(&moved).as_deref()), first);
        // A directory that held mail before profiles keeps the shared service.
        let old = root.join("old");
        std::fs::create_dir_all(&old).unwrap();
        std::fs::write(old.join("mail.sqlite"), b"").unwrap();
        assert_eq!(service_for(profile_id(&old).as_deref()), "dev.zonda.mail");
        assert_eq!(service_for(profile_id(&old).as_deref()), "dev.zonda.mail");
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// Touches the real OS keychain; run explicitly with `cargo test -- --ignored keychain`.
    #[test]
    #[ignore]
    fn keychain_roundtrip() {
        let service = "dev.zonda.mail.roundtrip";
        let user = "password:roundtrip@test.invalid";
        let entry = keyring::Entry::new(service, user).unwrap();
        entry.set_password("s3cret").unwrap();
        assert_eq!(entry.get_password().unwrap(), "s3cret");
        entry.delete_credential().unwrap();
        assert!(matches!(entry.get_password(), Err(keyring::Error::NoEntry)));
    }
}
