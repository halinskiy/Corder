import React from "react";
import { createRoot } from "react-dom/client";
import { listMeetings, MeetingSummary, RecordingState, getRecordingState, getSettings, setSettings } from "./api";
import { Sidebar } from "./components/Sidebar";
import { MeetingView } from "./components/MeetingView";

function App() {
  const [meetings, setMeetings] = React.useState<MeetingSummary[]>([]);
  const [activeId, setActiveId] = React.useState<string | null>(null);
  const [query, setQuery] = React.useState("");
  const [toast, setToast] = React.useState<{ msg: string; kind: "success" | "error" } | null>(null);
  const [recState, setRecState] = React.useState<RecordingState>({ active: false });
  const [boostMode, setBoostModeState] = React.useState(false);

  const refresh = React.useCallback(async () => {
    try {
      const m = await listMeetings();
      setMeetings(m);
      // Auto-select the newest meeting on first load.
      setActiveId((cur) => cur && m.some((x) => x.id === cur) ? cur : (m[0]?.id ?? null));
    } catch {}
  }, []);

  React.useEffect(() => { refresh(); }, [refresh]);

  // Periodic refresh so new recordings + status transitions show up live.
  React.useEffect(() => {
    const t = setInterval(refresh, 5000);
    return () => clearInterval(t);
  }, [refresh]);

  // Poll recording state every second so the in-app Stop banner stays in sync
  // with whatever the menu-bar popover is doing.
  React.useEffect(() => {
    const tick = async () => {
      try { setRecState(await getRecordingState()); } catch {}
    };
    tick();
    const t = setInterval(tick, 1000);
    return () => clearInterval(t);
  }, []);

  const showToast = React.useCallback((msg: string, kind: "success" | "error" = "success") => {
    setToast({ msg, kind });
    setTimeout(() => setToast(null), 2200);
  }, []);

  // Load persisted Boost setting once on mount.
  React.useEffect(() => {
    (async () => {
      try {
        const s = await getSettings();
        setBoostModeState(s.boost_mode);
      } catch {}
    })();
  }, []);

  const handleBoostModeChange = React.useCallback(async (next: boolean) => {
    setBoostModeState(next); // optimistic
    try {
      await setSettings({ boost_mode: next });
      showToast(
        next
          ? "Boost включён — следующая расшифровка через Gemini"
          : "Boost выключен",
        "success",
      );
    } catch {
      setBoostModeState(!next); // rollback
      showToast("Не удалось сохранить настройку", "error");
    }
  }, [showToast]);

  const handleDeleted = React.useCallback(async (deletedId?: string) => {
    setActiveId((prev) => (prev && (!deletedId || prev === deletedId) ? null : prev));
    await refresh();
    showToast("Запись удалена", "success");
  }, [refresh, showToast]);

  return (
    <div className="app">
      <Sidebar
        meetings={meetings}
        activeId={activeId}
        query={query}
        onQueryChange={setQuery}
        onSelect={setActiveId}
        onDeleted={handleDeleted}
        onToast={showToast}
      />
      <main className="main">
        {activeId ? (
          <MeetingView
            key={activeId}
            meetingId={activeId}
            onDeleted={handleDeleted}
            onToast={showToast}
            recordingState={recState}
            onRecordingStopped={() => { setRecState({ active: false }); refresh(); }}
            boostMode={boostMode}
            onBoostModeChange={handleBoostModeChange}
          />
        ) : (
          <>
            <div className="main-header">
              <div className="breadcrumb"><span className="breadcrumb-current">Записи</span></div>
            </div>
            <div className="empty">
              <div className="empty-title">Запись не выбрана</div>
              <div>Выбери запись из списка слева, или нажми Start в menu bar.</div>
            </div>
          </>
        )}
      </main>
      {toast && <div className={`toast toast-${toast.kind}`}>{toast.msg}</div>}
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
