#!/usr/bin/env bash
# Cuts a Corder release: builds the .app, zips it, signs the zip with
# Sparkle's EdDSA private key (kept in macOS Keychain), regenerates
# appcast.xml, and prints the next steps for hosting on GitHub.
#
# Prereqs (one-time):
#   1. Add Sparkle SwiftPM dep (already done) and run `swift build` once
#      so SwiftPM resolves the framework.
#   2. Generate the EdDSA keypair:
#        cd ~/Library/Caches/org.swift.swiftpm/checkouts/Sparkle/bin
#        ./generate_keys
#      This writes the private key into the macOS Keychain (item name
#      "https://sparkle-project.org") and prints the public key.
#      Paste the public key into Info.plist → SUPublicEDKey.
#   3. appcast.xml host MUST match Info.plist → SUFeedURL (that is where
#      the SHIPPED app actually looks). Currently:
#        https://halinskiy.github.io/corder-updates/appcast.xml
#      Hosted from the `corder-updates` repo `gh-pages` branch with
#      `appcast.xml` + the release zip. Change one → change both.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASES_DIR="$ROOT/releases"
mkdir -p "$RELEASES_DIR"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: scripts/release.sh <version>   (e.g. 0.6.0)"
  exit 1
fi

# 1. Build the .app bundle.
"$ROOT/Scripts/build-app.sh"

# 2. Stamp the version into the bundle's Info.plist (sed in-place).
PLIST="$ROOT/Corder.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"

# 3. Zip (Sparkle prefers .zip over .dmg for self-update).
ZIP="$RELEASES_DIR/Corder-$VERSION.zip"
( cd "$ROOT" && ditto -c -k --keepParent Corder.app "$ZIP" )

# 4. Sign the zip with the EdDSA private key from the Keychain.
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$SPARKLE_BIN/sign_update" ]]; then
  echo "ERROR: cannot find Sparkle's sign_update binary at $SPARKLE_BIN."
  echo "       Run \`swift build -c release\` once after adding Sparkle to"
  echo "       Package.swift, then re-run this script."
  exit 2
fi
SIG="$( "$SPARKLE_BIN/sign_update" "$ZIP" )"

# 5. Generate / update appcast.xml.
APPCAST="$RELEASES_DIR/appcast.xml"
# Repo MUST be the one whose gh-pages serves SUFeedURL (corder-updates),
# so the appcast and the binaries it points at live together.
"$SPARKLE_BIN/generate_appcast" "$RELEASES_DIR" \
  --download-url-prefix "https://github.com/halinskiy/corder-updates/releases/download/v$VERSION/"

echo
echo "✔ Release $VERSION ready in $RELEASES_DIR"
echo "  zip:      $ZIP"
echo "  signature: $SIG"
echo "  appcast:  $APPCAST"
echo
echo "Next:"
echo "  1. gh release create v$VERSION \"$ZIP\""
echo "  2. Copy $APPCAST to the gh-pages branch (or wherever SUFeedURL points)"
echo "  3. git push origin gh-pages"
