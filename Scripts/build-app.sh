#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 1. Build the web bundle and copy into SwiftPM resources
"$ROOT/Scripts/build-web.sh"

# 2. Build the Swift binary in release mode
swift build -c release

# 3. Assemble the .app bundle. We do NOT rm -rf the bundle — TCC tracks
# permissions per signed bundle identity and a fresh ad-hoc signature
# would invalidate prior Screen Recording / Microphone grants.
APP="$ROOT/Corder.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Replace just the executable + bundled web resources.
cp "$ROOT/.build/release/Corder" "$APP/Contents/MacOS/Corder"

if [ -d "$ROOT/.build/release/Corder_Corder.bundle" ]; then
    rm -rf "$APP/Contents/Resources/Corder_Corder.bundle"
    cp -R "$ROOT/.build/release/Corder_Corder.bundle" "$APP/Contents/Resources/"
fi

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/icons/AppIcon.icns" ]; then
    cp "$ROOT/Resources/icons/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# 3a. Sparkle framework (SwiftPM doesn't auto-embed XCFrameworks for CLI
# `swift build`, so we copy it into Contents/Frameworks/ ourselves).
SPARKLE_FW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
    cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
fi

# 4. Sign with a stable local identity. Ad-hoc signing ties TCC permissions
# to cdhash, which changes on every rebuild. A self-signed cert makes the
# designated requirement identifier-based, so Screen Recording / Microphone
# grants survive rebuilds.
SIGN_IDENTITY="ScreenOCR Dev"
ENTITLEMENTS="$ROOT/Corder.entitlements"
# Re-sign Sparkle's nested helpers FIRST (must not use --deep on the parent
# framework — that would clobber the launcher's own pre-applied signature
# that Sparkle relies on for its XPC sandbox model).
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    SPARKLE_VERSIONS="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
    for helper in "$SPARKLE_VERSIONS/Updater.app" \
                  "$SPARKLE_VERSIONS/XPCServices/"*.xpc \
                  "$SPARKLE_VERSIONS/Autoupdate"; do
        [ -e "$helper" ] || continue
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --preserve-metadata=entitlements,flags "$helper" 2>/dev/null || true
    done
    codesign --force --sign "$SIGN_IDENTITY" --options runtime "$APP/Contents/Frameworks/Sparkle.framework"
fi
codesign --force --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ENTITLEMENTS" --identifier com.3mpq.Corder "$APP/Contents/MacOS/Corder"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ENTITLEMENTS" --identifier com.3mpq.Corder "$APP"

# 5. Strip Gatekeeper quarantine
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "✔ Built $APP"
