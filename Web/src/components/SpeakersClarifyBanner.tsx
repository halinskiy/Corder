import React from "react";
import { X } from "lucide-react";
import { setExpectedSpeakers, retranscribe } from "../api";
import type { T } from "../i18n";

interface Props {
  meetingId: string;
  /// The PERSISTED user choice (`expected_other_speakers`), or null if
  /// the user has never picked. We deliberately do NOT fall back to the
  /// diarizer's auto-count here — a pre-highlighted guess nudges the
  /// user toward whatever the model decided. null = no pill active.
  /// Once the user picks, the backend stores it and this prop carries
  /// it back so the choice stays highlighted across the retranscribe
  /// remount.
  pickedOthers: number | null;
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
export function SpeakersClarifyBanner({ meetingId, pickedOthers, onChanged, onToast, onDismiss, t }: Props) {
  const [busy, setBusy] = React.useState(false);
  // Optimistic local echo so the pill lights up instantly on click,
  // before the retranscribe round-trip refreshes `pickedOthers`.
  const [optimistic, setOptimistic] = React.useState<number | null>(null);
  const picked = optimistic ?? pickedOthers;

  const select = async (count: number) => {
    if (busy) return;
    setOptimistic(count);
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
          // Active only reflects the user's own click in this session,
          // never a pre-filled guess. "4+" stays the bucket for 3+.
          const isActive =
            picked !== null &&
            (opt.othersValue === 3 ? picked >= 3 : picked === opt.othersValue);
          return (
            <button
              key={opt.othersValue}
              className={"clarify-btn" + (isActive ? " active" : "")}
              onClick={() => { if (!isActive) select(opt.othersValue); }}
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
