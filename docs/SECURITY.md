# Security & secret hygiene

This repository is **public** and contains zero secrets. Long-lived
credentials live exclusively under `~/.config/corder/` on the user's
machine. The repo enforces this through three independent layers; if any
one of them fires, a push is blocked.

## What's a secret here

| Secret                        | Where it lives                              |
| ----------------------------- | ------------------------------------------- |
| Dropbox refresh token         | `~/.config/corder/dropbox.json`             |
| Dropbox app secret            | `~/.config/corder/dropbox.json`             |
| Gemini API key                | `~/.config/corder/gemini_key`               |
| Sparkle EdDSA private key     | macOS Keychain (Sparkle stores it there)    |
| Self-signed code-sign cert    | macOS Keychain (`ScreenOCR Dev`)            |

None of these are ever read from the repo, environment variables of
ambient shells, or bundled into the `.app`. The code paths look like:

```swift
// DropboxService.swift
private static let credsPath = "~/.config/corder/dropbox.json".expandingTildeInPath
// BoostService.swift
let key = try String(contentsOfFile: "~/.config/corder/gemini_key".expandingTildeInPath)
```

## What's NOT a secret (committed on purpose)

- `Corder.entitlements` — public manifest of code-signing capabilities
  (`com.apple.security.device.audio-input`, etc.). No secret material.
- `Info.plist` — `SUPublicEDKey` (Sparkle update verification public
  half) goes here once Sparkle is wired up. **Public** half only.
- Dropbox **app key** (`94d8bcirlwa5ksz`) is treated as semi-public — it
  identifies the app in OAuth, but is paired with the user's refresh
  token to do anything. Do not commit the **app secret**.

## Three layers of defence

### 1. `.gitignore`

Hard list of patterns that catch the obvious before they're staged. See
`.gitignore` at the repo root: covers `dropbox.json`, `gemini_key`,
`*.pem`, `*.p12`, `secrets/`, `.env*` (with `!.env.example` carve-out),
`sparkle_eddsa_priv*`, `*.key`. Static, dumb, fast.

### 2. `gitleaks` pre-commit hook

Per-developer guarantee that nothing slips into a commit locally.
Installed by `scripts/bootstrap.sh` via `pre-commit`. Config:

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.21.2
    hooks:
      - id: gitleaks
```

Run manually: `gitleaks detect --source . --log-opts="--all"`.

### 3. GitHub Actions secret scan

Cloud-side belt-and-braces for collaborators / CI:

```
.github/workflows/secret-scan.yml — runs gitleaks on every push & PR.
```

If this ever fails red, the alert is real.

## GitHub-side settings

The user must enable **Push Protection** at account level (one-time):

1. github.com → Settings → Code security
2. "Push protection for yourself" → ON

This blocks pushes containing GitHub's own catalogue of recognised
secret formats at the protocol layer — strictly stronger than gitleaks
because GitHub maintains the patterns.

## Onboarding without committing keys

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

## Provenance proof

A clean-history scan was run before the repo was made public:

```
$ gitleaks detect --source . --log-opts="--all" --redact
    ○
    │╲
    │ ○
    ○ ░
    ░    gitleaks
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
2. **Gemini** — https://aistudio.google.com/app/apikey → delete & create.
3. **Sparkle EdDSA private key** — only relevant if a malicious update
   was published. Replace via Sparkle's `generate_keys`, push the new
   public half in a release that older versions trust under the *old*
   key, then sunset the old key. (Until first published release, this
   is a no-op.)
4. **Self-signed cert** — recreate in Keychain Access. Note: every TCC
   permission grant resets when the signing identity changes.
