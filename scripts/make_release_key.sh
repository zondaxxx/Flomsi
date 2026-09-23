#!/bin/bash
# Makes the Android release key once, keeps its password in the macOS Keychain, and gives
# both to GitHub Actions as repository secrets. Prints the key's SHA-1 for the Google
# Android client. The password is never shown.
#
#   scripts/make_release_key.sh            make the key (refuses if it exists)
#   scripts/make_release_key.sh --secrets  send an existing key to GitHub again
set -euo pipefail

KEY="$HOME/flomsi-release.jks"
SERVICE="Flomsi Android release key"
REPO="zondaxxx/Flomsi"

if [[ "${1:-}" != "--secrets" ]]; then
  if [[ -e "$KEY" ]]; then
    echo "$KEY already exists. Run with --secrets to send it to GitHub again." >&2
    exit 1
  fi
  export FLOMSI_KEY_PASSWORD="$(openssl rand -base64 30 | tr -d '/+=\n' | cut -c1-32)"
  # The Keychain holds the password: losing it means no more updates over this version.
  security add-generic-password -U -a "$USER" -s "$SERVICE" -w "$FLOMSI_KEY_PASSWORD"
  keytool -genkeypair -keystore "$KEY" -storetype PKCS12 -alias flomsi \
    -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=Flomsi" \
    -storepass:env FLOMSI_KEY_PASSWORD -keypass:env FLOMSI_KEY_PASSWORD >/dev/null
  chmod 600 "$KEY"
else
  export FLOMSI_KEY_PASSWORD="$(security find-generic-password -a "$USER" -s "$SERVICE" -w)"
fi

base64 -i "$KEY" | gh secret set FLOMSI_ANDROID_KEYSTORE_B64 --repo "$REPO"
printf '%s' "$FLOMSI_KEY_PASSWORD" | gh secret set FLOMSI_KEYSTORE_PASSWORD --repo "$REPO"

echo
echo "Key: $KEY (password in Keychain: \"$SERVICE\")."
echo "Back up the key file somewhere outside this Mac."
echo
keytool -list -v -keystore "$KEY" -alias flomsi -storepass:env FLOMSI_KEY_PASSWORD |
  grep -E '^[[:space:]]*SHA1:' | sed -E 's/^[[:space:]]*SHA1: /SHA-1 for Google: /'
