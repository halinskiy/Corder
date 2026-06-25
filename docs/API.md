# Local HTTP API

The Swift backend runs a Swifter HTTP server on `127.0.0.1:<random-port>`
that serves the React frontend bundle and a JSON API. Every endpoint
below is reachable only from localhost, with no authentication; the
trust boundary is the macOS user account.

> **CSRF Origin guard.** A `server.middleware` rejects any
> state-changing request (POST / PUT / PATCH / DELETE) whose `Origin`
> header is present AND is not loopback, with a `403 Forbidden`. Loopback
> means exactly `http://127.0.0.1`, `http://localhost`, or `http://[::1]`,
> optionally followed by `:` + port (the next char must be `:` or
> end-of-string, so `http://127.0.0.1.evil.com` is NOT treated as
> loopback). GET / HEAD, requests with no `Origin` (native / MCP
> clients), and loopback-Origin requests (the WKWebView app's own
> traffic) all pass. This closes cross-site POSTs from a browser tab to
> `start` / `stop` / `archive` / etc. while the local port is up.

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
| GET    | `/avatar.jpg` · `/icon.svg` · `/favicon.ico` | Bundled web-root files. |

`serveAsset` and `serveRoot` are path-traversal-safe: the resolved
target URL is `standardizedFileURL`'d and must stay contained under the
assets / web root (`target.path.hasPrefix(base.path + "/")`), else
`404`. Before this guard, a `:path` segment like
`..%2f..%2fetc%2fpasswd` (Swifter splits then percent-decodes) could
read any user-readable file, including `~/.config/corder/dropbox.json`
with the Dropbox `app_secret` + refresh token.

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
| GET    | `/api/meetings/:id/audio.m4a`           | Audio mix as compressed AAC `.m4a` (~10× smaller than the raw 32-bit `audio.wav`). Built on demand by `MediaExporter`, cached. |
| GET    | `/api/meetings/:id/video`               | `video.mov` when present (Range supported). Silent screen video; used by the in-app preview player, not offered as a standalone download. |
| GET    | `/api/meetings/:id/video-audio.mp4`     | The silent `video.mov` muxed WITH the mixed audio into one `.mp4`. Video is passthrough (no re-encode); only the audio is AAC-encoded. Built on demand by `MediaExporter`, cached. |
| GET    | `/api/meetings/:id/bundle.zip`          | ZIP of audio + video + transcript.* |
| POST   | `/api/meetings/:id/rename`              | Body `{title: string|null}`. Empty/`null` clears to the auto/date label. |
| POST   | `/api/meetings/:id/retranscribe`        | Optimistically flips status to `transcribing`, clears segments, enqueues pipeline. |
| POST   | `/api/meetings/:id/cancel-transcription`| Cancels in-flight pipeline task; flips status to `failed`. |
| POST   | `/api/meetings/:id/summarize`           | Returns `{summary}` (cached or generated on demand). |
| POST   | `/api/meetings/:id/expected-speakers`   | Body `{count: int|null}`. `null` = auto, `0` = "just me", positive = pin. |
| POST   | `/api/meetings/:id/segments/:segid/text`    | Body `{text}`. Right-click edit of one transcript line. |
| POST   | `/api/meetings/:id/segments/:segid/speaker` | Body `{speaker_id}`. Reassign a line; target speaker must belong to the meeting. |
| POST   | `/api/meetings/:id/speakers/:sid/merge`     | Body `{into}`. Fold a speaker's lines into another, drop the source. |
| GET    | `/api/calendar/upcoming`                    | `{connected, events: UpcomingEvent[]}`. Served from the opt-in Google Calendar cache. |
| POST   | `/api/calendar/connect`                     | Opens the incremental Google Calendar OAuth (separate from sign-in). |
| POST   | `/api/meetings/:id/pin` · `/unpin`      | Pin/unpin; pinned sort to a top group. |
| POST   | `/api/meetings/:id/archive` · `/restore`| Soft-archive / un-archive (7-day bin). |
| GET    | `/api/archive`                          | `{items: ArchivedMeeting[]}` with `purge_at`. |
| GET    | `/api/meetings/:id/last-error`          | `{error: string|null}` — last quota / billing / parse error. |
| POST   | `/api/meetings/:id/speakers/:sid/rename`| Body `{name: string|null}`.        |

`POST /api/meetings/:id/summarize` accepts an optional `?force=1`
query parameter that bypasses the on-disk cache and re-asks Gemini
for a fresh Granola-style structured-markdown summary. Without
`force=1`, an existing summary is returned as-is (and the prompt
isn't even loaded). The `auto_summary` setting in `/api/settings`
controls whether the transcription pipeline runs `summarize`
automatically as soon as the transcript is ready.

### `MeetingSummary`

```ts
{
  id: string;                  // uuid
  started_at: number;          // ms epoch
  ended_at?: number;
  duration_ms?: number;
  status: "recording" | "transcribing" | "ready" | "failed";
  title?: string | null;       // auto-generated headline
  preview?: string;            // first segment text (sidebar preview)
  speaker_count: number;       // unique speakers across segments
  speaker_names?: string;      // " · " join of names of who spoke
  pinned?: boolean;
  // False = user hasn't opened this meeting in `.ready` state yet.
  // Drives the gold "unseen" title in the sidebar and Dashboard
  // Recent. Stamped to true the first time the user fetches the
  // detail endpoint on a ready row.
  viewed?: boolean;
}
```

### `MeetingDetail`

```ts
{
  id: string;
  started_at: number;
  duration_ms?: number;
  status: MeetingStatus;
  title?: string | null;
  summary?: string | null;       // structured markdown (or legacy prose)
  speakers: SpeakerDTO[];
  segments: SegmentDTO[];
  expected_other_speakers?: number | null;
  has_video?: boolean;
  // 0…1 real per-chunk transcription progress while status ===
  // "transcribing"; null otherwise. Drives the Stop-transcription
  // progress fill. Now reported for BOTH the on-device model and cloud
  // (Groq / whisper) transcription: WhisperTranscriber reports progress
  // as each chunk finishes, fed through TranscriptionProgressStore.
  transcribe_progress?: number | null;
}

SpeakerDTO  { id, label, custom_name, color_hex }
SegmentDTO  { id, speaker_id, start_ms, end_ms, text, text_boost }
```

## Recording state

| Method | Path                       | Body                                  |
| ------ | -------------------------- | ------------------------------------- |
| GET    | `/api/recording/state`     | `{active: bool, meeting_id?, started_at_ms?, stopping?}` |
| POST   | `/api/recording/start`     | Triggers `RecordingController.startRecording(source: .fullDisplay)`. Used by the global hotkey and the menu-bar popover (the in-window inline recording indicator was removed). |
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
  // ISO 639-1 code. The backend stores any string and still accepts
  // one, but as of 0.14.57 the INTERFACE is English-only: the UI
  // LangPicker was removed and i18n ships `en` only, so this field is
  // effectively dormant on the client (native `AppLanguage` defaults to
  // `en`). NOTE: this is the interface language, NOT transcription;
  // spoken-audio language stays fully multilingual via the separate
  // TRANSCRIPTION_LANGS picker in Settings (Auto-detect default).
  language?: string;
  vocabulary?: string;       // domain terms fed into the transcription prompt
  gemini_key?: string;       // write-only: POST to set; never echoed back by GET
  gemini_key_set?: boolean;  // read-only: whether a key is on disk
  // Functional toggles. Absent on POST ⇒ unchanged. Default true.
  notifications?: boolean;
  capture_video?: boolean;   // screen video.mov (mic+system audio is always on)
  capture_audio?: boolean;   // server-side master; not surfaced as a UI toggle
  auto_transcribe?: boolean; // off ⇒ recording kept .ready, transcribe on demand
  auto_title?: boolean;
  // When true (default), after auto-transcribe completes the pipeline
  // also asks Gemini for a structured-markdown summary and persists it
  // on the meeting row. Frontend Summary tab then renders cached.
  auto_summary?: boolean;
  auto_chapters?: boolean;
  // Opt-in, default OFF (absent ≡ off): telemetry, launch_at_login, and
  // stats_enabled. stats_enabled shows the Dashboard statistics card.
  // (The Statistics settings block was removed from the Settings UI.)
  telemetry?: boolean;
  launch_at_login?: boolean;
  stats_enabled?: boolean;
  // Silent pre-roll: start capturing the instant a call is detected so
  // accepting the record offer keeps audio/video from the very start.
  // Default ON; the buffer is silent and discarded the moment the user
  // declines the offer.
  preroll?: boolean;
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

Non-admin users have no ASR provider picker: they transcribe through
Groq Whisper (cloud) or the on-device WhisperKit model only. A
`transcription_provider` of `gemini` or `whisper` (OpenAI whisper-1) is
ADMIN-ONLY; a non-admin POST that pins one is coerced back to the
tier-driven default (Groq for paid, on-device for free). The model
picker is hidden for non-admins in the Settings UI. Transcription keys
are not read from disk and never echoed; every cloud call goes through
the Cloudflare Worker with the user's Supabase JWT.

### Cloudflare Worker (`corder-api`) hardening

The proxied cloud endpoints live in the Worker, not this server, but the
client depends on their contract:

- **`gemini-proxy` (`generateContent`).** A non-text part
  (`inline_data` / `inlineData` audio, or `fileData` / `fileUri`) now
  counts as admin-only transcription (`generateContentNeedsPaid`),
  closing an `inlineData` bypass where a non-admin could inline base64
  audio for free unmetered Gemini transcription. The model is pinned to
  the Flash models the app uses (`gemini-2.5-flash` +
  `gemini-2.5-flash-lite`); a free user can no longer request
  `gemini-2.5-pro`. Plus a 2 MB body cap. (Summary / Chapters stay FREE
  for all tiers by product decision; the text-only paywall is
  intentionally NOT enforced.)
- **`whisper-cleanup` (gpt-4o-mini punctuation polish).** Now pins
  `model=gpt-4o-mini`, caps `max_tokens` (16384), and strips `tools`; it
  was an unmetered, un-admin-gated passthrough to OpenAI
  chat/completions with a client-controlled model/body.
- **`/submit-logs` (unauthenticated).** Per-IP rate limit (8/hour, via
  the usage D1 table with a synthetic key), field-length caps, and
  GitHub-label sanitization on the client-controlled `app_version`.

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
