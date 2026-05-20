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

# Make sure dyld can find Sparkle.framework (and any future bundled
# frameworks). swift-build doesn't set this rpath on bare CLI builds.
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Corder" 2>/dev/null || true

# The web assets live in this SwiftPM resource bundle. Routes.swift
# resolves it via Bundle.main from Contents/Resources — if it's missing
# the app serves a blank Library (or, on older code, HARD-CRASHED via
# Bundle.module's fatalError, which is what crashed the tester's Mac).
# Never ship a bundle without it: hard-fail the build instead.
if [ ! -d "$ROOT/.build/release/Corder_Corder.bundle" ]; then
    echo "FATAL: .build/release/Corder_Corder.bundle missing — web assets" \
         "would not ship. Run Scripts/build-web.sh; do not 'swift build' alone." >&2
    exit 1
fi
rm -rf "$APP/Contents/Resources/Corder_Corder.bundle"
cp -R "$ROOT/.build/release/Corder_Corder.bundle" "$APP/Contents/Resources/"
if [ ! -f "$APP/Contents/Resources/Corder_Corder.bundle/web/index.html" ]; then
    echo "FATAL: Corder_Corder.bundle copied but web/index.html absent —" \
         "the Library window would be blank on every machine." >&2
    exit 1
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
# Default = self-signed local cert (TCC-stable across rebuilds). For a
# notarizable build, pass CORDER_SIGN_IDENTITY="Developer ID Application:
# <Name> (<TEAMID>)" — notarize.sh does this. Switching identities resets
# TCC grants (the designated requirement changes), which is expected and
# unavoidable when moving off the self-signed cert.
SIGN_IDENTITY="${CORDER_SIGN_IDENTITY:-ScreenOCR Dev}"
ENTITLEMENTS="$ROOT/Corder.entitlements"
# Notarization requires a secure timestamp on every signature. A
# self-signed cert can't timestamp (no trusted TSA chain) and doesn't
# need to, so this is opt-in via CORDER_TIMESTAMP=1 (set by notarize.sh).
if [ "${CORDER_TIMESTAMP:-0}" = "1" ]; then
    TS_OPT=(--timestamp)
else
    TS_OPT=(--timestamp=none)
fi
# Hardened runtime is REQUIRED for notarization, so it stays ON by
# default. But a self-signed, NON-notarized hardened-runtime build
# crashes the instant WKWebView spawns its WebContent XPC process on
# any machine that doesn't trust "ScreenOCR Dev" (i.e. every machine
# but the dev's — the cert lives only in the dev keychain). For manual
# tester builds set CORDER_NO_HARDENED=1 to drop `--options runtime`
# so the WebContent process isn't killed. Such a build CANNOT be
# notarized — it is strictly an interim tester artifact.
# Hardened runtime + a NON-Developer-ID signature (the default
# self-signed "ScreenOCR Dev", or any cert a tester Mac doesn't trust)
# crashes WKWebView's WebContent XPC on every machine but the dev's.
# So hardened is auto-DROPPED unless we're signing with a real
# "Developer ID Application:" identity (the only case it's both
# required — for notarization — and safe). This makes the plain
# `Scripts/build-app.sh` produce a tester-safe artifact by default
# instead of a silent landmine that only the dev never hits.
case "$SIGN_IDENTITY" in
    "Developer ID Application:"*) IS_DEVELOPER_ID=1 ;;
    *)                            IS_DEVELOPER_ID=0 ;;
esac
if [ "${CORDER_NO_HARDENED:-0}" = "1" ] || [ "$IS_DEVELOPER_ID" = "0" ]; then
    RUNTIME_OPT=()
    if [ "$IS_DEVELOPER_ID" = "0" ] && [ "${CORDER_NO_HARDENED:-0}" != "1" ]; then
        echo "⚠️  '$SIGN_IDENTITY' is not a Developer ID — hardened runtime" \
             "AUTO-DISABLED (a self-signed + hardened build crashes WKWebView" \
             "on every Mac that doesn't trust this cert). Interim tester" \
             "artifact — NOT notarizable. For a notarized build pass" \
             "CORDER_SIGN_IDENTITY=\"Developer ID Application: …\"."
    else
        echo "⚠️  Building WITHOUT hardened runtime (interim tester build — NOT notarizable)"
    fi
else
    RUNTIME_OPT=(--options runtime)
fi
# Re-sign Sparkle's nested helpers FIRST (must not use --deep on the parent
# framework — that would clobber the launcher's own pre-applied signature
# that Sparkle relies on for its XPC sandbox model).
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    SPARKLE_VERSIONS="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
    for helper in "$SPARKLE_VERSIONS/Updater.app" \
                  "$SPARKLE_VERSIONS/XPCServices/"*.xpc \
                  "$SPARKLE_VERSIONS/Autoupdate"; do
        [ -e "$helper" ] || continue
        codesign --force --sign "$SIGN_IDENTITY" "${TS_OPT[@]}" "${RUNTIME_OPT[@]+${RUNTIME_OPT[@]}}" --preserve-metadata=entitlements,flags "$helper" 2>/dev/null || true
    done
    codesign --force --sign "$SIGN_IDENTITY" "${TS_OPT[@]}" "${RUNTIME_OPT[@]+${RUNTIME_OPT[@]}}" "$APP/Contents/Frameworks/Sparkle.framework"
fi
codesign --force --sign "$SIGN_IDENTITY" "${TS_OPT[@]}" "${RUNTIME_OPT[@]+${RUNTIME_OPT[@]}}" --entitlements "$ENTITLEMENTS" --identifier com.3mpq.Corder "$APP/Contents/MacOS/Corder"
codesign --force --sign "$SIGN_IDENTITY" "${TS_OPT[@]}" "${RUNTIME_OPT[@]+${RUNTIME_OPT[@]}}" --entitlements "$ENTITLEMENTS" --identifier com.3mpq.Corder "$APP"

# 5. Strip Gatekeeper quarantine
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "✔ Built $APP"
