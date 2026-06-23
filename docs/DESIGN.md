# Design system

> The Library window is what users actually look at. Everything in this
> document drives what they see. If a component, colour, or font weight
> isn't here, it shouldn't be in the UI either.

## Tone

Calm, editorial, a little serious. Mindtrip × Merge — generous whitespace,
hairlines instead of cards, mono captions for every numeric thing. The
product records private conversations; loud SaaS ergonomics would
undermine that. No emoji, no exclamation marks, no "AI" jargon.

The voice rule for any new copy: speak to "you", never "we". One claim
per sentence. End headlines with periods. Banned words: powered by,
seamlessly, unlock, leverage, cutting-edge, revolutionary, transform.

## Colour

### Tokens (Web/src/styles.css `:root`)

```
--bg            #ffffff       page / card backgrounds
--bg-elev       #f7f7f6       elevated surfaces (sidebar, etc.)
--bg-hover      #fafaf8       hover tint — almost imperceptible
--bg-active     #f3f3f1       pressed state for transparent buttons
--bg-input      #ffffff       inputs

--border        #ececea       hairlines, dividers
--border-strong #d8d8d4       framed buttons, banner outlines

--fg            #0e0e0d       text, icons, primary content
--fg-muted      #6b6b68       secondary text, eyebrows
--fg-dim        #a0a09c       meta (dates, sizes, version strings)

--accent         #0e7c44      single brand colour (light): CTA, selected
                              pills, toggle ON, link, ::selection.
                              Dark theme: #1f9d59.
--accent-pressed #0a5e34      hover/pressed state for accent (light).
                              Dark theme: #178048.

--danger        #b8443c       destructive only: Stop recording,
                              Delete session, error toast
--record        #dd3340       live recording indicator (animated dot)

--speaker-1..4               purple / green / red / blue — assigned
                              to "other" speakers in arrival order
```

### Hard rules

- **Never** use black (`--fg`) as a fill for selected states, CTA, or
  toggle ON. Black is for text and icons only. The accent is green.
- Red appears at most once per surface and only on something destructive.
  Two reds = bad design.
- No gradients except the very faint accent-tint wash behind the Local
  Mode card on the privacy section of the marketing site.
- Selected state has **no hover treatment**. Once a pill is the answer,
  hovering it doesn't make it "more selected" — it stays put. Other
  pills in the row still respond to hover normally.

## Typography

Three IBM Plex families:

```
display        IBM Plex Serif       300 / 400 / 500
body / UI      IBM Plex Sans        400 / 500 / 600
mono / spec    IBM Plex Mono        400 / 500
```

### Scale

```
Display    96 / 72 / 56     Plex Serif 300/300/400, tracking -0.02em
H1         40                Plex Serif 400
H2         28                Plex Serif 500
H3         22                Plex Serif 500

Body
- lede     20                Plex Sans 400
- long     18                Plex Sans 400
- ui       16                Plex Sans 500 (default)
- meta     14                Plex Sans 400, --fg-muted
- meeting  13.5              sidebar meta line
- pill     13                Plex Sans 500 (button labels)

Mono spec  13 / 14           Plex Mono 400, tabular-nums, --fg-dim

Eyebrow    12                Plex Sans 600, uppercase, tracking 0.04em
                              Used above every section H1.
```

### Universal rules

- `text-wrap: balance` on every heading.
- `text-wrap: pretty` on every paragraph.
- `font-variant-numeric: tabular-nums` anywhere a number changes
  (timer, file size, bucket counts, countdown).
- Never set line-height below 1.3 for body, never above 1.5 for
  display.

## Spacing

Four-step scale (multiples of 4):

```
4 · 8 · 12 · 16 · 24 · 32 · 48 · 64 · 96 · 120
```

- Section gutter desktop = 120, mobile = 64.
- Inside cards: padding 24-32.
- Heading → body: 24.
- Body → CTA: 32.
- Inline gaps in toolbar: 6-10.

## Radii

```
6   sm        small chips, tags
8   default   buttons, inputs, banner CTAs
12  cards     audio card, timeline card, modals
999 pill      navigation buttons, badges, status dots,
              toolbar CTAs, toast pills
```

The transcript-toolbar's icon-only Users button uses `border-radius: 50%`
because it's a circle, not a pill.

## Motion

- Easing: `cubic-bezier(0.16, 1, 0.3, 1)` — soft start, hard stop.
- Durations: 150 / 240 / 480ms.
- Hover transitions: 80-150ms (faster, because they're constant).
- Toast in: 280ms transform, 220ms opacity (slides up from y+32).
- Toast out: same curve, mirror direction.
- Banner expand/collapse: max-height + opacity, 240ms.
- No scroll-driven anything. No parallax. No marquees.

### Recording indicator

The floating recording HUD (a native NSPanel pill, all Spaces) shows a
real-time frequency-spectrum equalizer, not the old "blob". Each bar is
a genuine FFT frequency band (low to high) driven by
`RecordingLevelMeter.spectrum`, so lows / mids / highs react
independently and the shape tracks actual sound. Bars sit at a short
resting height (never collapse to dots) and animate toward each new band
level. The in-window recording indicator (the embedded blob in the
Library window bottom-right) was removed; recording is started and
stopped from the menu-bar popover and the global hotkey.

## Shadows

Light theme only:

```
sm        0 1px 2px  rgba(0,0,0,0.04)
default   0 6px 24px rgba(0,0,0,0.06)
lg        0 24px 64px rgba(0,0,0,0.08)
```

Toasts have **no shadow** — by user preference. Let the hairline border
do the lifting.

## Components

### Logo

Vertical split squircle. Left half ink (#0e0e0d) with a centred
record dot in `--record`. Right half paper (#fafaf8) with two thin
centred pause bars in `--fg`. Render at 28 (nav), 48 (footer), 128
(final CTA / app icon mosaic). Never re-stroke; let the system mask
clip on Tahoe.

The wordmark is "Corder" in IBM Plex Serif 400.

### Buttons

```
Primary CTA        --accent fill, white text, 14×28, 999 radius
Header pill        transparent, --border-strong outline, --fg text,
                   8×14, 999 radius — the EN / Copy / Delete row
Toolbar circle     38×38, --border-strong outline, 50% radius,
                   icon only; .active state = --bg-hover slightly
                   darker, no hover feedback
Banner action      transparent, --border-strong outline, --fg text,
                   13×16, 8 radius (Stop transcription, clarify pills)
Destructive        --danger fill, white text — Stop recording,
                   Delete session, Undo button on error toast
Boost toggle       custom switch — green when ON
```

### Banners

Three banner cards share the same outline-card visual language
(`max-width: 360-420`, `1px --border-strong`, `12 radius`, padding
`14×16`):

- **RecordingBanner** — live recording. Red dot pulses, timer counts
  up, "Stop recording" red CTA.
- **TranscribingBanner** — transcription in progress. Green spinner,
  timer, "Stop transcription" white outline CTA.
- **SpeakersClarifyBanner** — "How many people were on the call?"
  Four pills, X-dismiss in top-right corner. Active pill is
  `--accent-pressed` (slightly darker than --accent), no hover.
- **EmptyDeleteBanner** — for `status === ready` empty / `status ===
  failed`. Reuses the clarify card outline. Failed variant adds a
  Re-transcribe (white outline) above the destructive Delete (red).
  The "not transcribed yet" variant adds a Transcribe (white outline)
  above the Delete so the user can transcribe on demand when
  auto-transcribe is off.

### Popups (`.modal-pop`)

Sits in the `.donate-overlay` blurred backdrop and reads like an
enlarged inline banner — the same outline-card visual language as
the cards above so popups feel like the same product, not like a
stock OS alert.

- 12 px radius, 1 px `--border-strong`, `0 10px 32px rgba(0,0,0,.14)`
  shadow (subtle — the heavier 24/64 shadow on the older
  `.donate-card` read as generic platform chrome).
- Width per-instance: Archive 560 px, Download 380 px.
- Title — `.modal-pop-title`, 18/300 (mirrors `.clarify-body`, the
  banner heading).
- Subtitle — `.modal-pop-note`, 14/1.55 muted (segment-paragraph
  character, tightened to the title via negative margin-top).
- Close X — `.modal-pop-close`, top-right, borderless, hover bg only.
- Actions — `.clarify-btn` / `.clarify-btn.danger` (inline-flex with
  gap, icon+label centred).

Used by **ArchiveView** and **DownloadMenu**. The download chooser
offers two products: "Video + audio" (the silent screen video muxed with
the audio, served from `/video-audio.mp4`) and "Audio" (compressed AAC,
served from `/audio.m4a`). The old silent video-only download is gone.
The Donate modal keeps its own `.donate-card` shell because its content
is a 3-up amount grid with very different geometry. Don't introduce a third modal
style — extend `.modal-pop` instead.

### Update & Pricing modal (`.update-overlay` / `.update-card`)

A separate, richer shell from `.modal-pop` — a centred card on a
dimmed full-viewport backdrop with `StarsCanvas`, cursor-tilt
parallax, a cursor-following sheen, and a scale/fade entrance. Both
the **UpdateModal** and the **PricingModal** use it; the pricing modal
is the canonical "reuse, don't reinvent" case.

- Backdrop `.update-overlay`, card `.update-card` (380 px, 16 radius),
  buttons `.update-primary` (accent fill) / `.update-secondary`
  (outline). Secondary `is-active` = pressed (used by the pricing
  "Details" toggle, same vocabulary as the update modal's `?` toggle).
- **Update modal:** button label is ALWAYS "Install" — never a frozen
  "Installing…". At rest: no progress, no spinner. After the click:
  the label is replaced by a centred Loader2 spinner, plus a
  left-anchored fill (`.update-primary-fill`, like `.trans-stop-fill`)
  ONLY for a real download. Release notes render as plain text (no
  markers, no duplicate version heading).
- **Pricing modal:** ONE card holds Pro + Max columns split by a
  hairline (Free omitted; it's an upgrade surface). Each column shows
  name + price + yearly note, with "Upgrade" + "Details"; Details
  swaps the face for the feature list in place (no grey panel, no
  scrollbar). Plan data mirrors getcorder.com.

### Inline report link (`.report-link`)

Inside an AI-pane error card, the word "Send a report" is a green
(`--accent`), bold, borderless button that underlines on hover and
ships the diagnostic log (same backend as the header bug-report
button). Use for "this failed, tell us" affordances, not for navigation.

### Toasts

Bottom-centre, pill, 280ms slide-up enter, mirror slide-down exit.
- **Success / info** — white fill, hairline border, ink text. No
  shadow. No countdown. Auto-dismiss 2.2 s.
- **Error** — `#c4423a` fill, white text. Used for delete + undo:
  optional Undo button + live "5s · 4s · 3s" countdown.

### Sidebar

- `bg-elev` left rail, hairline divider as a vertical gradient (the
  scrollbar visually sits *on* the hairline — see the gradient trick
  in `.sidebar` styles).
- Section labels (TODAY / YESTERDAY / N DAYS AGO) in eyebrow 12/600
  uppercase. First label has no separator above; subsequent labels
  carry a top hairline + 18px breathing room.
- Meeting rows: 13/500 title (`Today, 17:56`), 13.5/400 meta, status
  dot 8×8 with semantic color.

### Transcript pane

- 8/20/80 padding (top breathing, sides, bottom).
- Hairline divider on the right edge using the same scrollbar-on-line
  gradient trick as the sidebar.
- Speaker groups: avatar (28px circle, deterministic colour from
  PALETTE), name, paragraph. Search highlights wrap segments in
  `--accent-tint` (`#dff1e5`) with green text.

### Right panel

- Audio scrub: 8 px tall by default, 10 px on hover. Pill-shape.
  Fill is `--fg`, hover tooltip shows `MM:SS`.
- Per-speaker timeline: 20 px bar with coloured ticks at speaker
  segments. Ticks are 2px wide, every 220 ms of speech.
- Cursor: black 1px line, never replaced for contrast.
- Screen-video preview: FIXED-size card (200px tall, `object-fit: cover`,
  no rounding) so every recording's preview is identical regardless of
  its native resolution. The card is `flex-shrink: 0` and the panel's
  native scrollbar is hidden so neither a tall timeline nor a scrollbar
  can change its width.

### Dashboard Upcoming tab

- A plain chronological list of calendar meetings, NOT boxed cards: each
  row is full-width with a 1px `--border` divider, text inset 20px, and
  the dividers never react to hover (the hover fill is an inset pseudo
  layer and the global `button:hover` border-darken is overridden).
- Reuses existing type tokens, no bespoke fonts: meeting title in
  `.clarify-body` (18/300, the "Ready when you are" voice), the date/time
  in `.meeting-title` (14/500, the sidebar session-title voice). Meeting
  service logo (Google Meet) at 24px on the left.

## Frontend conventions

- Components live under `Web/src/components/`, single file per
  component, named exports.
- All copy goes through `Web/src/i18n.ts`. 20 locales listed in the
  `LANGS` constant (picker order: **en → uk → ru → global popularity**).
  Three locales are fully translated (`en`, `ru`, `uk`); the rest
  resolve to English at runtime via `pickStrings(lang)`. Never inline
  a string in JSX; when adding a key, populate at least the three
  full locales and let `pickStrings` handle the rest until they ship.
- API layer: `Web/src/api.ts`. One typed wrapper per endpoint.
- Format helpers: `Web/src/format.ts` (durations, dates, buckets).
- Global styles: `Web/src/styles.css`. Tokens at the top, components
  grouped together. No CSS modules, no Tailwind. Plain CSS with
  custom properties.

## Frontend dependencies

```
react           ^18.3.0      UI runtime
react-dom       ^18.3.0
lucide-react    ^1.14.0      icon set (use sparingly)
flag-icons      ^7.x         CSS sprite of SVG country flags used by
                             the LangPicker; emoji flags render poorly
                             on Windows / Linux WebViews, so we
                             ship SVGs instead. CSS sprite is the only
                             part bundled (~94 KB gzipped CSS — the
                             one big concession to our bundle budget).
vite            ^5.4.0       dev server / bundler
typescript      ^5.5.0       strict
```

No state library, no router, no CSS-in-JS. Every additional dependency
must justify its existence — the JS bundle is ~58 KB gzipped today,
and that's the budget (the flag-icons CSS sprite is tracked
separately).

## What good looks like

- A new screen ships with no Lorem.
- Headings end in periods.
- The eye can count green appearances on the page (5, max 7).
- Red appears once or zero times.
- The screen reads from top to bottom without explanatory tooltips.
- Hairline dividers > card outlines wherever there's a choice.
- The number of fonts on the screen is exactly three (Serif / Sans / Mono).
