# Corder — Hero UI brief for Claude Design

This is everything the landing-page Claude needs to recreate the Library
window as a live HTML/CSS block in the hero section instead of a
screenshot. Tokens, structure, sample data are all final — copy them
verbatim. The visual reference is the actual macOS app at v0.7.

---

## 1. Hero composition

The Library window in its most representative state:

- **Sidebar (left)** — search, grouped meeting list (TODAY / YESTERDAY /
  THIS WEEK), one row in active state.
- **Main pane (centre)** — header row (breadcrumb + green Boost ON
  toggle + outline buttons EN / Copy / Delete), then transcript with
  two speakers and one search-highlight phrase.
- **Right panel (right)** — audio scrubber + per-speaker timeline.

Window dimensions in the real app: **1180 × 760**, radius 12, soft
drop shadow, transparent macOS title bar with the standard traffic-light
buttons in the top-left corner.

---

## 2. Design tokens (from `Web/src/styles.css :root`)

```css
:root {
  /* Backgrounds */
  --bg:             #ffffff;
  --bg-elev:        #f7f7f6;     /* sidebar fill */
  --bg-hover:       #fafaf8;     /* hover tint, almost imperceptible */
  --bg-active:      #f3f3f1;
  --bg-input:       #ffffff;

  /* Borders */
  --border:         #ececea;     /* hairlines, scrollbar dividers */
  --border-strong:  #d8d8d4;     /* outline buttons, banner cards */

  /* Text */
  --fg:             #0e0e0d;     /* primary text + icons */
  --fg-muted:       #6b6b68;     /* secondary text, eyebrows */
  --fg-dim:         #a0a09c;     /* meta — sizes, dates, version */

  /* Brand — single accent, green */
  --accent:         #1f7a4f;     /* CTA, selected state, ::selection,
                                    active toggle, link */
  --accent-pressed: #186439;     /* hover/pressed */
  --accent-tint:    #dff1e5;     /* highlight wash for search matches */

  /* Status */
  --danger:         #b8443c;     /* destructive only — Stop, Delete, error */
  --record:         #dd3340;     /* live record dot */

  /* Speaker palette — ticks on the timeline, avatar fills */
  --speaker-1:      #5a3aa6;     /* purple */
  --speaker-2:      #1f7a4f;     /* green */
  --speaker-3:      #b03a3a;     /* red */
  --speaker-4:      #1a4f8a;     /* blue */
}
```

Hard rules:
- Brand accent is **green**, never black. Black is only for text + icons.
- Red appears at most once per surface and only on something destructive.
- No gradients except the subtle sidebar-divider trick (see §6).
- Selected state has **no hover treatment**. Hover only on inactive items.

---

## 3. Typography

Three IBM Plex families, three weights of each:

```
Display    IBM Plex Serif      300 / 400 / 500
Body / UI  IBM Plex Sans       400 / 500 / 600
Mono       IBM Plex Mono       400 / 500   (numbers, sizes, version)
```

Inside the hero block, use **Plex Sans** for everything UI-like; **Plex
Mono** only for tabular numbers (durations, the breadcrumb time).

Sizes:

```
Breadcrumb               14 / 600
Meeting title (sidebar)  13 / 500
Meeting meta line        13.5 / 400 / --fg-muted / tabular-nums
Speaker name             15 / 600
Transcript paragraph     15 / 400 / line-height 1.55
Section label (TODAY)    11 / 600 / uppercase / letter-spacing 0.6px / --fg-dim
Audio time               13 / 500 / --fg / tabular-nums
Timeline % · duration    13 / 400 / --fg-muted / tabular-nums
Toolbar button label     13 / 500
```

Universal rules:
- `text-wrap: balance` on every heading.
- `text-wrap: pretty` on every paragraph.
- `font-variant-numeric: tabular-nums` everywhere a number changes (timer,
  durations, percentages).

---

## 4. Spacing, radii, motion

```
Spacing scale (4-step):  4 · 8 · 12 · 16 · 20 · 24 · 32 · 48 · 64
Radii:                   6 chips · 8 buttons & inputs · 12 cards · 999 pills
Motion:                  cubic-bezier(0.16, 1, 0.3, 1), 150 / 240ms
Hover transitions:       80–150ms
Shadow on Library card:  0 6px 24px rgba(0,0,0,0.06) (only one shadow on the page)
```

---

## 5. Window layout (ASCII)

```
┌── Library window (1180×760, radius 12, soft shadow) ─────────────────┐
│ [drag strip 28px tall, transparent — traffic lights live here]       │
│ ┌─ Sidebar (240px, --bg-elev) ─┐ ┌─ Main (1fr, --bg) ──────────────┐ │
│ │ ┌─ Search input (pill) ────┐ │ │ ┌─ Header row (h:60-ish) ─────┐ │ │
│ │ │ 🔍 Search recordings…    │ │ │ │ Recordings › Today, 17:09   │ │ │
│ │ └──────────────────────────┘ │ │ │  [Boost ON]   EN · Copy · 🗑 │ │ │
│ │                              │ │ └─────────────────────────────┘ │ │
│ │ TODAY                        │ │ ─── 1px hairline ──────────────  │ │
│ │ ─── 1px hairline ──          │ │ ┌─ Transcript pane ───┬─ Right ─│ │
│ │ ● Today, 17:09  2 👤  (act) │ │ │ ┌─ Search box ──┐    │  Audio  │ │
│ │   28s                        │ │ │ │ Search the…  │    │  ▶ 0:14 │ │
│ │   "He says it's almost…"     │ │ │ └──────────────┘    │  /4:32  │ │
│ │                              │ │ │                     │  ▓▓░░░░ │ │
│ │ ● Today, 16:20  3 👤         │ │ │ K  Kostya           │         │ │
│ │   12m 04s                    │ │ │ Right, so the      │ Timeline│ │
│ │   "Right, so the next…"      │ │ │ next step is to    │         │ │
│ │                              │ │ │ validate it.        │ you 43% │ │
│ │ YESTERDAY                    │ │ │                     │ ▌▌▌  ▌▌ │ │
│ │ ─── 1px hairline ──          │ │ │ V  Vadym            │         │ │
│ │ ● Yesterday, 18:51  2 👤     │ │ │ Hmm, let me think  │ Vadym 7%│ │
│ │   23s                        │ │ │ about that…         │ ▎▎▎▎▎   │ │
│ │   "you start recording…"     │ │ │                     │         │ │
│ │                              │ │ │ K  Kostya           │         │ │
│ │ THIS WEEK                    │ │ │ Good point — I'll  │         │ │
│ │ ─── 1px hairline ──          │ │ │ write that up.      │         │ │
│ │ ● May 1, 16:20  3 👤         │ │ │ ...                 │         │ │
│ │   40m 00s                    │ │ │                     │         │ │
│ └──────────────────────────────┘ └────────────────────────┴─────────│ │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

Grid: `.app { display: grid; grid-template-columns: 240px 1fr; height: 100vh; }`.

---

## 6. Sidebar

```html
<aside class="sidebar">
  <div class="sidebar-titlebar-pad"></div>     <!-- 36px under macOS title bar -->
  <div class="sidebar-search">
    <input type="search" placeholder="Search recordings…" />
  </div>
  <div class="sidebar-list">
    <div class="sidebar-section-label">TODAY</div>

    <div class="meeting-item active">
      <div class="meeting-row">
        <div class="meeting-title">Today, 17:09</div>
        <span class="meeting-people">2 <UserIcon/></span>
      </div>
      <div class="meeting-meta">
        <span class="status-dot ready"></span>
        <span>28s</span>
      </div>
      <div class="meeting-preview">
        He says it's almost there, just a few days left.
      </div>
    </div>

    <!-- ...more rows... -->

    <div class="sidebar-section-label">YESTERDAY</div>
    <!-- ...rows... -->

    <div class="sidebar-list-spacer"></div>      <!-- 48px, real last child -->
  </div>
</aside>
```

CSS specifics worth keeping faithful:

- `.meeting-item` — padding `10px 10px`, radius 6, `cursor: pointer`,
  hover `#ececea`, active `#e8e8e5` (slightly darker than hover).
- `.meeting-item + .meeting-item { border-top: 1px solid var(--border) }`
  — hairline between consecutive cards in the same date bucket.
- `.meeting-item + .sidebar-section-label { border-top: 1px solid
   var(--border); padding-top: 18px; margin-top: 12px; }` — bigger break
  between buckets.
- The sidebar's right edge has a **1px vertical hairline drawn as part of
  its background gradient**, not as a separate element. This is a
  signature Corder detail — the native scrollbar paints on top of the
  line and the whole thing reads as one polished unit:

  ```css
  .sidebar {
    background:
      linear-gradient(to right,
        transparent 0,
        transparent calc(100% - 4px),
        var(--border) calc(100% - 4px),
        var(--border) calc(100% - 3px),
        transparent calc(100% - 3px),
        transparent 100%),
      linear-gradient(to right,
        var(--bg-elev) 0,
        var(--bg-elev) calc(100% - 4px),
        transparent calc(100% - 4px),
        transparent 100%);
    display: flex; flex-direction: column;
    overflow: hidden;
  }
  ```

- The `.transcript-wrap` carries the same trick on its right edge so the
  transcript→right-panel split mirrors the sidebar→main split.

`.status-dot` palette:

```
.status-dot.ready        { background: #1f7a4f }   /* green dot */
.status-dot.recording    { background: #dd3340; animation: pulse 1.6s; }
.status-dot.transcribing { background: #d97706; animation: pulse 1.6s; }
.status-dot.failed       { background: #b8443c; opacity: 0.4 }
```

Size: `8 × 8` since v0.6 (was 6 × 6 — bigger reads better).

---

## 7. Transcript pane

```html
<div class="transcript-wrap">
  <div class="transcript-toolbar">
    <input type="search" placeholder="Search the transcript…" />
    <button class="toolbar-icon-btn"><UsersIcon/></button>   <!-- 38×38 round -->
  </div>

  <div class="transcript">
    <div class="segment-group">
      <div class="segment-head">
        <div class="speaker-avatar" style="background: #5a3aa6">K</div>
        <div class="speaker-name">Kostya</div>
      </div>
      <div class="segment-paragraph">
        Right, so the next step is to validate it.
        <span class="segment-highlight">Let's circle back on Thursday.</span>
        Sounds reasonable.
      </div>
    </div>

    <div class="segment-group">
      <div class="segment-head">
        <div class="speaker-avatar" style="background: #1a4f8a">V</div>
        <div class="speaker-name">Vadym</div>
      </div>
      <div class="segment-paragraph">
        Hmm, let me think about that for a second. Good point — I'll write
        that up.
      </div>
    </div>

    <!-- ...more groups... -->
  </div>
</div>
```

Styles to copy:

```css
.speaker-avatar {
  width: 28px; height: 28px;
  border-radius: 50%;
  color: #fff;
  font: 600 12px/1 "IBM Plex Sans", system-ui;
  display: flex; align-items: center; justify-content: center;
  flex-shrink: 0;
}
.segment-group     { display: flex; flex-direction: column; gap: 8px; }
.segment-head      { display: flex; align-items: center; gap: 10px; }
.speaker-name      { font: 600 15px/1 "IBM Plex Sans"; color: var(--fg); }
.segment-paragraph {
  font: 400 15px/1.55 "IBM Plex Sans";
  color: var(--fg);
  padding-left: 38px;     /* aligns the paragraph under the speaker name */
}
.segment-highlight {
  background: var(--accent-tint);
  padding: 1px 4px;
  border-radius: 3px;
}
.transcript {
  padding: 8px 20px 80px;
  display: flex; flex-direction: column;
  gap: 28px;
}
.transcript-toolbar { padding: 20px 20px 12px; display: flex; gap: 10px; }
.transcript-toolbar input { flex: 1; max-width: 480px; }
.toolbar-icon-btn {
  width: 38px; height: 38px;
  border-radius: 50%;
  border: 1px solid var(--border-strong);
  background: transparent;
  color: var(--fg-muted);
  display: inline-flex; align-items: center; justify-content: center;
}
```

---

## 8. Right panel — audio + timeline

```html
<div class="right-panel">
  <div class="audio-controls">
    <button class="audio-btn audio-btn-primary">▶</button>
    <div class="audio-time">0:14 / 4:32</div>
    <div class="audio-scrub">
      <div class="audio-scrub-fill" style="width: 5%"></div>
    </div>
  </div>

  <div class="timeline-card">
    <div class="timeline-tabs">
      <span class="timeline-tab active">Timeline</span>
    </div>

    <div class="tl-row">
      <div class="tl-row-head">
        <span class="tl-name">you</span>
        <span class="tl-stats">43% · 1m 58s</span>
      </div>
      <div class="tl-bar">
        <div class="tl-bar-tick" style="left:5%;  background:#1a4f8a"></div>
        <div class="tl-bar-tick" style="left:7%;  background:#1a4f8a"></div>
        <div class="tl-bar-tick" style="left:11%; background:#1a4f8a"></div>
        <!-- ...lots more ticks bunched in 2-3 clusters... -->
        <div class="tl-bar-cursor" style="left:5%"></div>
      </div>
    </div>

    <div class="tl-row">
      <div class="tl-row-head">
        <span class="tl-name">Vadym</span>
        <span class="tl-stats">7% · 17s</span>
      </div>
      <div class="tl-bar">
        <!-- sparser purple ticks -->
      </div>
    </div>
  </div>
</div>
```

Specs:

- `.right-panel` width = **380px**.
- `.audio-controls` — 36×36 primary play button, `--accent` fill, white
  glyph. Padding `20 20 12`.
- `.audio-scrub` — 8px tall pill, `--bg-paper` fill, `--fg`-coloured
  `audio-scrub-fill` inside. Hover swells height to 10px (skip in
  hero — static is fine).
- `.timeline-card` — radius 12, 1px `--border` outline, padding 16-20.
- `.tl-bar` — height 20px, white fill, 1px `--border` outline, radius 2.
- `.tl-bar-tick` — 2px wide, full height, every ~220 ms of speech.
  Colour comes from the speaker palette.
- `.tl-bar-cursor` — 1px black vertical line marking current playhead.

---

## 9. Header (breadcrumb + Boost + tools)

```html
<div class="main-header">
  <div class="breadcrumb">
    <span>Recordings</span>
    <span style="opacity:0.4">›</span>
    <span class="breadcrumb-current">Today, 17:09</span>
  </div>

  <button class="boost-switch on">
    <span class="boost-track"><span class="boost-thumb"></span></span>
    <span class="boost-label">Boost</span>
  </button>

  <div class="spacer"></div>

  <div class="toolbar">
    <button><GlobeIcon/> EN</button>
    <button><CopyIcon/> Copy</button>
    <button class="ghost danger"><TrashIcon/> Delete</button>
  </div>
</div>
```

Boost switch:

```css
.boost-switch {
  background: transparent;
  border: 1px solid var(--border-strong);
  border-radius: 999px;
  padding: 7px 14px 7px 16px;
  margin-left: 8px;
  display: inline-flex; align-items: center; gap: 8px;
  font: 500 13px "IBM Plex Sans"; color: var(--fg-muted);
}
.boost-switch.on             { background: var(--accent); border-color: var(--accent); color: #fff; }
.boost-switch.on .boost-label{ color: #fff }
.boost-track {
  width: 26px; height: 14px; border-radius: 999px;
  background: rgba(0, 0, 0, 0.12);
  position: relative;
}
.boost-switch.on .boost-track { background: rgba(255, 255, 255, 0.55); }
.boost-thumb {
  width: 10px; height: 10px; border-radius: 50%;
  background: #fff;
  position: absolute; top: 2px; left: 2px;
  transition: transform 150ms ease;
}
.boost-switch.on .boost-thumb { transform: translateX(12px); background: #fff; }
```

Toolbar buttons (`EN`, `Copy`, `Delete`) all share the same shape:

```css
.toolbar button {
  background: transparent;
  border: 1px solid var(--border-strong);
  color: var(--fg);
  border-radius: 999px;
  padding: 8px 14px;
  font: 500 13px "IBM Plex Sans";
  display: inline-flex; align-items: center; gap: 6px;
}
.toolbar button:hover { background: var(--bg-hover); border-color: #b8b8b4; }
```

---

## 10. Icons (Lucide)

| Where | Lucide name | Size | Stroke |
|---|---|---|---|
| Search input prefix | `search` | 14 | 2 |
| Header — language | `globe` | 14 | 2 |
| Header — Copy | `copy` | 14 | 2 |
| Header — Delete | `trash-2` | 14 | 2 |
| Toolbar circle (right of search) | `users` | 16 | 2 |
| Sidebar — participants count | `user` | 14 | 2 |

Audio play button is hand-rolled SVG, not Lucide:

```svg
<svg viewBox="0 0 16 16" width="14" height="14" fill="currentColor">
  <path d="M4 2.5v11c0 .6.7 1 1.2.6l8.4-5.5a.7.7 0 0 0 0-1.2L5.2 1.9C4.7 1.5 4 1.9 4 2.5z" />
</svg>
```

---

## 11. Sample data

Two speakers, 14 turns, one search-highlight phrase. Use as is —
already sounds like a real conversation rather than Lorem.

```js
const speakers = {
  K: { name: "Kostya", color: "#5a3aa6" },  // purple
  V: { name: "Vadym",  color: "#1a4f8a" },  // blue
};

const transcript = [
  { spk: "K", text: "Right, so the next step is to validate it." },
  { spk: "V", text: "Hmm, let me think about that for a second." },
  { spk: "V", text: "Good point — I'll write that up." },
  { spk: "K", text: "Yes, exactly. We can go that route." },
  { spk: "K", text: "Let's circle back on Thursday.", highlight: true },
  { spk: "V", text: "Sure, sounds reasonable." },
  { spk: "K", text: "What about the timeline?" },
  { spk: "V", text: "I'm not sure that fits the current scope." },
  { spk: "K", text: "Okay, makes sense. We'll re-scope and follow up." },
  { spk: "V", text: "One more thing — we should loop in the design team." },
  { spk: "K", text: "Agreed. I'll send a note tonight." },
  { spk: "V", text: "Thanks. That should unblock us." },
  { spk: "K", text: "Cool. Talk Thursday." },
  { spk: "V", text: "Talk Thursday." },
];
```

Sidebar list — 6 rows across three buckets:

```js
const sidebarMeetings = [
  { bucket: "TODAY",     date: "Today, 17:09",       dur: "28s",    speakers: 2, preview: "He says it's almost there, just a few days left.", active: true },
  { bucket: "TODAY",     date: "Today, 16:20",       dur: "12m 04s",speakers: 3, preview: "Right, so the next step is to validate it." },
  { bucket: "YESTERDAY", date: "Yesterday, 18:51",   dur: "23s",    speakers: 2, preview: "you start recording, say something." },
  { bucket: "YESTERDAY", date: "Yesterday, 17:00",   dur: "11s",    speakers: 1, preview: "The only problem is that, well, like…" },
  { bucket: "THIS WEEK", date: "May 1, 16:20",       dur: "40m 00s",speakers: 3, preview: "Right, so the next step is to validate it." },
  { bucket: "THIS WEEK", date: "May 1, 15:54",       dur: "1m 24s", speakers: 1, preview: "continues the investigation" },
];
```

Right panel timeline:

```js
const timelineRows = [
  {
    name: "you",
    color: "#1a4f8a",     // blue ticks
    pct: 43, duration: "1m 58s",
    // tick positions in % of the bar — clusters at 5-15%, 30-45%, 70-80%
    ticks: [5, 7, 9, 11, 13, 30, 32, 34, 36, 38, 40, 70, 72, 74, 76, 78, 80],
  },
  {
    name: "Vadym",
    color: "#5a3aa6",     // purple ticks
    pct: 7, duration: "17s",
    ticks: [25, 26, 28, 50, 52, 90, 91],
  },
];
```

---

## 12. Optional life

If the brief allows it:
- Subtle **moving cursor** on the audio scrub fill — left → right loop
  every 60 s, paused on hover so it doesn't jitter when the user reads.
- **Pulsing** record dot on the active sidebar row if the meeting status
  is "recording" (in this hero state we set it to `ready`, so leave the
  dot static — green, no animation).
- No marquees, no parallax, no scroll-jacking.

On mobile (<768px):
- Collapse the three-column layout into a single screenshot-equivalent
  card — show only the transcript pane with the header, hide sidebar
  + right panel. Keep the same fonts and tokens.

---

## 13. What NOT to invent

- Don't add a "Sign in" button. There is no auth.
- Don't add a Slack / Telegram avatar grid. The product is a personal
  recorder.
- Don't add gradient backgrounds, glow effects, or animated particles —
  the calm density is the point.
- Don't add a "Free / Pro / Enterprise" pricing tier in the window. The
  app is free, donations welcome via the Buy-Me-a-Coffee FAB which is
  intentionally outside the hero block.

That's everything. Drop the resulting HTML+CSS module under
`src/components/HeroLibraryDemo.tsx` (or whatever the landing layout
calls it), and import it in place of the current `<img src="…hero…">`
in the hero section. Tokens defined here can either replace the
landing's existing CSS variables (if they collide) or live scoped
under `.hero-library-demo` to avoid touching the rest of the page.
