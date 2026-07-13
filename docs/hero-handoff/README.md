# Corder Library, hero handoff

This folder is a 1:1 dump of the actual Library window from the running
Corder app. Use these files to recreate the hero block: everything here
is read out of the app itself, so it wins over any second-hand
description of the UI.

## What's in here

| File | Contents |
|---|---|
| `library-window.html`        | Full DOM dump of `.app` taken from a live WKWebView. Open it in a browser to inspect, `styles.css` is referenced relatively, so the file renders standalone. |
| `styles.css`                 | The real, full CSS file from `Web/src/styles.css`, every token, every component rule. Tokens are at the top (`:root { --bg: ...; --accent: ...; ... }`). |
| `format.ts`                  | `formatDate`, `formatDuration`, `dateBucket`, the helpers that produce the localised labels you see (`Today, 17:09`, `12m 04s`, `TODAY`). |
| `components/MeetingView.tsx` | Header (breadcrumb · Boost switch · EN / Copy / Delete), wires the rest. |
| `components/Sidebar.tsx`     | Meeting list with date buckets, participants count, status dot, preview line. |
| `components/TranscriptPane.tsx` | Speaker grouping, search highlight, banner switching. |
| `components/RightPanel.tsx`  | Audio scrubber + per-speaker timeline (the right column). |
| `components/Donate.tsx`      | Floating "Buy me a coffee" FAB, bottom-right of the window. |

## The typeface, since it gets guessed wrong

Corder is often assumed to use IBM Plex. **It doesn't.** The real font
stack (verified via `getComputedStyle` in the running app) is:

```
font-family:
  -apple-system,
  "system-ui",
  "SF Pro Text",
  Inter,
  system-ui,
  sans-serif;
```

So on macOS users see San Francisco; the web hero will fall through to
Inter (or whatever the landing already loads). No custom `@font-face`, nothing to ship in fonts/.

Other corrections vs. the brief:

- **Speaker avatars use TWO letters**, not one. The `initial()` helper
  in `TranscriptPane.tsx` returns first-letter-of-first-word +
  first-letter-of-last-word, so `Kostiantyn Halynskyi` → `KH`.
  Single-word names render a single uppercase letter as a fallback.
- **Speaker names are full names** (`Kostiantyn Halynskyi`,
  `Vadym Grosko`), not the first names in the brief.
- The window is **not** a card-inside-a-card; the sidebar runs the full
  height of the WKWebView, side by side with the main pane.
- The right-panel timeline `.tl-bar` height is **20 px** with **2 px**
  ticks every ~220 ms of speech (the brief said something else
  earlier, trust this).
- Search input height: **34 px** (font 13 + padding 8/8 + 1 border).
- Toolbar icon button at the right of the search: **38 × 38**, circle.
- Buy-Me-a-Coffee FAB lives at fixed bottom-right (44 × 44, 999 radius,
  `--bg` fill, `--border-strong` outline). Render it for the hero too, it's a real product surface, not landing-only chrome.

## Tokens (verbatim from `styles.css :root`)

```css
:root {
  /* surfaces */
  --bg:             #ffffff;
  --bg-elev:        #f7f7f6;     /* sidebar */
  --bg-hover:       #fafaf8;
  --bg-active:      #f3f3f1;
  --bg-input:       #ffffff;

  /* lines & text */
  --border:         #ececea;
  --border-strong:  #d8d8d4;
  --fg:             #0e0e0d;
  --fg-muted:       #6b6b68;
  --fg-dim:         #a0a09c;

  /* brand */
  --accent:         #1f7a4f;
  --accent-pressed: #186439;
  --accent-tint:    #dff1e5;
  --danger:         #b8443c;
  --record:         #dd3340;

  /* speaker palette */
  --speaker-1:      #5a3aa6;     /* purple */
  --speaker-2:      #1f7a4f;     /* green */
  --speaker-3:      #b03a3a;     /* red */
  --speaker-4:      #1a4f8a;     /* blue */
}
```

## DOM hierarchy (top-level skeleton)

```
.app                                    grid 240px 1fr, height 100vh
├── .sidebar                            flex column, --bg-elev fill,
│                                       hairline drawn as a background gradient
│   ├── .sidebar-titlebar-pad           36 px under macOS title bar
│   ├── .sidebar-search                 wraps the search input + magnifier
│   └── .sidebar-list                   overflow-y: auto, contains:
│       ├── .sidebar-section-label      TODAY / YESTERDAY / THIS WEEK
│       ├── .meeting-item               (.active for selected row)
│       │   ├── .meeting-row            title + .meeting-people (count + 👤)
│       │   ├── .meeting-meta           status-dot + duration
│       │   └── .meeting-preview        first-segment text, 2-line clamp
│       └── .sidebar-list-spacer        24 px in-flow spacer
└── .main
    ├── .main-header                    breadcrumb + boost-switch + spacer
    │                                   + .toolbar (EN / Copy / Delete)
    └── .detail
        ├── .detail-tabs                grid (1fr 380px), tab labels above
        │   ├── .detail-tab-col-left    "Transcript" tab
        │   └── .detail-tab-col-right   "Recording" tab
        └── .detail-body                grid (1fr 380px)
            ├── .transcript-wrap        flex column
            │   ├── .transcript-toolbar search input + .toolbar-icon-btn
            │   └── .transcript         overflow-y: auto, segments
            │       └── .segment-group  speaker head + paragraph
            │           ├── .segment-head    avatar + name
            │           ├── .segment-paragraph  speech text (with highlights)
            │           └── ...
            └── .right-panel            audio-controls + timeline-card
                ├── .audio-controls     play btn + time + scrub bar
                └── .timeline-card      "Timeline" tab + .tl-row × N
                    └── .tl-row         name+stats + .tl-bar with ticks
```

## Sample data shapes

Sidebar row (from `Web/src/api.ts → MeetingSummary`):

```ts
{
  id: "uuid",
  started_at: 1777905659364,           // ms epoch
  duration_ms: 28000,
  status: "ready" | "recording" | "transcribing" | "failed",
  preview: "He says it's almost there, just a few days left.",
  speaker_count: 2,
  speaker_names: "Kostiantyn Halynskyi · Vadym Grosko",  // "·"-joined
}
```

Transcript segment (from `MeetingDetail.segments[]`):

```ts
{
  id: 4711,
  speaker_id: "<meeting-id>-other-0",
  start_ms: 1200,
  end_ms: 5400,
  text: "Right, so the next step is to validate it.",
  text_boost: null,                     // or polished version when Boost ran
}
```

Speaker (from `MeetingDetail.speakers[]`):

```ts
{
  id: "<meeting-id>-you" | "<meeting-id>-other-0",
  label: "Speaker 1" | "Speaker 2" | ...,
  custom_name: "Kostiantyn Halynskyi" | "you" | null,
  color_hex: "#3b82f6",
}
```

If `custom_name === "you"`, render the speaker name as `"I"` and use the
purple speaker-1 colour for the avatar.

## How to recreate the hero block

1. Open `library-window.html` in a browser. That's the live DOM exactly
   as Corder ships it. Use DevTools to grab any subtree you want.
2. Strip out the parts you don't need (the Donate FAB and toast layer
   are direct siblings of the sidebar, remove them if the hero shows
   only the window).
3. Inline `styles.css` (or scope it under the hero container if it
   collides with the landing's tokens, they share `--accent`, etc.).
4. Replace meeting / segment data with whatever you want the hero to
   read. Keep timestamps and speaker counts plausible.

If anything still looks off after copying these files, the answer is
almost always either: (1) you forgot to include `styles.css` ancestors
(`:root` tokens, the `.app { display: grid }` rule), or (2) you swapped
the font. The font-stack above is the single source of truth.
