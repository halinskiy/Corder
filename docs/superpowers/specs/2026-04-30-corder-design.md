# Corder — Design Spec

**Date:** 2026-04-30
**Status:** Approved (brainstorm phase)
**Owner:** Kostya (3mpq)

## What this is

Personal macOS meeting recorder with local transcription, speaker diarization, and a Grain-style web UI for review. Free, fully local, single-user. Transcripts are copied manually into a Claude chat for summarization — no API integrations.

## Goals

- One-click record full screen + system audio + microphone
- Local Whisper transcription with speaker separation (Speaker 1/2/3)
- Library + meeting page that looks and feels like Grain
- Click-a-word-to-seek video player synced with transcript
- "Isolate this speaker" playback (concatenated segments of one speaker)
- Manual speaker rename
- One-button copy of the full formatted transcript to clipboard
- Full-text search across all meetings

## Non-goals (deferred)

- Auto-detect Zoom/Meet processes
- Voice fingerprinting / persistent speaker identity across meetings
- In-app summary generation (Claude does this via clipboard workflow)
- Tags, notes, highlights, clips, sharing
- File export (clipboard copy covers it)
- Multi-platform (macOS only)

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│  Corder.app (Swift, AppKit, menu bar)                          │
│                                                                │
│  CaptureEngine (ScreenCaptureKit) → mov + 16kHz mono wav       │
│         │                                                      │
│         ▼                                                      │
│  TranscriptionPipeline (sherpa-onnx) → segments + speakers     │
│         │                                                      │
│         ▼                                                      │
│  Storage: GRDB SQLite + FTS5 + files in Application Support    │
│         │                                                      │
│         ▼                                                      │
│  LocalServer (Swifter, http://127.0.0.1:<random-port>)         │
│         ▲                                                      │
│         │                                                      │
│  WKWebView ◄─ React+Vite SPA (built into bundle Resources)     │
│                                                                │
│  MenuBarController (NSStatusItem + NSPopover)                  │
└────────────────────────────────────────────────────────────────┘
```

### Why local HTTP instead of file:// + JS bridge

- Video playback over 1 GB+ files needs HTTP Range requests for scrubbing
- React dev workflow uses Vite hot reload in Safari against the same Swift API
- Clean Swift↔frontend interface, decoupled, testable independently

## Components

### CaptureEngine (Swift)

- `ScreenCaptureKit.SCStream` configured with the main display + system audio + microphone input
- Two simultaneous outputs:
  - `video.mov` — H.264 with embedded stereo audio (for playback)
  - `audio.wav` — 16 kHz mono mixdown of system + mic (for transcription only)
- File paths: `~/Library/Application Support/Corder/recordings/<meeting-id>/{video.mov, audio.wav}`
- Permissions handled at first use: Screen Recording + Microphone. If missing, deeplink to System Settings.

### TranscriptionPipeline (Swift)

Runs after recording stops. Pipeline stages:

1. **VAD** — Silero VAD via sherpa-onnx splits the wav into speech segments
2. **ASR** — whisper-medium-int8 ONNX transcribes each segment with word-level timestamps
3. **Diarization** — 3D-Speaker embedding model produces vectors per segment, agglomerative clustering assigns Speaker 1..N labels
4. **Persist** — segments inserted into SQLite with speaker_id, start_ms, end_ms, text, words(json)

Progress is published via NotificationCenter and exposed to the frontend through a Server-Sent Events endpoint (`GET /api/meetings/:id/progress`).

Models live in `~/Library/Application Support/Corder/models/`. First run downloads them from HuggingFace mirrors with a progress UI (~2 GB total).

### Storage (Swift, GRDB)

```sql
CREATE TABLE meetings (
  id TEXT PRIMARY KEY,             -- uuid
  started_at INTEGER NOT NULL,     -- unix ms
  ended_at INTEGER,
  duration_ms INTEGER,
  video_path TEXT NOT NULL,
  audio_path TEXT NOT NULL,
  transcribed_at INTEGER,          -- null until done
  status TEXT NOT NULL             -- recording | transcribing | ready | failed
);

CREATE TABLE speakers (
  id TEXT PRIMARY KEY,
  meeting_id TEXT NOT NULL REFERENCES meetings(id),
  label TEXT NOT NULL,             -- "Speaker 1", "Speaker 2", ...
  custom_name TEXT,                -- user-renamed, nullable
  color_hex TEXT NOT NULL          -- assigned at creation, persistent
);

CREATE TABLE segments (
  id INTEGER PRIMARY KEY,
  meeting_id TEXT NOT NULL REFERENCES meetings(id),
  speaker_id TEXT NOT NULL REFERENCES speakers(id),
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL,
  text TEXT NOT NULL,
  words_json TEXT                  -- [{w, start_ms, end_ms}, ...]
);

CREATE VIRTUAL TABLE segments_fts USING fts5(text, content='segments', content_rowid='id');
```

Triggers keep `segments_fts` in sync.

### LocalServer (Swift, Swifter)

Picks a free TCP port at startup, passes URL to WebView.

Routes:

| Method | Path | Purpose |
|---|---|---|
| GET | `/` | React `index.html` |
| GET | `/assets/*` | Static React bundle |
| GET | `/api/meetings` | List with id, started_at, duration, first segment preview |
| GET | `/api/meetings/:id` | Full meeting + speakers + segments |
| GET | `/api/meetings/:id/progress` | SSE stream of transcription progress |
| GET | `/api/meetings/:id/video` | Video file with HTTP Range support |
| GET | `/api/meetings/:id/audio` | Audio file with Range support |
| GET | `/api/meetings/:id/transcript.txt` | Formatted transcript for clipboard |
| POST | `/api/meetings/:id/speakers/:speakerId/rename` | Body: `{name: string}` |
| GET | `/api/search?q=…` | FTS5 across all segments, returns matches with meeting context |

Transcript text format (single source of truth, used by Copy button):

```
[00:00:12] Speaker 1: Hi everyone, thanks for joining.
[00:00:18] Speaker 2 (Misha): Yeah, let's start with the metrics.
```

### MenuBarController (Swift, AppKit)

- `NSStatusItem` with a small recording-dot icon
- Click opens an `NSPopover` containing:
  - `● Start Recording` button (or `■ Stop ─ 00:12:34` while recording)
  - `Open Library` button
  - Footer status: idle / recording / transcribing meeting "<id>" — N%
- Library button creates/raises a single `NSWindow` hosting `WKWebView` pointed at the local server

### React app (Vite + TypeScript, 3mpq monochrome design system)

Routes (client-side via React Router):

- `/` — **Library**
  - Top bar: search input (FTS5 backed)
  - List of meetings: date · duration · first transcript line as preview
  - Click → `/meeting/:id`

- `/meeting/:id` — **Meeting view**
  - Top: HTML5 `<video>` element pointing at `/api/meetings/:id/video`
  - Below or aside: scrollable transcript pane
    - Each segment: `[mm:ss] [Speaker chip] text…`
    - Active segment is highlighted as `<video>.currentTime` advances
    - Click any word → set `<video>.currentTime`
    - Speaker chip is clickable: opens inline rename input
    - Speaker chip has an "isolate" icon — toggling it filters playback to only that speaker's segments via sequential `currentTime` jumps (when the current segment ends, jump to the next one belonging to the isolated speaker)
  - Top-right: `Copy full transcript` button — fetches `/api/meetings/:id/transcript.txt`, writes to clipboard

UI styling done by the **3mpq-soldier subagent** during implementation, monochrome black-and-white aesthetic matching Grain's information density.

## Data flow

1. User clicks **Start Recording** → `CaptureEngine` starts `SCStream`, creates `meetings` row with status=`recording`
2. User clicks **Stop** → stream closes, files flushed, status=`transcribing`, `TranscriptionPipeline` enqueued
3. Pipeline runs (VAD → ASR → diarization → DB writes), progress events streamed via SSE
4. On completion: status=`ready`, native notification "Meeting ready", click opens Library on `/meeting/:id`
5. User reviews transcript, optionally renames speakers, clicks **Copy full transcript** → pastes into Claude chat for summary

## Error handling

| Failure | Behavior |
|---|---|
| Screen recording permission missing | Modal with deeplink to System Settings → Privacy → Screen Recording |
| Microphone permission missing | Same |
| Models not downloaded | First-run setup screen with download progress, blocks recording until done |
| Disk free < 5 GB | Warning before starting; soft block at < 1 GB |
| Recording crashes mid-session | File is still on disk; row marked `failed`, library shows it with "Retry transcription" |
| Transcription crashes | Status=`failed`, retry button in UI; raw audio preserved |
| Port allocation fails | Retry on different ports up to 10 times; show error if all fail |

## Testing

- **Swift unit tests** (XCTest): GRDB schema migrations, transcript text formatter, HTTP Range parser, segment FTS5 ingest
- **Manual integration**: record real Zoom call (3+ speakers), verify transcription quality and diarization correctness
- **React smoke test**: 3mpq-soldier subagent reviews final UI; no automated suite for v1
- **Permissions matrix**: cold-start with permissions denied, partially granted, fully granted

## Stack

| Layer | Technology |
|---|---|
| App shell | Swift 5.9 + AppKit (macOS 13+) |
| Capture | ScreenCaptureKit |
| ASR | sherpa-onnx + whisper-medium-int8 ONNX |
| VAD | sherpa-onnx + Silero VAD |
| Diarization | sherpa-onnx + 3D-Speaker embedding + agglomerative clustering |
| Database | GRDB.swift (SQLite + FTS5) |
| HTTP server | Swifter |
| WebView | WKWebView |
| Frontend | Vite + React + TypeScript |
| Design system | 3mpq monochrome |
| Build | Xcode + npm; `npm run build` outputs to `Corder/Resources/web/` |

## File layout (project)

```
/Users/3mpq/Corder/
├── Corder.xcodeproj
├── Sources/
│   ├── App/                        # AppDelegate, menu bar, windows
│   ├── Capture/                    # CaptureEngine
│   ├── Transcription/              # Pipeline, sherpa-onnx wrappers
│   ├── Storage/                    # GRDB models, migrations
│   ├── Server/                     # Swifter routes
│   └── Shared/                     # DTOs shared with frontend (codegen-friendly)
├── Web/                            # Vite + React app
│   ├── src/
│   ├── package.json
│   └── vite.config.ts
├── Resources/
│   └── web/                        # Built React bundle (gitignored, copied at build)
├── Scripts/
│   ├── build-web.sh
│   └── package-app.sh
├── docs/
│   └── superpowers/specs/
│       └── 2026-04-30-corder-design.md
└── README.md
```

## Runtime file layout

```
~/Library/Application Support/Corder/
├── corder.db
├── models/
│   ├── whisper-medium-int8.onnx
│   ├── silero-vad.onnx
│   └── 3dspeaker-embedding.onnx
└── recordings/
    └── <meeting-uuid>/
        ├── video.mov
        └── audio.wav
```

## Open questions (none blocking)

- Which Russian-friendly Whisper model variant to default to (medium vs large) — settled at medium-int8 for speed; can be made configurable later
- Whether to bundle ONNX models in the app or always download — chose download to keep app size sane (~50 MB vs 2 GB)

## Next step

Hand off to `writing-plans` skill to produce a phased implementation plan with concrete tickets.
