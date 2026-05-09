import React from "react";
import { X } from "lucide-react";
import { setExpectedSpeakers, retranscribe } from "../api";
import type { T } from "../i18n";

interface Props {
  meetingId: string;
  /// Number of "other" speakers currently associated with this meeting —
  /// either what the user picked previously, or what the diarizer counted
  /// automatically when they never picked. Used to mark one pill as active.
  currentOthers: number;
  onChanged: () => void;
  onToast: (msg: string, kind?: "success" | "error") => void;
  /// Called when the user dismisses the banner with the X button. The parent
  /// is expected to remember the dismissal (we use localStorage upstream) so
  /// the banner doesn't reappear on the next render.
  onDismiss: () => void;
  t: T;
}

/// Banner asks "how many people were on the call?" (total, including the
/// user). Backend stores `expected_other_speakers` = total − 1, so the
/// "Just me" option still maps to 0 and "2 people" maps to 1 etc.
const OPTIONS: Array<{ othersValue: number; label: string }> = [
  { othersValue: 0, label: "just_me" },
  { othersValue: 1, label: "2" },
  { othersValue: 2, label: "3" },
  { othersValue: 3, label: "4+" },
];

/// Sibling of RecordingBanner / TranscribingBanner, surfaced when the
/// auto-diarizer over-counted speakers and we'd like the user to confirm
/// the real number. Same outline-card visual language; instead of a timer
/// or live spinner it carries a single question and a row of pills.
export function SpeakersClarifyBanner({ meetingId, currentOthers, onChanged, onToast, onDismiss, t }: Props) {
  const [busy, setBusy] = React.useState(false);

  const select = async (count: number) => {
    if (busy) return;
    setBusy(true);
    try {
      await setExpectedSpeakers(meetingId, count);
      await retranscribe(meetingId);
      onToast(t.toast_retranscribe_started, "success");
      onChanged();
    } catch {
      onToast(t.toast_settings_failed, "error");
    } finally {
      // Always release the spinner so the user can pick a different
      // option again (e.g. they hit "Just me" and immediately want to
      // try "2 people"). We deliberately keep the banner open after a
      // selection — the active pill makes the current state obvious
      // and switching is a single click.
      setBusy(false);
    }
  };

  return (
    <div className="trans-banner clarify-banner">
      <button
        className="clarify-dismiss"
        onClick={onDismiss}
        title={t.clarify_dismiss_title}
        aria-label={t.clarify_dismiss_title}
      >
        <X size={14} strokeWidth={2} />
      </button>
      <div className="clarify-text">
        <div className="clarify-body">{t.clarify_question}</div>
      </div>
      <div className="clarify-actions">
        {OPTIONS.map((opt) => {
          // The "4+" pill represents 3 or more other speakers — clamp the
          // active match to it so e.g. 5-speaker meetings still highlight
          // the right bucket.
          const matches =
            opt.othersValue === 3
              ? currentOthers >= 3
              : opt.othersValue === currentOthers;
          return (
            <button
              key={opt.othersValue}
              className={"clarify-btn" + (matches ? " active" : "")}
              onClick={() => { if (!matches) select(opt.othersValue); }}
              disabled={busy}
            >
              {opt.label === "just_me" ? t.clarify_just_me : opt.label}
            </button>
          );
        })}
      </div>
    </div>
  );
}
