import React from "react";
import { createRoot } from "react-dom/client";
import { listMeetings, MeetingSummary, RecordingState, getRecordingState, getSettings, setSettings, archiveMeeting, restoreMeeting } from "./api";
import { Sidebar } from "./components/Sidebar";
import { MeetingView } from "./components/MeetingView";
import { ArchiveView } from "./components/ArchiveView";
import { Donate } from "./components/Donate";
import { STRINGS, Lang, T } from "./i18n";

function Toast({ toast, leaving }: { toast: ToastState; leaving: boolean }) {
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
        <button className="toast-action" onClick={toast.action.onClick}>
          {toast.action.label}
        </button>
      )}
      {remaining !== null && <span className="toast-countdown">{remaining}s</span>}
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
  const [activeId, setActiveId] = React.useState<string | null>(null);
  const [query, setQuery] = React.useState("");
  const [toast, setToast] = React.useState<ToastState | null>(null);
  const [toastLeaving, setToastLeaving] = React.useState(false);
  const toastTimer = React.useRef<number | null>(null);
  const toastLeaveTimer = React.useRef<number | null>(null);
  // Soft-deleted meeting IDs — UI hides them immediately, real DELETE is
  // scheduled for 10s later. While the meeting is in this set the user can
  // press Undo on the toast and the timer is cancelled.
  const [softDeleted, setSoftDeleted] = React.useState<Set<string>>(new Set());
  const pendingDeleteTimers = React.useRef<Map<string, number>>(new Map());
  // Ref-mirror so the 5-second refresh callback (memoised, no deps) sees
  // the live set instead of a stale closure capture. Without this the
  // refresh tick can re-select a meeting we just soft-deleted as the
  // active one, briefly bringing it back from the dead in the UI.
  const softDeletedRef = React.useRef<Set<string>>(softDeleted);
  React.useEffect(() => { softDeletedRef.current = softDeleted; }, [softDeleted]);
  const [recState, setRecState] = React.useState<RecordingState>({ active: false });
  const [boostMode, setBoostModeState] = React.useState(false);
  const [lang, setLangState] = React.useState<Lang>("en");
  const t: T = STRINGS[lang];

  const refresh = React.useCallback(async () => {
    try {
      const m = await listMeetings();
      setMeetings(m);
      // Pick a new active row only from meetings that aren't currently
      // pending soft-delete — otherwise the just-deleted row would briefly
      // come back as active until the 5-second timer finalises the DELETE.
      const dropped = softDeletedRef.current;
      const visible = m.filter((x) => !dropped.has(x.id));
      setActiveId((cur) =>
        cur && visible.some((x) => x.id === cur) ? cur : (visible[0]?.id ?? null)
      );
    } catch {}
  }, []);

  React.useEffect(() => { refresh(); }, [refresh]);

  React.useEffect(() => {
    const t = setInterval(refresh, 5000);
    return () => clearInterval(t);
  }, [refresh]);

  React.useEffect(() => {
    const tick = async () => {
      try { setRecState(await getRecordingState()); } catch {}
    };
    tick();
    const t = setInterval(tick, 1000);
    return () => clearInterval(t);
  }, []);

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

  const showToast = React.useCallback((msg: string, kind: "success" | "error" = "success", opts?: { action?: { label: string; onClick: () => void }; durationMs?: number; countdown?: boolean }) => {
    if (toastTimer.current) { window.clearTimeout(toastTimer.current); toastTimer.current = null; }
    if (toastLeaveTimer.current) { window.clearTimeout(toastLeaveTimer.current); toastLeaveTimer.current = null; }
    const ms = opts?.durationMs ?? 2200;
    setToastLeaving(false);
    setToast({
      msg,
      kind,
      action: opts?.action,
      expiresAt: opts?.countdown ? Date.now() + ms : undefined,
    });
    toastTimer.current = window.setTimeout(() => {
      // Auto-close: trigger the slide-out, parent unmounts on exit.
      dismissToast();
    }, ms);
  }, [dismissToast]);

  React.useEffect(() => {
    (async () => {
      try {
        const s = await getSettings();
        setBoostModeState(s.boost_mode);
        if (s.language === "ru" || s.language === "en") setLangState(s.language);
      } catch {}
    })();
  }, []);

  const handleBoostModeChange = React.useCallback(async (next: boolean) => {
    setBoostModeState(next);
    try {
      await setSettings({ boost_mode: next, language: lang });
      showToast(next ? t.toast_boost_on : t.toast_boost_off, "success");
    } catch {
      setBoostModeState(!next);
      showToast(t.toast_settings_failed, "error");
    }
  }, [showToast, lang, t]);

  const handleLangChange = React.useCallback(async (next: Lang) => {
    setLangState(next);
    try {
      await setSettings({ boost_mode: boostMode, language: next });
    } catch {
      setLangState(lang);
      showToast(STRINGS[next].toast_settings_failed, "error");
    }
  }, [boostMode, lang, showToast]);

  // Soft-archive with a 5-second Undo window. The meeting is hidden from the
  // UI immediately (optimistic) and the real archive request is fired right
  // away; Undo restores it via /restore. We keep the row visible during the
  // toast lifetime under softDeleted so refresh() — which polls every 2s —
  // doesn't bounce it back in even though the server already moved it to
  // archived_at != NULL. After the timer expires the optimistic hide
  // releases naturally.
  const handleArchived = React.useCallback((archivedId?: string) => {
    if (!archivedId) return;

    setActiveId((prev) => prev === archivedId ? null : prev);
    setSoftDeleted((prev) => { const n = new Set(prev); n.add(archivedId); return n; });

    // Fire the actual archive immediately so a sudden quit / network drop
    // can't leave the meeting in a half-archived state.
    archiveMeeting(archivedId).catch(() => {});

    const undo = async () => {
      const t = pendingDeleteTimers.current.get(archivedId);
      if (t) { window.clearTimeout(t); pendingDeleteTimers.current.delete(archivedId); }
      try { await restoreMeeting(archivedId); } catch {}
      setSoftDeleted((prev) => { const n = new Set(prev); n.delete(archivedId); return n; });
      await refresh();
      dismissToast();
    };

    const finalize = async () => {
      pendingDeleteTimers.current.delete(archivedId);
      setSoftDeleted((prev) => { const n = new Set(prev); n.delete(archivedId); return n; });
      await refresh();
    };

    const tid = window.setTimeout(finalize, 5_000);
    pendingDeleteTimers.current.set(archivedId, tid);

    showToast(t.toast_archived, "success", {
      action: { label: t.toast_undo, onClick: undo },
      durationMs: 5_000,
      countdown: true,
    });
  }, [refresh, showToast, dismissToast, t]);

  const visibleMeetings = React.useMemo(
    () => meetings.filter((m) => !softDeleted.has(m.id)),
    [meetings, softDeleted]
  );

  const [archiveOpen, setArchiveOpen] = React.useState(false);

  return (
    <div className="app">
      <Sidebar
        meetings={visibleMeetings}
        activeId={activeId}
        query={query}
        onQueryChange={setQuery}
        onSelect={setActiveId}
        onDeleted={handleArchived}
        onToast={showToast}
        t={t}
        lang={lang}
      />
      <main className="main">
        {activeId ? (
          <MeetingView
            key={activeId}
            meetingId={activeId}
            onDeleted={handleArchived}
            onOpenArchive={() => setArchiveOpen(true)}
            onToast={showToast}
            recordingState={recState}
            onRecordingStopped={() => { setRecState({ active: false }); refresh(); }}
            boostMode={boostMode}
            onBoostModeChange={handleBoostModeChange}
            lang={lang}
            onLangChange={handleLangChange}
            t={t}
          />
        ) : (
          <>
            <div className="main-header">
              <div className="breadcrumb"><span className="breadcrumb-current">{t.breadcrumb_records}</span></div>
            </div>
            <div className="empty">
              <div className="empty-title">{t.no_meeting_selected_title}</div>
              <div>{t.no_meeting_selected_body}</div>
            </div>
          </>
        )}
      </main>
      {toast && <Toast toast={toast} leaving={toastLeaving} />}
      <Donate t={t} />
      {archiveOpen && (
        <ArchiveView
          onClose={() => setArchiveOpen(false)}
          onChanged={refresh}
          onToast={showToast}
          t={t}
          lang={lang}
        />
      )}
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
