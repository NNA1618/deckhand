#!/bin/bash
# Builds Deckhand.app from the SwiftPM output, installs it to /Applications and launches it.
# Usage: ./scripts/bundle.sh [debug|release]
# Set NO_LAUNCH=1 to skip launching, NO_INSTALL=1 to only build the bundle.
# BUNDLE_ID overrides the bundle id; check.sh uses its own so test runs never share settings with the installed app.

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP_NAME="Deckhand"
BUNDLE_ID="${BUNDLE_ID:-com.nna1618.deckhand}"
VERSION="0.6.0"
BUILD="7"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
[ -f "$BIN_PATH" ] || { echo "error: binary not found at $BIN_PATH"; exit 1; }

APP_PATH=".build/$CONFIG/$APP_NAME.app"
echo "==> assembling $APP_PATH"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH" "$APP_PATH/Contents/MacOS/$APP_NAME"

# Translations live next to the binary so Bundle.main finds them
cp -R Localization/*.lproj "$APP_PATH/Contents/Resources/"
[ -f Resources/AppIcon.icns ] || swift scripts/make-icons.swift
cp Resources/AppIcon.icns "$APP_PATH/Contents/Resources/"
cp Resources/Brand/*.svg "$APP_PATH/Contents/Resources/"

cat > "$APP_PATH/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 NNA1618. MIT License.</string>
    <key>NSAppleEventsUsageDescription</key><string>Deckhand reads the current track from Music, Spotify and browser tabs, and switches Dark Mode when you ask.</string>
</dict>
</plist>
EOF

# Sign with a stable identity if there is one, otherwise ad-hoc. macOS ties permissions to the signature,
# so a stable one keeps them across rebuilds and updates. Releases use "Deckhand Release Signing"
# (./scripts/setup-release-keys.sh, maintainer only); contributors make "Deckhand Local Signing"
# with ./scripts/setup-signing.sh.
SIGN_ID="${SIGN_ID:-}"
for NAME in "Deckhand Release Signing" "Deckhand Local Signing"; do
    if [ -z "$SIGN_ID" ] && security find-certificate -c "$NAME" >/dev/null 2>&1; then
        SIGN_ID="$NAME"
    fi
done
codesign --force --deep --sign "${SIGN_ID:--}" "$APP_PATH"
echo "==> signed with ${SIGN_ID:-ad-hoc}"
echo "==> built $APP_PATH"

[ "${NO_INSTALL:-0}" = "1" ] && exit 0

echo "==> installing to /Applications"
# Quit only the installed copy, the way the user would; check builds and snapshot runs keep running
INSTALLED="/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME"
osascript -e "if application id \"$BUNDLE_ID\" is running then tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "^$INSTALLED" >/dev/null || break; sleep 0.3; done
pkill -f "^$INSTALLED" 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_PATH" "/Applications/$APP_NAME.app"

if [ "${NO_LAUNCH:-0}" != "1" ]; then
    open "/Applications/$APP_NAME.app"
fi
echo "==> done"
