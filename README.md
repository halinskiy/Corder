# Corder

A macOS meeting recorder + transcriber for people who hate that Grain
and Otter ship audio to a third party and bake their bot into the
call. Corder runs as your local app, never invites a bot, and only
talks to the one provider you opted into (Gemini).

> Status-bar app. macOS 14+ (Sonoma). Apple Silicon recommended.

## What it does

- **Records** — single click in the menu bar. Captures system audio
  (via ScreenCaptureKit) and your microphone (via AVAudioEngine) onto
  **separate** `.wav` tracks. The HUD pill floats over every Space
  while you're recording, with a live waveform meter so you can tell
  capture is actually working.
- **Transcribes — dual-track** — `mic.wav` and `system.wav` go to
  Google's Gemini 2.5 Flash File API as **two separate calls** in
  parallel. The mic call is forced to a single speaker ("you"); the
  system call is asked to diarise everyone on the remote side. Results
  are merged by start-time. This is the fix for the "it merged my words
  with the other person's during silence" class of bugs that you get
  when you mix both streams and ask one model to guess.
- **Caches the raw transcript** by audio MD5 — so re-mapping speakers
  (e.g. after the clarify banner pins a count) and re-transcribes
  after a Dropbox archive don't re-bill the Gemini File API.
- **Rename & pin** — right-click a session to rename or pin it (pinned
  sessions float to a group at the top, marked with a gold dot); the
  header title is click-to-edit too.
- **Exports** — download any recording as video, audio, transcript
  (TXT / Markdown / JSON) or a single ZIP bundle.
- **Archives (optional)** — if you fill in `~/.config/corder/dropbox.json`,
  each recording's `mix.wav` (plus its mic + system tracks) is uploaded
  after transcription and the local copies are deleted. Playback streams
  via signed Dropbox links.
- **Archive bin** — sessions you don't want to see go to a 7-day bin
  before being purged. Restore or delete-forever from the toolbar.
- **Lives in a Library window** — sidebar of meetings, transcript with
  speakers, audio scrubber, per-speaker timeline, full-text search.

## Why

Off-the-shelf meeting tools (Grain, Otter, Fireflies) ship audio to
their own servers and join the call as a participant. Corder runs on
your machine, never joins anything, talks only to Gemini for the
transcribe call (audio is auto-deleted from Google's File API after the
job), and lets you turn the cloud part off entirely if you want — at
the cost of nothing transcribing at all.

## Install

```bash
git clone https://github.com/halinskiy/Corder.git
cd Corder

# One-time setup: drop config templates into ~/.config/corder/
scripts/bootstrap.sh

# Build everything (web bundle + Swift binary + .app shell + sign):
Scripts/build-app.sh

# Move into Applications (optional, keeps TCC permissions stable):
ditto Corder.app /Applications/Corder.app
xattr -dr com.apple.quarantine /Applications/Corder.app
open /Applications/Corder.app
```

First launch:

1. macOS prompts for **Screen Recording**, then **Microphone**. Allow both.
2. Click the menu-bar icon → **Open Library**.
3. Paste your Gemini API key into `~/.config/corder/gemini_key`. Without
   it, recording still works fully — only transcription fails (red toast).

## Configuration

All secrets live outside the repo, under `~/.config/corder/`. Templates
are copied by `scripts/bootstrap.sh`; fill them in by hand.

```
~/.config/corder/
├── dropbox.json     # { app_key, app_secret, refresh_token, remote_root }
└── gemini_key       # one-line API key
```

Without these the app still runs — recording and playback work; only
transcription needs the Gemini key, and Dropbox archival silently
skips. Read [`docs/SECURITY.md`](docs/SECURITY.md) for how to obtain
the keys safely.

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — modules, data
  lifecycle, SQLite schema, dual-track transcription model.
- [`docs/SECURITY.md`](docs/SECURITY.md) — threat model, secret
  hygiene, runtime privacy by provider.
- [`docs/API.md`](docs/API.md) — every endpoint of the local HTTP
  server.
- [`docs/DESIGN.md`](docs/DESIGN.md) — colour, type, components, motion.
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) — first-time setup,
  build loop, common tasks, code style.
- [`docs/RELEASE.md`](docs/RELEASE.md) — Sparkle update workflow.
- [`AGENTS.md`](AGENTS.md) — single source of truth for AI agents
  working on this repo.

## License

MIT (forthcoming). For now: personal project, all rights reserved by
the author. Open issues / PRs are welcome but the repo is not a
community project yet.
