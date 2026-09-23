//! How verbose the app may be. async-imap logs every command it sends at `trace`, and LOGIN
//! and the XOAUTH2 response carry the password or token, so `trace` is never allowed.
//! Release builds keep to warnings.

use log::LevelFilter;

pub fn max_level() -> LevelFilter {
    if cfg!(debug_assertions) {
        LevelFilter::Info
    } else {
        LevelFilter::Warn
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::imap::{Credential, ImapProvider};
    use crate::provider::Provider;
    use std::sync::Mutex;

    struct Capture(Mutex<Vec<String>>);

    impl log::Log for Capture {
        fn enabled(&self, _: &log::Metadata) -> bool {
            true
        }
        fn log(&self, record: &log::Record) {
            self.0.lock().unwrap().push(format!("{}", record.args()));
        }
        fn flush(&self) {}
    }

    static CAPTURE: Capture = Capture(Mutex::new(Vec::new()));

    #[tokio::test]
    async fn the_password_never_reaches_the_log() {
        let _ = log::set_logger(&CAPTURE);
        let fake = crate::provider::fake_imap::FakeImap::start("z@x.dev", "hunter2-7f3a").await;
        fake.with(|s| s.add_box("INBOX", None));
        let login = || async {
            let mut p = ImapProvider::connect_trusting(
                "localhost",
                fake.port,
                "z@x.dev",
                Credential::Password("hunter2-7f3a".into()),
                std::slice::from_ref(&fake.cert),
            )
            .await
            .unwrap();
            p.logout().await.unwrap();
        };
        let leaked = || {
            CAPTURE
                .0
                .lock()
                .unwrap()
                .iter()
                .any(|l| l.contains("hunter2-7f3a"))
        };

        // What the default FRB setup did: trace shows the LOGIN line, password included.
        log::set_max_level(LevelFilter::Trace);
        login().await;
        assert!(leaked(), "trace is expected to expose the LOGIN command");

        CAPTURE.0.lock().unwrap().clear();
        log::set_max_level(max_level());
        login().await;
        assert!(!leaked(), "the app's level must not expose credentials");
    }
}
