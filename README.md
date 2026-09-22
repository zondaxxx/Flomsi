# mail_

Keyboard-first mail client for macOS, Windows, iOS and Android. Rust core, Flutter UI, dark glass.

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
make app-mac-mock         # UI only, sample data
```

Gmail with an app password: enable 2-step verification, create an app password, use it at the `add-imap` prompt.
OAuth for Gmail / Outlook lands in phase 1 (see docs/ARCHITECTURE.md).

Keyboard: `j`/`k` move, `↵` open, `e` archive, `#` delete, `*` star, `/` search, `⌘K` palette, `g i` inbox, `?` help.
Presets live in `keymaps/` (`vim` default, `gmail`).
