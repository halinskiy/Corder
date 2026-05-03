# Architecture

> Live source-of-truth. Update when adding modules / endpoints / pipeline
> stages. The high-level shape changes rarely; flip from "what" to "why"
> when in doubt — the code already shows "what".

## Process model

Corder is a single executable, run as a status-bar app
(`LSUIElement = true`, no Dock icon by default; `setActivationPolicy(.regular)`
flips temporarily for permission prompts and the Library window).

Inside the process there are three independent runtime concerns that
communicate via shared state in `AppContext`:

1. **Capture loop** — `CaptureEngine` driven by ScreenCaptureKit callbacks.
2. **HTTP server** — Swifter, serves the React frontend + JSON API.
3. **UI** — SwiftUI popover (status-bar) + AppKit `NSWindow` hosting a
   WKWebView that loads `http://127.0.0.1:<port>/`.

```
┌──────────────────── Status-bar ────────────────────┐
│ MenuBarController  ─▶  PopoverContentView          │
│        │                                           │
│        ▼                                           │
│ RecordingController ◀──────────────────────────┐   │
└────────│───────────────────────────────────────│───┘
         │                                       │
         ▼                                       │
┌────────────────── CaptureEngine ───────────┐   │
│ SCStream                                   │   │
│ ├ .screen     →  (no writer; see gotcha)   │   │
│ ├ .audio      →  system.wav                │   │
│ └ .microphone →  mic.wav (macOS 15+)       │   │
└───────────────│────────────────────────────┘   │
                ▼                                │
┌──────────── TranscriptionPipeline ─────────┐   │
│ AudioMixer  → audio.wav (16k mono)         │   │
│ WhisperKit  → segments[]                   │   │
│ Diarizer    → channel-gate + FluidAudio    │   │
│ Hallucinations filter                      │   │
│ BoostService (optional, Gemini)            │   │
│ DropboxService (optional, archive)         │   │
└───────────────│────────────────────────────┘   │
                ▼                                │
┌────────────── GRDB / SQLite ───────────────┐   │
│ meetings, speakers, segments               │───┘
└───────────────│────────────────────────────┘
                ▼
┌────────────── HTTP server ─────────────────┐
│ Swifter on 127.0.0.1:<random>              │
│ /api/meetings, /:id, /:id/audio, …         │
│ /api/recording/state (polled by UI 1Hz)    │
└───────────────│────────────────────────────┘
                ▼
┌────────────── WKWebView library ───────────┐
│ Vite/React app (built into Resources/web)  │
│ Sidebar │ TranscriptPane │ RightPanel      │
└────────────────────────────────────────────┘
```

## Data lifecycle

Each meeting has a UUID. All filesystem state for that meeting lives
under `~/Library/Application Support/Corder/recordings/<uuid>/`. After a
successful Dropbox upload, local files are deleted and the SQLite row gets
`dropbox_audio_path` filled in.

```
Recording active:
  recordings/<uuid>/
  ├── system.wav            # SCStream system audio
  └── mic.wav               # SCStream microphone (macOS 15+)

Stop pressed → TranscriptionPipeline:
  1. AudioMixer.produceWhisperInput(system.wav, mic.wav) → audio.wav
  2. WhisperKit.transcribe(audio.wav) → [Segment]
  3. Diarizer.decide(segments, mic.wav, system.wav) → [SpeakerKey]
  4. Hallucination filter drops YouTube-subtitle artifacts
  5. INSERT INTO meetings/segments/speakers (GRDB)

Optional, fire-and-forget after step 5:
  6. BoostService.boostSegments → segments.text_boost
  7. DropboxService.upload(audio.wav, video.mov*) → meetings.dropbox_*
     then unlink local files

* video.mov is currently never produced (see "Gotchas / video" below).
```

## SQLite schema

Migrations are append-only in `Storage/Migrations.swift`.

```sql
-- v1
CREATE TABLE meetings (
  id              TEXT PRIMARY KEY,
  started_at      INTEGER NOT NULL,
  ended_at        INTEGER,
  duration_ms     INTEGER,
  video_path      TEXT NOT NULL,
  audio_path      TEXT NOT NULL,
  transcribed_at  INTEGER,
  status          TEXT NOT NULL  -- recording | transcribing | ready | failed
);
CREATE TABLE speakers ( id, meeting_id, label, custom_name, color_hex );
CREATE TABLE segments ( id, meeting_id, speaker_id, start_ms, end_ms, text, words_json );
-- + segments_fts FTS5 index, kept in sync with INSERT/DELETE/UPDATE triggers

-- v2_boost
ALTER TABLE meetings ADD COLUMN boosted_text TEXT;
ALTER TABLE meetings ADD COLUMN boosted_at   INTEGER;

-- v3_segment_boost
ALTER TABLE segments ADD COLUMN text_boost TEXT;

-- v4_dropbox
ALTER TABLE meetings ADD COLUMN dropbox_video_path  TEXT;
ALTER TABLE meetings ADD COLUMN dropbox_audio_path  TEXT;
ALTER TABLE meetings ADD COLUMN dropbox_uploaded_at INTEGER;
```

Why the per-segment `text_boost` (v3) instead of a single `boosted_text` blob:
when Boost was a meeting-level prose dump, the UI couldn't reuse the timeline,
speaker grouping, or scrub-to-segment. Per-segment polish keeps the existing
TranscriptPane intact — toggle just swaps which string each segment renders.

## Diarization

Two-source approach, much more robust than blind clustering on a single
mixed stream:

```
For each Whisper segment [start, end]:

  RMS_mic = rms(mic.wav,    start, end)
  RMS_sys = rms(system.wav, start, end)

  if RMS_mic > 2 * RMS_sys && RMS_mic > 0.005:
      speaker = "user"
  else:
      // FluidAudio is run once over the whole system.wav.
      // We pick the FluidAudio turn with the largest temporal overlap.
      speaker = "other-<fluidAudioSpeakerId>"
```

The 2× ratio is empirically robust against echo bleed when the user wears
speakers (not headphones). The 0.005 floor blocks the case where the user
never speaks but mic is louder than total silence.

FluidAudio loads two CoreML bundles into the Apple Neural Engine:
`pyannote_segmentation.mlmodelc` + `wespeaker_v2.mlmodelc`, ~13 MB combined,
cached to `~/Library/Application Support/FluidAudio/`. Cold start is the
download; subsequent inits are sub-second.

## Gotchas / video

`AVAssetWriter` with SCStream-sourced frames is broken on the macOS builds
we tested. Every output configuration we tried —
`.mov`/`.mp4` × `BGRA`/`YUV` × `AAC`/`PCM`/no-audio — flips writer status
to `.failed` with `kAudioCodecAudioFormatErr (-16122)` within ~1 s of the
first appended buffer. Even with the audio input deleted entirely from the
writer, the failure persists, suggesting an internal mux pipeline problem.

We chose **no video file** rather than a brittle 0-byte one. The frontend
exposes audio-only playback (parallel `<audio>` element with custom
controls). When/if Apple fixes the underlying bug, `CaptureEngine.start`
step 3 is the place to revive `AVAssetWriter`.

## Security model

- All long-lived secrets in `~/.config/corder/`, **never bundled** with the
  app, **never committed** to the repo.
- Gemini and Dropbox are optional; everything else (recording, Whisper,
  diarization) works fully offline.
- Self-signed `ScreenOCR Dev` cert ⇒ TCC permissions persist across rebuilds
  as long as the signing identity stays the same.
- See [`SECURITY.md`](SECURITY.md) for the full policy + gitleaks output.

## What we deliberately don't do

- **No background sync of past recordings.** Dropbox archival fires only
  for new meetings completed after the integration was added. Old local-only
  recordings stay local until the user re-transcribes them.
- **No multi-window UI.** Single Library window, single popover. Avoids
  AppKit window-management complexity in an LSUIElement app.
- **No auto-launch.** User runs the app manually (or via Sparkle update
  flow). LaunchAgents would require explicit consent UX we haven't built.
- **No OpenAI API.** WhisperKit on-device is the only ASR path. Gemini is
  used solely for text polishing, which is non-essential.
