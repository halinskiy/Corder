#!/usr/bin/env bash
# Full notarized release build. UNTESTED until a Developer ID cert +
# notarytool credentials are available (waiting on the boss's Apple
# Developer account). Run from repo root: Scripts/notarize.sh
#
# Requires in the environment:
#   CORDER_SIGN_IDENTITY  "Developer ID Application: <Name> (<TEAMID>)"
#                         (the cert+key must be imported into the login
#                          keychain — e.g. from a shared .p12)
#
# Plus ONE notarytool auth method:
#   A) NOTARY_KEYCHAIN_PROFILE=<name>           (after `notarytool store-credentials`)
#   B) NOTARY_API_KEY=/path/AuthKey_XXXX.p8  NOTARY_KEY_ID=XXXX  NOTARY_ISSUER=<uuid>
#   C) NOTARY_APPLE_ID=<email>  NOTARY_PASSWORD=<app-specific-pw>  NOTARY_TEAM_ID=<TEAMID>
#
# (B) — App Store Connect API key — is preferred: revocable, scoped,
# never exposes anyone's Apple ID password.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${CORDER_SIGN_IDENTITY:?Set CORDER_SIGN_IDENTITY to the Developer ID Application identity}"

# notarytool auth args.
NOTARY_AUTH=()
if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [ -n "${NOTARY_API_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
    NOTARY_AUTH=(--key "$NOTARY_API_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
elif [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ]; then
    NOTARY_AUTH=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
else
    echo "ERROR: no notarytool credentials. Set NOTARY_KEYCHAIN_PROFILE, or"
    echo "NOTARY_API_KEY+NOTARY_KEY_ID+NOTARY_ISSUER, or"
    echo "NOTARY_APPLE_ID+NOTARY_PASSWORD+NOTARY_TEAM_ID." >&2
    exit 1
fi

# 1. Build + sign with Developer ID, hardened runtime ON, secure
#    timestamp ON. (NOT CORDER_NO_HARDENED — notarization needs it.)
CORDER_SIGN_IDENTITY="$CORDER_SIGN_IDENTITY" CORDER_TIMESTAMP=1 "$ROOT/Scripts/build-app.sh"

APP="$ROOT/Corder.app"

# 2. Pre-flight: signature must be Developer ID + hardened (flags=runtime).
echo "── codesign preflight ──"
codesign --verify --deep --strict --verbose=1 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority=Developer ID|flags=.*runtime" \
    || { echo "ERROR: not Developer-ID-signed or hardened runtime missing." >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$ROOT/Corder-${VERSION}-notarized.zip"

# 3. notarytool wants a zip (ditto preserves the bundle + symlinks).
SUBMIT_ZIP="$(mktemp -d)/Corder-submit.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"

# 4. Submit + block until Apple returns a verdict.
echo "── submitting to Apple notary (this can take a few minutes) ──"
xcrun notarytool submit "$SUBMIT_ZIP" "${NOTARY_AUTH[@]}" --wait

# 5. Staple the ticket into the bundle so it validates offline.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# 6. Gatekeeper must now accept it as Notarized.
spctl -a -vvv -t execute "$APP" 2>&1 | grep -E "accepted|Notarized" \
    || { echo "ERROR: Gatekeeper still rejects the app." >&2; exit 1; }

# 7. Final distributable zip (stapled).
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✔ Notarized + stapled. Distributable: $ZIP"
