# Security & secret hygiene

This repository is **public** and contains zero secrets. The desktop
app distributed to users carries no API keys; every cloud call goes
through the Cloudflare Worker (`corder-api.empqwork.workers.dev`)
which holds the only OpenAI / Gemini credentials on its side.

## Threat model in plain words

Corder records meetings, including potentially sensitive 1-on-1s,
customer calls, and "thinking out loud" sessions. The product makes
two distinct security claims, and they should be evaluated separately:

1. **Repository hygiene.** Nothing in the repo (history included) leaks
   credentials. See [Secret hygiene](#secret-hygiene) below.
2. **Runtime privacy.** What happens to your audio depends on which
   transcription provider you've enabled. See
   [Provider privacy](#provider-privacy).

Things explicitly outside the threat model:
- Other apps on your Mac with Screen Recording / Microphone permission
  can also tap the same buses Corder records — Corder doesn't sandbox
  those.
- A compromised macOS account is game over: the audio files are stored
  unencrypted under `~/Library/Application Support/Corder/`. We rely on
  macOS filesystem permissions and FileVault.
- Dropbox is treated as trusted under the user's own account.
- Sparkle update integrity rests on EdDSA signature verification — see
  "Update channel" below.

## Provider privacy

The transcription provider depends on tier:

- **Free tier** — on-device WhisperKit (`large-v3-turbo` Core ML, ≈1.5 GB
  one-time download). Audio never leaves the Mac.
- **Pro / Max** : Groq Whisper (`whisper-large-v3-turbo`) **via the
  Cloudflare Worker proxy** (`/transcribe/groq`). The user sends the
  audio over TLS to our Worker with their Supabase JWT; the Worker
  forwards to Groq with our server-side key.

Non-admin users transcribe through Groq (paid) or the on-device model
(free) only. Gemini and OpenAI whisper-1 (`/transcribe/gemini` and
`/transcribe/whisper`) are **admin-only**, kept so the dev can benchmark
providers; the Worker returns 403 for those paths from a non-admin
token. So a normal user's audio can only ever reach Groq, and only on a
paid tier.

Auto-title / auto-summary / auto-chapters use Gemini 2.5 Flash through
the same Worker proxy (`/transcribe/gemini-proxy/*`), again with the
server-side key. These text-only notes flows are **free for all tiers
by product decision** (the text-only paywall is intentionally NOT
enforced); only audio/video transcription is gated.

**Server-side enforcement of the HARD PROVIDER LOCK.** The provider lock
(non-admins → Groq or on-device only; Gemini and OpenAI whisper-1 are
admin-only) is enforced on the Worker, not just the client. Two holes
were closed:

- `gemini-proxy` now treats a non-text `generateContent` part as
  admin-only transcription (`generateContentNeedsPaid`): a request part
  carrying `inline_data` / `inlineData` (base64 audio) OR `fileData` /
  `fileUri` (an uploaded file reference) counts as paid. The earlier
  fileData-only check missed inlined base64 audio, letting a non-admin
  inline a small audio chunk and get free, unmetered Gemini
  transcription. The `generateContent` MODEL is also pinned to the cheap
  Flash models the app actually uses (`gemini-2.5-flash` +
  `gemini-2.5-flash-lite`); previously a free user could request any
  model, including `gemini-2.5-pro`, with arbitrary prompts. Plus a 2 MB
  body cap.
- `whisper-cleanup` (the gpt-4o-mini punctuation polish) now pins
  `model=gpt-4o-mini`, caps `max_tokens` (16384), and strips `tools`. It
  was previously an unmetered, un-admin-gated passthrough to OpenAI
  chat/completions with a client-controlled model + body, so any paid
  user could run unlimited gpt-4o on the maintainer's key.

The app **never** reads an OpenAI or Gemini key from disk and never
ships one inside the binary. There is no `~/.config/corder/openai_key`
or `gemini_key` path any more — removed in 0.13.29.

Dropbox archival, when configured, uploads `audio.wav` to a folder
under the user's own Dropbox app token. Local copies are deleted
after upload.

**Google Calendar (Upcoming tab, opt-in).** Calendar access is a
separate, opt-in flow, never bundled into sign-in, so a user who never
clicks "Connect calendar" never grants it. The connect runs an
incremental OAuth requesting only `calendar.readonly`, pinned to the
signed-in account via `login_hint`; a callback that resolved to a
different Google account is rejected so connecting a calendar can't swap
the Corder identity. The pending-connect window is 900 s (15 min, raised
from 300 s): a slow Google consent (account chooser + 2FA + the
unverified-app warning) routinely exceeds 5 min, and the old 300 s timer
disarmed the identity-mismatch rollback in `finishConnectIfPending`
before the genuine callback landed, silently swapping the Corder
identity to whatever account the browser had resolved to. The Google
access token (1 h) and refresh token are
stored only in the account-scoped `calendar_cache.json` on the user's
disk, never committed and never shipped. Token renewal goes through the
Worker (`/calendar/refresh`): the app sends the refresh token + its
Supabase JWT, the Worker exchanges it with Google using the server-side
`GOOGLE_CLIENT_SECRET` and returns a fresh access token. The app never
holds the Google client secret. Only event metadata (title, time,
attendee count, join URL) is read, into the upcoming list.

## Secret hygiene

### What's a secret here

| Secret                       | Where it lives                                                |
| ---------------------------- | ------------------------------------------------------------- |
| OpenAI API key (Whisper)     | Cloudflare Worker secret (`wrangler secret put OPENAI_API_KEY`) |
| Gemini API key               | Cloudflare Worker secret (`GEMINI_API_KEY`)                   |
| Supabase service-role JWT    | Cloudflare Worker secret (`SUPABASE_SERVICE_ROLE`)            |
| Resend API key (transactional email) | Cloudflare Worker secret (`RESEND_API_KEY`)         |
| GitHub bot token (bug-report → issue) | Cloudflare Worker secret (`GITHUB_TOKEN`)          |
| Dropbox refresh token        | `~/.config/corder/dropbox.json` (user-side, mode 0600)        |
| Sparkle EdDSA private key    | macOS Keychain (Sparkle stores it there)                      |
| Developer ID signing cert    | macOS Keychain (`Developer ID Application: …`)                |

None of these are ever read from the repo, environment variables of
ambient shells, or bundled into the `.app`.

User identity (the Supabase session) lives in the Supabase SDK's
Keychain item and is short-lived (≈1 h JWT, refresh-rotated by the
SDK). Even a stolen JWT can only burn the user's monthly cap until
expiry; it cannot reach the OpenAI/Gemini secrets directly because
those never leave the Worker.

### What's NOT a secret (committed on purpose)

- `Corder.entitlements` — public manifest of code-signing capabilities
  (`com.apple.security.device.audio-input`, etc.). No secret material.
- `Info.plist` — `SUPublicEDKey` (Sparkle update verification public
  half) goes here. **Public** half only. Also `SUFeedURL`, which is a
  public URL.
- Supabase **anon key** is treated as public — it identifies the
  Supabase project on the client; gates beyond it (tier check) live
  server-side on the Worker.
- Dropbox **app key** is treated as semi-public — it identifies the
  app in OAuth, but is paired with the user's refresh token to do
  anything. Do not commit the **app secret**.

### Three layers of defence

**1. `.gitignore`** — hard list of patterns: `dropbox.json`, `*.pem`,
`*.p12`, `secrets/`, `.env*`, `sparkle_eddsa_priv*`, `*.key`.

**2. `gitleaks` pre-commit hook**:

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.21.2
    hooks:
      - id: gitleaks
```

Run manually: `gitleaks detect --source . --log-opts="--all"`.

**3. GitHub Actions secret scan**:

```
.github/workflows/secret-scan.yml — runs gitleaks on every push & PR.
```

If this ever fails red, the alert is real.

### GitHub-side settings

Push Protection at the account level should be ON:
github.com → Settings → Code security → "Push protection for yourself" → ON.

This blocks pushes containing GitHub's own catalogue of recognised
secret formats at the protocol layer — strictly stronger than
gitleaks because GitHub maintains the patterns.

### Onboarding without committing keys

Local development needs the Worker, not provider keys. To bring up
the Worker yourself:

```bash
cd corder-api
wrangler secret put OPENAI_API_KEY
wrangler secret put GEMINI_API_KEY
wrangler secret put SUPABASE_SERVICE_ROLE
wrangler secret put RESEND_API_KEY
wrangler secret put GITHUB_TOKEN
wrangler deploy
```

Dropbox archival is optional and only needs setup if a contributor
wants to test the cloud-backup path:

```bash
scripts/bootstrap.sh
$EDITOR ~/.config/corder/dropbox.json
```

`bootstrap.sh` never copies anything if the destination already
exists, so re-running it is safe.

## Local network surface

The app starts a Swifter HTTP server that binds to **127.0.0.1** on a
port that's preserved across launches (UserDefaults
`Corder.localServerPort`) so OAuth loopback redirects survive
relaunch. The port is never exposed beyond localhost; the WKWebView
Library window is the only intended client.

There is no authentication on the local API. Any process running as
your user can curl `http://127.0.0.1:<port>/api/meetings` and get the
full transcript list. We rely on macOS process isolation; if a
malicious app already runs as your user it has plenty of other ways
to read `~/Library/Application Support/Corder/`. (The newer
`GET /api/account/usage` endpoint, which feeds the header guest
"N left" session counter, is the opposite end of the spectrum: it
returns only non-sensitive counts (`is_guest`, `sessions_used`,
`sessions_left`, `limit`), no transcript, email, or identity.)

**CSRF guard (cross-site POST).** Even though the port is loopback-only,
a web page open in any browser can still issue "simple" cross-origin
POSTs to `http://127.0.0.1:<port>/api/...` (e.g. start, stop, archive).
A `server.middleware` rejects any state-changing request (POST / PUT /
PATCH / DELETE) whose `Origin` header is present AND not loopback.
GET / HEAD, requests with no `Origin` (native clients), and
loopback-Origin requests (the WKWebView Library window) pass. Loopback
is matched exactly: `http://127.0.0.1` / `http://localhost` / `http://[::1]`
followed by `:` or end-of-string, so an attacker-registrable
`http://127.0.0.1.evil.com` is NOT treated as loopback.

**Path traversal (fixed).** `serveAsset` and `serveRoot` now
`standardizedFileURL` the resolved target and require it to stay
contained under the web / assets root (`target.path.hasPrefix(base.path + "/")`).
Before this, the raw `:path` segment plus Swifter's split-then-percent-decode
let a request like `GET /assets/..%2f..%2fetc%2fpasswd` (or, worse,
`~/.config/corder/dropbox.json` with the Dropbox `app_secret` +
refresh token) read ANY file readable by the user. Verified: a
traversal path now returns 404, a legitimate asset returns 200.

## Update channel

Sparkle 2 with EdDSA-signed appcast at
`https://halinskiy.github.io/corder-updates/appcast.xml`. The public
key is pinned in `Info.plist`; updates that don't verify against it
are rejected by Sparkle before installation. Private signing key
lives in the developer's macOS Keychain, never in the repo. The
DMG itself is Developer-ID-signed, notarized, and stapled — Gatekeeper
verifies offline against the stapled ticket.

The auto-update flow is driven by Corder's own `SPUUserDriver`
implementation (`Sources/Corder/Update/CorderUpdateDriver.swift`),
which renders the update modal in our design system. Sparkle still
owns the download / extract / install pipeline; only the chrome is
ours.

## Telemetry

Opt-in (`Help improve Corder` toggle in Settings → General, default
ON during the test period, will revert to default-OFF before paid
plans ship). When on, Corder sends a single envelope once per 24 h
to the Worker `/telemetry` endpoint:

- App version, macOS version, Mac model, RAM, tier
- Aggregate counts: meetings total / ready / failed / transcribing,
  advanced-vs-local minute usage
- `anonymous_id` = SHA-256 of the lowercased account email

No transcripts, no audio, no raw email. The Worker persists the
envelope into a Cloudflare D1 database (`corder-telemetry`) for the
maintainer's continuous health view.

## Bug reports (`/submit-logs`)

The "Send a report" / `submitLogs()` path POSTs the diagnostic log to
the Worker `/submit-logs` endpoint, which emails the maintainer (Resend)
and files a GitHub issue (`GITHUB_TOKEN`). This endpoint is
**unauthenticated** by design (a user hitting a crash may not have a
valid session), so it is hardened against abuse: a per-IP rate limit
(8 / hour, tracked in the usage D1 table under a synthetic key),
field-length caps on the submitted payload, and GitHub-label
sanitization of the client-controlled `app_version` (so a crafted
version string can't inject arbitrary labels into the issue tracker).

## Provenance proof

A clean-history scan was run before the repo was made public:

```
$ gitleaks detect --source . --log-opts="--all" --redact
9:55PM INF scan completed in 1.42s
9:55PM INF no leaks found
```

If you find something gitleaks missed, please open a private security
advisory rather than a public issue.

## If you need to rotate keys

Compromise drill, in order:

1. **OpenAI / Gemini** — go to the provider console, revoke + create
   a new key. `wrangler secret put OPENAI_API_KEY` (or `GEMINI_API_KEY`),
   then `wrangler deploy`. No client release needed — the new key
   takes effect on the next Worker invocation.
2. **Supabase service role** — Supabase Dashboard → Settings → API →
   "Reset service_role key". `wrangler secret put SUPABASE_SERVICE_ROLE`,
   deploy.
3. **Dropbox** — go to `https://www.dropbox.com/developers/apps/info/<app_key>`
   → "Generated access token" reset & remove app authorizations.
   Reissue refresh token via the OAuth flow described in
   `docs/ARCHITECTURE.md`.
4. **Sparkle EdDSA private key** — only relevant if a malicious
   update was published. Replace via Sparkle's `generate_keys`, push
   the new public half in a release that older versions trust under
   the *old* key, then sunset the old key.
5. **Developer ID** — re-issue from developer.apple.com, update the
   `CORDER_SIGN_IDENTITY` env var for the release scripts. Note: every
   TCC permission grant resets when the signing identity changes.

## Things to be aware of

- **WKWebView** has its own cookie / localStorage / cache store under
  `~/Library/WebKit/com.3mpq.Corder/`. The Library UI uses localStorage
  only for non-secret UI state (dismissed news ids, theme choice,
  rating prompt state).
- **The local SQLite is not encrypted at rest.** FileVault is the only
  protection. If you need stronger guarantees, encrypt the macOS
  account itself, or use SQLCipher (not currently integrated).
- **OpenAI Whisper retention** — we pass `store=false` on every
  request through the Worker; the audio is processed and discarded
  within the request lifetime.
- **Gemini File API retention** — files uploaded via
  `/transcribe/gemini-proxy/upload/v1beta/files` expire automatically
  after 48 h, and the pipeline explicitly deletes them after the
  transcript is back. If the request errors before the delete fires,
  expiry handles cleanup.
