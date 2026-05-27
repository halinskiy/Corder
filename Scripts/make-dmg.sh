#!/usr/bin/env bash
# Build a styled DMG installer for Corder.app.
#
# Usage:
#   Scripts/make-dmg.sh <version>
#
# Requires:
#   - Corder.app already built + signed + notarized + stapled at
#     repo root (run Scripts/notarize.sh first).
#   - `create-dmg` from Homebrew: `brew install create-dmg`.
#   - `python3` with PIL — used to regenerate the background PNG.
#
# Output:
#   releases/Corder-<version>.dmg
#
# DMG layout:
#   - Window 540×400
#   - Corder.app icon at (130, 200), hidden file extension
#   - /Applications symlink at (410, 200)
#   - Centred background image with brand-coloured arrow between
#     the two icons + helper headline above.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASES="$ROOT/releases"
mkdir -p "$RELEASES"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: Scripts/make-dmg.sh <version>   (e.g. 0.9.0)"
    exit 1
fi

APP="$ROOT/Corder.app"
if [[ ! -d "$APP" ]]; then
    echo "ERROR: $APP not found — run Scripts/build-app.sh (and"
    echo "       ideally Scripts/notarize.sh) first."
    exit 2
fi

# 1. Regenerate the background image (cheap, idempotent).
python3 "$ROOT/Scripts/make-dmg-background.py"

DMG="$RELEASES/Corder-$VERSION.dmg"
rm -f "$DMG"

# 2. Build the DMG. `--hdiutil-quiet` suppresses chatter; the
#    --hide-extension keeps the Finder caption clean ("Corder",
#    not "Corder.app").
create-dmg \
    --volname "Corder $VERSION" \
    --volicon "$APP/Contents/Resources/AppIcon.icns" \
    --background "$ROOT/Resources/dmg-background.png" \
    --window-pos 200 120 \
    --window-size 540 400 \
    --icon-size 100 \
    --icon "Corder.app" 130 200 \
    --hide-extension "Corder.app" \
    --app-drop-link 410 200 \
    --no-internet-enable \
    --hdiutil-quiet \
    "$DMG" \
    "$APP"

echo "✔ DMG written: $DMG"
ls -lh "$DMG"
