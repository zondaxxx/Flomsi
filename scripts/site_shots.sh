#!/bin/bash
# Renders the phone screens the website shows (app/test/site_shots_test.dart: the app's
# own fonts, iOS icons, 390 x 844 at 2x, light and dark) and writes them to site/img as
# WebP. Needs Flutter and cwebp.
#
#   scripts/site_shots.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

(cd "$ROOT/app" && SITE_SHOTS="$work" flutter test test/site_shots_test.dart >/dev/null)
for png in "$work"/*.png; do
  name=$(basename "$png" .png)
  # Flat UI pictures: lossless is smaller than lossy here, and has no ringing around text.
  cwebp -quiet -lossless -z 9 "$png" -o "$ROOT/site/img/$name.webp"
  echo "site/img/$name.webp $(($(wc -c <"$ROOT/site/img/$name.webp") / 1024)) KB"
done
