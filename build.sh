#!/usr/bin/env bash
set -euo pipefail

APP_NAME="BarTune"
BUNDLE_ID="com.arya.BarTune"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
if ! BASE_VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")" || [[ -z "$BASE_VERSION" ]]; then
    echo "error: cannot read the app version from $SCRIPT_DIR/VERSION" >&2
    exit 1
fi
# Versions from main count commits since the last stable tag, which a shallow clone cannot see.
if [[ "$(git -C "$SCRIPT_DIR" rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
    echo "error: shallow clone; run 'git fetch --unshallow --tags' so build.sh can count commits" >&2
    exit 1
fi
BUILD_NUMBER="$(git -C "$SCRIPT_DIR" rev-list --count HEAD 2>/dev/null || echo 0)"
GIT_COMMIT="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "$SCRIPT_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    GIT_COMMIT="$GIT_COMMIT-dirty"
fi
# Stable releases (BARTUNE_RELEASE=1, set by release.yml for v* tags) carry VERSION. Every other build
# follows the newest stable tag: vX.Y.Z plus N commits is X.Y.(Z+N), restarting when the next release is tagged.
if [[ "${BARTUNE_RELEASE:-}" == "1" ]]; then
    VERSION="$BASE_VERSION"
    RELEASE_CHANNEL="stable"
else
    # Only plain vX.Y.Z tags count; v0.5.0-rc.1 and similar are skipped.
    LAST_TAG="$(git -C "$SCRIPT_DIR" tag --merged HEAD --list 'v*' --sort=-v:refname 2>/dev/null \
        | grep -E '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' | head -n 1 || true)"
    if [[ -z "$LAST_TAG" ]] && git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        echo "error: no vX.Y.Z tag reachable from HEAD; run 'git fetch --tags' so build.sh can version this build" >&2
        exit 1
    fi
    if [[ -n "$LAST_TAG" ]]; then
        COMMITS_SINCE="$(git -C "$SCRIPT_DIR" rev-list --count "$LAST_TAG..HEAD")"
        STABLE_BASE="${LAST_TAG#v}"
    else
        COMMITS_SINCE="$BUILD_NUMBER"
        STABLE_BASE="$BASE_VERSION"
    fi
    IFS=. read -r MAJOR MINOR PATCH <<< "$STABLE_BASE"
    VERSION="$MAJOR.$MINOR.$((PATCH + COMMITS_SINCE))"
    RELEASE_CHANNEL="dev"
fi

echo "==> Building $APP_NAME $VERSION ($GIT_COMMIT, build $BUILD_NUMBER)..."
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
    <string>$BUILD_NUMBER</string>
    <key>BarTuneGitCommit</key>
    <string>$GIT_COMMIT</string>
    <key>BarTuneReleaseChannel</key>
    <string>$RELEASE_CHANNEL</string>
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

SIGN_IDENTITY="${BARTUNE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1 || true)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1 || true)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="-"
fi

echo "==> Signing $APP_BUNDLE with identity: $SIGN_IDENTITY"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"

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
