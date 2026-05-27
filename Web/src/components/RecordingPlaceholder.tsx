import type { T } from "../i18n";

interface Props { t: T; }

/// Static recording card shown for the brief window between "user pressed
/// Stop" and "pipeline flipped meeting status to transcribing in the DB".
/// Without it the UI flashes the empty-state text — visually inconsistent
/// with the live RecordingBanner above. No timer, no Stop button — the
/// action is over, we just hold the visual. Same shell as the other
/// status banners so the surface doesn't resize as we walk through
/// recording → transcribing → ready.
export function RecordingPlaceholder({ t }: Props) {
  return (
    <div className="trans-banner clarify-banner">
      <div className="clarify-text">
        <div className="clarify-body clarify-body-with-icon">
          <span className="rec-dot-inline on" aria-hidden />
          <span>{t.rec_label}</span>
        </div>
        <div className="dash-sub clarify-sub-mono">—</div>
      </div>
    </div>
  );
}
