# Flomsi

[![ci](https://github.com/zondaxxx/Flomsi/actions/workflows/ci.yml/badge.svg)](https://github.com/zondaxxx/Flomsi/actions/workflows/ci.yml)

Keyboard-first mail client for macOS, Windows, iOS and Android. Rust core, Flutter UI, an editor-style interface (Zed / Warp lineage, IBM Plex, One Dark).

```
core/      Rust workspace: mailcore (IMAP, SQLite, search, sync, sanitize, compose, SMTP) + mailctl CLI
app/       Flutter application; app/rust is the flutter_rust_bridge crate (native-assets backend)
keymaps/   keymap presets (vim, gmail)
design/    design tokens exported from the mockups
docs/      architecture and decisions
```

See `docs/ARCHITECTURE.md`.

## Quick start

```bash
make core-test            # Rust core unit tests
make cli                  # builds core/target/release/mailctl
core/target/release/mailctl add-imap --email you@gmail.com --host imap.gmail.com
core/target/release/mailctl sync
core/target/release/mailctl ls "is:unread"
make app-mac              # the app reads the same ~/.mail_ database
core/target/release/mailctl reply 12 --text "Works for me."   # SMTP send with the original quoted
make app-mac-mock         # UI only, sample data
```

Gmail with an app password: enable 2-step verification, create an app password, use it at the `add-imap` prompt.
OAuth for Gmail / Outlook lands in phase 1 (see docs/ARCHITECTURE.md).

Keyboard: `j`/`k` move, `↵` open, `e` archive, `#` delete, `*` star, `/` search, `⌘K` palette, `g i` inbox, `?` help.
Presets live in `keymaps/` (`vim` default, `gmail`).

## Builds

Every build runs in GitHub Actions (`.github/workflows/ci.yml`): Rust checks and tests, Flutter analyze and tests,
and a macOS release build uploaded as the `Flomsi-macOS` artifact. iOS, Android and Windows jobs are added as each
platform's Rust bridge packaging lands. Local builds are for screenshots only.
