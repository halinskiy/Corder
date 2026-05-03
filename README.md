# Corder

Local-first macOS meeting recorder. Captures system audio + your microphone,
transcribes via WhisperKit (large-v3, RU/EN), diarizes speakers via FluidAudio
(CoreML port of pyannote 3.1), polishes transcripts via Gemini Flash, and
optionally archives recordings to your own Dropbox so the local disk stays
empty. Runs entirely on-device. No cloud, no signups.

> Status-bar app. macOS 14+ (Sonoma). Apple Silicon recommended.

## Why

Off-the-shelf meeting tools (Grain, Otter, Fireflies) ship audio to their
servers. For private 1-on-1s, brainstorms and diary-style "talk-it-through"
sessions, that's the wrong default. Corder records to your machine, runs
transcription locally, and only touches the network if you explicitly turn on
the Gemini-polish toggle or hand it Dropbox creds.

## Features

- **Status-bar recording** — single click Start/Stop, no window in your way.
- **Two-source capture** — `mic.wav` (you) and `system.wav` (everyone else)
  recorded separately via ScreenCaptureKit (incl. macOS 15+ shared mic tap),
  so we know who said what without blind diarization.
- **Whisper large-v3 + VAD chunking** — handles 1-hour recordings, Russian +
  English mixed, drops known hallucinations.
- **FluidAudio diarizer** — pyannote 3.1 segmentation + WeSpeaker embeddings,
  Apple Neural Engine accelerated. Up to 17.7% DER on AMI.
- **"Усилить" toggle** — when on, every new transcript is automatically
  polished segment-by-segment via Gemini 2.5 Flash (free tier). Toggle persists
  across launches.
- **Dropbox archive** — uploads `audio.wav` after transcription, deletes local
  copies. Playback streams via signed temporary links proxied through the app.
- **Live banner** — while a meeting is recording the Library window shows a
  red-dot card with timer + Stop button. Menu-bar icon turns red.

## Install

```bash
git clone https://github.com/<you>/Corder.git
cd Corder

# One-time setup: drop config templates into ~/.config/corder/
scripts/bootstrap.sh

# Build everything (web bundle + Swift binary + .app shell + sign):
Scripts/build-app.sh

# Move into Applications (optional, keeps TCC permissions stable):
mv Corder.app /Applications/
open /Applications/Corder.app
```

First launch:
1. macOS prompts for **Screen Recording**, then **Microphone**. Allow both.
2. Click the menu-bar icon → **Открыть библиотеку**.

## Configuration

All secrets live outside the repo, under `~/.config/corder/`. Templates are
copied by `scripts/bootstrap.sh`; fill them in by hand.

```
~/.config/corder/
├── dropbox.json     # { app_key, app_secret, refresh_token, remote_root }
└── gemini_key       # one-line API key
```

Without these the app still runs — Boost simply errors and Dropbox archival
silently skips. Read `docs/SECURITY.md` for how to obtain the keys safely
and why the repo enforces zero-secrets via gitleaks.

## Architecture

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). TL;DR: a status-bar app
spawns a local Swifter HTTP server, the WKWebView library window loads a
Vite/React UI from the same process, recordings flow through SCStream →
AudioMixer → WhisperKit → FluidAudio → SQLite (GRDB) → Dropbox.

## License

MIT (forthcoming). For now: personal project, all rights reserved by the
author. Open issues / PRs are welcome but the repo is not a community project
yet.
