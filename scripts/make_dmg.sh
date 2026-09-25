#!/bin/bash
# Packs Flomsi.app into a disk image to drag across: the app next to a link to
# Applications, with the app's own icon on the mounted disk. Only hdiutil and SetFile,
# which every Mac with Xcode has, so it runs the same on a CI runner.
#
#   scripts/make_dmg.sh path/to/Flomsi.app [Flomsi-macOS.dmg]
set -euo pipefail

APP="${1:?usage: make_dmg.sh path/to/Flomsi.app [out.dmg]}"
OUT="${2:-Flomsi-macOS.dmg}"
[[ -d "$APP/Contents/MacOS" ]] || { echo "$APP is not an app bundle" >&2; exit 1; }

work=$(mktemp -d)
cleanup() {
  hdiutil detach -quiet -force "$work/mnt" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

mkdir "$work/src" "$work/mnt"
ditto "$APP" "$work/src/Flomsi.app"
ln -s /Applications "$work/src/Applications"

# Writable first, so the disk can take its icon; room for the app plus the filesystem.
size=$(($(du -sm "$work/src" | cut -f1) + 20))
# hdiutil on a busy runner now and then fails with "Resource busy": try again.
for try in 1 2 3; do
  if hdiutil create -quiet -volname Flomsi -srcfolder "$work/src" -fs HFS+ \
    -format UDRW -size "${size}m" "$work/rw.dmg"; then
    break
  fi
  [[ $try == 3 ]] && exit 1
  sleep 5
done
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$work/mnt" "$work/rw.dmg"
icon="$APP/Contents/Resources/AppIcon.icns"
if [[ -f "$icon" ]]; then
  cp "$icon" "$work/mnt/.VolumeIcon.icns"
  # Without SetFile the disk only shows the generic icon: not worth failing for.
  SetFile -a C "$work/mnt" || echo "no custom disk icon (SetFile failed)" >&2
fi
hdiutil detach -quiet "$work/mnt"

rm -f "$OUT"
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT"
hdiutil verify -quiet "$OUT"
echo "$OUT: $(du -h "$OUT" | cut -f1)"
