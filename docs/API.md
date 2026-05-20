# Local HTTP API

The Swift backend runs a Swifter HTTP server on `127.0.0.1:<random-port>`
that serves the React frontend bundle and a JSON API. Every endpoint
below is reachable only from localhost, with no authentication — the
trust boundary is the macOS user account.

> All bodies are JSON unless otherwise noted. Field names are
> `snake_case` on the wire. DTO definitions live in
> `Sources/Corder/Server/DTOs.swift`; matching TS interfaces in
> `Web/src/api.ts`.

## Static

| Method | Path                | Notes                                       |
| ------ | ------------------- | ------------------------------------------- |
| GET    | `/`                 | Serves `index.html` from the bundled web.   |
| GET    | `/index.html`       | Same.                                       |
| GET    | `/assets/:path`     | Bundled web assets (JS / CSS).              |

## Meetings

| Method | Path                                    | Returns / Body                     |
| ------ | --------------------------------------- | ---------------------------------- |
| GET    | `/api/meetings`                         | `MeetingSummary[]`                 |
| GET    | `/api/meetings/:id`                     | `MeetingDetail`                    |
| DELETE | `/api/meetings/:id`                     | `200 OK`. Hard delete + Dropbox cleanup. |
| GET    | `/api/meetings/:id/transcript.txt`      | Plain text transcript.             |
| GET    | `/api/meetings/:id/transcript.md`       | Markdown transcript (title + speaker-grouped). |
| GET    | `/api/meetings/:id/transcript.json`     | JSON transcript (segments + speakers). |
| GET    | `/api/meetings/:id/audio`               | `audio.wav` (Range supported).     |
| GET    | `/api/meetings/:id/video`               | `video.mov` when present (Range supported). |
| GET    | `/api/meetings/:id/bundle.zip`          | ZIP of audio + video + transcript.* |
| POST   | `/api/meetings/:id/rename`              | Body `{title: string|null}`. Empty/`null` clears to the auto/date label. |
| POST   | `/api/meetings/:id/retranscribe`        | Optimistically flips status to `transcribing`, clears segments, enqueues pipeline. |
| POST   | `/api/meetings/:id/cancel-transcription`| Cancels in-flight pipeline task; flips status to `failed`. |
| POST   | `/api/meetings/:id/summarize`           | Returns `{summary}` (cached or generated on demand). |
| POST   | `/api/meetings/:id/expected-speakers`   | Body `{count: int|null}`. `null` = auto, `0` = "just me", positive = pin. |
| POST   | `/api/meetings/:id/pin` · `/unpin`      | Pin/unpin; pinned sort to a top group. |
| POST   | `/api/meetings/:id/archive` · `/restore`| Soft-archive / un-archive (7-day bin). |
| GET    | `/api/archive`                          | `{items: ArchivedMeeting[]}` with `purge_at`. |
| GET    | `/api/meetings/:id/last-error`          | `{error: string|null}` — last quota / billing / parse error. |
| POST   | `/api/meetings/:id/speakers/:sid/rename`| Body `{name: string|null}`.        |

### `MeetingSummary`

```ts
{
  id: string;                  // uuid
  started_at: number;          // ms epoch
  ended_at?: number;
  duration_ms?: number;
  status: "recording" | "transcribing" | "ready" | "failed";
  preview?: string;            // first segment text (sidebar preview)
  speaker_count: number;       // unique speakers across segments
  speaker_names?: string;      // " · " join of names of who spoke
}
```

### `MeetingDetail`

```ts
{
  id: string;
  started_at: number;
  duration_ms?: number;
  status: MeetingStatus;
  speakers: SpeakerDTO[];
  segments: SegmentDTO[];
  expected_other_speakers?: number | null;
}

SpeakerDTO  { id, label, custom_name, color_hex }
SegmentDTO  { id, speaker_id, start_ms, end_ms, text, text_boost }
```

## Recording state

| Method | Path                       | Body                                  |
| ------ | -------------------------- | ------------------------------------- |
| GET    | `/api/recording/state`     | `{active: bool, meeting_id?, started_at_ms?, stopping?}` |
| POST   | `/api/recording/start`     | Triggers `RecordingController.startRecording(source: .fullDisplay)`. Used by the global hotkey and the in-page inline blob. |
| POST   | `/api/recording/stop`      | Triggers `RecordingController.stopRecording()`. |

The frontend polls `/api/recording/state` once per second to drive the
live RecordingBanner card. The state is read through the lock-protected
`RecordingStateSnapshot` mirror — Swifter handlers don't need to hop
to `MainActor`.

## Settings

| Method | Path                | Body                                            |
| ------ | ------------------- | ----------------------------------------------- |
| GET    | `/api/settings`     | `Settings`                                      |
| POST   | `/api/settings`     | `Settings` — partial updates accepted; returns the merged result. |

```ts
Settings {
  language?: "ru" | "en";
  vocabulary?: string;       // domain terms fed into the transcription prompt
  gemini_key?: string;       // write-only: POST to set; never echoed back by GET
  gemini_key_set?: boolean;  // read-only: whether a key is on disk
  // Functional toggles. Absent on POST ⇒ unchanged. Default true.
  notifications?: boolean;
  capture_video?: boolean;   // screen video.mov (mic+system audio is always on)
  capture_audio?: boolean;   // server-side master; not surfaced as a UI toggle
  auto_transcribe?: boolean; // off ⇒ recording kept .ready, transcribe on demand
  auto_title?: boolean;
  meeting_whitelist?: string[]; // bundle ids: always offer to record
  meeting_blacklist?: string[]; // bundle ids: never offer
  detected_mic_apps?: string[]; // read-only: recent mic owners (UI picker)
  // Global record hotkey. Write Carbon key code + Carbon mod mask
  // (cmd 256 | shift 512 | option 2048 | ctrl 4096). Default ⌘⇧F.
  record_hotkey_code?: number;
  record_hotkey_mods?: number;
  record_hotkey_label?: string;       // read-only e.g. "⇧⌘F"
  record_hotkey_conflict?: string|null; // read-only: clashing macOS system shortcut
  record_hotkey_ok?: boolean;         // read-only: OS accepted the binding
}

`GET /api/installed-apps` → `[{ bundle, name, recent }]` (apps for the
auto-detect picker; `recent` = seen on the mic lately).
`GET /api/app-icon/:bundle` → 64 px PNG icon for that bundle.
```

Gemini is the only provider — there is no provider toggle. The key is
write-only over this endpoint and is stored at
`~/.config/corder/gemini_key` (mode 0600); GET only reports whether one
is set.

## Sparkle / Updater

| Method | Path                  | Returns / Body                      |
| ------ | --------------------- | ----------------------------------- |
| GET    | `/api/update-status`  | `{state: "idle"|"checking"|"available"|"downloading"|"ready"|"error", target_version?, error?}` |
| POST   | `/api/update-check`   | Forces an immediate Sparkle feed check; updates `update-status`. |

The update pill in the title bar polls `/api/update-status`; clicking
it calls `/api/update-check`. The feed URL itself lives in
`Info.plist → SUFeedURL`.

## Search

| Method | Path                   | Returns                         |
| ------ | ---------------------- | ------------------------------- |
| GET    | `/api/search?q=:term`  | `SearchHit[]`                   |

```ts
SearchHit { meeting_id, segment_id, start_ms, text }
```

Powered by SQLite FTS5 (`segments_fts` virtual table). Triggers in
the v1 migration keep it in sync with `segments`.

## Notes for backend hackers

- Swifter handlers run on a Swifter-managed background pool. Anything
  that touches `MainActor` state (RecordingController, CaptureEngine,
  TranscriptionPipeline) has to hop via `Task { @MainActor in ... }`.
- The `audio` endpoint supports HTTP Range. When the local file has
  been Dropbox-archived and is gone, the handler proxies bytes from a
  Dropbox `temporary_link` with the correct `Content-Type`. **This
  blocks a Swifter worker thread** for the duration of the proxy via
  `DispatchSemaphore.wait()` — known limitation, see ARCHITECTURE.md.
- `retranscribe` flips the status row synchronously before enqueuing
  the actual pipeline so the UI sees `transcribing` on the very next
  GET.
- `cancel-transcription` calls `Task.cancel()` and writes `failed` to
  the DB synchronously; the in-flight pipeline can still run for a
  few seconds but won't write more rows because the next
  `try Task.checkCancellation()` will throw.
- Errors that surface to the user (Gemini quota, billing, parse
  failures) are stored in the lock-protected `TranscriptionErrors`
  map and read via `/api/meetings/:id/last-error`. The frontend polls
  this when a meeting goes to `failed`.

## What's deliberately not in the API

- No auth, ever — see Security model.
- No batch endpoints (`POST /api/meetings/batch-delete`) — the UI
  doesn't need them and they invite footguns.
- No WebSocket / SSE — polling at 1 Hz is enough for the cardinality
  of a personal recorder. If we ever add live partial transcripts
  during recording, that's the moment to revisit.
- No GraphQL. Three endpoints would be GraphQL by accident, the rest
  REST by accident.
