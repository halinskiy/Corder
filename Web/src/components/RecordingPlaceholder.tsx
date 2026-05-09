import type { T } from "../i18n";

interface Props { t: T; }

/// Static rec-style card shown for the brief window between "user pressed
/// Stop" and "pipeline flipped meeting status to transcribing in the DB".
/// Without it the UI flashes the empty-state text "Recording…" — which the
/// user finds visually inconsistent with the live RecordingBanner above.
/// No timer, no Stop button — the action is over, we just hold the visual.
export function RecordingPlaceholder({ t }: Props) {
  return (
    <div className="rec-banner">
      <div className="rec-banner-row">
        <span className="rec-dot on" />
        <div className="rec-text">
          <div className="rec-label">{t.rec_label}</div>
        </div>
      </div>
    </div>
  );
}
