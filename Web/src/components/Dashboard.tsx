import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Loader2 } from "lucide-react";
import { getSettings } from "../api";
import { NewsBanner } from "./NewsBanner";
import { formatDuration } from "../format";
import type { Lang, T } from "../i18n";
import { ResizeHandle } from "./ResizeHandle";
import { SettingsPane } from "./SettingsPane";
import { GhostRecordingPanel } from "./RightPanel";
import { UpcomingPane } from "./UpcomingPane";
import { OverlayScrollbar } from "./OverlayScrollbar";

/// Same filled-bust glyph the sidebar uses next to each meeting's
/// speaker count — duplicated here (not exported from Sidebar.tsx) so
/// the Recent rows render the same chip without crossing components.
/// Small wrapper that polls /api/settings once on mount + every 5 s
/// to expose the current tier to children (NewsBanner). Cheap GET,
/// reuses the shared backend cache. Kept local because no other
/// Dashboard child needs the tier yet.
function DashTier({ render }: { render: (tier: "free" | "pro" | "max") => React.ReactNode }) {
  const [tier, setTier] = useState<"free" | "pro" | "max">("free");
  useEffect(() => {
    let alive = true;
    const tick = async () => {
      try {
        const s = await getSettings();
        if (!alive) return;
        setTier(s.tier === "pro" || s.tier === "max" ? s.tier : "free");
      } catch {}
    };
    void tick();
    const id = window.setInterval(tick, 5000);
    return () => { alive = false; window.clearInterval(id); };
  }, []);
  return <>{render(tier)}</>;
}


interface Props {
  /// Lifetime stats sample — all meetings EVER recorded, archived
  /// included. Drives the Stats card (Recordings / Total recorded /
  /// This week) so the counters reflect everything the user has
  /// produced, not just the current library subset. Only the
  /// `started_at` and `duration_ms` fields are read.
  statsMeetings: Array<{ started_at: number; duration_ms?: number }>;
  onStart: () => void;
  /// Mirrors `RecordingState.active` from the backend. When true, the
  /// Dashboard's primary card flips to a "still recording" headline +
  /// a red Stop button, so the surface stays in sync with the menu-bar
  /// HUD instead of pretending nothing is happening.
  isRecording: boolean;
  /// Called when the user hits Stop on the Dashboard card while
  /// `isRecording` is true. Same backend route as the menu-bar Stop.
  onStop: () => void;
  t: T;
  lang: Lang;
  /// Hooks into the same `--right-w` setter as MeetingView so dragging
  /// the divider on the Dashboard moves the same right-pane width.
  onResizeSplit: (dx: number) => void;
  onResetSplit: () => void;
  /// Bumped when the profile menu's Settings item is clicked. We
  /// listen for changes (not value) and flip the right section from
  /// the Recent/sort view to Settings. Stats column on the left
  /// stays untouched — only the right section toggles.
  openSettingsNonce: number;
  /// Lifted Settings state — null = Settings not open, "general" /
  /// "advanced" = which slice. Lives in main.tsx so opening Settings
  /// here and then clicking a meeting keeps the right pane on
  /// Settings (Костя: «настройки должны быть поверх пока не выключу»).
  settingsSection: null | "general" | "advanced";
  onSettingsSectionChange: (next: null | "general" | "advanced") => void;
  /// Legacy no-op kept for prop-shape compat. Replaced by deriving
  /// the flag from `settingsSection !== null` upstream.
  onSettingsOpenChange?: (open: boolean) => void;
  /// Surfaces one-line nudge/error toasts from the Dashboard surface.
  onToast?: (msg: string, kind?: "success" | "error") => void;
}

/// Home / landing surface (shown when no specific meeting is open).
/// Built from the SAME bones as `MeetingView` — `.detail` (column) wraps
/// `.detail-tabs` (two-col tab strip with a shared 1 px hairline divider)
/// and `.detail-body` (grid 1fr | --right-w). Same `ResizeHandle` for
/// the split, so dragging the divider here resizes the right pane the
/// same way it does in a meeting (and vice-versa — they share `--right-w`).
export function Dashboard({ statsMeetings, onStart, isRecording, onStop, t, lang, onResizeSplit, onResetSplit, openSettingsNonce, settingsSection, onSettingsSectionChange }: Props) {
  // Counters read off `statsMeetings` (lifetime — includes archived
  // rows) so archiving never silently decreases the user's totals.
  // The Recent list and everything else below still uses `meetings`
  // (the live library subset).
  // Memoised so the two passes over `statsMeetings` (sum + week filter)
  // only re-run when the list actually changes, not on every Dashboard
  // re-render (sort change, settings toggle, resize drag, etc.).
  const { total, totalMs, thisWeek } = useMemo(() => {
    const weekAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
    return {
      total: statsMeetings.length,
      totalMs: statsMeetings.reduce((s, m) => s + (m.duration_ms ?? 0), 0),
      thisWeek: statsMeetings.filter((m) => m.started_at >= weekAgo).length,
    };
  }, [statsMeetings]);

  // `formatDuration` tops out at "Nm SSs" — fine for one session, not
  // for a totals tile where N can be 100s of minutes. Render hours
  // explicitly past the 1-hour mark.
  const totalLabel = (() => {
    if (totalMs <= 0) return "—";
    const sec = Math.round(totalMs / 1000);
    const h = Math.floor(sec / 3600);
    const m = Math.floor((sec % 3600) / 60);
    if (h > 0) return `${h}h ${m}m`;
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
  /// Same overlay scrollbar wiring as the Transcript pane: pass
  /// just the scroll container, no dividerRef — the thumb centres
  /// on the container's own right edge (the column seam carrying
  /// the hairline from `.transcript-wrap`).
  const dashLeftRef = useRef<HTMLDivElement | null>(null);
  // Monotonic counter bumped on every transition into a recording
  // state — covers Start from the Dashboard button, the menu-bar
  // popover, and the auto-detect invite.
  useEffect(() => {
    if (lastRecRef.current !== isRecording) {
      lastRecRef.current = isRecording;
      setBusy(false);
    }
  }, [isRecording]);

  // The Dashboard statistics card is opt-in: a paid-only toggle in
  // Advanced → Statistics (off by default for everyone). Poll the
  // setting so flipping it in Settings reflects here within ~5 s.
  const [statsEnabled, setStatsEnabled] = useState<boolean>(false);
  useEffect(() => {
    let alive = true;
    const tick = async () => {
      try { const st = await getSettings(); if (alive) setStatsEnabled(st.stats_enabled === true); }
      catch {}
    };
    tick();
    const id = window.setInterval(tick, 5000);
    return () => { alive = false; window.clearInterval(id); };
  }, []);
  const handlePrimary = useCallback(async () => {
    if (busy) return;
    setBusy(true);
    try {
      if (isRecording) {
        await onStop();
      } else {
        await onStart();
      }
    } catch {
      // The API helpers already toast on failure; just unstick the
      // button so the user can try again.
      setBusy(false);
    }
  }, [busy, isRecording, onStart, onStop]);

  // Right section toggle: the Recent/sort list or the Settings pane.
  // Driven by the profile menu's Settings item via `openSettingsNonce`.
  // Stats column on the LEFT stays untouched in either mode.
  // Settings open / which slice is now LIFTED into main.tsx so the
  // state survives Dashboard ↔ Meeting flips. The local rightSection
  // is derived: "recent" when settingsSection is null, otherwise the
  // matching settings-* value.
  const rightSection: "recent" | "settings-general" | "settings-advanced" =
    settingsSection === "general"  ? "settings-general"
  : settingsSection === "advanced" ? "settings-advanced"
                                   : "recent";
  const inSettings = settingsSection !== null;
  const setRightSection = (next: "recent" | "settings-general" | "settings-advanced") => {
    onSettingsSectionChange(
      next === "settings-general"  ? "general"
    : next === "settings-advanced" ? "advanced"
                                   : null
    );
  };
  // Nonce is consumed in main.tsx now; this useRef just keeps the
  // ref name from going unused while we transition.
  void openSettingsNonce;

  // Left-column tab: Stats (default) vs Upcoming. Upcoming lists future
  // meetings from the connected calendar (the mirror of the Recent list).
  // Independent of the right-column Settings pane, so it stays put when
  // Settings opens.
  const [leftTab, setLeftTab] = useState<"stats" | "upcoming">("stats");

  return (
    <div className={"detail dashboard-detail" + (inSettings ? "" : " dashboard-solo")}>
      {/* Plain dashboard = ONE column (Home content), no divider, no empty
          right column. Opening Settings adds the right panel at the SHARED
          --right-w width (same as MeetingView's settings/right pane); the
          Home card is left-aligned so the reflow doesn't visibly move it.
          The splitter drags --right-w, so resizing here resizes the right
          pane everywhere — identical to how the left sidebar width is shared
          across sessions/archive. */}
      {inSettings && (
        <ResizeHandle className="resizer-split" onDrag={onResizeSplit} onReset={onResetSplit} />
      )}
      <div className="detail-tabs">
        <div className="detail-tab-col detail-tab-col-left">
          <span
            className={"tab" + (leftTab === "stats" ? " active" : "")}
            role="button"
            onClick={() => setLeftTab("stats")}
          >{t.dashboard_tab_home ?? "Home"}</span>
          {/* Upcoming/Calendar tab hidden until Google verifies the
              calendar.readonly scope (consent currently shows the
              "unverified app" screen). Re-enable by restoring this
              span once verification clears. */}
        </div>
        <div className="detail-tab-col detail-tab-col-right">
          {inSettings && (
            // Settings mode — `← General Settings` doubles as back
            // affordance (returns to Recent when clicked while
            // General is already active), `Advanced Settings` is a
            // plain sibling tab. Same pattern as MeetingView's strip.
            <>
              <span
                className={"tab" + (rightSection === "settings-general" ? " active" : "")}
                role="button"
                onClick={() => setRightSection("settings-general")}
              >
                {t.tab_general_settings ?? "General"}
              </span>
              <span
                className={"tab" + (rightSection === "settings-advanced" ? " active" : "")}
                onClick={() => setRightSection("settings-advanced")}
              >
                {t.tab_advanced_settings ?? "Advanced"}
              </span>
            </>
          )}
        </div>
      </div>
      <div className="detail-body">
        <div className="transcript-wrap dashboard-left ovsb-scroll" ref={dashLeftRef}>
          <div className="dashboard-left-inner">
            {leftTab === "upcoming" ? (
              <UpcomingPane t={t} lang={lang} />
            ) : (
            <>
            <DashTier
              render={(tier) => (
                <NewsBanner
                  tier={tier}
                  t={t}
                  onOpenSettings={() => onSettingsSectionChange("general")}
                />
              )}
            />
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
            </div>

            {statsEnabled && (
              <>
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
              </>
            )}
            </>
            )}
          </div>
          <OverlayScrollbar scrollRef={dashLeftRef} name="corder-sb-dashboard" />
        </div>

        {/* Right column now hosts ONLY the Settings pane (the Recent /
            "Longest" session list was removed — sessions live in the
            left sidebar). Both settings sections stay mounted, display
            toggled, so toggle state survives a tab flip. */}
        <div style={{ display: rightSection === "settings-general" ? "contents" : "none" }}>
          <SettingsPane t={t} section="general" />
        </div>
        <div style={{ display: rightSection === "settings-advanced" ? "contents" : "none" }}>
          <SettingsPane t={t} section="advanced" />
        </div>
        {/* Welcome state: a ghost preview of the session right panel (screen
            video grant pitch + ghost audio + ghost timeline) so the right
            column isn't empty and the user sees what a recording looks like. */}
        {rightSection === "recent" && <GhostRecordingPanel t={t} />}
      </div>
    </div>
  );
}
