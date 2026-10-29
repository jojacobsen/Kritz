#!/bin/bash
# Builds a Developer ID–signed, Apple-notarized Kritz.dmg ready for distribution.
#
#   ./release.sh
#
# Prerequisites (one-time):
#   - "Developer ID Application" certificate in the login keychain
#   - notarytool credential profile stored:
#       xcrun notarytool store-credentials "kritz-notary" \
#         --apple-id "<id>" --team-id "BTZJHLR33N"
set -euo pipefail

APP_NAME="Kritz"
SIGN_ID="Developer ID Application: Johannes Jacob (BTZJHLR33N)"
NOTARY_PROFILE="kritz-notary"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
APP_DIR="$ROOT/build/$APP_NAME.app"
DMG="$ROOT/build/$APP_NAME.dmg"

# 1. Build the .app bundle (icon, localizations, ad-hoc signature).
./build-app.sh

# 2. Re-sign with Developer ID + Hardened Runtime + secure timestamp.
echo "▶︎ codesign (Developer ID, hardened runtime)"
codesign --force --options runtime --timestamp \
    --sign "$SIGN_ID" "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"

# 3. Assemble the DMG (app + drag-to-Applications).
echo "▶︎ building DMG"
STAGE="$(mktemp -d)"
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# 4. Notarize the DMG and wait for the result.
echo "▶︎ notarizing (this can take a few minutes) …"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

# 5. Staple the ticket so it verifies offline.
echo "▶︎ stapling"
xcrun stapler staple "$DMG"

# 6. Verify Gatekeeper acceptance.
echo "▶︎ verifying"
spctl -a -t open --context context:primary-signature -v "$DMG" || true
stapler validate "$DMG"

echo "✓ Notarized DMG ready: $DMG"
