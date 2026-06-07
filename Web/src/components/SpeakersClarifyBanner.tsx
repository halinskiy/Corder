import React from "react";
import { X } from "lucide-react";
import { setExpectedSpeakers, retranscribe } from "../api";
import { SettingsSelect, type SettingsSelectOption } from "./SettingsSelect";
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
/// Discrete pills for the common small-call cases. "4+" is no longer a
/// pill — it's a dropdown (see below) so the user picks the EXACT
/// headcount for bigger calls instead of a fuzzy bucket.
const OPTIONS: Array<{ othersValue: number; label: string }> = [
  { othersValue: 0, label: "just_me" },
  { othersValue: 1, label: "2" },
  { othersValue: 2, label: "3" },
];

/// Dropdown choices for 4..10 people total (othersValue = total − 1).
const PEOPLE_DROPDOWN = [4, 5, 6, 7, 8, 9, 10];

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
          const isActive = picked !== null && picked === opt.othersValue;
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
        {/* 4+ is a dropdown — click it and pick the exact headcount.
            Same `SettingsSelect` widget as the theme picker, sized to a
            pill so it sits flush in the row. Shows "4+" until a value is
            picked (no matching option → literal fallback label), then the
            chosen total. */}
        <div className="clarify-people-slot">
          <SettingsSelect
            value={picked !== null && picked >= 3 ? String(picked + 1) : "4+"}
            options={PEOPLE_DROPDOWN.map<SettingsSelectOption<string>>((n) => ({
              value: String(n),
              label: String(n),
            }))}
            disabled={busy}
            onChange={(v) => {
              const total = parseInt(v, 10);
              if (!Number.isNaN(total)) select(total - 1);
            }}
            ariaLabel={t.clarify_question}
          />
        </div>
      </div>
    </div>
  );
}
