#!/bin/bash
# Builds Kritz.app as a proper .app bundle and ad-hoc signs it so that the
# Screen Recording permission (needed for capture) can attach to a stable bundle.
#
#   ./build-app.sh          build + bundle
#   ./build-app.sh run      build + bundle + launch
#
# For distribution (Developer ID + notarization) see README.md.
set -euo pipefail

APP_NAME="Kritz"
BUNDLE_ID="com.johannesjacob.kritz"
VERSION="0.2.0"
# Sparkle compares this monotonically-increasing integer build number to decide
# whether an update is newer. Bump it on every release (see release.sh).
BUILD="10"
MIN_MACOS="14.0"

# Sparkle auto-updater feed (served via GitHub Pages from docs/appcast.xml).
FEED_URL="https://jojacobsen.github.io/Kritz/appcast.xml"
# EdDSA public key; private key lives in the login Keychain (generate_keys).
PUBLIC_ED_KEY="S2mnzu9XJCjFet7jCSsgzo1pQ4xjB4QajvZ6D+k0lbU="

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "▶︎ swift build -c release"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
APP_DIR="$ROOT/build/$APP_NAME.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$PUBLIC_ED_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

# App icon: copy the compiled .icns into Resources (referenced by CFBundleIconFile).
if [ -f "$ROOT/Assets/AppIcon.icns" ]; then
    cp "$ROOT/Assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
    echo "✓ Copied app icon"
fi

# Localizations: copy every <lang>.lproj into the bundle's Resources.
if [ -d "$ROOT/Localization" ]; then
    cp -R "$ROOT/Localization/"*.lproj "$APP_DIR/Contents/Resources/"
    echo "✓ Copied $(ls -d "$ROOT/Localization/"*.lproj | wc -l | tr -d ' ') localizations"
fi

# Embed Sparkle.framework (auto-updater) from the SwiftPM binary artifact.
SPARKLE_FW="$(find "$ROOT/.build" -type d -path '*/Sparkle.xcframework/macos-*/Sparkle.framework' 2>/dev/null | head -1)"
if [ -n "$SPARKLE_FW" ]; then
    mkdir -p "$APP_DIR/Contents/Frameworks"
    rm -rf "$APP_DIR/Contents/Frameworks/Sparkle.framework"
    cp -R "$SPARKLE_FW" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
    echo "✓ Embedded Sparkle.framework"
else
    echo "⚠︎ Sparkle.framework not found in .build — run 'swift build' first" >&2
fi

# Ad-hoc signature (-). For release, swap for your Developer ID identity.
codesign --force --deep --sign - "$APP_DIR"

echo "✓ Built $APP_DIR"

if [[ "${1:-}" == "run" ]]; then
    echo "▶︎ launching …"
    open "$APP_DIR"
fi
