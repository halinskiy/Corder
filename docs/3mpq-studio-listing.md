# Corder card on 3mpq.studio

The portfolio site at https://halinskiy.github.io/3mpq-studio/ is built
from a Vite + React source (`/Users/3mpq/3mpq-studio-export/`) and
deployed to the public repo `halinskiy/3mpq-studio` on the `gh-pages`
branch. The deploy artifact is the `dist/` output, copied wholesale
into the repo root.

## Updating the Corder card

1. Edit the source: `src/data/products.ts` in `3mpq-studio-export/`.
   Find the `id: 'corder'` entry and adjust copy / features.
2. If the icon needs updating, replace
   `public/icons/corder.svg` with the new artwork. Keep the file at
   1024×1024 (the studio renders at multiple sizes).
3. Build with the GitHub Pages base path:
   ```bash
   cd /Users/3mpq/3mpq-studio-export
   VITE_BASE=/3mpq-studio/ npm run build
   ```
4. Sync `dist/` into the deploy repo:
   ```bash
   cd /tmp && gh repo clone halinskiy/3mpq-studio
   cd 3mpq-studio
   rm -f assets/index-*.js assets/index-*.css index.html
   cp -R /Users/3mpq/3mpq-studio-export/dist/. ./
   git add -A && git commit -m "content: refresh Corder card"
   git push origin gh-pages
   ```
5. GitHub Pages picks up the push within ~30 s.

## Current copy (state at last refresh)

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
  icon: `${BASE}icons/corder.svg`,
  type: 'product',
  downloadUrl: 'https://github.com/halinskiy/Corder/releases/latest/download/Corder.zip',
}
```
