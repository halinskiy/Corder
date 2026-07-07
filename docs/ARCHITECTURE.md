# Architecture

> Live source-of-truth. Update when adding modules / endpoints / pipeline
> stages. The high-level shape changes rarely; flip from "what" to "why"
> when in doubt — the code already shows "what".

## Process model

Corder is a single executable, run as a status-bar app
(`LSUIElement = true`, no Dock icon by default; `setActivationPolicy(.regular)`
flips temporarily for permission prompts and the Library window).

Inside the process there are four independent runtime concerns that
communicate via shared state in `AppContext`:

1. **Capture loop** — `CaptureEngine` driven by ScreenCaptureKit
   callbacks (system audio) + AVAudioEngine input tap (microphone).
2. **HUD pill** — `RecordingHUDPanel` (NSPanel, all Spaces). Renders a
   real-time frequency-spectrum equalizer fed by `RecordingLevelMeter`.
3. **HTTP server** — Swifter, serves the React frontend + JSON API on
   `http://127.0.0.1:<random-port>/`.
4. **UI** — SwiftUI popover (status-bar) + AppKit `NSWindow` hosting a
   WKWebView that loads the local server URL.

```
┌──────────────────── Status-bar ────────────────────┐
│ MenuBarController  ─▶  PopoverContentView          │
│        │                                           │
│        ▼                                           │
│ RecordingController ◀──────────────────────────┐   │
└────────│───────────────────────────────────────│───┘
         │                                       │
         ▼                                       │
┌──────── CaptureEngine ─────────────────┐       │
│ SCStream (SKIPPED in audio-only mode): │       │
│   .screen  →  video.mov (H.264/BGRA)   │       │
│   .audio   →  system_sck.wav DROPPED    │       │
│              (0.15.22, was dead silence) │       │
│ Core-Audio tap → system.wav (primary)  │       │
│ AVAudioEngine:                         │       │
│   default input →  mic.wav             │       │
│ Both → RecordingLevelMeter (HUD)       │       │
└───────────────│────────────────────────┘       │
                ▼                                │
┌──────── TranscriptionPipeline ─────────┐       │
│ Cache check (audio MD5)                │       │
│   hit  → reuse gemini_raw_turns        │       │
│   miss + dual tracks (real call):      │       │
│     EchoSuppressor on mic.wav first     │       │
│     async let micPart  (mode=.single)  │       │
│     async let sysPart  (mode=.diarize) │       │
│   miss + mix only:                     │       │
│     legacy single-stream + channel-gate│       │
│ Auto-split on JSON truncation (depth 3)│       │
│ mapDualTrackTurns / mapTurnsToSpeakers │       │
│ Hallucination filter                   │       │
│ BoostService (Gemini 2.5 Pro, optional)│       │
│ DropboxService (optional, archive)     │       │
└───────────────│────────────────────────┘       │
                ▼                                │
┌──────── GRDB / SQLite ─────────────────┐       │
│ meetings, speakers, segments           │───────┘
└───────────────│────────────────────────┘
                ▼
┌──────── HTTP server ───────────────────┐
│ Swifter on 127.0.0.1:<random>          │
│ /api/meetings, /:id, /:id/audio        │
│ /:id/audio.m4a, /:id/video-audio.mp4   │
│ /api/archive, /:id/{archive,restore}   │
│ /api/recording/state (polled by UI 1Hz)│
└───────────────│────────────────────────┘
                ▼
┌──────── WKWebView library ─────────────┐
│ Vite/React app (built into Resources)  │
│ Sidebar │ TranscriptPane │ RightPanel  │
│ Modal: ArchiveView                     │
└────────────────────────────────────────┘
```

## Modules (Sources/Corder/)

```
App/                Entry point, app delegate, recording state machine
├ CorderApp.swift           NSApplication boot
├ AppDelegate.swift         lifecycle, menu, server start, prewarm,
│                           purgeExpiredArchive() on launch (>7 d),
│                           duplicate-instance kill.
│                           Launch recovery (stuck + failed-retriable
│                           meetings) enqueues SEQUENTIALLY (awaits each)
│                          , two whisperLocal model loads racing Core
│                           ML/Metal was a documented SIGABRT.
├ AppContext.swift          shared state (singleton); AppSettings
│                           UserDefaults-backed enum (sync, thread-safe);
│                           BoostMode / AppLanguage / AppVocabulary;
│                           TranscriptionErrors + MicAppsSnapshot
│                           lock-protected mirrors
├ RecordingController.swift @MainActor state machine (idle/recording/
│                           stopping); shows + hides RecordingHUDPanel;
│                           orchestrates CaptureEngine + DB; produces
│                           the playback `audio.wav` mix synchronously
│                           on stop when auto-transcribe is OFF (the
│                           normal `transcribe()` path never runs)
├ RecordingLevelMeter.swift ObservableObject fed by capture taps;
│                           sqrt-scaled peak + a real FFT frequency
│                           spectrum (`spectrum`, 11 log-spaced bands)
│                           with per-band AGC and SEPARATE mic / system
│                           envelopes published as a per-band max (so the
│                           high-rate system tap can't wash out the mic);
│                           30 Hz publish; drives the HUD equalizer
├ MeetingDetector.swift     per-process default-input owner detector
│                           (kAudioProcessPropertyIsRunningInput);
│                           respects whitelist/blacklist from AppSettings
│                           and publishes MicAppsSnapshot for the UI
├ NetworkMonitor.swift      reachability for Gemini calls
├ Notifications.swift       UNUserNotificationCenter wrapper
├ SleepWatchdog.swift       wakes the audio engine on sleep events
├ FileLogger.swift          /tmp/corder.log appender (NSLog dual-write)
└ UpdateController.swift    Sparkle 2 wrapper (hand-built SPUUpdater)

Update/
├ CorderUpdateDriver.swift  custom SPUUserDriver — drives the React
│                           update modal via UpdateBridge; terminates
│                           the host in ONE place (showInstallingUpdate)
│                           so the install never double-terminates.
└ UpdateBridge.swift        Swift↔WebView glue for the update modal
                            (push state, route primary/dismiss actions).

Capture/
├ CaptureEngine.swift       SCStream wiring (.screen video, H.264 on
│                           32BGRA input, height-capped at 720p by
│                           default / 4K for signed-in high-res, bitrate
│                           scaled with height; the .audio → system_sck.wav
│                           BT backup was DROPPED in 0.15.22 — dead silence),
│                           AVAudioEngine.installTap on default input
│                           for mic (4-attempt init retry around the
│                           -10868 audio-device-change failure),
│                           Core-Audio process tap for system.wav
│                           (primary). In audio-only mode (video off,
│                           non-BT) SCStream is SKIPPED entirely (it
│                           used to capture the whole screen even with
│                           video off, the real recording-heat source).
│                           AVAssetWriter.movieFragmentInterval = 3s so
│                           a crash/power-loss mid-recording leaves a
│                           recoverable partial video.mov (fragmented,
│                           remuxed to faststart on first play by
│                           VideoRemux; a faststart writer left 0 bytes).
│                           `tearingDown` flag latched at stop so a
│                           late tap/SCK buffer can't reopen-truncate
│                           the just-finished WAV.
├ SystemAudioTap.swift      Core-Audio process tap + private
│                           aggregate device; opens lazily on first
│                           buffer, format taken from the tap
└ PermissionsChecker.swift  TCC: screen + mic; opens System Settings

Transcription/
├ TranscriptionPipeline.swift  Pipeline driver. Holds activeTasks for
│                              cancellation; cache check (MD5);
│                              dual-track fork (.single + .diarize in
│                              parallel) vs legacy single-stream;
│                              mapDualTrackTurns / mapTurnsToSpeakers;
│                              auto-boost; auto-archive; hallucination
│                              filter
├ GeminiTranscriber.swift   Cloud provider: TranscribeMode { single,
│                           diarize }, VAD pre-pass + concat speech-
│                           only wav, File API upload → poll ACTIVE →
│                           :generateContent; auto-split on JSON
│                           truncation (depth ≤ 3, slice ≥ 70 s);
│                           projects compressed-timeline turns back
│                           onto the original frame
├ VoiceActivityDetector.swift  RMS-gating speech detector + concat
│                              + projection table from compressed
│                              speech-only timeline → original frame
├ Diarizer.swift            Channel-gate (mic_RMS vs system_RMS) for
│                           the legacy single-stream Gemini path only
├ EchoSuppressor.swift      Offline speaker-bleed echo suppression.
│                           When the user records on speakers (no
│                           headphones) the far-end voice bleeds into
│                           mic.wav; this removes it before ASR using
│                           system.wav as the clean reference (FFT
│                           cross-correlation bulk-delay align, then
│                           per-bin coupling + spectral over-subtraction,
│                           frequency-domain / gain-based so it can't
│                           diverge). Self-gating: skips when the
│                           correlation is low (headphones / BT)
└ AudioMixer.swift          16 kHz mono mix; peak-normalised, not /N

Boost/
└ BoostService.swift        Per-segment Gemini 2.5 Pro polish

Cloud/
├ DropboxService.swift      Refresh-token OAuth, chunked upload,
│                           temporary_link proxy
├ SupabaseTierSync.swift    Server tier (app_metadata) -> AppSettings;
│                           refreshTier() on app-active + pollAfterUpgrade
└ GoogleCalendar.swift      Opt-in calendar.readonly OAuth (separate from
                            sign-in, account-pinned), Calendar API fetch,
                            account-scoped cache, Worker token refresh.
                            The pending-connect expiry timer is 900s (15
                            min): a slow Google consent flow (chooser +
                            2FA + unverified-app warning) routinely
                            exceeds 5 min, and the old 300s timer
                            disarmed the identity-mismatch rollback in
                            finishConnectIfPending before the genuine
                            callback landed.

Storage/
├ Database.swift            DatabaseQueue factory + migrations.run
├ Migrations.swift          v1 → v16_viewed_at, append-only
├ Models.swift              Meeting / Speaker / Segment + CodingKeys;
│                           gemini_raw_turns, audio_hash, archived_at
└ MeetingRepository.swift   GRDB read/write, FTS search, listMeetings
                            filtered by archived_at == NULL,
                            listArchived(), setArchived(),
                            archivedOlderThan(),
                            setRawTurnsCache(...) targeted UPDATE,
                            setTranscribeFinished(...) targeted UPDATE
                            of status + transcribed_at only (so pin/
                            title/expected_other_speakers edits made
                            WHILE a row is .transcribing aren't reverted
                            by a full save from a stale snapshot)

Server/
├ LocalServer.swift         Swifter wrapper; binds to 127.0.0.1 on a
│                           random port; reachable only locally
├ Routes.swift              All HTTP routes (see API.md). A
│                           server.middleware CSRF guard rejects
│                           state-changing (POST/PUT/PATCH/DELETE)
│                           requests whose Origin is present AND not
│                           loopback (127.0.0.1 / localhost / [::1],
│                           next char ':' or end so 127.0.0.1.evil.com
│                           is NOT matched); GET/HEAD, no-Origin
│                           (native/MCP) and loopback-Origin (WKWebView)
│                           pass. serveAsset / serveRoot standardize the
│                           resolved URL and require containment under
│                           the assets/web root (hasPrefix base+"/") to
│                           block path traversal.
├ MediaExporter.swift       On-demand download products: audio.wav →
│                           compressed AAC `.m4a` (~10× smaller than the
│                           32-bit WAV), and the silent screen video.mov
│                           muxed WITH the audio into one `.mp4` (video
│                           passthrough, no re-encode; only the audio is
│                           AAC-encoded). Cached in a temp exports dir
├ DTOs.swift                Wire types, snake_case for JSON
├ TranscriptFormatter.swift Clipboard text builder (paragraph mode)
└ RangeRequest.swift        HTTP Range header parser

UI/
├ MenuBarController.swift   NSStatusItem + popover wiring
├ PopoverContentView.swift  SwiftUI popover (idle/recording/stopping)
├ LibraryWindow.swift       NSWindow + WKWebView + JS bridge
│                           (drag, copy, openExternal); contentMinSize
│                           920 x 600 so the three-column layout
│                           (sidebar + transcript + right panel) can't
│                           be crushed
└ RecordingHUDPanel.swift   Floating NSPanel pill; real-time
                            frequency-spectrum equalizer (bars driven by
                            `RecordingLevelMeter.spectrum`, not the old
                            blob) + timer + Stop; .canJoinAllSpaces +
                            .stationary + .nonactivatingPanel. The
                            in-window recording indicator (the embedded
                            blob in the Library window bottom-right) was
                            removed; recording is started/stopped from the
                            menu-bar popover and the in-app button only.

Shared/
└ Paths.swift               AppPaths.* singletons
```

## Data lifecycle

Each meeting has a UUID. All filesystem state for that meeting lives under
`…/accounts/<id>/recordings/<dir>/`. The folder is CREATED as the `<uuid>` and
RENAMED to a human-readable `<yyyy-MM-dd_HH-mm> <title>` (or just the date when
untitled) once the auto-title lands (0.15.29). The name is stored in
`meetings.dir_name` (migration `v23`); `AppPaths.recordingDir(for:)` resolves it
via a launch-loaded index and always prefers a folder that exists on disk, so
`<uuid>` stays a valid fallback. See `Shared/RecordingDirNaming.swift`. After a
successful Dropbox upload, local files are deleted and the SQLite row gets
`dropbox_audio_path` filled in.

```
Recording active:
  recordings/<uuid>/
  ├── system.wav            # SCStream system audio
  └── mic.wav               # AVAudioEngine microphone

Stop pressed → TranscriptionPipeline.enqueue:

  1. AudioMixer.produceMixIfNeeded(system.wav, mic.wav) → mix.wav
     (peak-normalised to 0.98, not /N — preserves dynamic range).
     Used for playback + as the legacy single-stream fallback.

  2. Cache lookup:
       key = "dual:v11:{md5(mic.wav)}:{md5(system.wav)}"  if both exist
       key = "mix:{md5(mix.wav)}"                          otherwise
     (The dual-track key was bumped to v11 when mic.wav started passing
     through EchoSuppressor before ASR: the cleaned mic changes the raw
     text, so the old cache must miss once. A provider tag is also
     prefixed so Groq / Whisper / Gemini raw turns never replay each
     other.)
     If meetings.audio_hash matches and gemini_raw_turns is non-null,
     re-use the raw turns and skip Gemini entirely.

  3. Cache miss path:
       a. Both tracks present, real call (the normal case):
            // Speaker-bleed suppression. On speakers the far-end voice
            // bleeds into mic.wav; EchoSuppressor removes it (system.wav
            // as the clean reference) before ASR. Self-gating: returns
            // nil on a headphone/BT recording, so we fall back to the raw
            // mic and this is a no-op there.
            micURL = EchoSuppressor.suppress(mic, system) ?? mic.wav
            async let micPart = transcribe(audio: micURL,   mode: .single)
            async let sysPart = transcribe(audio: system.wav, mode: .diarize)
            (userTurns, otherTurns) = try await (micPart, sysPart)

       b. Only mix.wav (post-archive of an old row without cache):
            legacyTurns = transcribe(audio: mix.wav, mode: .diarize)

       Each transcribe() call:
         - splits files >9 min into chunks before upload;
         - on JSON truncation it halves the affected chunk and retries
           (recursive, depth ≤ 3, minSlice = 60 s).
       On the on-device path the local model SELF-HEALS a corrupt/partial
       bundle instead of failing the meeting (0.14.72):
       LocalWhisperTranscriber.isModelDownloaded now requires a NON-EMPTY
       weights/weight.bin in each .mlmodelc package, so a model whose weight
       blob never finished re-downloads rather than attempting a doomed load;
       if it loads on BOTH encoders (ANE + GPU) anyway, loadGPU wipes the
       model folder AND its sibling HuggingFace download cache
       (huggingFaceDownloadCacheURL) so a re-download can't resume from the
       same corrupt bytes, and throws modelCorruptWiped; transcribe() catches
       that and re-downloads + retries the load ONCE before giving up.

  4. Mapping:
       Dual-track:
         userTurns  → speakerId = userSpeakerId
         otherTurns → grouped by Gemini label, each label → "other-N"
                       in arrival order
         merged on start_ms.
       Legacy:
         channel-gate (mic vs system RMS) picks which Gemini label is
         the user; others become "other-0", "other-1", …

  5. Hallucination filter drops YouTube-subtitle artefacts.
     The Gemini prompt has an anti-hallucination clause that mostly
     prevents these from appearing in the first place. The live
     insert-time filter uses isHallucination (60% substring); the
     launch-time purge of stored segments uses isExactHallucination
     (whole-segment exact match only), so a real sentence merely
     containing a known pattern is never hard-deleted. Everyday meeting
     sign-offs ("спасибо за внимание", "have a great day", "дякую за
     увагу", ...) were removed from the pattern list, they are not
     YouTube outros.

  6. setRawTurnsCache(meetingId, gemini_raw_turns, audio_hash)
     (targeted UPDATE — does NOT touch status).
     Then INSERT/UPDATE segments/speakers; the mappers finalize the row
     via setTranscribeFinished (targeted UPDATE of status → .ready +
     transcribed_at only), NOT a full updateMeeting() from a stale
     snapshot, so pin/title/expected_other_speakers edits the user made
     while the row was .transcribing survive.

Optional, fire-and-forget after step 6:
  7. BoostService.boostSegments → segments.text_boost
     (only if BoostMode.isEnabled)
  8. DropboxService.upload(mix.wav + mic.wav + system.wav) →
     meetings.dropbox_audio_path; local copies deleted only on
     hard-delete (the archive bin's "Delete forever") — re-transcribe
     needs the originals.
```

## SQLite schema

Migrations are append-only in `Storage/Migrations.swift`.

```sql
-- v1 (initial)
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

-- v2_boost (legacy meeting-level polish; superseded by v3)
ALTER TABLE meetings ADD COLUMN boosted_text TEXT;
ALTER TABLE meetings ADD COLUMN boosted_at   INTEGER;

-- v3_segment_boost (current per-segment polish)
ALTER TABLE segments ADD COLUMN text_boost TEXT;

-- v4_dropbox
ALTER TABLE meetings ADD COLUMN dropbox_video_path  TEXT;
ALTER TABLE meetings ADD COLUMN dropbox_audio_path  TEXT;
ALTER TABLE meetings ADD COLUMN dropbox_uploaded_at INTEGER;

-- v5_expected_speakers
ALTER TABLE meetings ADD COLUMN expected_other_speakers INTEGER;

-- v6_drop_legacy_boost_columns
ALTER TABLE meetings DROP COLUMN boosted_text;
ALTER TABLE meetings DROP COLUMN boosted_at;

-- v7_gemini_raw_cache
ALTER TABLE meetings ADD COLUMN gemini_raw_turns TEXT;  -- serialized turns
ALTER TABLE meetings ADD COLUMN audio_hash       TEXT;  -- "dual:m:s" or "mix:h"

-- v8_archive
ALTER TABLE meetings ADD COLUMN archived_at INTEGER;    -- soft-archive bin

-- v16_viewed_at
ALTER TABLE meetings ADD COLUMN viewed_at INTEGER;      -- ms epoch when the user first opened the .ready meeting
UPDATE meetings SET viewed_at = ended_at
  WHERE viewed_at IS NULL AND ended_at IS NOT NULL;     -- existing rows are "seen" from the user's POV
```

The `boosted_text` / `boosted_at` columns existed from v2 as a
meeting-level prose dump but were replaced in v3 by per-segment
`text_boost` (the prose-dump UI couldn't reuse the timeline, speaker
grouping, or scrub-to-segment). v6 removes them.

`expected_other_speakers` (v5) — user-provided hint from the clarify
banner. `null` = auto-detect, `0` = "just me, skip diarisation", positive
N = pin Gemini's prompt to N other speakers.

`gemini_raw_turns` + `audio_hash` (v7) — raw transcription cache. The
hash format encodes which file(s) were sent so re-transcribing the
same audio (post-archive, post-clarify-banner) costs zero File API calls.

`archived_at` (v8) — soft-archive timestamp. `listMeetings()` filters
`archived_at IS NULL`. `purgeExpiredArchive()` runs on launch and
hard-deletes rows where `archived_at < now − 7 d`.

`viewed_at` (v16) — ms epoch when the user first fetched the
`/api/meetings/:id` endpoint with the row already in `.ready` state.
`MeetingRepository.markViewedIfNew(meetingId:atMs:)` stamps it; the
detail route is the only caller. The sidebar + Dashboard Recent
render the title in `--accent-gold` while `viewed_at IS NULL` for a
ready meeting — that's the "unseen new transcript" affordance. The
v16 migration seeds existing rows with `ended_at` so nothing pre-existing
shows up as "unseen" on first launch after upgrade.

## Cancellation model

`TranscriptionPipeline` keeps `activeTasks: [meetingId: Task<Void, Never>]`.
- `enqueue(meetingId:)` — wraps `transcribe` in a tracked Task.
- `cancel(meetingId:)` — `task.cancel()` + flips meeting to `.failed`
  in the DB **synchronously**, so the UI flips to the failed banner
  immediately. The underlying Gemini call may keep running briefly;
  we ignore its eventual result via the `catch is CancellationError`
  arm in `transcribe`.
- `try Task.checkCancellation()` is sprinkled between stages
  (after each transcribe call, before mapping, before final DB write).

## Diarisation

There are two paths now. Dual-track is the default; the legacy path
exists for archived rows whose original mic/system tracks were already
deleted before the cache was introduced.

### Dual-track (default — when both `mic.wav` and `system.wav` are present)

```
mic.wav   → Gemini, mode=.single
              prompt: "This audio is one person speaking — always
              label them 'Speaker 1'. Never invent additional speakers."
              all turns → userSpeakerId

system.wav → Gemini, mode=.diarize
              prompt: "Identify each distinct speaker and label them
              in arrival order: Speaker 1, Speaker 2, ..."
              turns grouped by label → "other-0", "other-1", …

merge by start_ms.
```

The split eliminates two failure modes that plagued the single-stream
path:

1. **Silence-misattribution.** When the user is quiet but the remote
   side is talking, mixing both tracks asked Gemini to guess from
   prosody alone — and on Russian / English mixed audio it would
   often paste your conversational filler into the friend's column.
2. **Speaker-label drift between chunks.** The single-stream path
   would sometimes reassign labels mid-chunk after a long pause,
   leaving you with "Speaker 1" being two different people. Each
   stream is now homogeneous: mic = always one person, system =
   always not-you.

Cost: ~2× Gemini File API calls on the first transcription. Cached
afterward via `gemini_raw_turns`, so re-runs are free.

**3+ speakers auto-estimate.** Auto-detected calls now start with
`expectedOtherSpeakers = nil` in BOTH `MeetingDetector` paths (was
hardcoded `1`, which collapsed every 3+-person call into a single
"other"). `nil` lets FluidAudio's VBx clustering AUTO-estimate the
count. The clarify banner (`withSpeakers exactly:N`) remains the exact
manual override. The `clusteringThreshold` was measured (offline default
0.6) and is effectively inert across 0.6-0.85, so it is not a tunable.

### Legacy single-stream (fallback for `mix.wav`-only rows)

```
For each Gemini turn [start, end]:

  RMS_mic = rms(mic.wav,    start, end)
  RMS_sys = rms(system.wav, start, end)

  if RMS_mic > 2 * RMS_sys && RMS_mic > 0.005:
      this turn's label → userSpeakerId
  else:
      keep Gemini's label

Per Gemini label, sum total "user-dominant" seconds.
The label with the largest sum that crosses 1.5 s becomes the user;
the rest become "other-0", "other-1", … in sorted order.
```

This path is taken only when the originals are gone (post-archive
without cache). It's also what runs for every row that existed before
v7 added `audio_hash`.

## Gotchas / video

Video IS recorded now (this section used to claim the opposite). The
old `kAudioCodecAudioFormatErr (-16122)` failures came from feeding
`AVAssetWriter` BGRA→YUV-converted samples with an audio input attached;
the working path is **H.264 on 32BGRA input** (the Apple-Silicon H.264
hardware encoder takes BGRA and converts internally), no audio track on
the writer (audio lives in the WAVs). Output height is capped at **720p by
default** to keep recordings small; a **signed-in** user who enables "Record
in high resolution" (Settings → General) gets the display's native size
capped at **4K**, and the bitrate scales with height (~1.4 Mbps at 720p,
~5 Mbps at 4K). Gate: `captureVideoHiresEffective = captureVideoHires &&
isSignedIn`. It is gated by the **Screen video recording** setting; when off
(and not on a BT route) the SCStream is SKIPPED entirely, since registering
`.screen` just to keep the audio clock pacing was the real always-on
recording-heat source. The frontend renders `<audio>` when `has_video=false`.

**Crash-safe partial video (fragmented + serve-time remux, 0.15.21).**
`AVAssetWriter.movieFragmentInterval = 3s` flushes a self-describing
`moof`+`mdat` fragment every 3 s, so a crash / power-loss / app-update kill
mid-recording leaves a RECOVERABLE partial `video.mov` instead of a 0-byte
file (a faststart writer's top-level moov only lands on `finishWriting`). A
fragmented QuickTime MOV can't be progressively loaded by WKWebView, so
`Shared/VideoRemux.swift` remuxes it to faststart LAZILY on first play
(`serveMedia` → passthrough export moving the moov to the front, idempotent,
atomic swap). This gets crash-safety AND WKWebView playback.

## Concurrency model

- `CaptureEngine`, `RecordingController`, `TranscriptionPipeline`,
  `AppContext`, `RecordingLevelMeter` — all `@MainActor`.
- `DropboxService` — `actor`.
- Swifter request handlers run on a Swifter-managed background pool;
  any access to MainActor state hops via `Task { @MainActor in ... }`
  or reads through `RecordingStateSnapshot` (NSLock-protected mirror).
- `TranscriptionErrors` is a lock-protected static dict; safe from
  Swifter handlers and the pipeline alike.
- The two Gemini calls in dual-track run in parallel via `async let`;
  they're independent network jobs, no shared state.

## Known limitations

- **First playback after archival blocks one Swifter worker** while
  the audio file is hydrated from Dropbox to disk via
  `hydrateDropboxFile`. The download itself streams chunks straight
  to disk via `URLSession.download(for:)` (constant memory), but the
  Swifter handler still waits for the full file before serving the
  first byte of the response. This happens at most once per archived
  meeting — subsequent Range requests are served straight from local
  disk without blocking.

- **VAD overshoot on whispered audio.** The RMS gate at -46 dBFS
  (`VoiceActivityDetector.Config.rmsThreshold = 0.005`) covers normal
  conversational levels but trims confidently-whispered speech
  alongside true silence. Whispered meetings are rare; if they become
  a real complaint, lower the threshold or add an ML detector.

## What we deliberately don't do

- **No background sync of past recordings.** Dropbox archival fires only
  for new meetings completed after the integration was added. Old local-only
  recordings stay local until the user re-transcribes them.
- **No multi-window UI.** Single Library window, single popover, single
  HUD pill. Avoids AppKit window-management complexity in an LSUIElement
  app.
- **No auto-launch.** User runs the app manually (or via Sparkle update
  flow). LaunchAgents would require explicit consent UX we haven't built.
- **No user-facing provider picker for ASR.** Non-admin users transcribe
  ONLY through Groq Whisper (cloud) or the on-device WhisperKit model;
  there is no toggle to pick a different cloud model. Gemini and OpenAI
  whisper-1 are admin-only, kept for benchmarking. See the provider-lock
  note below.

## Transcription provider lock

Non-admin users can transcribe through exactly two providers: Groq
Whisper (cloud) and the on-device WhisperKit model. Gemini and OpenAI
whisper-1 are ADMIN-ONLY (for the dev to benchmark). The paid-tier
default is Groq, not Gemini. `AppSettings.isAdmin` is mirrored from the
Supabase JWT `app_metadata.role == "admin"` by `SupabaseTierSync`.

Enforced at four independent layers, so a normal user can never have
Gemini suddenly transcribe:

1. **Client resolver.** `AppSettings.transcriptionProvider` clamps a
   non-admin to `groq` (paid) or `whisperLocal` (free); any other
   resolution collapses to those.
2. **Pipeline fallbacks.** Every Gemini fallback path in
   `TranscriptionPipeline` is gated on `AppSettings.isAdmin`.
3. **Settings handler.** `POST /api/settings` refuses a `gemini` /
   `whisper` provider override from a non-admin (coerces it back to the
   tier default).
4. **Worker.** The Cloudflare Worker (`corder-api`) returns 403 for
   `/transcribe/gemini` and `/transcribe/whisper` from a non-admin.

## Security model

See [`SECURITY.md`](SECURITY.md) for the full policy.
