import React from "react";
import { createRoot } from "react-dom/client";
import { listMeetings, listArchive, MeetingSummary, ArchivedMeeting, RecordingState, getRecordingState, getSettings, archiveMeeting, restoreMeeting, startRecordingNow, stopRecordingNow, submitLogs } from "./api";
import { Sidebar } from "./components/Sidebar";
import { MeetingView } from "./components/MeetingView";
import { ArchiveSidebar } from "./components/ArchiveSidebar";
import { Dashboard } from "./components/Dashboard";
import { UpdateModalHost } from "./components/UpdateModal";
import { SignInModalHost } from "./components/SignInModal";
import { MainHeader } from "./components/MainHeader";
import { ResizeHandle } from "./components/ResizeHandle";
import { Lang, T, pickStrings } from "./i18n";
import { initTheme } from "./theme";

const SIDEBAR_DEFAULT = 240, SIDEBAR_MIN = 200, SIDEBAR_MAX = 480;
const RIGHT_DEFAULT = 380, RIGHT_MIN = 300, RIGHT_MAX = 760;

const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));

function readNum(key: string, fallback: number): number {
  try {
    const v = parseFloat(localStorage.getItem(key) || "");
    return Number.isFinite(v) ? v : fallback;
  } catch {
    return fallback;
  }
}

function Toast({ toast, leaving, onDismiss }: { toast: ToastState; leaving: boolean; onDismiss: () => void }) {
  // Two-phase mount: render with `.entering` (off-screen below), flip to the
  // resting state on the next frame so CSS sees a transition. Exit is parent-
  // driven via the `leaving` prop — when true, the modifier flips us back to
  // the off-screen state and the parent unmounts after the transition.
  const [entering, setEntering] = React.useState(true);
  React.useEffect(() => {
    const id = requestAnimationFrame(() => setEntering(false));
    return () => cancelAnimationFrame(id);
  }, []);

  const [, setTick] = React.useState(0);
  React.useEffect(() => {
    if (!toast.expiresAt) return;
    const id = setInterval(() => setTick((n) => n + 1), 250);
    return () => clearInterval(id);
  }, [toast.expiresAt]);

  const remaining = toast.expiresAt
    ? Math.max(0, Math.ceil((toast.expiresAt - Date.now()) / 1000))
    : null;

  const cls = [
    "toast",
    `toast-${toast.kind}`,
    entering ? "entering" : "",
    leaving ? "leaving" : "",
  ].filter(Boolean).join(" ");

  return (
    <div className={cls}>
      <span>{toast.msg}</span>
      {toast.action && (
        <button
          className="toast-action"
          onClick={() => {
            // Run the action's callback FIRST so consumers see the
            // toast as "still open" while cancelling work, then close
            // the toast — clicking Undo shouldn't leave a stale
            // countdown chip on screen waiting out its 10 s.
            toast.action!.onClick();
            onDismiss();
          }}
        >
          {toast.action.label}
        </button>
      )}
      {remaining !== null && <span className="toast-countdown">{remaining}s</span>}
      <button
        type="button"
        className="toast-close"
        onClick={onDismiss}
        aria-label="Dismiss"
        title="Dismiss"
      >
        ×
      </button>
    </div>
  );
}

interface ToastState {
  msg: string;
  kind: "success" | "error";
  action?: { label: string; onClick: () => void };
  /// When set, the toast renders a live "Ns" countdown next to the action
  /// button. Used by the soft-delete Undo flow.
  expiresAt?: number;
}

function App() {
  const [meetings, setMeetings] = React.useState<MeetingSummary[]>([]);
  // First-load flag — distinguishes "no meetings yet, still fetching" from
  // "fetched, list is empty". Sidebar renders skeleton rows in the former
  // case and an empty-state in the latter.
  const [meetingsLoaded, setMeetingsLoaded] = React.useState(false);
  const [activeId, setActiveId] = React.useState<string | null>(null);
  // Lifted "which Settings slice is open" — null = not in Settings.
  // Lives up here so Settings PERSIST across Dashboard ↔ Meeting
  // flips: opening Settings on Dashboard and then clicking a
  // session keeps the right pane on Settings until the user
  // explicitly closes it (or flips to Advanced). Same shape as
  // `archiveOpen` already does for the archive overlay.
  const [settingsSection, setSettingsSection] = React.useState<null | "general" | "advanced">(null);
  const settingsOpenUI = settingsSection !== null;
  // Bumped each time the user taps the gear (header / profile menu)
  // so consumers (Dashboard / MeetingView) can react with toggle
  // semantics — same nonce pattern as before, but now it only feeds
  // the "open / close Settings" toggle in main.tsx.
  const [openSettingsNonce, setOpenSettingsNonce] = React.useState(0);
  const lastSettingsNonceRef = React.useRef(openSettingsNonce);
  React.useEffect(() => {
    if (openSettingsNonce === lastSettingsNonceRef.current) return;
    lastSettingsNonceRef.current = openSettingsNonce;
    // Toggle: if Settings already open (in either slice), close;
    // otherwise open on General — Advanced stays one click away in
    // the tab strip.
    setSettingsSection((cur) => (cur === null ? "general" : null));
  }, [openSettingsNonce]);
  // Last meeting the user actually opened — keeps MeetingView mounted
  // across Dashboard↔Meeting flips so its `detail` survives and the
  // skeleton doesn't flash on every return. See the render block below.
  const lastSeenMeetingRef = React.useRef<string | null>(null);
  // Meeting whose audio is currently playing → sidebar play marker.
  const [playingId, setPlayingId] = React.useState<string | null>(null);
  const [query, setQuery] = React.useState("");
  const [toast, setToast] = React.useState<ToastState | null>(null);
  const [toastLeaving, setToastLeaving] = React.useState(false);
  const toastTimer = React.useRef<number | null>(null);
  const toastLeaveTimer = React.useRef<number | null>(null);
  // Suppression table — keyed by toast message (or explicit `dedupKey`
  // when passed) → timestamp until which we silently swallow new toasts
  // with that key. The native bridge can fire the same Whisper-cancel
  // toast a dozen times as one cancellation cascades through the
  // pipeline; without this the user sees the same scary card repeat
  // over and over. Lives outside React state because it's a side-channel,
  // not part of the visible UI tree.
  const toastSuppressUntilRef = React.useRef<Map<string, number>>(new Map());
  // Soft-deleted meeting IDs — UI hides them immediately, real DELETE is
  // scheduled for 10s later. While the meeting is in this set the user can
  // press Undo on the toast and the timer is cancelled.
  const [softDeleted, setSoftDeleted] = React.useState<Set<string>>(new Set());
  // Archived rows are kept around just for the Dashboard stats card —
  // the user wants the lifetime "Recordings / Total recorded / This week"
  // counters to include everything they've ever recorded, not only the
  // library subset. Polled alongside meetings on every `refresh()`.
  const [archived, setArchived] = React.useState<ArchivedMeeting[]>([]);
  // Ref-mirror so the 5-second refresh callback (memoised, no deps) sees
  // the live set instead of a stale closure capture. Without this the
  // refresh tick can re-select a meeting we just soft-deleted as the
  // active one, briefly bringing it back from the dead in the UI.
  const softDeletedRef = React.useRef<Set<string>>(softDeleted);
  React.useEffect(() => { softDeletedRef.current = softDeleted; }, [softDeleted]);
  const [recState, setRecState] = React.useState<RecordingState>({ active: false });
  // Hide the native recording-blob (bottom-right NSView) while the user
  // sits on the Dashboard and nothing is recording — the Dashboard's
  // "Start recording" CTA already covers that role, the blob is just
  // visual clutter there. As soon as recording starts (or the user
  // opens a meeting), restore it so the stop-affordance reappears.
  React.useEffect(() => {
    const isDashboard = activeId === null;
    const isIdle = !recState.active;
    const visible = !(isDashboard && isIdle);
    const bridge = (window as unknown as {
      corderSetBlobVisible?: (v: boolean) => void;
    }).corderSetBlobVisible;
    try { bridge?.(visible); } catch {}
  }, [activeId, recState.active]);
  // English-only build. `lang` stays a typed constant so `pickStrings`
  // and the date/number helpers in `format.ts` keep a single source of
  // truth and a locale can be reintroduced without reshaping callers.
  const lang: Lang = "en";
  const t: T = pickStrings(lang);

  // The native window posts this on show/close. While the Library
  // window is hidden the page is alive but invisible — pausing the
  // poll timers stops pointless background requests/CPU. Defaults to
  // active so the very first open (event may fire before listeners
  // attach) still polls.
  const [windowActive, setWindowActive] = React.useState(true);
  React.useEffect(() => {
    const onActive = (e: Event) => {
      setWindowActive(!!(e as CustomEvent).detail);
    };
    window.addEventListener("corder-window-active", onActive);
    return () => window.removeEventListener("corder-window-active", onActive);
  }, []);

  // Native → web toast bridge. RecordingController posts a
  // `corder-toast` event when the user should see something inside
  // the window (e.g. "Silent recording auto-archived"); we route the
  // payload through the existing `showToast` queue so the in-window
  // banner reads identically to other toasts.
  React.useEffect(() => {
    const onNativeToast = (e: Event) => {
      const d = (e as CustomEvent).detail as { title?: string; body?: string; kind?: string };
      // Use whichever piece is set; never join with an em-dash
      // (project-wide style rule). When both are present, the title
      // wins as the user-visible string — body becomes the implicit
      // context that lives in the native banner / log lines only.
      const msg = (d?.title && d.title.trim()) || (d?.body && d.body.trim()) || "";
      if (!msg) return;
      const kind = d?.kind === "error" ? "error" : "success";
      // Native error toasts (TranscriptionPipeline failure cascade,
      // BT-output warning, etc.) tend to fire many times in a row
      // when one root cause ripples through the pipeline. Suppress
      // repeats keyed on the title for one hour so the user sees
      // the error once and isn't badgered for the rest of the session.
      showToast(msg, kind, kind === "error"
        ? { dedupKey: msg, suppressAfterMs: 60 * 60 * 1000 }
        : undefined);
    };
    window.addEventListener("corder-toast", onNativeToast);
    return () => window.removeEventListener("corder-toast", onNativeToast);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const refresh = React.useCallback(async () => {
    try {
      const [m, a] = await Promise.all([
        listMeetings(),
        listArchive().catch(() => [] as ArchivedMeeting[]),
      ]);
      setMeetings(m);
      setArchived(a);
      setMeetingsLoaded(true);
      // Validate the current selection against the fresh list:
      //   • still there → keep it.
      //   • gone / none selected → open the MOST RECENT meeting. The
      //     start screen (Dashboard) is now shown ONLY when the library
      //     is completely empty; once there's at least one recording the
      //     window always lands on a session, never the dashboard.
      const dropped = softDeletedRef.current;
      const visible = m.filter((x) => !dropped.has(x.id));
      setActiveId((cur) => {
        if (cur && visible.some((x) => x.id === cur)) return cur;
        if (visible.length === 0) return null; // empty library → start screen
        return visible.reduce((a, b) => (b.started_at > a.started_at ? b : a)).id;
      });
    } catch {}
  }, []);

  React.useEffect(() => { refresh(); }, [refresh]);

  // Two-speed polling. While a recording is in flight we want fresh
  // state for the live HUD / banner; when the app is idle there's
  // nothing changing on the server side that matters at 1 s
  // granularity, so we drop both polls to a much lazier 5 s.
  // Previously the recording-state poll ran every second
  // unconditionally, which kept the whole React tree re-rendering and
  // showed up as background CPU even when the user wasn't doing
  // anything.
  const isActive = recState.active;
  React.useEffect(() => {
    if (!windowActive) return;          // window hidden → stop polling
    const ms = isActive ? 1000 : 5000;
    const tick = async () => {
      try { setRecState(await getRecordingState()); } catch {}
    };
    tick();                            // immediate refresh on (re)activate
    const t = setInterval(tick, ms);
    return () => clearInterval(t);
  }, [isActive, windowActive]);

  React.useEffect(() => {
    if (!windowActive) return;
    refresh();                         // immediate refresh on (re)activate
    const ms = isActive ? 5000 : 15000;
    const t = setInterval(refresh, ms);
    return () => clearInterval(t);
  }, [refresh, isActive, windowActive]);

  const dismissToast = React.useCallback(() => {
    if (toastTimer.current) { window.clearTimeout(toastTimer.current); toastTimer.current = null; }
    if (toastLeaveTimer.current) { window.clearTimeout(toastLeaveTimer.current); toastLeaveTimer.current = null; }
    setToastLeaving(true);
    // Wait for the slide-down transition (~280ms) before unmount so the
    // exit animation actually plays. Match the CSS duration.
    toastLeaveTimer.current = window.setTimeout(() => {
      setToast(null);
      setToastLeaving(false);
      toastLeaveTimer.current = null;
    }, 300);
  }, []);

  // Ref to the latest showToast so the error toast's default "Send a
  // report" action can show a confirmation without a circular dependency.
  const showToastRef = React.useRef<((m: string, k?: "success" | "error", o?: { action?: { label: string; onClick: () => void }; durationMs?: number; countdown?: boolean; dedupKey?: string; suppressAfterMs?: number }) => void) | null>(null);
  // Ship the diagnostic log (same backend as the header bug-report button),
  // with optimistic confirmation. Attached to every error toast by default.
  const sendReportFromToast = React.useCallback(() => {
    showToastRef.current?.("Report sent. Thank you.", "success");
    submitLogs().catch(() => {});
  }, []);

  const showToast = React.useCallback((msg: string, kind: "success" | "error" = "success", opts?: { action?: { label: string; onClick: () => void }; durationMs?: number; countdown?: boolean; dedupKey?: string; suppressAfterMs?: number }) => {
    const key = opts?.dedupKey ?? msg;
    const now = Date.now();
    const suppressedUntil = toastSuppressUntilRef.current.get(key);
    if (suppressedUntil && suppressedUntil > now) {
      // Same toast was shown recently and asked to be muted; bail.
      return;
    }
    if (opts?.suppressAfterMs && opts.suppressAfterMs > 0) {
      toastSuppressUntilRef.current.set(key, now + opts.suppressAfterMs);
    }
    if (toastTimer.current) { window.clearTimeout(toastTimer.current); toastTimer.current = null; }
    if (toastLeaveTimer.current) { window.clearTimeout(toastLeaveTimer.current); toastLeaveTimer.current = null; }
    const isError = kind === "error";
    // Errors carry a "Send a report" button (same affordance/backend as the
    // header bug-report button) and — unless the caller asked for a finite
    // duration — they DON'T auto-dismiss: an error you need to read and act
    // on shouldn't vanish on a timer. It stays until the user clicks "Send a
    // report" (which closes it) or the × close button. (Костя.)
    const persist = isError && opts?.durationMs == null;
    const ms = opts?.durationMs ?? (isError ? 8000 : 2200);
    const action = opts?.action ?? (isError ? { label: "Send a report", onClick: sendReportFromToast } : undefined);
    setToastLeaving(false);
    setToast({
      msg,
      kind,
      action,
      expiresAt: (opts?.countdown && !persist) ? Date.now() + ms : undefined,
    });
    if (!persist) {
      toastTimer.current = window.setTimeout(() => {
        // Auto-close: trigger the slide-out, parent unmounts on exit.
        dismissToast();
      }, ms);
    }
  }, [dismissToast, sendReportFromToast]);
  React.useEffect(() => { showToastRef.current = showToast; }, [showToast]);

  // Current paid-tier rung — drives the Sidebar Upgrade-card
  // visibility (`max` hides it) and is forwarded to nested components
  // that need to react to the tier. Re-fetched alongside the language
  // so a manual `defaults write Corder.set.userTier` shows up after a
  // window reload.
  const [tier, setTier] = React.useState<"free" | "pro" | "max">("free");

  React.useEffect(() => {
    (async () => {
      try {
        const s = await getSettings();
        const v = s.tier ?? (s.is_pro ? "pro" : "free");
        if (v === "free" || v === "pro" || v === "max") setTier(v);
      } catch {}
    })();
  }, []);

  // Batched soft-archive: every meeting archived within a 5-second window
  // collects into ONE pending batch with ONE shared timer + ONE toast.
  // Previously each archive replaced the previous toast and its
  // `pendingDeleteTimers` entry — so Undo restored only the most-recent
  // row even when the user just archived a dozen in a row. Now Undo
  // restores every id in the open batch, the toast label updates to
  // "Archived (N)", and the 5-second countdown resets each time a new
  // archive lands so the user always has the full window from their
  // LAST action.
  const archiveBatchRef = React.useRef<{ ids: string[]; tid: number | null }>({ ids: [], tid: null });
  const handleArchived = React.useCallback((archivedId?: string) => {
    if (!archivedId) return;

    // If we archived the open meeting, fall to the landing target (most
    // recent remaining meeting, or the empty start screen when none left)
    // instead of the dashboard — it's hidden while recordings exist.
    setActiveId((prev) => {
      if (prev !== archivedId) return prev;
      const visible = meetings.filter((m) => !softDeleted.has(m.id) && m.id !== archivedId);
      if (visible.length === 0) return null;
      return visible.reduce((a, b) => (b.started_at > a.started_at ? b : a)).id;
    });
    // Also clear `lastSeenMeetingRef` if it points at the row we're
    // archiving. MeetingView is mount-stable via a `display:none`
    // wrapper that keys off `lastSeen`, so without this clear it stays
    // rendered with the just-archived id and EmptyDeleteBanner's local
    // `busy='archive'` spinner never gets a chance to unmount (Костя's
    // "Archive Session бесконечно грузится" case).
    if (lastSeenMeetingRef.current === archivedId) {
      lastSeenMeetingRef.current = null;
    }
    setSoftDeleted((prev) => { const n = new Set(prev); n.add(archivedId); return n; });

    // Fire the actual archive immediately so a sudden quit / network drop
    // can't leave the meeting in a half-archived state.
    archiveMeeting(archivedId).catch(() => {});

    // Add to / open a batch.
    const batch = archiveBatchRef.current;
    if (!batch.ids.includes(archivedId)) batch.ids.push(archivedId);
    if (batch.tid != null) { window.clearTimeout(batch.tid); batch.tid = null; }

    const undoBatch = async () => {
      const ids = archiveBatchRef.current.ids.slice();
      if (archiveBatchRef.current.tid != null) {
        window.clearTimeout(archiveBatchRef.current.tid);
      }
      archiveBatchRef.current = { ids: [], tid: null };
      // Restore every id in parallel; tolerate individual failures so
      // one bad row can't block the rest from coming back.
      await Promise.all(ids.map((id) => restoreMeeting(id).catch(() => {})));
      setSoftDeleted((prev) => {
        const n = new Set(prev);
        for (const id of ids) n.delete(id);
        return n;
      });
      await refresh();
      dismissToast();
      // Confirm the undo actually happened — the original "Archived"
      // toast is gone by now, so without this the user is left
      // guessing whether the click landed. Singular / plural copy
      // is handled inside the locale helper.
      const done = t.toast_undo_done ?? ((n: number) => n === 1 ? "Restored" : `Restored ${n}`);
      showToast(done(ids.length), "success");
    };

    const finalize = async () => {
      const ids = archiveBatchRef.current.ids.slice();
      archiveBatchRef.current = { ids: [], tid: null };
      setSoftDeleted((prev) => {
        const n = new Set(prev);
        for (const id of ids) n.delete(id);
        return n;
      });
      await refresh();
    };

    batch.tid = window.setTimeout(finalize, 5_000);

    const count = archiveBatchRef.current.ids.length;
    const label = count > 1 ? `${t.toast_archived} (${count})` : t.toast_archived;
    showToast(label, "success", {
      action: { label: t.toast_undo, onClick: undoBatch },
      durationMs: 5_000,
      countdown: true,
    });
  }, [refresh, showToast, dismissToast, t, meetings, softDeleted]);

  const visibleMeetings = React.useMemo(
    () => meetings.filter((m) => !softDeleted.has(m.id)),
    [meetings, softDeleted]
  );

  // Lifetime stats sample for the Dashboard counters — live meetings
  // (including the just-archived rows still in softDeleted) PLUS the
  // server's archive listing, so the totals never tick down when the
  // user moves a row to Archive. We only need `started_at` and
  // `duration_ms` downstream.
  const statsMeetings = React.useMemo(() => {
    return [
      ...meetings.map((m) => ({ started_at: m.started_at, duration_ms: m.duration_ms })),
      ...archived.map((a) => ({ started_at: a.started_at, duration_ms: a.duration_ms })),
    ];
  }, [meetings, archived]);

  /// Open a meeting AND immediately clear its "unseen" gold/green
  /// title — the backend stamps `viewed_at` inside `GET /api/meetings/:id`,
  /// but the 5-second poll on `/api/meetings` only catches up later.
  /// Without this optimistic flip, the title stays accent-coloured for
  /// up to a poll cycle after the user obviously sees it.
  const pickMeeting = React.useCallback((id: string) => {
    setMeetings((prev) =>
      prev.map((m) => (m.id === id && m.viewed === false ? { ...m, viewed: true } : m))
    );
    setActiveId(id);
  }, []);

  // "Home" / landing target. The Dashboard start screen only exists when
  // the library is empty; otherwise Home opens the most recent meeting so
  // the dashboard is never shown once there are recordings.
  const goLanding = React.useCallback(() => {
    const visible = meetings.filter((m) => !softDeleted.has(m.id));
    if (visible.length === 0) { setActiveId(null); return; }
    setActiveId(visible.reduce((a, b) => (b.started_at > a.started_at ? b : a)).id);
  }, [meetings, softDeleted]);

  const [sidebarW, setSidebarW] = React.useState(() =>
    clamp(readNum("corder.sidebarW", SIDEBAR_DEFAULT), SIDEBAR_MIN, SIDEBAR_MAX)
  );
  const [rightW, setRightW] = React.useState(() =>
    clamp(readNum("corder.rightW", RIGHT_DEFAULT), RIGHT_MIN, RIGHT_MAX)
  );
  React.useEffect(() => {
    try { localStorage.setItem("corder.sidebarW", String(sidebarW)); } catch {}
  }, [sidebarW]);
  React.useEffect(() => {
    try { localStorage.setItem("corder.rightW", String(rightW)); } catch {}
  }, [rightW]);

  const [archiveOpen, setArchiveOpen] = React.useState(false);
  // Bumped when the currently-open meeting is re-transcribed from the
  // sidebar, so MeetingView knows to start polling for the new result.
  const [retranscribeNonce, setRetranscribeNonce] = React.useState(0);

  return (
    <div
      className="app"
      style={{
        ["--sidebar-w" as string]: `${sidebarW}px`,
        ["--right-w" as string]: `${rightW}px`,
      } as React.CSSProperties}
    >
      {archiveOpen ? (
        <ArchiveSidebar
          onClose={() => setArchiveOpen(false)}
          onChanged={refresh}
          onToast={showToast}
          t={t}
          lang={lang}
        />
      ) : (
        <Sidebar
          meetings={visibleMeetings}
          loaded={meetingsLoaded}
          activeId={activeId}
          playingId={playingId}
          query={query}
          onQueryChange={setQuery}
          onSelect={pickMeeting}
          onDeleted={handleArchived}
          onRetranscribed={(id) => { if (id === activeId) setRetranscribeNonce((n) => n + 1); }}
          onChanged={refresh}
          onToast={showToast}
          t={t}
          lang={lang}
          tier={tier}
        />
      )}
      <ResizeHandle
        className="resizer-sidebar"
        onDrag={(dx) => setSidebarW((w) => clamp(w + dx, SIDEBAR_MIN, SIDEBAR_MAX))}
        onReset={() => setSidebarW(SIDEBAR_DEFAULT)}
      />
      <main className="main">
        {(() => {
          // Remember the last meeting the user actually opened. Used so
          // MeetingView can stay MOUNTED while the Dashboard is showing
          // — that's what makes flipping Dashboard ↔ Meeting feel
          // instant. Without this, every return to a meeting remounts
          // MeetingView with `detail = null`, which flashes the
          // skeleton on every click ("postoянно подгружается").
          if (activeId) lastSeenMeetingRef.current = activeId;
          const lastSeen = lastSeenMeetingRef.current;
          // Show the Dashboard (start screen) ONLY once we've confirmed the
          // library is actually empty. On launch the meetings list is still
          // loading and `activeId` is null, which used to flash the
          // Dashboard for a beat before the auto-open of the latest session
          // kicked in. While loading (or when meetings exist) we render
          // nothing here instead of that flash.
          const showDashboard = !activeId && meetingsLoaded && visibleMeetings.length === 0;
          return (
            <>
              {showDashboard && (
                <>
                  <MainHeader
                    breadcrumb={<span className="breadcrumb-current">{t.breadcrumb_dashboard}</span>}
                    onOpenArchive={() => setArchiveOpen((v) => !v)}
                    archiveOpen={archiveOpen}
                    archiveEmpty={archived.length === 0}
                    onOpenSettings={() => setOpenSettingsNonce((n) => n + 1)}
                    settingsOpen={settingsOpenUI}
                    onOpenDashboard={goLanding}
                    onToast={showToast}
                    t={t}
                  />
                  <Dashboard
                    onToast={showToast}
                    statsMeetings={statsMeetings}
                    onStart={async () => {
                      try { await startRecordingNow(); } catch { showToast(t.toast_settings_failed, "error"); }
                    }}
                    isRecording={isActive}
                    onStop={async () => {
                      try { await stopRecordingNow(); } catch { showToast(t.toast_settings_failed, "error"); }
                    }}
                    t={t}
                    lang={lang}
                    onResizeSplit={(dx) => setRightW((w) => clamp(w - dx, RIGHT_MIN, RIGHT_MAX))}
                    onResetSplit={() => setRightW(RIGHT_DEFAULT)}
                    openSettingsNonce={openSettingsNonce}
                    settingsSection={settingsSection}
                    onSettingsSectionChange={setSettingsSection}
                    onSettingsOpenChange={() => {}}
                  />
                </>
              )}
              {lastSeen !== null && (
                // MeetingView stays mounted across Dashboard↔Meeting
                // flips so its `detail` survives — no skeleton flash
                // on subsequent opens. The wrapper toggles flex/none;
                // when hidden it's still in the DOM, just not painted.
                <div
                  style={{
                    display: activeId ? "flex" : "none",
                    flexDirection: "column",
                    flex: 1,
                    minHeight: 0,
                  }}
                >
                  <MeetingView
                    // No `key={activeId}` — id changes are handled by
                    // MeetingView's internal `useEffect([meetingId])`,
                    // which fetches the new detail while keeping the
                    // previous one visible until it arrives. `initialTitle`
                    // / `initialStartedAt` come from the cached sidebar
                    // row so the breadcrumb updates INSTANTLY on session
                    // switch — without these, the header showed the
                    // previous meeting's title for the ~few hundred ms
                    // the detail fetch took.
                    meetingId={activeId ?? lastSeen}
                    initialTitle={visibleMeetings.find((m) => m.id === (activeId ?? lastSeen))?.title ?? null}
                    initialStartedAt={visibleMeetings.find((m) => m.id === (activeId ?? lastSeen))?.started_at ?? null}
                    onDeleted={handleArchived}
                    onOpenArchive={() => setArchiveOpen((v) => !v)}
                    archiveOpen={archiveOpen}
                    archiveEmpty={archived.length === 0}
                    onOpenSettings={() => setOpenSettingsNonce((n) => n + 1)}
                    onOpenDashboard={goLanding}
                    onToast={showToast}
                    recordingState={recState}
                    onRecordingStopped={() => { setRecState({ active: false }); refresh(); }}
                    reloadSignal={retranscribeNonce}
                    openSettingsNonce={openSettingsNonce}
                    settingsSection={settingsSection}
                    onSettingsSectionChange={setSettingsSection}
                    lang={lang}
                    onResizeSplit={(dx) => setRightW((w) => clamp(w - dx, RIGHT_MIN, RIGHT_MAX))}
                    onResetSplit={() => setRightW(RIGHT_DEFAULT)}
                    onPlayingChange={(playing) => setPlayingId(playing && activeId ? activeId : null)}
                    onSettingsOpenChange={() => {}}
                    t={t}
                  />
                </div>
              )}
            </>
          );
        })()}
      </main>
      {toast && <Toast toast={toast} leaving={toastLeaving} onDismiss={dismissToast} />}
      {/* Sparkle update modal — rendered into the same WebView so a
          `position: fixed; inset: 0` overlay covers the whole Library,
          not a fragment-sized child window. */}
      <UpdateModalHost lang={lang} />
      {/* In-app sign-in modal — same card/tilt as the update modal (no
          stars), driven by the native auth bridge. Replaces the old
          separate native sign-in window. */}
      <SignInModalHost lang={lang} />
    </div>
  );
}

initTheme();
createRoot(document.getElementById("root")!).render(<App />);
