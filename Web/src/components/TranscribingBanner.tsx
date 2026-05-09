import React from "react";
import { Loader2 } from "lucide-react";
import { cancelTranscription } from "../api";
import type { T } from "../i18n";

interface Props {
  meetingId: string;
  onCancelled: () => void;
  onToast: (msg: string, kind?: "success" | "error") => void;
  t: T;
}

/// Mirrors RecordingBanner but for the transcribing phase: green spinner
/// instead of a red blinking dot, "TRANSCRIBING" + elapsed timer, and a
/// "Stop transcription" button that cancels the pipeline server-side.
export function TranscribingBanner({ meetingId, onCancelled, onToast, t }: Props) {
  // Timer starts when the banner mounts. This is approximate (we don't
  // know exactly when WhisperKit started chewing), but matches the user's
  // mental model: "I clicked Re-transcribe at 00:00 of the spinner".
  const startedAt = React.useRef(Date.now()).current;
  const [now, setNow] = React.useState(Date.now());
  const [stopping, setStopping] = React.useState(false);
  React.useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);

  const elapsed = Math.max(0, Math.floor((now - startedAt) / 1000));
  const m = Math.floor(elapsed / 60).toString().padStart(2, "0");
  const s = (elapsed % 60).toString().padStart(2, "0");

  const onStop = async () => {
    setStopping(true);
    try {
      await cancelTranscription(meetingId);
      onToast(t.trans_cancelled, "success");
      onCancelled();
    } catch {
      setStopping(false);
      onToast(t.toast_settings_failed, "error");
    }
  };

  return (
    <div className="trans-banner">
      <div className="trans-banner-row">
        <Loader2 size={16} className="trans-spinner" />
        <div className="trans-text">
          <div className="trans-label">{t.trans_label}</div>
          <div className="trans-time">{m}:{s}</div>
        </div>
      </div>
      <button className="trans-stop" onClick={onStop} disabled={stopping}>
        <span className="trans-stop-square" />
        {t.trans_stop}
      </button>
    </div>
  );
}
