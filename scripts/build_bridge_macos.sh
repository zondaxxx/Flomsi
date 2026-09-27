#!/bin/sh
# Xcode run-script phase (Runner target, last phase): build the Rust bridge and drop it into the app bundle.
# Debug configs build cargo in debug for speed; everything else builds release.
# One cargo build per architecture Xcode builds the app for ($ARCHS: only the machine's own in
# Debug, arm64 and x86_64 in Release), joined with lipo, so a release app runs on Intel Macs too.
set -eu
export PATH="$HOME/.cargo/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
CRATE_DIR="$SRCROOT/../rust"
if [ "${CONFIGURATION:-Debug}" = "Debug" ]; then
  PROFILE_DIR=debug; CARGO_FLAGS=""
else
  PROFILE_DIR=release; CARGO_FLAGS="--release"
fi
SLICES=""
for ARCH in ${ARCHS:-$(uname -m)}; do
  case "$ARCH" in
    arm64) TARGET=aarch64-apple-darwin ;;
    x86_64) TARGET=x86_64-apple-darwin ;;
    *) echo "mail_bridge: no Rust target for $ARCH" >&2; exit 1 ;;
  esac
  if command -v rustup >/dev/null 2>&1 && ! rustup target list --installed | grep -qx "$TARGET"; then
    echo "mail_bridge: adding the Rust target $TARGET"
    rustup target add "$TARGET"
  fi
  cargo build --manifest-path "$CRATE_DIR/Cargo.toml" --target "$TARGET" $CARGO_FLAGS
  SLICES="$SLICES $CRATE_DIR/target/$TARGET/$PROFILE_DIR/libmail_bridge.dylib"
done
DEST="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$DEST"
# shellcheck disable=SC2086 # one path per slice
lipo -create $SLICES -output "$DEST/libmail_bridge.dylib"
install_name_tool -id "@rpath/libmail_bridge.dylib" "$DEST/libmail_bridge.dylib"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$DEST/libmail_bridge.dylib"
echo "mail_bridge: bundled $PROFILE_DIR dylib ($(lipo -archs "$DEST/libmail_bridge.dylib")) into $DEST"
