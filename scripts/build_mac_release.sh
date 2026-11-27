#!/bin/bash
# Build the Mac app (Release) for YOUR OWN Macs: signed with whatever Config/Signing.xcconfig + Config/Local.xcconfig
# select (by default "Sign to Run Locally"; with your team: Apple Development), verified, and packaged as
# dist/NEBULA-<version>-mac/NEBULA.app + NEBULA-<version>-mac.dmg (build/ and dist/ are git-ignored).
# This is a development build: it is not notarized and not hardened for distribution, so do not publish the result.
# NEBULA ships no binaries; everybody builds from source.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"  # the repository root (this file is scripts/build_mac_release.sh)
VERSION="${VERSION:-1.0.0}"
DD="$ROOT/build/dd-mac-release"
OUT="$ROOT/dist/NEBULA-$VERSION-mac"
cd "$ROOT"
xcodebuild -project NEBULA.xcodeproj -scheme "NEBULA Mac" -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DD" build | tail -3
APP="$DD/Build/Products/Release/NEBULA.app"
codesign --verify --deep --strict --verbose=2 "$APP"
rm -rf "$OUT" "$OUT.dmg"
mkdir -p "$OUT"
ditto "$APP" "$OUT/NEBULA.app"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/NEBULA.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "NEBULA $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT.dmg" >/dev/null
codesign -dv --verbose=2 "$OUT/NEBULA.app" 2>&1 | grep -E "Authority=|Signature|TeamIdentifier|Identifier=" | head -4
shasum -a 256 "$OUT.dmg" | tee "$OUT.dmg.sha256"
echo "Built: $OUT/NEBULA.app and $OUT.dmg"
