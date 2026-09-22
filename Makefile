# mail_ — common tasks. Requires: rustup (stable), flutter, Xcode (macOS/iOS).
CARGO := $(HOME)/.cargo/bin/cargo

.PHONY: core core-test cli app-mac app-mac-mock app-ios app-android bridge fmt check

core:            ## build the Rust core
	cd core && $(CARGO) build

core-test:       ## run core unit tests
	cd core && $(CARGO) test

cli:             ## build the mailctl CLI (release) → core/target/release/mailctl
	cd core && $(CARGO) build --release -p mailctl

bridge:          ## regenerate flutter_rust_bridge glue after editing app/rust/src/api
	cd app && flutter_rust_bridge_codegen generate

bridge-lib:      ## build the bridge dylib by hand (Xcode does this automatically on macOS builds)
	cd app/rust && $(CARGO) build --release

app-mac:         ## run the macOS app against the Rust core (~/.mail_)
	cd app && flutter run -d macos

app-mac-mock:    ## run the macOS app with in-memory mock data (design work)
	cd app && flutter run -d macos --dart-define=MAIL_MOCK=true

app-ios:         ## run on the booted iOS simulator
	cd app && flutter run -d ios

app-android:     ## run on a connected Android device / emulator
	cd app && flutter run -d android

fmt:             ## format everything
	cd core && $(CARGO) fmt
	cd app && dart format lib test

check:           ## lint + tests, both sides
	cd core && $(CARGO) clippy --all-targets -- -D warnings && $(CARGO) test
	cd app && flutter analyze && flutter test
