# Security & secret hygiene

This repository is **public** and contains zero secrets. Long-lived
credentials live exclusively under `~/.config/corder/` on the user's
machine.

## Threat model in plain words

Corder records meetings, including potentially sensitive 1-on-1s,
customer calls, and "thinking out loud" sessions. The product makes
two distinct security claims, and they should be evaluated separately:

1. **Repository hygiene.** Nothing in the repo (history included) leaks
   credentials. See [Secret hygiene](#secret-hygiene) below.
2. **Runtime privacy.** What happens to your audio depends on which
   transcription provider you've enabled. See [Provider privacy](#provider-privacy).

Things explicitly outside the threat model:
- Other apps on your Mac with Screen Recording / Microphone permission can
  also tap the same buses Corder records — Corder doesn't sandbox those.
- A compromised macOS account is game over: the audio files are stored
  unencrypted under `~/Library/Application Support/Corder/`, the API
  keys are unencrypted under `~/.config/corder/`. We rely on macOS
  filesystem permissions and FileVault.
- Dropbox is treated as trusted under the user's own account.
- Sparkle update integrity rests on EdDSA signature verification —
  see "Update channel" below.

## Provider privacy

The default transcription provider is **Gemini 2.5 Flash (cloud)**. When
on, every recording's `audio.wav` is uploaded to Google's File API,
processed for transcription with built-in diarisation, then deleted by
Google after the request completes. The pinned billing tier (Tier 1 /
paid) explicitly opts the project out of training-data reuse.

Gemini is the **only** transcription provider. There is no local /
on-device fallback and no provider toggle — if a recording is
transcribed, its audio went to Google's File API. A meeting that is
never transcribed (recording kept, transcription cancelled or failed)
never leaves the machine.

The Gemini API key is read at runtime only — from the `GEMINI_API_KEY`
environment variable or `~/.config/corder/gemini_key` (mode 0600). It
is never compiled into the binary and never committed, so neither the
public source nor a distributed `.app` carries it.

Dropbox archival, when configured, uploads `audio.wav` to a folder under
the user's own Dropbox app token. Local copies are deleted after upload.

## Secret hygiene

### What's a secret here

| Secret                        | Where it lives                              |
| ----------------------------- | ------------------------------------------- |
| Dropbox refresh token         | `~/.config/corder/dropbox.json`             |
| Dropbox app secret            | `~/.config/corder/dropbox.json`             |
| Gemini API key                | `~/.config/corder/gemini_key`               |
| Sparkle EdDSA private key     | macOS Keychain (Sparkle stores it there)    |
| Self-signed code-sign cert    | macOS Keychain (`ScreenOCR Dev`)            |

None of these are ever read from the repo, environment variables of
ambient shells, or bundled into the `.app`. The code paths are:

```swift
// DropboxService.swift
private static let credsPath = "~/.config/corder/dropbox.json".expandingTildeInPath
// BoostService.swift / GeminiTranscriber.swift
let path = "~/.config/corder/gemini_key".expandingTildeInPath
let trimmed = (try String(contentsOfFile: path, encoding: .utf8)).trimming…
```

### What's NOT a secret (committed on purpose)

- `Corder.entitlements` — public manifest of code-signing capabilities
  (`com.apple.security.device.audio-input`, etc.). No secret material.
- `Info.plist` — `SUPublicEDKey` (Sparkle update verification public
  half) goes here. **Public** half only.
- Dropbox **app key** is treated as semi-public — it identifies the app
  in OAuth, but is paired with the user's refresh token to do anything.
  Do not commit the **app secret**.

### Three layers of defence

**1. `.gitignore`** — hard list of patterns: `dropbox.json`, `gemini_key`,
`*.pem`, `*.p12`, `secrets/`, `.env*`, `sparkle_eddsa_priv*`, `*.key`.

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

The user must enable **Push Protection** at account level (one-time):

1. github.com → Settings → Code security
2. "Push protection for yourself" → ON

This blocks pushes containing GitHub's own catalogue of recognised
secret formats at the protocol layer — strictly stronger than gitleaks
because GitHub maintains the patterns.

### Onboarding without committing keys

`scripts/bootstrap.sh` materialises the config dir from `*.example`
templates that ship with the repo:

```
config-templates/
├── dropbox.json.example     # placeholders, no real values
└── gemini_key.example       # "<paste-your-gemini-key-here>"
```

After clone:

```bash
scripts/bootstrap.sh
$EDITOR ~/.config/corder/dropbox.json
$EDITOR ~/.config/corder/gemini_key
```

The script never copies anything if the destination already exists.

## Local network surface

The app starts a Swifter HTTP server that binds to **127.0.0.1** on a
random unprivileged port. The port is never exposed beyond localhost,
the WKWebView Library window is the only intended client.

There is no authentication on the local API. Any process running as
your user can curl `http://127.0.0.1:<port>/api/meetings` and get the
full transcript list. We rely on macOS process isolation; if a
malicious app already runs as your user it has plenty of other ways
to read `~/Library/Application Support/Corder/`.

## Update channel

Sparkle 2 with EdDSA-signed appcast at
`https://halinskiy.github.io/corder-updates/appcast.xml`. The public
key is pinned in `Info.plist`; updates that don't verify against it
are rejected by Sparkle before installation. Private signing key
lives in the developer's macOS Keychain, never in the repo.

## Provenance proof

A clean-history scan was run before the repo was made public:

```
$ gitleaks detect --source . --log-opts="--all" --redact
9:55PM INF scan completed in 1.42s
9:55PM INF no leaks found
```

If you find something gitleaks missed, please [open a private security
advisory](https://github.com/<org>/Corder/security/advisories/new)
rather than a public issue.

## If you need to rotate keys

Compromise drill, in order:

1. **Dropbox** — go to https://www.dropbox.com/developers/apps/info/<app_key>
   → "Generated access token" reset & remove app authorizations. Reissue
   refresh token via the OAuth flow described in `docs/ARCHITECTURE.md`.
2. **Gemini** — https://aistudio.google.com/app/apikey → delete & create
   a new key under the same paid project. Update `~/.config/corder/gemini_key`.
3. **Sparkle EdDSA private key** — only relevant if a malicious update
   was published. Replace via Sparkle's `generate_keys`, push the new
   public half in a release that older versions trust under the *old*
   key, then sunset the old key.
4. **Self-signed cert** — recreate in Keychain Access. Note: every TCC
   permission grant resets when the signing identity changes.

## Things to be aware of

- **WKWebView** has its own cookie / localStorage / cache store under
  `~/Library/WebKit/com.3mpq.Corder/`. The Library UI uses localStorage
  only for non-secret UI state (`corder.clarify_dismissed` — list of
  meeting IDs the user dismissed the speakers banner for).
- **The local SQLite is not encrypted at rest.** FileVault is the only
  protection. If you need stronger guarantees, encrypt the macOS
  account itself, or use SQLCipher (not currently integrated).
- **The Gemini File API holds your audio for up to 48 hours** unless
  Corder explicitly deletes it after the request — which it does
  (`GeminiTranscriber.deleteFile`). If a request errors out before the
  delete, the file expires automatically.
