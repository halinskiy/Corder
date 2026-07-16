# Share links — feature spec (Phase 1)

Status: DRAFT for build, independently reviewed against the codebase (see
"Review corrections applied" at the end). Not released until fully built +
verified on a branch.

## Goal

Add a **share link** to a meeting. Clicking Share opens a modal (the existing
semi-3D login/update modal shell) with a single "Copy link". The link opens a
**public web page** showing the meeting (summary + full transcript + audio
player) and greets the viewer with a "X shared this with you → Download
Corder" CTA. The link auto-expires after 30 days.

Model = Granola's share page, richer: Granola shows summary only; we show the
full transcript + audio. The growth hook (download CTA on the shared page) is
the point.

## Decisions (locked by owner)

- **Audio on the page from v1** (compact mix player).
- **Free for all tiers.** Requires a free sign-in (a public page cannot be
  served from files that live only on the user's Mac).
- **Page = the real Corder frontend** (`Web/src`) built read-only, on
  `share.getcorder.com`.
- **Link lifetime: 30 days**, then auto-deleted.
- **Full transcript public** on the page.

## Export button — REMOVED entirely (owner decision, final)

The old Export (a chooser with separate video / audio / transcript-file /
bundle downloads) is retired. Everything is delivered through the share link.
The share page carries what Export used to: transcript (rendered + a "Copy
transcript" button), audio player, and **video player when the meeting has
video**. A meeting recorded audio-only (Screen video off → `has_video=false`)
simply has no video block on the share page, exactly like the app.

Remove the RightPanel download chooser UI; the Swift routes
(`serveExport`/`transcriptExport`/`bundleZip`, `Routes.swift:753/809/2063`) are
only reached by that chooser (review §6) so they can be dropped too.

## Audio storage — Supabase Storage, no R2, no card (owner decision)

Phase 1 is AUDIO-ONLY. Video needs files in the hundreds of MB, which exceed
Supabase Storage's 50 MB free-tier per-file cap and would force R2 (which
requires enabling R2 + a card). To ship without a card, audio only.

Audio is uploaded as a compact **AAC `.m4a`** produced by the existing
`MediaExporter.exportAudioM4A` (`MediaExporter.swift:60`, ~10× smaller than the
WAV mix). Even a 2-hour meeting m4a (~28 MB) fits Supabase's 50 MB free cap. The
app uploads it to a private Supabase Storage `shares` bucket at
`<uid>/<meeting_id>.m4a` (owner-write via JWT/RLS, same shape as the existing
`uploadRecording`). The Worker, on the public audio route, mints a short-lived
signed URL for it (service role).

## Video — deferred to Phase 1.5 (drop-in)

The `shares` table already carries a `video_key` column. When the owner later
enables R2 + a card, video becomes a drop-in: upload the faststart-remuxed
`video.mov` to R2, set `video_key`, and un-hide the video slot on the share
page. No rework of Phase 1.

## Out of scope (Phase 2)

- Chapters on the share page — VERIFIED blocked: chapters do not sync to
  Supabase (`SupabaseSync` has no chapters table; `MeetingDetail.chapters` is
  local-only, `api.ts:58`). Needs a chapters sync path first.
- "Share a segment / clip" (Grain model, Umberto's ask): audio/video trimming +
  partial transcript.
- Access controls beyond "public with unguessable link".

## Architecture + data flow

```
Mac app (owner, live Supabase session)
  │  Share is enabled only when: live session AND status==.ready AND segments>0
  │  1. AWAITABLE throwing re-push of this meeting to Supabase; verify it landed
  │  2. ensure compact mix audio.wav exists (produce via AudioMixer if missing)
  │  3. upload mix to cloud audio store (reuse the queued R2/Storage path)
  │  4. POST /share/create (JWT) → { token, url }
  ▼
Cloudflare Worker (corder-api)
  │  creates shares row (token, meeting_id, owner_id, owner_name,
  │    audio_key, created_at, expires_at=+30d) via SUPABASE_SERVICE_ROLE
  │  GET /share/<token>  (PUBLIC, no auth):
  │    → 410 if missing or expires_at < now (read-time enforcement)
  │    → else read meetings/speakers/segments/summaries via service key,
  │      scoped ONLY by the token's meeting_id (never a client-supplied id)
  │    → returns JSON + audio via GET /share/<token>/audio (Worker-proxied
  │      stream from the store; NOT a presigned URL)
  │  scheduled() cron nightly: delete expired rows + their audio objects
  ▼
share.getcorder.com  (Web/src, read-only share mode)
  │  fetches GET /share/<token>, renders MeetingView (transcript+summary+audio)
  │  CTA overlay: "{owner_name} shared this with you → Download Corder"
```

## Component specs

### 1. Mac app (Swift + Web/src)

- **`MeetingView.tsx`**: add **Share** as the primary action. Keep Export,
  trimmed to video + transcript-file (see Export section).
- **Share gate**: Share is enabled only when ALL hold:
  - a **live Supabase session** — `SupabaseClientHolder.shared.auth.currentSession`,
    NOT `AppSettings.isSignedIn` (that is a `userEmail != nil` UserDefaults
    mirror, `AppContext.swift:581`, and can diverge → sync no-ops / Worker 401);
  - meeting `status == .ready`;
  - non-empty segments.
  Otherwise Share is disabled (or, signed-out → open the sign-in modal via
  `AuthController`; never-transcribed → "transcribe first").
- **`ShareService` (Cloud/) create-share flow:**
  1. Guard the live session + status + segments.
  2. **AWAITABLE, THROWING re-push** of THIS meeting to Supabase — a new method
     that mirrors the inline chain in `SupabaseSync.backfillIfNeeded`
     (`SupabaseSync.swift:486-576`): `await upsert meeting → await replace
     speakers → await replace segments → await upsert summary`, each an awaited
     `.execute()`, throwing on failure. Do NOT use the existing
     `replaceSpeakersAndSegments`/`setSummary` — they are fire-and-forget
     `Task.detached { try? }` (`SupabaseSync.swift:35-47`) and cannot be awaited
     or verified. This is the load-bearing fix: only proceed if the rows landed.
  3. Ensure `audio.wav` (16k mono) exists; produce via `AudioMixer.produceWhisperInput`
     (`AudioMixer.swift:23`, self-heals headers) if missing. EDGE: a
     Dropbox-archived meeting may have source tracks off-disk — hydrate first or
     block the share with "audio archived". (Low prevalence.)
  4. Upload the mix using the **already-queued audio-to-cloud path**
     (`SupabaseSync.uploadRecording`, `SupabaseSync.swift:339`, currently
     disabled pending R2 at `:343-357`). Reuse its key scheme
     `<uid>/<mid>/<kind>`; do NOT invent a parallel scheme. Turn it on for the
     share path (R2 has no 50 MB cap that disabled it for Supabase Storage).
  5. `POST /share/create` (JWT via `currentSession.accessToken`, as
     `GoogleCalendar.swift:191` does) → `{ token, url }`.
  6. URL to clipboard + shown in the modal.
- **Share modal**: reuse the `.update-card` semi-3D shell. Title, Copy-link,
  the URL, note "Anyone with the link can view. Expires in 30 days." Spinner
  during create (push + upload + Worker call). Offer "Stop sharing" (revoke).

### 2. Supabase

- New table `shares`: `token TEXT PK` (≥128-bit base64url, ~22 chars),
  `meeting_id TEXT`, `owner_id UUID`, `owner_name TEXT`, `audio_key TEXT NULL`,
  `created_at TIMESTAMPTZ`, `expires_at TIMESTAMPTZ`.
- Create/revoke go through the **Worker** (service key). Owner RLS on `shares`
  is optional defense-in-depth, NOT the access path (the app never touches
  `shares` directly).

### 3. Cloudflare Worker (`corder-api/src/index.ts`)

- **NET-NEW infra:** add a `scheduled()` export + `[triggers] crons` (the
  Worker currently exports only `{ async fetch }`, no cron surface). No R2 —
  audio lives in Supabase Storage (no card).
- `POST /share/create` (JWT): verify caller owns meeting_id
  (`select meetings where id=? and user_id=<jwt.sub>` via service key,
  `supaFetch` pattern `index.ts:397-415`), generate token, insert `shares`
  (with `audio_key` = the m4a path the app uploaded), return `{ token, url }`.
  Audio is uploaded by the APP directly to Supabase Storage (owner JWT), so no
  Worker upload route is needed.
- `GET /share/<token>` (PUBLIC): 410 if missing/expired (read-time check);
  else read meetings/speakers/segments/summaries via service key, **every
  sub-query scoped by the token's resolved `meeting_id`**, never a client id;
  return `{ meeting, speakers, segments, summary, owner_name, expires_at,
  audio_url }` where `audio_url` is a short-lived Supabase Storage signed URL
  minted with the service role.
- `scheduled()` cron nightly: delete expired `shares` rows + their Storage
  objects.
- **CORS:** the simple `GET /share/<token>` works under `Access-Control-Allow-Origin: *`
  (`index.ts:78-80`). If `shareApi` ever sends a custom header the browser
  preflights and `corsOrigin()` (`index.ts:106-109`) rejects unknown origins →
  add `https://share.getcorder.com` to `ALLOWED_ORIGINS` (`index.ts:99-104`),
  or keep the share GET header-free.

### 4. Share frontend (`share.getcorder.com`) — concrete gating tasks

`Web/src` is same-origin-coupled in several spots, not one fetch. Read-only
share mode must:
- **Swap audio**: `audioSrc(detail.id)` → the signed/proxied R2 URL
  (`RightPanel.tsx:935`).
- **Hide the whole video slot** (no video in Phase 1): `videoSrc`
  (`RightPanel.tsx:587, 676`) and the `ScreenVideo` block.
- **Hide the download chooser**: `videoWithAudioSrc / audioM4ASrc /
  transcriptSrc / transcriptMdSrc / transcriptJsonSrc / bundleSrc`
  (`RightPanel.tsx:254-264`).
- **Stub `RightPanel`'s own `getSettings()`** mount call (`RightPanel.tsx:47`) —
  it 404s/hangs off the local server.
- **Swap the data source**: `MeetingView` imports `getMeeting` etc. directly
  and calls `getMeeting(meetingId)` in `load()` (`MeetingView.tsx:3, 245`) — a
  module-level swap of `api.ts` for a `shareApi` (single `GET /share/<token>`)
  returning the same shapes; gate off rename/retranscribe/archive + the poll.
- **Web fallbacks for native bridges**: `window.corderCopy`
  (`SummaryPane.tsx:204`, `MeetingView.tsx:38`) → `navigator.clipboard`;
  `window.corderOpenExternal` → `window.open`.
- **CTA overlay** (`.update-overlay` style): avatar glyph + "{owner_name}
  shared this with you." + one line + "Download Corder" → getcorder.com/install
  + "Maybe later".
- Deploy: separate Vercel project, `share.getcorder.com`, pointed at the Worker.

### 5. Privacy policy / terms

- Add a "Shared links" clause: opt-in (user clicks Share), unguessable public
  link, contains summary + full transcript + a copy of the audio, auto-deletes
  after 30 days, revocable.

## Security & privacy — sound (review §5)

- Service-key-only public read is already how the Worker reads Supabase; no
  public RLS policy on `segments` needed.
- One-meeting guarantee holds IFF every sub-query is scoped by the token's
  resolved `meeting_id` and no client-supplied id is accepted on the public GET.
- Token ≥128-bit → enumeration infeasible.
- Expiry enforced at read time (works today, no cron dependency); cron only
  does physical cleanup. A leaked-but-expired link is dead at GET.
- Full transcript + audio public is a bigger exposure than Granola's
  summary-only. Mitigated by opt-in + unguessable token + 30-day expiry +
  revoke.

## Storage / cost — free for us at this scale

Text already in Supabase (negligible). Audio = compact mix ~1.9 MB/min; 30-day
expiry bounds the working set; R2 = 10 GB free storage + **free egress**.
Reuse the queued R2 migration rather than a parallel scheme.

## Build order

1. Supabase `shares` table + R2 bucket + Worker routes (create/audio/get/cron).
2. Swift `ShareService` (awaitable re-push + mix upload + create) + Share gate +
   modal.
3. `share.getcorder.com` read-only frontend + CTA.
4. Privacy policy clause.
5. Verify end-to-end on a branch; only then release.

## Rollback

Additive, on a branch. The Share button + share frontend revert without
touching the recording/transcription core. `shares` table + R2 bucket are new
and isolated. No release until built + verified.

## Review corrections applied (from independent validation)

1. (BLOCKER) Fire-and-forget sync → replaced with an awaitable, throwing
   re-push awaited before `/share/create`.
2. (BLOCKER) Share gated on live session + `status==.ready` + segments>0;
   guest-migrated + never-transcribed meetings explicitly handled (not in cloud).
3. R2 + cron flagged net-new; audio default = Worker-proxied stream, not
   presigned URLs; CORS allowlist note.
4. Frontend share mode enumerated as concrete gating tasks with line refs.
5. Export KEPT (video + transcript-file downloads have no share-page
   substitute); Share added as primary. OWNER FLAG raised.
6. Reuse the already-queued `uploadRecording` R2/Storage path, not a parallel
   audio scheme.
7. `shares` RLS clarified as optional defense-in-depth (Worker is the writer).
