#!/bin/sh
# Xcode run-script phase (Runner target, last phase): build the Rust bridge and drop it into the app bundle.
# Debug configs build cargo in debug for speed; everything else builds release.
set -eu
export PATH="$HOME/.cargo/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
CRATE_DIR="$SRCROOT/../rust"
if [ "${CONFIGURATION:-Debug}" = "Debug" ]; then
  PROFILE_DIR=debug; CARGO_FLAGS=""
else
  PROFILE_DIR=release; CARGO_FLAGS="--release"
fi
# Only the native arch of the build machine for now; universal builds come with the release pipeline.
cargo build --manifest-path "$CRATE_DIR/Cargo.toml" $CARGO_FLAGS
DYLIB="$CRATE_DIR/target/$PROFILE_DIR/libmail_bridge.dylib"
DEST="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$DEST"
cp -f "$DYLIB" "$DEST/libmail_bridge.dylib"
install_name_tool -id "@rpath/libmail_bridge.dylib" "$DEST/libmail_bridge.dylib"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$DEST/libmail_bridge.dylib"
echo "mail_bridge: bundled $PROFILE_DIR dylib into $DEST"
