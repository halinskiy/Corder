# AGENTS.md — Corder

Local-only macOS meeting recorder + transcriber. Status-bar app (LSUIElement) with
a SwiftUI popover, an embedded Swifter HTTP server, and a WKWebView Library
window that loads a Vite/React frontend served by the same process.

This file is the single source of truth for AI agents (Claude Code, Codex,
Cursor, Copilot, Aider). Keep it short, dense, and fresh — every change to
build commands, architecture, or gotchas goes here.

## Project at a glance

| Thing             | Value                                                                              |
| ----------------- | ---------------------------------------------------------------------------------- |
| Language          | Swift 6 (executable target, swift-tools 6.0)                                        |
| Min macOS         | 14.0 (FluidAudio requires Sequoia)                                                 |
| Architecture      | Status-bar app + local HTTP server + WKWebView frontend                            |
| Frontend          | Vite + React 18 + TypeScript, bundled into `Sources/Corder/Resources/web/`         |
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

Always rebuild the **app bundle** (`Scripts/build-app.sh`) after Swift or web
changes — a bare `swift build` produces a binary without the `Corder_Corder.bundle`
that Swifter serves the web assets from.

## Pipeline (recording → transcript)

```
Menu-bar Start
    │
    ▼
CaptureEngine.start (Capture/CaptureEngine.swift)
    │   SCStream:  .screen + .audio + .microphone (macOS 15+)
    │   ↳ system.wav (system audio)
    │   ↳ mic.wav    (user mic)
    │   AVAssetWriter is intentionally NOT created — flips to .failed
    │   with -16122 on every config we tried. Video is omitted; audio
    │   files are the source of truth.
    ▼
RecordingController.stopRecording
    │
    ▼
TranscriptionPipeline.transcribe
    │   AudioMixer.produceWhisperInput(system.wav, mic.wav) → audio.wav (16k mono)
    │   WhisperKit large-v3, language=ru, VAD chunking
    │   Diarizer.decide:
    │       • Channel gate: mic_RMS > 2× system_RMS && mic_RMS > 0.005 → "user"
    │       • System-only stream → FluidAudio (CoreML port of pyannote 3.1)
    │       • Whisper segment → speakerId by max temporal overlap
    │   Hallucination filter (TranscriptionPipeline.isHallucination) drops
    │   YouTube-subtitle artifacts: "Субтитры сделал DimaTorzok",
    │   "Спасибо за просмотр", "Продолжение следует…"
    │
    ▼
Optional: BoostService (Gemini 2.5 Flash) — segment-by-segment polish
Optional: DropboxService — upload audio.wav, then delete local files
    │
    ▼
SQLite via GRDB — meetings, speakers, segments tables
    │
    ▼
Library window (WKWebView)
    │   GET /api/meetings        → list
    │   GET /api/meetings/:id    → detail
    │   GET /api/meetings/:id/audio  → file or Dropbox proxy (302 → temporary_link)
    │   POST /api/meetings/:id/boost → fire-and-forget Gemini polish
    │   POST /api/meetings/:id/retranscribe → re-run pipeline
```

## Module map (`Sources/Corder/`)

| Folder           | Responsibility                                                                  |
| ---------------- | ------------------------------------------------------------------------------- |
| `App/`           | `CorderApp` entry, `AppDelegate` (LSUIElement, main menu), `RecordingController` (state machine), `FileLogger` |
| `Capture/`       | `CaptureEngine` (SCStream wiring, mic via SC microphone output on macOS 15+)    |
| `Transcription/` | `AudioMixer`, `TranscriptionPipeline` (Whisper + diar + boost + Dropbox), `Diarizer` (channel gate + FluidAudio) |
| `Boost/`         | `BoostService` — Gemini 2.5 Flash, per-segment polish                           |
| `Cloud/`         | `DropboxService` — refresh-token OAuth, chunked upload, temporary-link proxy    |
| `Storage/`       | GRDB models, repository, migrations (currently v1..v4_dropbox)                  |
| `Server/`        | Swifter routes, range-aware media serving, JSON DTOs                            |
| `UI/`            | `MenuBarController` (status-item + popover), `PopoverContentView` (SwiftUI), `LibraryWindow` (NSWindow + WKWebView + JS↔Swift bridge) |
| `Shared/`        | `AppPaths` — single source of truth for filesystem locations                    |
| `Resources/web/` | Built Vite output. Don't hand-edit; rebuild via `Scripts/build-web.sh`.         |

Frontend lives in `Web/src/`:

- `main.tsx` — App shell, polls recording state every 1s, manages settings.
- `components/Sidebar.tsx` — meeting list with date buckets, search, ctx menu (delete / re-transcribe).
- `components/MeetingView.tsx` — header (Усилить toggle, Копировать/Расшифровать заново/Удалить), routes data into TranscriptPane + RightPanel.
- `components/TranscriptPane.tsx` — speaker grouping, search-highlight, RecordingBanner when live.
- `components/RightPanel.tsx` — audio player + per-speaker timeline (FluidAudio diarizer output).
- `api.ts` — typed wrapper around the Swift backend.

## Common tasks (cookbooks)

### Add a new API endpoint

1. Define the DTO in `Server/DTOs.swift`.
2. Add route in `Server/Routes.swift::register`.
3. Add typed wrapper in `Web/src/api.ts`.
4. Rebuild: `Scripts/build-app.sh`.

### Add a database column

1. Append a migration in `Storage/Migrations.swift` (`v5_…`). Never edit existing migrations.
2. Add the field to the model in `Storage/Models.swift` + `CodingKeys`.
3. Add helper in `Storage/MeetingRepository.swift` if it's a write path.
4. Surface in `Server/DTOs.swift` if the frontend needs it.

### Bump the WhisperKit model

`TranscriptionPipeline.swift::modelName`. `large-v3` is current. `medium`
is faster and still acceptable for Russian. Whisper stores models under
`~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-<name>`.

### Forget Dropbox / Gemini auth

```bash
rm ~/.config/corder/dropbox.json
rm ~/.config/corder/gemini_key
```
The app falls back gracefully — Dropbox archival skips if creds missing,
Gemini boost throws "missingAPIKey".

### Reset microphone TCC permission

```bash
tccutil reset Microphone com.3mpq.Corder
```
Next `Start` will re-prompt. Required because LSUIElement apps need an
active activation policy for the prompt to render — see `CaptureEngine.start`.

### Re-run diarization on existing recordings

In the UI: right-click a meeting → **Расшифровать заново**. Re-fetches
`audio.wav` from Dropbox if local copies were cleaned, runs Whisper +
FluidAudio anew. The `text_boost` stays untouched unless Boost is on
(triggers per-segment Gemini polish on the new segments).

## Gotchas

- **AVAssetWriter on this macOS build is broken for SCStream output.** Every
  config we tried (BGRA→YUV, mov/mp4, AAC/PCM/no audio) ends in
  `kAudioCodecAudioFormatErr (-16122)` within ~1 s. We don't write video at
  all; the frontend treats absence as audio-only. See the long comment in
  `CaptureEngine.start` step 3.

- **Swifter request handlers run on background threads, not the main actor.**
  When you need MainActor state inside a handler, hop with `Task { @MainActor }`
  or use `RecordingStateSnapshot` (NSLock-protected mirror in `AppContext`).

- **WKWebView ⌘C beep.** WKWebView doesn't dispatch `copy:` to a first
  responder when the app has no `Edit` menu. We added a real Edit menu in
  `AppDelegate.installMainMenu` plus a JS keydown handler in
  `LibraryWindow.swift` that calls `e.preventDefault()`. Don't undo either.

- **Hardened runtime needs entitlements.** `Corder.entitlements` is committed
  and contains `com.apple.security.device.audio-input`. Without it, `--options
  runtime` codesigning silently breaks the macOS Microphone TCC prompt.

- **Self-signed cert + TCC.** Re-using identity `ScreenOCR Dev` keeps Screen
  Recording / Microphone permissions across rebuilds. If you change the
  signing identity, all TCC grants reset.

- **Hallucinations on silent audio.** Whisper `large-v3` invents
  YouTube-subtitle phrases on silence. Drop list lives in
  `TranscriptionPipeline.hallucinationPatterns`. Add new variants there.

## Code style

- Swift 6 with `.swiftLanguageMode(.v5)` (set in `Package.swift`). No strict
  concurrency yet.
- `@MainActor` on UI/state classes; detached `Task` for I/O off the main thread.
- 4-space indent. No force-unwraps in production paths; `try?` is fine for
  best-effort filesystem cleanup.
- Comments explain *why*, not *what*. WhisperKit/SCStream/AVAssetWriter quirks
  earn comments; obvious code does not.
- TypeScript strict; Tailwind not used — hand-written CSS in `Web/src/styles.css`.

## Testing

There is no automated test suite yet. Manual smoke test before commit:

1. `Scripts/build-app.sh && open Corder.app`
2. Menu-bar Start → speak ~10 s → Stop.
3. Open Library → check transcript appeared, speakers diarized correctly,
   audio plays, scrub works, search highlights work.
4. Right-click a meeting → Удалить → row disappears immediately.
5. Tail `/tmp/corder.log` for `writer.status=failed` (expected, harmless),
   `Diarizer: remote stream produced N speakers`, `mic frames captured > 0`.

## Where things live on disk

```
~/Library/Application Support/Corder/
├── corder.db
├── models/                    # WhisperKit downloaded weights
└── recordings/<id>/
    ├── system.wav             # before Dropbox archive
    ├── mic.wav                # before Dropbox archive
    └── audio.wav              # mix; after archive only this remains until upload

~/Library/Application Support/FluidAudio/Models/
└── speaker-diarization-coreml/
    ├── pyannote_segmentation.mlmodelc
    └── wespeaker_v2.mlmodelc

~/.config/corder/
├── dropbox.json               # { app_key, app_secret, refresh_token, remote_root }
└── gemini_key                 # one-line Gemini API key
```

Tail of useful runtime log lines:

- `CaptureEngine.start: …` — bookkeeping for capture session.
- `Diarizer: remote stream produced N speaker turns, speakers=K` — diarizer health.
- `dropbox: video at /Corder/<id>/video.mov` — archive succeeded.
- `transcribe(): dropping Whisper hallucination: <text>` — hallucination filter active.

## See also

- `docs/ARCHITECTURE.md` — diagram + lifecycle details.
- `docs/SECURITY.md` — secret-handling policy and gitleaks proof.
- `CHANGELOG.md` — release history (kept for Sparkle).
- `README.md` — human-facing intro.
