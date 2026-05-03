# Adding Corder to 3mpq Studio

The portfolio site at https://halinskiy.github.io/3mpq-studio/ ships as a
prebuilt Vite/React bundle on `gh-pages`. The source repo isn't public, so
to add Corder you need to ping Mikhail with the artifacts below.

## Asset

`Resources/icons/corder-portfolio.svg` — 1024×1024, rounded-rect with a
green gradient (`#1f7a4f → #0e3d28`), white record-circle glyph centered.
Matches the format of the existing icons (pts.svg, timex.svg etc).

Drop it into the studio repo at `public/icons/corder.svg`.

## Product object to insert into the products array

```ts
{
  id: 'corder',
  name: 'Corder',
  tagline: 'Local meeting recorder & transcriber for macOS',
  description:
    'Status-bar app that records system audio + your microphone, ' +
    'transcribes locally with Whisper large-v3, diarizes speakers with ' +
    'a CoreML port of pyannote 3.1, optionally polishes transcripts via ' +
    'Gemini Flash, and archives recordings to your own Dropbox. ' +
    'Everything runs on-device. No cloud, no signups.',
  platform: 'macOS',
  stack: [
    'Swift', 'SwiftUI', 'WKWebView',
    'ScreenCaptureKit', 'WhisperKit', 'FluidAudio',
    'GRDB', 'Sparkle',
  ],
  features: [
    {
      title: 'Local-first',
      description:
        'On-device transcription via Apple Neural Engine. No audio ever leaves your machine unless you turn on Boost or Dropbox.',
    },
    {
      title: 'Two-source diarization',
      description:
        'Mic and system audio captured separately; mic-RMS gate plus FluidAudio (pyannote 3.1) on the system stream means "I" is always you.',
    },
    {
      title: 'Auto-polish',
      description:
        'Optional segment-by-segment Gemini Flash pass that fixes punctuation and obvious recognition errors without losing speaker / timing structure.',
    },
    {
      title: 'Cloud archive',
      description:
        'After transcription, audio uploads to your own Dropbox app folder. Local copy is deleted; playback streams via signed temporary links.',
    },
  ],
  icon: `${Os}icons/corder.svg`,
  type: 'product',
}
```

(`${Os}` = the same `import.meta.env.BASE_URL`-prefix template the
existing entries use; copy whatever they already do for `pts.svg` etc.)

## Where to drop it

Insert the literal anywhere in the `products` array in the React source —
alphabetical with `corder` between `cms` and `finex` works.

## Verification

After deploy:

1. `https://halinskiy.github.io/3mpq-studio/` shows a `Corder` card.
2. Card hover → details panel with the four features above.
3. Icon renders crisp; SVG ~370 B, no PNG fallback needed.
