#!/usr/bin/env bash
set -euo pipefail

APP_NAME="BarTune"
BUNDLE_ID="com.arya.BarTune"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "0.2.0")"

echo "==> Building $APP_NAME (release)..."
cd "$SCRIPT_DIR"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "==> Packaging $APP_NAME.app..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
if [[ -f "$SCRIPT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>BarTune</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>BarTune needs Automation access to read the currently playing track and playback position from Spotify.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>BarTune uses on-device Speech Recognition to align karaoke lyrics to playing audio when Apple Speech Sync is enabled.</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP_BUNDLE"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications/$APP_NAME.app..."
    killall "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
    echo "==> Installed! Launch with: open -a $APP_NAME"
elif [[ "${1:-}" == "--dmg" ]]; then
    DIST_DIR="$SCRIPT_DIR/dist"
    DMG_NAME="$APP_NAME-$VERSION.dmg"
    DMG_PATH="$DIST_DIR/$DMG_NAME"
    STAGING_DIR="$(mktemp -d)"
    trap 'rm -rf "$STAGING_DIR"' EXIT

    mkdir -p "$DIST_DIR"
    cp -R "$APP_BUNDLE" "$STAGING_DIR/"
    ln -s /Applications "$STAGING_DIR/Applications"

    echo "==> Creating $DMG_PATH..."
    rm -f "$DMG_PATH" "$DMG_PATH.sha256"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
    (cd "$DIST_DIR" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")
    echo "==> Created $DMG_PATH"
else
    echo "==> Built $APP_BUNDLE"
    echo "    Run ./build.sh --install to install to /Applications"
    echo "    Run ./build.sh --dmg to package dist/$APP_NAME-$VERSION.dmg"
fi
