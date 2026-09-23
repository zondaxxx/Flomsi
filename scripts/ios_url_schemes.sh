#!/usr/bin/env bash
# Register the URL schemes the sign-in sheet returns to on iOS: the reversed Google iOS
# client ID and Microsoft's msal<id>. Run before `flutter build ios`; nothing happens when
# neither client is configured.
set -euo pipefail
PLIST="${1:-app/ios/Runner/Info.plist}"
schemes=()
google="${FLOMSI_GOOGLE_IOS_CLIENT_ID:-}"
google="${google%.apps.googleusercontent.com}"
[ -n "$google" ] && schemes+=("com.googleusercontent.apps.$google")
[ -n "${FLOMSI_MICROSOFT_CLIENT_ID:-}" ] && schemes+=("msal${FLOMSI_MICROSOFT_CLIENT_ID}")
[ ${#schemes[@]} -eq 0 ] && { echo "no sign-in clients: URL schemes unchanged"; exit 0; }
PB=/usr/libexec/PlistBuddy
$PB -c "Delete :CFBundleURLTypes" "$PLIST" 2>/dev/null || true
$PB -c "Add :CFBundleURLTypes array" "$PLIST"
$PB -c "Add :CFBundleURLTypes:0 dict" "$PLIST"
$PB -c "Add :CFBundleURLTypes:0:CFBundleTypeRole string Editor" "$PLIST"
$PB -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$PLIST"
for i in "${!schemes[@]}"; do
  $PB -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:$i string ${schemes[$i]}" "$PLIST"
done
echo "URL schemes: ${schemes[*]}"
