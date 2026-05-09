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
| GET    | `/api/meetings/:id/audio`               | `audio.wav` (Range supported).     |
| GET    | `/api/meetings/:id/video`               | Reserved (videos are not currently produced). |
| POST   | `/api/meetings/:id/retranscribe`        | Optimistically flips status to `transcribing`, clears segments, enqueues pipeline. |
| POST   | `/api/meetings/:id/cancel-transcription`| Cancels in-flight pipeline task; flips status to `failed`. |
| POST   | `/api/meetings/:id/expected-speakers`   | Body `{count: int|null}`. `null` = auto, `0` = "just me", positive = pin. |
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
  boost_mode: boolean;
  language?: "ru" | "en";
  transcription_provider?: "whisper" | "gemini-flash";
}
```

The provider toggle has no UI right now (default is `gemini-flash`).
Power users flip it via `defaults write com.3mpq.Corder
Corder.transcriptionProvider whisper`. The DTO field exists so the
endpoint can stay forward-compatible with a future toggle.

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
