# Release process

Corder ships as a Sparkle 2 auto-updating macOS app. The signed update
appcast lives in a separate repo (`corder-updates`) on `gh-pages`. End
users never download .zip files manually, they run an existing copy
of Corder, Sparkle's daemon polls the appcast (default 24 h), an
update notification appears, and a verified install proceeds.

## Versioning

Semantic versioning (`MAJOR.MINOR.PATCH`). Bump:

- **MAJOR** when the SQLite schema breaks backwards compatibility
  beyond what an additive migration can do (we haven't yet).
- **MINOR** for user-visible features, new providers, new endpoints.
- **PATCH** for bug fixes that don't change the UI.

The version lives in two files:

- `Info.plist` (repo root, copied verbatim into the bundle by
  `build-app.sh`) → `CFBundleShortVersionString` is the marketing semver
  (`0.14.74`); `CFBundleVersion` is a **monotonic integer build number**
  (currently `135`), bumped by one every release and NOT the semver.
- `CHANGELOG.md` → top section heading, which must match
  `CFBundleShortVersionString`.

## Prerequisites (one-time)

1. Sparkle's `generate_keys` produced an EdDSA keypair. Public half
   sits in `Info.plist` under `SUPublicEDKey`. Private half is in the
   developer's macOS Keychain, Sparkle's `sign_update` finds it
   automatically.
2. A `corder-updates` GitHub repo with a `gh-pages` branch and a
   `appcast.xml` pointing at release zips on `https://halinskiy.github.io/corder-updates/`.
3. `~/.config/corder/notary-creds.json` with Apple ID + app-specific
   password for `xcrun notarytool`. Format:

   ```json
   {"apple_id":"…","team_id":"…","password":"…"}
   ```

## Step-by-step

### 1. Update CHANGELOG.md

Move entries from `[Unreleased]` to a new dated section. Format:

```
## [0.7.0], 2026-MM-DD

### Added
- One sentence per feature, present-tense.

### Changed / Fixed / Removed (only sections that have entries).
```

This text becomes the "What's New" panel users see in the in-app updater.
Make it human.

It does NOT reach the appcast on its own: `generate_appcast` embeds a
`<description>` only when a notes file (`Corder-<v>.html`) sits next to the
archive. `Scripts/release.sh` (and the manual flow below) runs
`Scripts/changelog-to-notes.py <v> CHANGELOG.md > releases/Corder-<v>.html`
for every archive in `releases/` BEFORE `generate_appcast`, so the notes are
generated straight from this changelog. Skip that step and the modal shows
"No release notes attached to this update" (the long-standing empty-notes
bug, fixed for good in 0.14.62). When cutting by hand, always regenerate the
notes files first.

### 2. Bump Info.plist

Edit the repo-root `Info.plist` (build-app.sh copies it into the bundle).
`CFBundleShortVersionString` gets the semver; `CFBundleVersion` gets the
next integer build number (e.g. 129 → 130), it is NOT the semver.

```bash
plutil -replace CFBundleShortVersionString -string "0.7.0" Info.plist
plutil -replace CFBundleVersion -string "130" Info.plist
```

### 3. Build a release artefact

```bash
Scripts/build-app.sh
```

Verify:

```bash
codesign --verify --deep --strict --verbose=2 Corder.app
spctl --assess --type execute --verbose Corder.app    # should not error
```

### 4. Notarize (optional but recommended)

Sparkle works fine on a self-signed app, but Gatekeeper warns the
first time the user runs an un-notarized binary. Notarisation removes
that warning.

```bash
xcrun notarytool submit --keychain-profile "Corder" Corder.app.zip --wait
xcrun stapler staple Corder.app
```

The `Corder` keychain profile is created once with
`xcrun notarytool store-credentials Corder`.

### 5. Sign the update for Sparkle

```bash
zip -r Corder-0.7.0.zip Corder.app
sign_update Corder-0.7.0.zip > /tmp/sparkle-signature.txt
```

The signature is what Sparkle's client verifies against `SUPublicEDKey`
before installing. If the keypair drifts, recovery is painful (see
SECURITY.md).

### 6. Push to corder-updates

```bash
cd ../corder-updates
cp ../Corder/Corder-0.7.0.zip .
$EDITOR appcast.xml      # add a new <item> with the signed signature
git add . && git commit -m "0.7.0" && git push origin gh-pages
```

Existing installs poll once per 24 h by default; for impatient testing
add `--check-now` from the in-app menu (Проверить обновления…).

### 7. Tag in main repo

```bash
git tag v0.7.0
git push origin v0.7.0
```

Optional: open a GitHub Release with the same notes.

## Sparkle update appcast format

```xml
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <title>0.7.0</title>
      <pubDate>Mon, 04 May 2026 14:00:00 +0000</pubDate>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://halinskiy.github.io/corder-updates/Corder-0.7.0.zip"
        sparkle:version="0.7.0"
        sparkle:edSignature="<signature from sign_update>"
        length="<bytes>"
        type="application/octet-stream"
      />
    </item>
  </channel>
</rss>
```

## Automatic + critical updates (0.15.51+)

Two mechanisms let an update install without the user clicking the pill:

- **Automatic updates** — the user opts in via Settings → General
  ("Automatic updates", default OFF). The app then downloads a found update
  silently and installs it on the NEXT quit (no modal). See the update-driver
  gotcha in `AGENTS.md`.
- **Critical update** — add `<sparkle:criticalUpdate></sparkle:criticalUpdate>`
  inside the release's `<item>` in `appcast.xml` (after `generate_appcast`,
  before pushing to `gh-pages`; `generate_appcast` preserves it on re-runs).
  A build **≥ 0.15.51** treats a non-user-initiated critical update as a
  silent install-on-quit even with the Automatic-updates toggle OFF. This is
  CLIENT-side: it forces 0.15.51+ users, it can NOT retroactively force older
  builds (they lack the logic — for them a critical flag only reinforces the
  every-launch update prompt).

## Hotfixes

If you ship a release that bricks installs, push a `MAJOR.MINOR.PATCH+1`
within hours, not days. Sparkle pulls again on next launch. There is no
rollback infrastructure, older zips stay on the `gh-pages` branch but
the app only ever installs the latest one.

## Things that go wrong

- **`signature does not match`** in Sparkle's logs → the EdDSA private
  key used to sign isn't the one that pairs with the public key pinned
  in `Info.plist`. Either you swapped Macs or rotated the key.
- **`notarytool` returns "invalid"** → check the audit log via
  `xcrun notarytool log <submission-id> --keychain-profile Corder`.
  Common causes: hardened runtime entitlements drift, third-party
  dependency unsigned (Sparkle.framework!).
- **`The application "Corder" can't be opened`** on first run after
  zip → quarantine. `xattr -dr com.apple.quarantine /Applications/Corder.app`.
  Should never happen for users who got the binary through Sparkle, Sparkle handles quarantine internally.

## Don't release if

- `tail /tmp/corder.log` shows new error lines after a 5-minute
  idle test.
- The smoke test in `docs/DEVELOPMENT.md` doesn't pass clean.
- A meeting in the Library window shows `failed` immediately after
  recording (means transcription pipeline regression).
- Boost mode has been on for 5 minutes and no segment has gained a
  `text_boost` value (means Gemini integration regression).
