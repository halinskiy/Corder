import React from "react";
import { Loader2 } from "lucide-react";
import { cancelTranscription } from "../api";
import type { T } from "../i18n";

interface Props {
  meetingId: string;
  /// Unix-ms timestamp the backend stamped when the pipeline first
  /// flipped this meeting into `transcribing`. The banner counter
  /// elapses from this mark — that way the user sees real backend
  /// time, not "00:00" every time they open the meeting view.
  /// `null` for legacy rows; we fall back to "now" so the counter
  /// still ticks instead of going negative.
  startedAtMs: number | null;
  onCancelled: () => void;
  onToast: (msg: string, kind?: "success" | "error") => void;
  t: T;
}

/// "Transcribing…" card. Shares the EXACT same shell as every other
/// status / empty / clarify banner in the product —
/// `.trans-banner.clarify-banner` + `.clarify-text` (body + sub) +
/// `.clarify-actions` — so the surface doesn't change size or layout
/// between recording / transcribing / failed / empty states. The
/// spinner sits inline next to the headline so the "this is moving"
/// signal is part of the title, not a separate row that grows the card.
export function TranscribingBanner({ meetingId, startedAtMs, onCancelled, onToast, t }: Props) {
  // Backend mark when the pipeline went into .transcribing. Falling
  // back to Date.now() for legacy rows that don't carry the field —
  // keeps the timer monotonic rather than negative.
  const startedAt = startedAtMs ?? Date.now();
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
    <div className="trans-banner clarify-banner">
      <div className="clarify-text">
        <div className="clarify-body clarify-body-with-icon">
          <Loader2 size={16} className="trans-inline-spinner" aria-hidden />
          <span>{t.trans_label}</span>
        </div>
        <div className="dash-sub clarify-sub-mono">{m}:{s}</div>
      </div>
      <div className="clarify-actions clarify-actions-stack">
        <button className="clarify-btn danger" onClick={onStop} disabled={stopping}>
          {t.trans_stop}
        </button>
      </div>
    </div>
  );
}
