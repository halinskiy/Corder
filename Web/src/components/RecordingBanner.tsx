import React from "react";
import { RecordingState, stopRecordingNow } from "../api";
import type { T } from "../i18n";

interface Props {
  state: RecordingState;
  onStopped: () => void;
  onToast: (msg: string, kind?: "success" | "error") => void;
  t: T;
}

/// "Recording …" card pinned to the top of the meeting view. Shares
/// the EXACT same `.trans-banner.clarify-banner` shell as every other
/// status banner (Transcribing / Failed / Ready-when-you-are) so the
/// surface keeps a single voice — same width, same padding, same
/// typography — no layout pop between states. The blinking red dot
/// lives inline next to the headline; the elapsed timer is the
/// subtitle; Stop is a single `.clarify-btn.danger` button.
export function RecordingBanner({ state, onStopped, onToast, t }: Props) {
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
      onStopped();
    } catch {
      onToast(t.toast_settings_failed, "error");
    }
  };

  return (
    <div className="trans-banner clarify-banner">
      <div className="clarify-text">
        <div className="clarify-body clarify-body-with-icon">
          <span className={"rec-dot-inline" + (blink ? " on" : "")} aria-hidden />
          <span>{t.rec_label}</span>
        </div>
        <div className="dash-sub clarify-sub-mono">{m}:{s}</div>
      </div>
      <div className="clarify-actions clarify-actions-stack">
        <button className="clarify-btn danger" onClick={onStop} disabled={stopping}>
          {t.rec_stop}
        </button>
      </div>
    </div>
  );
}
