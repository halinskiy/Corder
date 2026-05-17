# AGENTS.md — Corder

macOS meeting recorder + transcriber. Status-bar app (LSUIElement) with
a SwiftUI popover, a floating recording HUD, an embedded Swifter HTTP
server, and a WKWebView Library window that loads a Vite/React frontend
served by the same process.

This file is the single source of truth for AI agents (Claude Code,
Codex, Cursor, Copilot, Aider). Keep it short, dense, and fresh —
every change to build commands, architecture, or gotchas goes here.

## Project at a glance

| Thing             | Value                                                                              |
| ----------------- | ---------------------------------------------------------------------------------- |
| Language          | Swift 6 (executable target, swift-tools 6.0)                                       |
| Min macOS         | 14.0 (15+ recommended for ScreenCaptureKit shared mic-tap path; we now use AVAudioEngine for mic regardless) |
| Architecture      | Status-bar app + floating HUD pill + local HTTP server + WKWebView frontend       |
| Frontend          | Vite + React 18 + TypeScript, bundled into `Sources/Corder/Resources/web/`         |
| ASR               | Gemini 2.5 Flash, **dual-track** (mic + system as parallel calls). Only provider — no local/Whisper fallback. |
| Storage           | GRDB on top of SQLite, `~/Library/Application Support/Corder/corder.db`            |
| Recordings dir    | `~/Library/Application Support/Corder/recordings/<meeting-id>/`                    |
| Logs              | `/tmp/corder.log` (FileLogger, simple append)                                      |
| User config       | `~/.config/corder/{dropbox.json, gemini_key}` — never bundled, see SECURITY        |
| Code signing      | Self-signed cert "ScreenOCR Dev", hardened runtime, entitlements file              |

## Build, run, package

```bash
# Bundle the web app and Swift binary into ./Corder.app:
Scripts/build-app.sh

# Web dev only (when iterating on the frontend without rebuilding the binary):
cd Web && npm install && npm run dev          # Vite on :5173
cd Web && npm run build                       # production bundle into Sources/Corder/Resources/web/

# Swift only (CLI binary, no .app shell):
swift build -c release

# Launch the bundled app:
open Corder.app

# Tail the runtime log while testing:
tail -f /tmp/corder.log
```

Always rebuild the **app bundle** (`Scripts/build-app.sh`) after Swift
or web changes — a bare `swift build` produces a binary without the
`Corder_Corder.bundle` that Swifter serves the web assets from.

## Pipeline (recording → transcript)

```
Menu-bar Start
    │
    ▼
RecordingController.start
    │   • shows RecordingHUDPanel (floating pill, all Spaces)
    │   • CaptureEngine.start
    ▼
CaptureEngine
    │   SCStream:        .screen + .audio        →  system.wav
    │   AVAudioEngine:   default input tap        →  mic.wav
    │   Both taps also feed RecordingLevelMeter (sqrt-scaled peak,
    │   30 Hz publish, 12 Hz history shift) → drives HUD waveform.
    │   AVAssetWriter is intentionally NOT created — flips to .failed
    │   with -16122 on every config we tried. The .screen output is
    │   left registered to keep audio-clock pacing intact.
    ▼
Stop pressed → RecordingController.stopRecording → TranscriptionPipeline.enqueue
    │   • hides HUD
    │
    ▼
TranscriptionPipeline.transcribe
    │
    │   AudioMixer.produceMixIfNeeded → mix.wav (16 k mono, peak-norm)
    │   used for playback + as the single-stream fallback if the
    │   originals were already archived.
    │
    │   Cache check: MD5(mic.wav) + MD5(system.wav) (or MD5(mix.wav)
    │   for legacy rows). Hit → reuse `gemini_raw_turns` from DB,
    │   skip Gemini entirely, jump to mapping.
    │
    │   Miss + both tracks present (the normal path):
    │     async let micPart =
    │       GeminiTranscriber.transcribe(audioURL: mic.wav,    mode: .single)
    │     async let sysPart =
    │       GeminiTranscriber.transcribe(audioURL: system.wav, mode: .diarize)
    │     let (userTurns, otherTurns) = try await (micPart, sysPart)
    │
    │   Miss + only mix.wav (post-archive, no cache):
    │     legacyTurns = GeminiTranscriber.transcribe(audioURL: mix.wav, mode: .diarize)
    │
    │   Per-chunk auto-split: chunks > 9 min are sliced; on JSON
    │   truncation (`GError.parse`) the chunk is halved and retried,
    │   recursively up to depth 3 (≥ 70 s slice).
    │
    │   mapDualTrackTurns:
    │     userTurns      → speakerId = userSpeakerId
    │     otherTurns     → grouped by Gemini label, each label →
    │                       "other-N" (in arrival order)
    │     merged by start_ms.
    │
    │   mapTurnsToSpeakers (legacy single-stream): channel-gate
    │   (mic_RMS vs system_RMS) decides which Gemini label is the user.
    │
    │   Hallucination filter (`isHallucination`) drops YouTube-subtitle
    │   artefacts ("Субтитры сделал DimaTorzok", "Спасибо за просмотр",
    │   "Продолжение следует…"). Anti-hallucination clause in the
    │   Gemini prompt makes silent-stretch poetry rare in the first place.
    │
    │   Persist: `setRawTurnsCache` (gemini_raw_turns + audio_hash)
    │   then segments / speakers tables. Status flips ready.
    ▼
Optional: DropboxService — upload mix.wav + mic.wav + system.wav,
          delete local copies (kept under archive_root, see SECURITY)
    │
    ▼
SQLite via GRDB — meetings, speakers, segments
    │
    ▼
Library window (WKWebView)
    GET    /api/meetings              → list (excludes archived)
    GET    /api/archive               → archived rows + purge_at
    GET    /api/meetings/:id          → detail
    GET    /api/meetings/:id/audio    → file or Dropbox proxy
    POST   /api/meetings/:id/retranscribe         → re-run pipeline
    POST   /api/meetings/:id/cancel-transcription → cancel + flip failed
    POST   /api/meetings/:id/archive  → soft-archive (sets archived_at)
    POST   /api/meetings/:id/restore  → un-archive
    DELETE /api/meetings/:id          → hard delete (used by archive UI)
    POST   /api/meetings/:id/expected-speakers    → pin numClusters
    GET    /api/meetings/:id/last-error           → red toast
```

## Module map (`Sources/Corder/`)

| Folder           | Responsibility                                                                  |
| ---------------- | ------------------------------------------------------------------------------- |
| `App/`           | `CorderApp` entry, `AppDelegate` (LSUIElement, main menu, archive purge), `RecordingController` (state machine + HUD), `RecordingLevelMeter` (HUD-feeding ObservableObject), `NetworkMonitor`, `Notifications`, `SleepWatchdog`, `FileLogger`, `UpdateController` (Sparkle) |
| `Capture/`       | `CaptureEngine` (SCStream system audio + AVAudioEngine mic, level-meter ingest), `PermissionsChecker` |
| `Transcription/` | `AudioMixer`, `TranscriptionPipeline` (driver + dual-track fork + cache + auto-archive), `GeminiTranscriber` (cloud, with `TranscribeMode.{single,diarize}`, VAD pre-pass, auto-split), `VoiceActivityDetector` (RMS-gating + concat + projection), `Diarizer` (channel gate for legacy single-stream path only) |
| `Cloud/`         | `DropboxService` — refresh-token OAuth, chunked upload, temporary-link proxy    |
| `Storage/`       | GRDB models (with default-nil optionals), repository, migrations (v1..v8_archive) |
| `Server/`        | Swifter routes, range-aware media serving, JSON DTOs, RangeRequest parser       |
| `UI/`            | `MenuBarController` (status-item + popover), `PopoverContentView` (SwiftUI), `LibraryWindow` (NSWindow + WKWebView + JS↔Swift bridge), `RecordingHUDPanel` (floating NSPanel pill) |
| `Shared/`        | `AppPaths` — single source of truth for filesystem locations                    |
| `Resources/web/` | Built Vite output. Don't hand-edit; rebuild via `Scripts/build-app.sh`.          |

Frontend lives in `Web/src/`:

- `main.tsx` — App shell, polls recording state every 1 s, owns soft-
  archive + toast state, mounts `ArchiveView` modal, mounts `Donate` FAB.
- `components/Sidebar.tsx` — meeting list with date buckets, search, ctx menu.
- `components/MeetingView.tsx` — header + transcript-toolbar; owns the
  clarify-banner state machine + per-meeting open/closed persistence in
  localStorage; the toolbar Archive button opens the archive view (not
  the current meeting).
- `components/ArchiveView.tsx` — modal listing archived rows, master +
  per-row checkboxes, Restore / Delete-forever (with `confirm()`).
- `components/TranscriptPane.tsx` — speaker grouping, search highlight, banner switching.
- `components/{RecordingBanner,TranscribingBanner,RecordingPlaceholder,SpeakersClarifyBanner,EmptyDeleteBanner}.tsx` — status cards.
- `components/RightPanel.tsx` — audio scrub + per-speaker timeline.
- `components/Donate.tsx` — floating Buy Me a Coffee FAB (bottom-right).
- `api.ts` — typed wrapper around the Swift backend.
- `i18n.ts` — ru / en string tables.
- `format.ts` — date / duration / bucket helpers (these are NOT in i18n).
- `styles.css` — global tokens + component styles.

## Common tasks (cookbooks)

### Add a new API endpoint

1. Define the DTO in `Server/DTOs.swift`.
2. Add the route in `Server/Routes.swift::register`.
3. Add the typed wrapper in `Web/src/api.ts`.
4. Document it in `docs/API.md`.
5. Rebuild: `Scripts/build-app.sh`.

### Add a database column

1. Append a migration in `Storage/Migrations.swift` (`v9_…`). Never
   edit existing migrations.
2. Add the field to `Storage/Models.swift` + `CodingKeys`. Default
   optional fields to `nil` (`var newField: Int? = nil`).
3. Surface in `Server/DTOs.swift` if the frontend needs it.

### Add a UI string

1. Add the key to the `Strings` interface in `Web/src/i18n.ts`.
2. Add Russian and English values. Never ship a partial translation.
3. Use as `t.foo`. Never inline a string in JSX.

### Forget Dropbox / Gemini auth

```bash
rm ~/.config/corder/dropbox.json
rm ~/.config/corder/gemini_key
```

### Reset microphone TCC permission

```bash
tccutil reset Microphone com.3mpq.Corder
```

### Force the icon cache to drop a cached old icon

```bash
sudo rm -rf /Library/Caches/com.apple.iconservices.store
killall iconservicesd Dock NotificationCenter
# Bump CFBundleVersion in Info.plist if the cache survives this.
```

## Gotchas

- **Dual-track is the source of truth.** If `mic.wav` and `system.wav`
  both exist, transcribe each separately (`mode: .single` for mic,
  `mode: .diarize` for system) and merge by start-ms. NEVER mix the
  two streams and ask one Gemini call to label speakers — that path
  produces "your words attributed to your friend" failures during
  silent stretches and is reserved for legacy rows whose originals
  were already archived (single-stream + channel-gate fallback).

- **Don't delete `mic.wav` / `system.wav` after Dropbox upload.** The
  re-transcribe path needs them. Only delete on hard-delete (the archive
  bin's "Delete forever" or the legacy DELETE route).

- **The cache is keyed by audio MD5, not meeting id.** That's what
  makes re-transcribe + re-map free. When you edit anything that
  *would* change the raw Gemini output (prompt, model, chunking),
  invalidate by adding a version prefix to the cache key —
  `dual:v2:{micMD5}:{sysMD5}` — not by clearing the column.

- **`setRawTurnsCache(meetingId:geminiRawTurns:audioHash:)` is the
  ONLY way to write the cache.** It uses a targeted UPDATE that
  doesn't touch `status`. The earlier pattern (load row → mutate →
  save row) carried a stale `status = .transcribing` and tripped
  `resetStuckMeetings()` on next launch into `.failed`.

- **AVAssetWriter on this macOS build is broken for SCStream output.**
  Every config we tried (BGRA→YUV, mov/mp4, AAC/PCM/no audio) ends in
  `-16122` within ~1 s. We don't write video; the frontend treats
  absence as audio-only. See the long comment in `CaptureEngine.start`
  step 3.

- **Mic capture path is AVAudioEngine, not SCStream `.microphone`.**
  We tried SCStream's shared mic-tap (macOS 15+) and it silently
  loses samples whenever Discord / Telegram holds an exclusive claim.
  AVAudioEngine on the default input is more reliable. The `.microphone`
  case in the SCStream output handler has been removed.

- **Swifter request handlers run on background threads, not the main
  actor.** When you need MainActor state inside a handler, hop with
  `Task { @MainActor }` or use `RecordingStateSnapshot` (NSLock-mirror
  in `AppContext`). For per-meeting transcription errors, write/read
  through `TranscriptionErrors` (also lock-protected).

- **The HUD panel is `.nonactivatingPanel` + `.canJoinAllSpaces` +
  `.stationary` + `.fullScreenAuxiliary`.** Don't collapse those flags
  when adding behaviour — losing `.canJoinAllSpaces` makes the pill
  vanish on Space switches; losing `.nonactivatingPanel` steals focus
  every time the user clicks the Stop button.

- **WKWebView ⌘C beep.** WKWebView doesn't dispatch `copy:` to a first
  responder when the app has no `Edit` menu. We added a real Edit menu
  in `AppDelegate.installMainMenu` plus a JS keydown handler in
  `LibraryWindow.swift` that calls `e.preventDefault()`. Don't undo
  either.

- **WKWebView `target="_blank"` doesn't open URLs.** We added a native
  `window.corderOpenExternal(url)` bridge that hands the URL to
  `NSWorkspace.shared.open`. Use it for any external link from the UI
  (donate buttons, etc.).

- **WKWebView clipboard.** Same story — we route Copy through native
  via `window.corderCopy(text)`. The web `navigator.clipboard` fallback
  exists for `npm run dev` only.

- **First playback of a Dropbox-archived meeting** blocks one Swifter
  worker while `hydrateDropboxFile` pulls the audio back to local disk.
  Subsequent Range scrubs read from disk without blocking.

- **Hardened runtime needs entitlements.** `Corder.entitlements` is
  committed and contains `com.apple.security.device.audio-input`.
  Without it, `--options runtime` codesigning silently breaks the
  Microphone TCC prompt.

- **Self-signed cert + TCC.** Re-using identity `ScreenOCR Dev` keeps
  Screen Recording / Microphone permissions across rebuilds. If you
  change the signing identity, all TCC grants reset.

- **Anti-hallucination clause in the Gemini prompt is load-bearing.**
  Without it, long silent gaps come back as poetry / weather forecasts /
  song lyrics, which then survive the hallucination filter (it only
  catches a fixed list of YouTube-subtitle phrases). Keep the
  "no clearly intelligible speech → output NO segment" rule.

## Code style

- Swift 6 with `.swiftLanguageMode(.v5)` (set in `Package.swift`). No
  strict concurrency yet.
- `@MainActor` on UI/state classes; `actor` for I/O isolation
  (`DropboxService`); detached `Task` for background work.
- 4-space indent. No force-unwraps in production paths; `try?` is
  fine for best-effort filesystem cleanup.
- **Comments explain why, not what.** SCStream / AVAssetWriter / Gemini
  / cache-invariant quirks earn comments; obvious code does not.
- **Frontend brand accent is green** (`var(--accent)` =`#1f7a4f`).
  NEVER use black (`var(--fg)`) for primary actions, selected states,
  or toggle ON. Black is for text and icons only.
- Selected state has no hover treatment.
- TypeScript strict, `noUnusedLocals`, `noUnusedParameters`. Tailwind
  is NOT used — hand-written CSS in `Web/src/styles.css`.

## Testing

There is no automated test suite for the cloud pipeline yet (would
need to mock Gemini). Manual smoke test before commit:

1. `Scripts/build-app.sh && open Corder.app`
2. Menu-bar Start → speak ~10 s → Stop. HUD pill should appear over
   every Space, react to your voice, and disappear on Stop.
3. Open Library → check transcript appeared, dual-track turns merged
   in start-ms order, audio plays, scrub works, search highlights work.
4. Right-click a meeting → Archive → row disappears with Undo toast,
   reopen archive panel from toolbar → row is there with `purge_at`
   in 7 days.
5. Re-transcribe a row → log should say `cache hit (dual)` if the
   raw turns are cached, or `dual-track — transcribing mic.wav +
   system.wav in parallel` if not.
6. Tail `/tmp/corder.log` for unexpected errors.

## Where things live on disk

```
~/Library/Application Support/Corder/
├── corder.db
└── recordings/<id>/
    ├── system.wav             # SCStream system audio
    ├── mic.wav                # AVAudioEngine mic
    └── mix.wav                # 16k mono mix; written by AudioMixer

~/.config/corder/
├── dropbox.json               # { app_key, app_secret, refresh_token, remote_root }
└── gemini_key                 # one-line Gemini API key
```

## See also

- `docs/ARCHITECTURE.md` — diagram, modules, lifecycle, schema.
- `docs/SECURITY.md` — threat model + secret hygiene.
- `docs/DESIGN.md` — colour, type, components, motion.
- `docs/API.md` — every HTTP endpoint.
- `docs/DEVELOPMENT.md` — first-time setup, common tasks, code style.
- `docs/RELEASE.md` — Sparkle update workflow.
- `CHANGELOG.md` — release history (read by Sparkle).
- `README.md` — human-facing intro.
