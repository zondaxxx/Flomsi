#!/bin/sh
# Xcode run-script phase (iOS Runner target, FIRST phase): build the Rust bridge as a static library
# for the current platform/arch and leave it where OTHER_LDFLAGS expects it.
set -eu
export PATH="$HOME/.cargo/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
XCODE_PLATFORM="${PLATFORM_NAME:-iphoneos}"
XCODE_ARCHS="${ARCHS:-arm64}"
# Xcode exports SDK/deployment variables that break rustc for host tools (build scripts, proc-macros).
unset SDKROOT PLATFORM_NAME IPHONEOS_DEPLOYMENT_TARGET MACOSX_DEPLOYMENT_TARGET TVOS_DEPLOYMENT_TARGET \
      WATCHOS_DEPLOYMENT_TARGET XROS_DEPLOYMENT_TARGET DRIVERKIT_DEPLOYMENT_TARGET CC CXX LD CPATH LIBRARY_PATH CFLAGS CXXFLAGS LDFLAGS 2>/dev/null || true
env > "${TMPDIR:-/tmp}/flomsi-ios-bridge-env.txt"
CRATE_DIR="$SRCROOT/../rust"
if [ "${CONFIGURATION:-Debug}" = "Debug" ]; then
  PROFILE_DIR=debug; CARGO_FLAGS=""
else
  PROFILE_DIR=release; CARGO_FLAGS="--release"
fi
OUT="$BUILT_PRODUCTS_DIR/libmail_bridge.a"
LIBS=""
for ARCH in $XCODE_ARCHS; do
  case "$XCODE_PLATFORM:$ARCH" in
    iphonesimulator:arm64)  TRIPLE=aarch64-apple-ios-sim ;;
    iphonesimulator:x86_64) TRIPLE=x86_64-apple-ios ;;
    iphoneos:arm64)         TRIPLE=aarch64-apple-ios ;;
    *) echo "unsupported $PLATFORM_NAME:$ARCH" >&2; exit 1 ;;
  esac
  cargo build --manifest-path "$CRATE_DIR/Cargo.toml" --target "$TRIPLE" $CARGO_FLAGS
  LIBS="$LIBS $CRATE_DIR/target/$TRIPLE/$PROFILE_DIR/libmail_bridge.a"
done
mkdir -p "$BUILT_PRODUCTS_DIR"
# shellcheck disable=SC2086
lipo -create $LIBS -output "$OUT"
echo "mail_bridge: $OUT ($XCODE_ARCHS, $PROFILE_DIR)"
