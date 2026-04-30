#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 1. Build the web bundle and copy into SwiftPM resources
"$ROOT/Scripts/build-web.sh"

# 2. Build the Swift binary in release mode
swift build -c release

# 3. Assemble the .app bundle
APP="$ROOT/Corder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$ROOT/.build/release/Corder" "$APP/Contents/MacOS/Corder"

# Resources bundle from SwiftPM (.copy("Resources/web") becomes Corder_Corder.bundle)
if [ -d "$ROOT/.build/release/Corder_Corder.bundle" ]; then
    cp -R "$ROOT/.build/release/Corder_Corder.bundle" "$APP/Contents/Resources/"
fi

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

# App icon
if [ -f "$ROOT/Resources/icons/AppIcon.icns" ]; then
    cp "$ROOT/Resources/icons/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# 4. Ad-hoc sign so TCC can identify the bundle by signature
codesign --force --deep --sign - "$APP" 2>/dev/null || true

# 5. Strip macOS quarantine attribute that Gatekeeper adds for downloaded binaries
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "✔ Built $APP"
echo "Run with:  open $APP"
