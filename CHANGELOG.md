# Changelog

All notable changes to Corder. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file is read by Sparkle to generate per-version release notes in the
appcast. Entries here become the "What's New" panel users see in the
in-app updater. Keep them human, terse, and oriented to user-visible
behaviour, not internal refactors.

## [Unreleased]

### Added
- `NOTES.md` / `docs/ARCHITECTURE.md` / `docs/SECURITY.md`
  to make the repo legible for AI collaborators and humans alike.
- gitleaks pre-commit hook + GitHub Actions secret-scan workflow.
- `scripts/bootstrap.sh` for first-time setup of `~/.config/corder/`.
- Sparkle 2 autoupdate framework (appcast, EdDSA-signed updates).

### Changed
- AVAssetWriter is no longer instantiated — repeated `-16122` failures on
  current macOS made the video file unusable. Recordings are audio-only
  (`system.wav` + `mic.wav` + the mixed `audio.wav` for playback).
- Frontend right-pane replaces the broken `<video>` element with a
  custom audio player (green progress, hover tooltip with timecode,
  expandable scrub bar).

## [0.5.0] — 2026-05-03

Snapshot of the state at the moment the repo was made public.

### Added
- Speaker diarization rebuilt around the **two-source** trick: mic vs
  system RMS gate decides "user", FluidAudio (CoreML pyannote 3.1 +
  WeSpeaker) clusters only the system-audio side. Replaces the previous
  pitch-based k-means that misassigned the user 80% of the time.
- ScreenCaptureKit **microphone capture** (macOS 15+ shared mic tap),
  replacing AVAudioEngine — the latter silently lost samples whenever
  Telegram or Zoom held an exclusive mic claim.
- Microphone TCC permission flow with explicit `AVCaptureDevice.requestAccess`
  and a temporary `setActivationPolicy(.regular)` so the prompt actually
  appears for an LSUIElement app.
- Dropbox archival: `audio.wav` uploads after each transcription, local
  files are deleted, playback streams via signed temporary links proxied
  through the local server with the correct `Content-Type`.
- "Усилить" toggle (per-user persisted setting). When on, every new
  transcript is auto-polished segment-by-segment via Gemini 2.5 Flash.
- Hallucination filter for Whisper YouTube-subtitle artefacts ("Субтитры
  сделал DimaTorzok", "Спасибо за просмотр", "Продолжение следует…").
- Audio player with green progress, hover-time tooltip, ±click scrub.
- Adaptive timeline cursor — switches to white when contrast against the
  underlying speaker tick is below WCAG 2.5.

### Changed
- Whisper model: `medium` → `large-v3` with VAD chunking. Long recordings
  (1h+) now finish; Russian quality went up substantially.
- Library window UI: right panel moved from "video card + timeline" to
  "audio card + timeline" (see Unreleased note above).
- Sidebar list: hover/active styling, hairline divider draws below the
  scrollbar via background gradient (no more z-index gymnastics).

### Fixed
- Whisper detected Russian as English when `detectLanguage: true` —
  pinned to `language: "ru"`.
- Cmd+C on transcript text inside WKWebView would beep — added a real
  Edit menu in `AppDelegate.installMainMenu` and `e.preventDefault()`
  on the JS keydown bridge.
- Stop button visibility in dark mode (used `windowBackgroundColor`
  for the glyph foreground).
- Right-click context menu on sidebar items closing the moment it
  opened (window-level `contextmenu` listener was racing the React
  state).

### Removed
- AVAssetWriter video output (see Unreleased — the writer flips to
  `.failed` with `-16122` on every config tested on this macOS build).
- Pitch-based k-means clustering + per-meeting "boost prose" view.

## [0.1.0] — 2026-04-XX

Initial walking skeleton: ScreenCaptureKit recording, Whisper-CPP via
WhisperKit, SQLite via GRDB, Vite/React Library window served by Swifter.
Single-speaker, English-only, no diarization.
