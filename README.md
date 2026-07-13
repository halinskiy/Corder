# Corder

A macOS meeting recorder + transcriber for people who hate that Grain
and Otter ship audio to a third party and bake their bot into the
call. Corder runs as your local app, never invites a bot, and
transcribes either fully on-device (Apple Silicon Whisper, $0,
nothing leaves your Mac) or through a single cloud Whisper provider
you opted into.

> Status-bar app. macOS 14+ (Sonoma). Apple Silicon recommended.

## What it does

- **Records** — single click in the menu bar or the in-app Start
  button inside the Library window. Captures system
  audio (Core-Audio process tap + ScreenCaptureKit backup) and your
  microphone (via AVAudioEngine) onto **separate** `.wav` tracks. The
  HUD pill floats over every Space while you're recording, with a live
  waveform meter so you can tell capture is actually working.
- **Transcribes — dual-track** — `mic.wav` and `system.wav` are
  transcribed as **two separate jobs**, the mic forced to a single
  speaker ("you") and the system diarised for everyone on the remote
  side, then merged by start-time. This is the fix for the "it merged
  my words with the other person's during silence" class of bugs that
  you get when you mix both streams and ask one model to guess. The
  transcriber is on-device WhisperKit (Apple Silicon, $0) or Groq's
  hosted Whisper-large-v3-turbo; the cloud audio is processed and not
  retained for training.
- **Caches the raw transcript** by audio MD5 — so re-mapping speakers
  (e.g. after the clarify banner pins a count) and re-transcribes
  after a Dropbox archive don't re-bill the cloud transcription.
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
your machine, never joins anything, and can transcribe entirely
on-device (Apple Silicon Whisper) so no audio ever leaves your Mac.
When you opt into the cloud transcriber instead, only the audio for
that one call is sent, to a single Whisper provider, for that one job.

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

1. The app opens straight to the Library, fully usable signed-out with
   nothing granted. There is no upfront permission or sign-in wall.
2. Hit Start (menu-bar icon or the in-app Start button in the Library).
   Permissions are requested **on demand**: an audio-only recording asks
   only for **Microphone**; **Screen Recording** is requested only when
   you turn on screen video (and, because macOS grants it on the next
   launch, that prompt offers to quit-and-relaunch or record audio only).
3. Transcription runs on-device on Apple Silicon at no cost. For the
   cloud transcriber, sign in from the profile menu (optional); the app
   no longer reads any API key from disk.

## Configuration

All secrets live outside the repo, under `~/.config/corder/`. Templates
are copied by `scripts/bootstrap.sh`; fill them in by hand.

```
~/.config/corder/
├── dropbox.json     # { app_key, app_secret, refresh_token, remote_root }
└── gemini_key       # one-line API key (dev/admin only; see below)
```

Neither file is required for normal use. On-device transcription needs
nothing, and the cloud transcriber authenticates through a hosted
proxy with your account session (no provider key on disk). `dropbox.json`
is only for optional archival, it silently skips when absent. `gemini_key`
is a legacy dev/admin escape hatch for the admin-only Gemini path, not
the default route. Read [`docs/SECURITY.md`](docs/SECURITY.md) for how
to obtain the keys safely.

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

## License

Corder is free software, licensed under the **GNU General Public License
v3.0**. See [LICENSE](LICENSE) for the full text.

Copyright (C) 2026 Kostiantyn Halynskyi.

In short: you are free to read, run, modify and redistribute this code. If
you distribute a modified version, or a product built on it, you have to
release your source under the GPL as well.

The source is public on purpose. Corder claims that your recordings and
their transcription stay on your Mac; the point of publishing the capture
engine and the on-device transcription pipeline is that you do not have to
take that on trust. Read `Sources/Corder/Capture/` and
`Sources/Corder/Transcription/` and check.

The hosted backend (the Cloudflare Worker that proxies cloud transcription
and meters usage) is a separate, closed component and is not part of this
repository.

Issues and pull requests are welcome.
