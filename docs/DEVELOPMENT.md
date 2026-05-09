# Development

> If you're picking up Corder cold, read this in order. Architecture is
> described separately in `ARCHITECTURE.md`; this document is the
> day-to-day "how do I do X" reference.

## Prerequisites

- macOS 14 (Sonoma) or newer. Apple Silicon strongly preferred —
  WhisperKit on Intel is technically supported but slow.
- Xcode 15+ (for the bundled SDK / Swift 6 compiler), or just the
  Command Line Tools if you don't need the IDE.
- Node 20+ (for the Vite frontend).
- A self-signed code-signing identity called `ScreenOCR Dev` in your
  Keychain, or whatever identity is referenced in
  `Scripts/build-app.sh`. Keeping the identity stable preserves TCC
  permissions across rebuilds.

## First-time setup

```bash
git clone https://github.com/<you>/Corder.git
cd Corder
scripts/bootstrap.sh        # materialises ~/.config/corder/{dropbox.json,gemini_key}
$EDITOR ~/.config/corder/gemini_key      # paste your Gemini API key
```

Without `gemini_key`, the Gemini transcription provider (default) errors
out and falls back to nothing useful. To run fully offline, switch
provider to Whisper:

```bash
defaults write com.3mpq.Corder Corder.transcriptionProvider whisper
```

## Build & run

```bash
# Bundle frontend + Swift binary + .app shell + sign:
Scripts/build-app.sh

# Move into Applications (optional, keeps TCC stable):
ditto Corder.app /Applications/Corder.app
xattr -dr com.apple.quarantine /Applications/Corder.app
open /Applications/Corder.app

# Tail the runtime log while testing:
tail -f /tmp/corder.log
```

`Scripts/build-app.sh` does, in order:

1. `Web && npm run build` — produces `dist/` and copies it into
   `Sources/Corder/Resources/web/`.
2. `swift build -c release` — produces the binary.
3. Wraps the binary into `Corder.app/Contents/MacOS/Corder`, copies
   `Info.plist`, the Sparkle framework, and the resources, signs.
4. Strips quarantine.

### Frontend dev loop

When iterating only on the React UI:

```bash
cd Web
npm run dev          # Vite on :5173
```

Open `http://localhost:5173/` in a browser. Most UI works in plain
Safari; what won't work without the Swift app are the native bridges
(`window.corderCopy`, `window.corderOpenExternal`) and any API call
because the local server isn't running. Use this for layout / styling.

For full-loop testing (real meetings, real transcription) you have to
rebuild the .app — Vite's dev server can't talk to the embedded
Swifter on the random port.

### Swift dev loop

```bash
swift build -c debug             # faster, no app bundle
swift run                        # CLI binary, missing the bundled web
                                 # → Library window will 404 on /
```

For meaningful testing always go through `Scripts/build-app.sh`.

## Project layout

```
Corder/
├── Package.swift                  SwiftPM manifest
├── Sources/Corder/                Swift modules (see ARCHITECTURE.md)
├── Web/                           Vite + React frontend
│   ├── src/                       App code
│   │   ├── components/            One file per UI component
│   │   ├── api.ts                 typed fetch wrappers
│   │   ├── i18n.ts                ru / en string tables
│   │   ├── format.ts              date / duration helpers
│   │   ├── styles.css             global styles + tokens
│   │   └── main.tsx               App shell
│   ├── package.json
│   └── tsconfig.json              strict, noUnusedLocals on
├── Scripts/                       Build / signing helpers
├── Resources/                     SVG icons, AppIcon.icns
├── docs/                          you are here
├── NOTES.md                      single source of truth for AI agents
├── NOTES.md                       local editor addendum
└── CHANGELOG.md
```

## Common tasks

### Add a new API endpoint

1. Define the DTO in `Sources/Corder/Server/DTOs.swift`.
2. Add the route in `Sources/Corder/Server/Routes.swift::register`.
3. Add the typed wrapper in `Web/src/api.ts`.
4. Document it in `docs/API.md`.
5. Rebuild: `Scripts/build-app.sh`.

### Add a database column

1. Append a migration to `Sources/Corder/Storage/Migrations.swift`
   (`v6_…`). **Never** edit existing migrations — they've already run
   on installed copies.
2. Add the field to `Sources/Corder/Storage/Models.swift` plus the
   `CodingKeys` enum. Default optional fields to `nil`:

   ```swift
   var newField: Int? = nil
   ```

3. Surface in `Server/DTOs.swift` if the frontend needs it.
4. Update `docs/ARCHITECTURE.md`'s SQL block.

### Add a UI string

1. Add the key to the `Strings` interface in `Web/src/i18n.ts`.
2. Add Russian and English values. Don't ship a partial translation.
3. Use as `t.foo` in the component. Never inline a string.

### Add a colour or font weight

1. If it's brand-meaningful (selected state, CTA), add the token to
   `Web/src/styles.css :root` and document it in `docs/DESIGN.md`.
2. If it's a one-off shade for a specific component (e.g. a toast
   countdown), keep it scoped to that selector with a comment.
3. Never hardcode `#0e0e0d` — use `var(--fg)`.

### Bump the WhisperKit model

`Sources/Corder/Transcription/TranscriptionPipeline.swift` →
`modelName`. Defaults to `large-v3`. The model lives at
`~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-<name>`
and is downloaded on first use.

### Forget Dropbox / Gemini auth

```bash
rm ~/.config/corder/dropbox.json
rm ~/.config/corder/gemini_key
```

The app falls back gracefully — Dropbox archival skips if creds are
missing, the Gemini path throws `missingAPIKey`.

### Reset microphone TCC permission

```bash
tccutil reset Microphone com.3mpq.Corder
```

Next `Start` will re-prompt. Required because LSUIElement apps need an
active activation policy for the prompt to render — see
`CaptureEngine.start`.

## Testing

XCTest suite under `Tests/CorderTests/`. Run with:

```bash
swift test
```

Coverage as of v0.6.0 (23 tests total):

- `RangeRequestTests` — HTTP Range header parser edge cases.
- `MigrationsTests` — schema bootstrap, FTS5 round-trip.
- `MeetingRepositoryTests` — insert, list, search, rename.
- `TranscriptFormatterTests` — paragraph mode, "you" → "I", custom
  names, hour formatting, empty segment skipping.
- `AudioMixerTests` — peak-normalised mix, clip safety, length handling.
- `DiarizerTests` — channel-gate (mic dominance) thresholds + per-segment
  independence, with on-the-fly `.wav` fixtures in the temp dir.

We don't yet test the bigger integration paths (Whisper, Gemini,
FluidAudio, Dropbox). Those are integration concerns; for any change
that touches those modules, also run the manual smoke test:

1. `Scripts/build-app.sh && open Corder.app`
2. Menu-bar Start → speak ~10 s → Stop.
3. Open Library → check transcript appeared, speakers diarised
   correctly, audio plays, scrub works, search highlights work.
4. Right-click a meeting → Удалить → red toast with `Undo` countdown
   appears, row disappears immediately, comes back if Undo clicked.
5. Tail `/tmp/corder.log` for errors. Expected log lines:
   - `CaptureEngine.start: …`
   - `transcribe(): …`
   - `Diarizer: …` (Whisper provider)
   - `GeminiTranscriber: …` (Gemini provider)
   - `dropbox: …` if Dropbox is configured
   - `transcribe(): dropping Whisper hallucination: …` for known
     YouTube-subtitle artefacts
6. Toggle Boost; record a new meeting; watch each segment grow a
   `text_boost` value within ~5-10 s after recording ends.

## Known build / runtime warnings

- `NSUserNotification` deprecated in macOS 11 — used in
  `AppDelegate.swift` and `RecordingController.swift`. Migration to
  `UserNotifications.framework` is pending; the deprecated API still
  works fine.
- `'WhisperKit' was deprecated …` — depends on which version of
  WhisperKit is pinned in `Package.swift`. Upstream churn; usually
  safe to ignore unless the build itself fails.

## Release process

See `docs/RELEASE.md` for the Sparkle workflow. TL;DR:

1. Bump version in `Info.plist` and `CHANGELOG.md`.
2. `Scripts/build-app.sh && Scripts/notarize.sh && Scripts/sign-update.sh`.
3. Push the .zip + appcast XML to the `corder-updates` gh-pages repo.
4. Existing installs see the update within their next 24 h Sparkle
   poll.

## Code style

### Swift

- Swift 6 with `.swiftLanguageMode(.v5)` (see `Package.swift`). No
  strict concurrency yet.
- `@MainActor` on UI/state classes; `actor` for I/O isolation
  (`DropboxService`); detached `Task` for background work.
- 4-space indent. No force-unwraps in production paths; `try?` is
  fine for best-effort filesystem cleanup.
- Comments explain *why*, not *what*. WhisperKit / SCStream /
  AVAssetWriter quirks earn comments; obvious code does not.

### TypeScript

- Strict, `noUnusedLocals`, `noUnusedParameters`. The `tsc -b` step in
  `npm run build` is your linter — it will fail the build on dead
  imports and props.
- Avoid `any`. If you can't avoid it, leave a comment why.
- `useCallback` for callbacks that go into `useEffect` deps.
- `useEffect` cleanup: every `setInterval` / `setTimeout` /
  `addEventListener` returns a cleanup function. No exceptions.

### CSS

- Tokens at the top of `styles.css :root`. Component rules grouped by
  component, in roughly the order they appear in the UI top-down.
- No `!important` unless commented. The clarify-banner X button
  carries a few because it overrides the global `button { … }` rules.
- Avoid magic numbers: prefer the spacing scale (4 / 8 / 12 / 16 /
  24 / 32 / 48 / 64 / 96 / 120). Document any deviation.

## Useful one-liners

```bash
# What did the pipeline log for the latest meeting?
tail -200 /tmp/corder.log | grep -E "transcribe|Diarizer|Gemini"

# Wipe local SQLite (forget all meetings, audio files stay):
rm ~/Library/Application\ Support/Corder/corder.db

# Force re-download of WhisperKit model:
rm -rf ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml

# List all running Corder processes (in case of zombies):
pgrep -lf "Corder.app/Contents/MacOS/Corder"
```
