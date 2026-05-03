import React from "react";
import { Copy, RotateCcw, Trash2 } from "lucide-react";
import { MeetingDetail, RecordingState, getMeeting, getTranscriptText, deleteMeeting, retranscribe } from "../api";

function BoostSwitch({
  active, onToggle,
}: {
  active: boolean; onToggle: () => void;
}) {
  return (
    <button
      className={"boost-switch" + (active ? " on" : "")}
      onClick={onToggle}
      title="Когда включён, каждая следующая расшифровка автоматически улучшается через Gemini Flash"
    >
      <span className="boost-track">
        <span className="boost-thumb" />
      </span>
      <span className="boost-label">Усилить</span>
    </button>
  );
}


/// Clipboard via native bridge. WKWebView blocks both
/// `navigator.clipboard.writeText` and `document.execCommand('copy')` in our
/// Library window, so we ask Swift to write to NSPasteboard. Falls back to
/// the web APIs when the bridge isn't available (e.g. running in a regular
/// browser during dev with `npm run dev`).
async function copyText(text: string): Promise<void> {
  const native = (window as any).corderCopy;
  if (typeof native === "function") {
    if (native(text)) return;
  }
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return;
    }
  } catch {}
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.style.position = "fixed";
  ta.style.left = "-9999px";
  document.body.appendChild(ta);
  ta.focus();
  ta.select();
  const ok = document.execCommand("copy");
  document.body.removeChild(ta);
  if (!ok) throw new Error("clipboard unavailable");
}
import { formatDate } from "../format";
import { TranscriptPane } from "./TranscriptPane";
import { RightPanel } from "./RightPanel";

interface Props {
  meetingId: string;
  onDeleted: (id?: string) => void;
  onToast: (msg: string, kind?: "success" | "error") => void;
  recordingState: RecordingState;
  onRecordingStopped: () => void;
  boostMode: boolean;
  onBoostModeChange: (next: boolean) => void;
}

export function MeetingView({ meetingId, onDeleted, onToast, recordingState, onRecordingStopped, boostMode, onBoostModeChange }: Props) {
  const [detail, setDetail] = React.useState<MeetingDetail | null>(null);
  const [error, setError] = React.useState<string | null>(null);
  const [currentTime, setCurrentTime] = React.useState(0);
  const [search, setSearch] = React.useState("");
  const videoRef = React.useRef<HTMLVideoElement>(null);

  const load = React.useCallback(async () => {
    setError(null);
    try { setDetail(await getMeeting(meetingId)); }
    catch (e) { setError(String(e)); }
  }, [meetingId]);

  React.useEffect(() => {
    setDetail(null);
    setSearch("");
    load();
  }, [load]);

  React.useEffect(() => {
    if (!detail) return;
    // Re-poll while a transcription or recording is in flight, or while we're
    // waiting on auto-boost — segments only get text_boost asynchronously.
    const hasBoostNow = detail.segments.some((s) => s.text_boost);
    const awaitingBoost = boostMode && detail.status === "ready" && detail.segments.length > 0 && !hasBoostNow;
    if (detail.status === "transcribing" || detail.status === "recording" || awaitingBoost) {
      const t = setInterval(load, 2000);
      return () => clearInterval(t);
    }
  }, [detail, load, boostMode]);

  if (error) return <div className="empty"><div className="empty-title">Ошибка</div><div>{error}</div></div>;
  if (!detail) return <div className="empty"><div>Загрузка…</div></div>;

  const onSeek = (sec: number) => {
    const v = videoRef.current;
    if (v) {
      // currentTime is only meaningful once metadata has loaded; setting it
      // before that quietly snaps back to 0. Wait for `loadedmetadata` if
      // we're not there yet, then seek + play. play() may reject in some
      // states (e.g. while still loading); we silently ignore — the click
      // counts as a user gesture so the next call usually succeeds.
      const apply = () => {
        try { v.currentTime = sec; } catch {}
        v.play().catch(() => {});
      };
      if (v.readyState >= 1) {
        apply();
      } else {
        v.addEventListener("loadedmetadata", apply, { once: true });
        // Make sure metadata actually loads — `preload="auto"` does this
        // already, but calling load() guards against browsers that paused
        // it after the previous error/seek.
        try { v.load(); } catch {}
      }
    }
    setCurrentTime(sec);
  };

  const onCopy = async () => {
    try {
      const text = await getTranscriptText(detail.id);
      await copyText(text);
      onToast("Транскрипт скопирован", "success");
    } catch { onToast("Не удалось скопировать", "error"); }
  };

  const onDelete = async () => {
    // No confirm() — WKWebView's native confirm sheet doesn't fire without
    // a UIDelegate, so the dialog never appeared and the user perceived the
    // button as broken. Toast confirms the action after the fact.
    try {
      await deleteMeeting(detail.id);
      onDeleted(detail.id);
    } catch {
      onToast("Не удалось удалить", "error");
    }
  };

  const onRetranscribe = async () => {
    try {
      await retranscribe(detail.id);
      onToast("Запускаю расшифровку…", "success");
      setTimeout(load, 1000);
    } catch { onToast("Не удалось запустить расшифровку", "error"); }
  };

  const hasBoost = !!detail?.segments.some((s) => s.text_boost);
  // Boost is now a global mode: the switch reflects the persisted setting and
  // toggling it never triggers work on the currently-viewed meeting. The
  // existing meeting only renders polished text when both the global switch is
  // on AND it actually has text_boost rows (left over from a previous run with
  // the switch on, or freshly auto-boosted after retranscribe).
  const boostOn = boostMode && hasBoost;

  return (
    <>
      <div className="main-header">
        <div className="breadcrumb">
          <span>Записи</span>
          <span style={{ opacity: 0.4 }}>›</span>
          <span className="breadcrumb-current">{formatDate(detail.started_at)}</span>
        </div>
        <BoostSwitch
          active={boostMode}
          onToggle={() => onBoostModeChange(!boostMode)}
        />
        <div className="spacer" />
        <div className="toolbar">
          <button onClick={onCopy} disabled={detail.segments.length === 0}>
            <Copy size={14} strokeWidth={2} /> Копировать
          </button>
          <button className="ghost" onClick={onRetranscribe}>
            <RotateCcw size={14} strokeWidth={2} /> Расшифровать заново
          </button>
          <button className="ghost danger" onClick={onDelete}>
            <Trash2 size={14} strokeWidth={2} /> Удалить
          </button>
        </div>
      </div>
      <div className="detail">
        <div className="transcript-wrap">
          <div className="tabs">
            <span className="tab active">Транскрипт</span>
          </div>
          <div className="transcript-toolbar">
            <input
              type="search"
              placeholder="Поиск по транскрипту…"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
          </div>
          <TranscriptPane
            detail={detail}
            currentTimeSec={currentTime}
            onSeek={onSeek}
            onSpeakersUpdated={load}
            query={search}
            boostOn={boostOn}
            recordingState={recordingState}
            onRecordingStopped={onRecordingStopped}
            onToast={onToast}
          />
        </div>
        <RightPanel
          detail={detail}
          videoRef={videoRef}
          onTimeUpdate={setCurrentTime}
          currentTimeSec={currentTime}
          onSeek={onSeek}
        />
      </div>
    </>
  );
}
