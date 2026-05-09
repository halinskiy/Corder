# Adding Corder to 3mpq Studio

The portfolio site at https://halinskiy.github.io/3mpq-studio/ ships as a
prebuilt Vite/React bundle on `gh-pages`. The source repo isn't public, so
to add / refresh Corder you need to ping Mikhail with the artifacts below.

> Last refreshed: dual-track Gemini transcription, recording HUD, archive
> bin, raw-turn cache. The previous "local-first / Whisper / FluidAudio"
> framing is **stale** — see CHANGELOG `[Unreleased]` for the full diff.

## Asset

`Resources/icons/corder-portfolio.svg` — 1024×1024. Two glossy 3D pause
bars on a warm-white radial-gradient ground. The exact SVG also lives at
`/Users/3mpq/3mpq-studio-export/public/icons/corder.svg` if you have
that local export handy.

Drop it into the studio repo at `public/icons/corder.svg` (overwrite
the previous green-record-circle version).

## Product object to insert into the products array

```ts
{
  id: 'corder',
  name: 'Corder',
  tagline: 'Local meeting recorder & transcriber for macOS',
  description:
    "macOS status-bar app that records system audio and your microphone " +
    "onto separate tracks, transcribes them in parallel via Gemini 2.5 " +
    "Flash with a dual-track speaker model, and stores everything in a " +
    "local Library window. Floating recording HUD over every Space, " +
    "optional segment-by-segment polish, optional Dropbox archive. " +
    "No bot in the call. No signups.",
  platform: 'macOS',
  stack: [
    'Swift', 'SwiftUI', 'WKWebView',
    'ScreenCaptureKit', 'AVAudioEngine',
    'Gemini 2.5', 'GRDB', 'Sparkle',
  ],
  features: [
    {
      title: 'Dual-track transcription',
      description:
        "Mic and system audio go to Gemini as two parallel calls — mic " +
        "forced to a single speaker, system asked to diarise the remote " +
        "side. Solves the 'your words got merged with your friend's " +
        "during a silent gap' class of bug that single-stream tools have.",
    },
    {
      title: 'Floating recording HUD',
      description:
        "Granola-style pill that hovers over every Space while you " +
        "record. Pulsing dot, live EQ-style waveform driven by both " +
        "tracks, elapsed-time counter, one-click stop. Constant " +
        "feedback that capture is actually running.",
    },
    {
      title: 'Smart re-transcribe',
      description:
        "Raw Gemini turns are cached by audio MD5. Re-mapping speakers " +
        "(clarify banner, pinned count) and re-transcribing after a " +
        "Dropbox archive both reuse the cache — zero extra API calls.",
    },
    {
      title: '7-day archive bin',
      description:
        "Sessions you don't want to see go to a soft-archive bin instead " +
        "of being deleted. Restore or purge per row, or let the 7-day " +
        "timer clean them up automatically.",
    },
  ],
  icon: `${Os}icons/corder.svg`,
  type: 'product',
  downloadUrl: 'https://github.com/halinskiy/Corder/releases/latest/download/Corder.zip',
}
```

(`${Os}` = the same `import.meta.env.BASE_URL`-prefix template the
existing entries use; copy whatever they already do for `pts.svg` etc.)

## Where to drop it

Replace the existing `corder` entry in the `products` array. Position
stays the same (alphabetical, between `cms` and `finex` works).

## Verification

After deploy:

1. `https://halinskiy.github.io/3mpq-studio/` shows the `Corder` card with
   the new pause-bars icon (not the old green record circle).
2. Card hover → details panel with the four features above.
3. Icon renders crisp; SVG ~3 kB, no PNG fallback needed.
4. Tagline reads "Local meeting recorder & transcriber for macOS"
   (was: "Local-first meeting recorder & transcriber").
