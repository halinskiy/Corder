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
#   - `python3` with PIL, used to regenerate the background PNG.
#
# Output:
#   releases/Corder-<version>.dmg
#
# DMG layout:
#   - Window 540×400
#   - Corder.app icon at (145, 140), hidden file extension
#   - /Applications symlink at (395, 140)
#   - White background with two soft brand-green blobs flanking the
#     icon row, a "Drag to install" caption above, and a dashed arrow
#     between the two icons.
#   - Icon Y is 140 (not window-centre 200): on macOS 26 the Finder window
#     keeps a toolbar + status bar that shrink the visible area to ~305pt,
#     so 140 centres the icon/arrow/caption unit. Keep it in sync with
#     ICON_CY_TOP in make-dmg-background.swift.
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
    echo "ERROR: $APP not found, run Scripts/build-app.sh (and"
    echo "       ideally Scripts/notarize.sh) first."
    exit 2
fi

# 1. Regenerate the background image (cheap, idempotent).
python3 "$ROOT/Scripts/make-dmg-background.py"

DMG="$RELEASES/Corder-$VERSION.dmg"
rm -f "$DMG"

# 2. Stage a copy of Corder.app onto APFS and set the Finder Info
#    `kIsExtensionHidden` bit there via `SetFile -a E`. This sticks
#    to the bundle when create-dmg embeds it into the DMG image,
#    and Finder honours the flag even when the user has
#    `AppleShowAllExtensions = true` set system-wide (which is what
#    overrides the AppleScript `set extension hidden` path inside
#    create-dmg). End-user sees "Corder" in the installer window;
#    on drag-to-Applications the file lands as `/Applications/Corder.app`
#    because LaunchServices re-applies the canonical extension on copy.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Corder.app"
/usr/bin/SetFile -a E "$STAGING/Corder.app" 2>/dev/null || true

# 3. Build the DMG. Window is 540×400 with the icon row at y=140 so the
#    caption sits above it, the Finder captions have room below, and the
#    whole unit is centred inside the toolbar-shrunk content area.
#    Geometry must match the constants in `make-dmg-background.swift`.
create-dmg \
    --volname "Corder $VERSION" \
    --volicon "$APP/Contents/Resources/AppIcon.icns" \
    --background "$ROOT/Resources/dmg-background.tiff" \
    --window-pos 200 120 \
    --window-size 540 400 \
    --icon-size 100 \
    --icon "Corder.app" 145 140 \
    --hide-extension "Corder.app" \
    --app-drop-link 395 140 \
    --no-internet-enable \
    --hdiutil-quiet \
    "$DMG" \
    "$STAGING"

echo "✔ DMG written: $DMG"
ls -lh "$DMG"
