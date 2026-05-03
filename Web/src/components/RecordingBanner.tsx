import React from "react";
import { RecordingState, stopRecordingNow } from "../api";

interface Props {
  state: RecordingState;
  onStopped: () => void;
  onToast: (msg: string, kind?: "success" | "error") => void;
}

/// Status card pinned to the top of the sidebar while a recording is active —
/// mirrors the IdleStatus / RecordingStatus blocks from the menu-bar popover so
/// the user can see "ИДЁТ ЗАПИСЬ <timer>" and tap Stop without leaving the
/// Library window.
export function RecordingBanner({ state, onStopped, onToast }: Props) {
  const [now, setNow] = React.useState(Date.now());
  React.useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);

  if (!state.active) return null;
  const startedAt = state.started_at_ms ?? now;
  const elapsed = Math.max(0, Math.floor((now - startedAt) / 1000));
  const m = Math.floor(elapsed / 60).toString().padStart(2, "0");
  const s = (elapsed % 60).toString().padStart(2, "0");
  const blink = Math.floor(now / 1000) % 2 === 0;
  const stopping = !!state.stopping;

  const onStop = async () => {
    try {
      await stopRecordingNow();
      onToast("Останавливаю…", "success");
      onStopped();
    } catch {
      onToast("Не удалось остановить", "error");
    }
  };

  return (
    <div className="rec-banner">
      <div className="rec-banner-row">
        <span className={"rec-dot" + (blink ? " on" : "")} />
        <div className="rec-text">
          <div className="rec-label">{stopping ? "ОСТАНАВЛИВАЕМ…" : "ИДЁТ ЗАПИСЬ"}</div>
          <div className="rec-time">{m}:{s}</div>
        </div>
      </div>
      <button className="rec-stop" onClick={onStop} disabled={stopping}>
        <span className="rec-stop-square" />
        Остановить запись
      </button>
    </div>
  );
}
