#!/bin/bash
# Show the real expiry of YOUR Apple Development signing identities and provisioning profiles (read-only).
# Free Apple ID profiles expire after 7 days, paid program profiles after a year.
set -euo pipefail
echo "== Code signing identities (Apple Development)"
security find-identity -v -p codesigning | grep "Apple Development" || true
echo
echo "== Certificate expiry"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
security find-certificate -a -c "Apple Development" -p > "$tmp/all.pem"
awk -v d="$tmp" '/BEGIN CERT/{n++} {print > (d "/c" n ".pem")}' "$tmp/all.pem"
for c in "$tmp"/c*.pem; do
  openssl x509 -in "$c" -noout -subject -enddate 2>/dev/null | sed 's/^subject=//' | tr '\n' ' '; echo
done
echo
echo "== Development provisioning profiles"
find "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles" \
  -name '*.mobileprovision' 2>/dev/null | while read -r f; do
  security cms -D -i "$f" > "$tmp/p.plist" 2>/dev/null || continue
  name=$(/usr/libexec/PlistBuddy -c "Print :Name" "$tmp/p.plist")
  team=$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" "$tmp/p.plist")
  exp=$(/usr/libexec/PlistBuddy -c "Print :ExpirationDate" "$tmp/p.plist")
  devices=$(/usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$tmp/p.plist" 2>/dev/null | grep -cE '^[[:space:]]+[0-9A-Fa-f-]{20,}$' || true)
  echo "$name | team $team | expires $exp | devices $devices"
done
echo
app="${1:-}"
if [ -n "$app" ] && [ -d "$app" ]; then
  echo "== $app"
  codesign -dv --verbose=2 "$app" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier=" || true
  if [ -f "$app/embedded.mobileprovision" ]; then
    security cms -D -i "$app/embedded.mobileprovision" > "$tmp/e.plist"
    echo "embedded profile expires: $(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$tmp/e.plist")"
  fi
fi
