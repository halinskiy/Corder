import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { ChevronDown, ChevronLeft, Check, Loader2 } from "lucide-react";
import { MeetingSummary } from "../api";
import { formatDate, formatDuration } from "../format";
import type { Lang, T } from "../i18n";
import { ResizeHandle } from "./ResizeHandle";
import { SettingsPane } from "./SettingsPane";

/// Same filled-bust glyph the sidebar uses next to each meeting's
/// speaker count — duplicated here (not exported from Sidebar.tsx) so
/// the Recent rows render the same chip without crossing components.
function UserFilledIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor" aria-hidden>
      <circle cx="6" cy="3.5" r="2.2" />
      <path d="M1.5 11c0-2.3 2-4 4.5-4s4.5 1.7 4.5 4v0.5h-9V11z" />
    </svg>
  );
}

type SortKey = "duration" | "recent" | "speakers";
const SORT_STORAGE_KEY = "corder.dashRecentSort";
const SORT_DEFAULT: SortKey = "duration";

interface Props {
  meetings: MeetingSummary[];
  /// Lifetime stats sample — all meetings EVER recorded, archived
  /// included. Drives the Stats card (Recordings / Total recorded /
  /// This week) so the counters reflect everything the user has
  /// produced, not just the current library subset. Only the
  /// `started_at` and `duration_ms` fields are read.
  statsMeetings: Array<{ started_at: number; duration_ms?: number }>;
  onPick: (id: string) => void;
  onStart: () => void;
  /// Mirrors `RecordingState.active` from the backend. When true, the
  /// Dashboard's primary card flips to a "still recording" headline +
  /// a red Stop button, so the surface stays in sync with the menu-bar
  /// HUD instead of pretending nothing is happening.
  isRecording: boolean;
  /// Called when the user hits Stop on the Dashboard card while
  /// `isRecording` is true. Same backend route as the menu-bar Stop.
  onStop: () => void;
  hotkeyLabel: string;
  t: T;
  lang: Lang;
  /// Forwarded into SettingsPane so the inline Language picker can
  /// flip the app-wide locale (lifted into App-level state). Kept on
  /// Dashboard's props rather than re-reading from a global because
  /// every other surface (MeetingView, MainHeader) takes the same
  /// handle for the same purpose — single source of truth.
  onLangChange: (next: Lang) => void;
  /// Hooks into the same `--right-w` setter as MeetingView so dragging
  /// the divider on the Dashboard moves the same right-pane width.
  onResizeSplit: (dx: number) => void;
  onResetSplit: () => void;
  /// Bumped when the profile menu's Settings item is clicked. We
  /// listen for changes (not value) and flip the right section from
  /// the Recent/sort view to Settings. Stats column on the left
  /// stays untouched — only the right section toggles.
  openSettingsNonce: number;
}

/// Home / landing surface (shown when no specific meeting is open).
/// Built from the SAME bones as `MeetingView` — `.detail` (column) wraps
/// `.detail-tabs` (two-col tab strip with a shared 1 px hairline divider)
/// and `.detail-body` (grid 1fr | --right-w). Same `ResizeHandle` for
/// the split, so dragging the divider here resizes the right pane the
/// same way it does in a meeting (and vice-versa — they share `--right-w`).
export function Dashboard({ meetings, statsMeetings, onPick, onStart, isRecording, onStop, hotkeyLabel, t, lang, onLangChange, onResizeSplit, onResetSplit, openSettingsNonce }: Props) {
  // Counters read off `statsMeetings` (lifetime — includes archived
  // rows) so archiving never silently decreases the user's totals.
  // The Recent list and everything else below still uses `meetings`
  // (the live library subset).
  const total = statsMeetings.length;
  const totalMs = statsMeetings.reduce((s, m) => s + (m.duration_ms ?? 0), 0);
  const weekAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
  const thisWeek = statsMeetings.filter((m) => m.started_at >= weekAgo).length;

  // `formatDuration` tops out at "Nm SSs" — fine for one session, not
  // for a totals tile where N can be 100s of minutes. Render hours
  // explicitly past the 1-hour mark.
  const totalLabel = (() => {
    if (totalMs <= 0) return "—";
    const sec = Math.round(totalMs / 1000);
    const h = Math.floor(sec / 3600);
    const m = Math.floor((sec % 3600) / 60);
    if (h > 0) return lang === "ru" ? `${h}ч ${m}м` : `${h}h ${m}m`;
    return formatDuration(totalMs, lang);
  })();

  /// `busy` covers the gap between the user clicking Start/Stop and
  /// the backend `RecordingState.active` flipping in the next poll.
  /// Without this, the button looked frozen — the click landed, the
  /// network hop took 100-400 ms, and nothing on-screen changed.
  /// Now the click flips `busy` immediately, the button shows a
  /// spinner + "Starting…" / "Stopping…" copy, and the moment
  /// `isRecording` actually transitions we clear `busy`.
  const [busy, setBusy] = useState(false);
  const lastRecRef = useRef(isRecording);
  useEffect(() => {
    if (lastRecRef.current !== isRecording) {
      lastRecRef.current = isRecording;
      setBusy(false);
    }
  }, [isRecording]);
  const handlePrimary = useCallback(async () => {
    if (busy) return;
    setBusy(true);
    try {
      if (isRecording) await onStop();
      else await onStart();
    } catch {
      // The API helpers already toast on failure; just unstick the
      // button so the user can try again.
      setBusy(false);
    }
  }, [busy, isRecording, onStart, onStop]);

  // Right section toggle: the Recent/sort list or the Settings pane.
  // Driven by the profile menu's Settings item via `openSettingsNonce`.
  // Stats column on the LEFT stays untouched in either mode.
  const [rightSection, setRightSection] = useState<"recent" | "settings">("recent");
  const lastSettingsNonceRef = useRef(openSettingsNonce);
  useEffect(() => {
    if (openSettingsNonce !== lastSettingsNonceRef.current) {
      lastSettingsNonceRef.current = openSettingsNonce;
      setRightSection("settings");
    }
  }, [openSettingsNonce]);

  // Sort key — persisted across launches so the user's pick survives
  // a window close. Default is "duration" (longest meetings first):
  // the user's most explicit ask was "по длительности по дефолту".
  const [sortBy, setSortBy] = useState<SortKey>(() => {
    try {
      const stored = localStorage.getItem(SORT_STORAGE_KEY);
      if (stored === "duration" || stored === "recent" || stored === "speakers") return stored;
    } catch {}
    return SORT_DEFAULT;
  });
  useEffect(() => {
    try { localStorage.setItem(SORT_STORAGE_KEY, sortBy); } catch {}
  }, [sortBy]);

  const recent = useMemo(() => {
    const arr = [...meetings];
    switch (sortBy) {
      case "duration":
        arr.sort((a, b) => (b.duration_ms ?? 0) - (a.duration_ms ?? 0));
        break;
      case "speakers":
        // Tie-breaker on duration so two meetings with the same count
        // don't shuffle randomly between polls.
        arr.sort((a, b) => (b.speaker_count - a.speaker_count)
          || ((b.duration_ms ?? 0) - (a.duration_ms ?? 0)));
        break;
      case "recent":
      default:
        arr.sort((a, b) => b.started_at - a.started_at);
        break;
    }
    return arr.slice(0, 8);
  }, [meetings, sortBy]);

  const sortOptions: { key: SortKey; label: string }[] = [
    { key: "duration", label: t.dashboard_sort_duration },
    { key: "recent",   label: t.dashboard_sort_recent },
    { key: "speakers", label: t.dashboard_sort_speakers },
  ];
  const activeSortLabel = sortOptions.find((o) => o.key === sortBy)?.label ?? sortOptions[0].label;

  return (
    <div className="detail dashboard-detail">
      {/* Same divider as MeetingView — Dashboard and meetings share
          `--right-w`, so dragging here moves the right pane there too. */}
      <ResizeHandle className="resizer-split" onDrag={onResizeSplit} onReset={onResetSplit} />
      <div className="detail-tabs">
        <div className="detail-tab-col detail-tab-col-left">
          <span className="tab active">{t.dashboard_tab_stats}</span>
        </div>
        <div className="detail-tab-col detail-tab-col-right">
          {rightSection === "recent" ? (
            // Clickable label + chevron — opens a popover with the
            // three sort options. The label IS the currently selected
            // sort, so the active tab reads as both "what list this
            // is" and "tap to change it".
            <SortPicker
              value={sortBy}
              onChange={setSortBy}
              options={sortOptions}
              activeLabel={activeSortLabel}
            />
          ) : (
            // Settings mode — leading ChevronLeft makes the affordance
            // unambiguous: the user opened Settings from the profile
            // menu, and this strip is how they get back to the Recent
            // list. The label still doubles as the back trigger so the
            // whole chip is one big click target, not just the icon.
            <span
              className="tab active dash-settings-back"
              role="button"
              onClick={() => setRightSection("recent")}
              title={t.dashboard_tab_recent}
              aria-label={t.dashboard_tab_recent}
            >
              <ChevronLeft size={14} strokeWidth={2} />
              <span>{t.tab_settings}</span>
            </span>
          )}
        </div>
      </div>
      <div className="detail-body">
        <div className="transcript-wrap dashboard-left">
          <div className="dashboard-left-inner">
            {/* Same outline-card as EmptyDeleteBanner: `.trans-banner`
                shell with the `.clarify-banner` size override. */}
            <div className="trans-banner clarify-banner dash-banner">
              <div className="clarify-text">
                {/* Headline + subtitle both flip while recording so the
                    surface reads as "you're already recording, hit
                    Stop" instead of luring the user into a second
                    Start. Subtitle stays visible (always two lines)
                    so the card's height doesn't pop in/out around
                    the state change — only the copy and the button
                    change, not the chrome. */}
                <div className="clarify-body">
                  {isRecording ? t.rec_label : t.dashboard_heading}
                </div>
                <div className="dash-sub">
                  {isRecording
                    ? (t.dashboard_subtitle_recording ?? t.dashboard_subtitle)
                    : t.dashboard_subtitle}
                </div>
              </div>
              <div className="clarify-actions clarify-actions-stack">
                <button
                  type="button"
                  className={"clarify-btn dash-primary-btn " + (isRecording ? "danger" : "accent")}
                  onClick={handlePrimary}
                  disabled={busy}
                  aria-busy={busy}
                >
                  {busy && (
                    <Loader2
                      size={14}
                      strokeWidth={2.5}
                      className="dash-primary-spin"
                      aria-hidden
                    />
                  )}
                  <span>
                    {busy
                      ? (isRecording ? (t.rec_stopping ?? t.rec_stop) : (t.rec_starting ?? t.dashboard_start))
                      : (isRecording ? t.rec_stop : t.dashboard_start)}
                  </span>
                </button>
              </div>
              <div className="dash-hint">{t.dashboard_hotkey_hint(hotkeyLabel)}</div>
            </div>

            {/* Stats — one outlined `.settings-rows` card, three rows
                separated by hairline borders. Same width and look as
                the banner above; same as Settings rows. */}
            <div className="settings-rows dash-stats-card">
              <div className="dash-stat-row">
                <div className="settings-row-label">{t.dashboard_stat_total}</div>
                <div className="dash-stat-value">{total}</div>
              </div>
              <div className="dash-stat-row">
                <div className="settings-row-label">{t.dashboard_stat_time}</div>
                <div className="dash-stat-value">{totalLabel}</div>
              </div>
              <div className="dash-stat-row">
                <div className="settings-row-label">{t.dashboard_stat_thisweek}</div>
                <div className="dash-stat-value">{thisWeek}</div>
              </div>
            </div>
          </div>
        </div>

        {/* Right column hosts either the Recent/sort list or the
            Settings pane. Both stay mounted (display toggled) so the
            settings pane keeps its already-loaded toggle state and the
            Recent scroll position survives a tab flip. */}
        <div
          className="right-panel dashboard-right"
          style={{ display: rightSection === "recent" ? "flex" : "none" }}
        >
          {recent.length === 0 ? (
            // Ghost placeholder card — same `.dash-recent-card` shape
            // as a real row, dashed border + faded copy so it reads
            // as "your first recording will land here", not as a wall
            // of empty-state text.
            <div className="dash-recent-stack">
              <div className="dash-recent-card ghost" aria-hidden>
                <div className="dash-recent-row">
                  <div className="dash-recent-title-row">
                    <div className="dash-recent-title">
                      {t.ghost_title ?? "Your first recording"}
                    </div>
                  </div>
                  <div className="dash-recent-meta">
                    {t.ghost_preview ?? "Hit Start to begin."}
                  </div>
                </div>
              </div>
            </div>
          ) : (
            <div className="dash-recent-stack">
              {recent.map((m) => (
                <button
                  key={m.id}
                  type="button"
                  className="dash-recent-card"
                  onClick={() => onPick(m.id)}
                >
                  <div className="dash-recent-row">
                    {/* Title row — `.dash-recent-title` is flex-1 +
                        min-width:0 + ellipsis so the participant chip
                        on the right pins, and the title truncates
                        BEFORE it. */}
                    <div className="dash-recent-title-row">
                      <div
                        className={
                          "dash-recent-title"
                          + (m.viewed === false && m.status === "ready" ? " unseen" : "")
                        }
                      >
                        {m.title?.trim() || formatDate(m.started_at, lang)}
                      </div>
                      {m.speaker_count > 0 && (
                        <span
                          className="meeting-people dash-recent-people"
                          title={t.participants(m.speaker_count)}
                        >
                          <span className="meeting-people-count">{m.speaker_count}</span>
                          <UserFilledIcon />
                        </span>
                      )}
                    </div>
                    <div className="dash-recent-meta">
                      {m.duration_ms != null ? formatDuration(m.duration_ms, lang) : t.status_recording}
                      {m.title?.trim() ? ` · ${formatDate(m.started_at, lang)}` : ""}
                    </div>
                  </div>
                </button>
              ))}
            </div>
          )}
        </div>
        <div style={{ display: rightSection === "settings" ? "contents" : "none" }}>
          <SettingsPane t={t} lang={lang} onLangChange={onLangChange} />
        </div>
      </div>
    </div>
  );
}

/// Sort selector — looks like a tab (matches the left "Статистика" tab
/// visually) but acts as a dropdown trigger. Popover is fixed-positioned
/// from the button's rect (same anchoring as `ProfileMenu`) so it
/// floats above the `overflow:hidden` tabs strip.
function SortPicker({
  value, onChange, options, activeLabel,
}: {
  value: SortKey;
  onChange: (k: SortKey) => void;
  options: { key: SortKey; label: string }[];
  activeLabel: string;
}) {
  const [open, setOpen] = useState(false);
  const btnRef = useRef<HTMLSpanElement>(null);
  const [pos, setPos] = useState<{ top: number; right: number } | null>(null);

  const place = useCallback(() => {
    const r = btnRef.current?.getBoundingClientRect();
    if (r) setPos({ top: r.bottom + 6, right: window.innerWidth - r.right });
  }, []);

  /// Synchronous toggle: measure the anchor rect BEFORE flipping
  /// `open` to true. Doing this in a `useEffect` instead caused a
  /// one-frame flash where `open && pos` was false → true → the
  /// popover mounted in the wrong place and snapped into position
  /// on the next paint (the "skip" the user saw).
  const toggle = useCallback(() => {
    setOpen((v) => {
      if (!v) {
        const r = btnRef.current?.getBoundingClientRect();
        if (r) setPos({ top: r.bottom + 6, right: window.innerWidth - r.right });
      }
      return !v;
    });
  }, []);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    const onDown = (e: MouseEvent) => {
      if (!btnRef.current?.contains(e.target as Node)) setOpen(false);
    };
    window.addEventListener("keydown", onKey);
    window.addEventListener("resize", place);
    // Defer the outside-click handler so the opening click itself
    // doesn't close the popover.
    const id = window.setTimeout(() => window.addEventListener("mousedown", onDown), 0);
    return () => {
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("resize", place);
      window.clearTimeout(id);
      window.removeEventListener("mousedown", onDown);
    };
  }, [open, place]);

  return (
    <>
      {/* <span> (not <button>) so we keep the exact `.tab` look — no
          native button shape, no Safari focus ring around the chip.
          role="button" + tabIndex makes it keyboard-reachable. */}
      <span
        ref={btnRef}
        className="tab active dash-sort-trigger"
        role="button"
        tabIndex={0}
        onClick={toggle}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            toggle();
          }
        }}
        aria-haspopup="menu"
        aria-expanded={open}
      >
        <span>{activeLabel}</span>
        <ChevronDown size={14} strokeWidth={2} />
      </span>
      {open && pos && createPortal(
        // Portal to <body> — without this the popover renders inside
        // `.detail` which is `overflow: hidden`, so the menu was
        // clipped invisibly the moment it opened.
        <div
          className="profile-pop dash-sort-pop"
          role="menu"
          style={{ top: pos.top, right: pos.right }}
          // Stop both mousedown AND click — the window mousedown
          // listener that closes the popover fires BEFORE React
          // delivers the item's onClick, otherwise selection swallows.
          onMouseDown={(e) => e.stopPropagation()}
          onClick={(e) => e.stopPropagation()}
        >
          {options.map((opt) => (
            <button
              key={opt.key}
              className="profile-pop-item dash-sort-item"
              role="menuitemradio"
              aria-checked={opt.key === value}
              onClick={() => { onChange(opt.key); setOpen(false); }}
            >
              <span className="dash-sort-check">
                {opt.key === value && <Check size={14} strokeWidth={2.5} />}
              </span>
              <span>{opt.label}</span>
            </button>
          ))}
        </div>,
        document.body
      )}
    </>
  );
}
