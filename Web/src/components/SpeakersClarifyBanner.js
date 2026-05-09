import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import React from "react";
import { X } from "lucide-react";
import { setExpectedSpeakers, retranscribe } from "../api";
/// Banner asks "how many people were on the call?" (total, including the
/// user). Backend stores `expected_other_speakers` = total − 1, so the
/// "Just me" option still maps to 0 and "2 people" maps to 1 etc.
const OPTIONS = [
    { othersValue: 0, label: "just_me" },
    { othersValue: 1, label: "2" },
    { othersValue: 2, label: "3" },
    { othersValue: 3, label: "4+" },
];
/// Sibling of RecordingBanner / TranscribingBanner, surfaced when the
/// auto-diarizer over-counted speakers and we'd like the user to confirm
/// the real number. Same outline-card visual language; instead of a timer
/// or live spinner it carries a single question and a row of pills.
export function SpeakersClarifyBanner({ meetingId, currentOthers, onChanged, onToast, onDismiss, t }) {
    const [busy, setBusy] = React.useState(false);
    const select = async (count) => {
        if (busy)
            return;
        setBusy(true);
        try {
            await setExpectedSpeakers(meetingId, count);
            await retranscribe(meetingId);
            onToast(t.toast_retranscribe_started, "success");
            onChanged();
        }
        catch {
            onToast(t.toast_settings_failed, "error");
        }
        finally {
            // Always release the spinner so the user can pick a different
            // option again (e.g. they hit "Just me" and immediately want to
            // try "2 people"). We deliberately keep the banner open after a
            // selection — the active pill makes the current state obvious
            // and switching is a single click.
            setBusy(false);
        }
    };
    return (_jsxs("div", { className: "trans-banner clarify-banner", children: [_jsx("button", { className: "clarify-dismiss", onClick: onDismiss, title: t.clarify_dismiss_title, "aria-label": t.clarify_dismiss_title, children: _jsx(X, { size: 14, strokeWidth: 2 }) }), _jsx("div", { className: "clarify-text", children: _jsx("div", { className: "clarify-body", children: t.clarify_question }) }), _jsx("div", { className: "clarify-actions", children: OPTIONS.map((opt) => {
                    // The "4+" pill represents 3 or more other speakers — clamp the
                    // active match to it so e.g. 5-speaker meetings still highlight
                    // the right bucket.
                    const matches = opt.othersValue === 3
                        ? currentOthers >= 3
                        : opt.othersValue === currentOthers;
                    return (_jsx("button", { className: "clarify-btn" + (matches ? " active" : ""), onClick: () => { if (!matches)
                            select(opt.othersValue); }, disabled: busy, children: opt.label === "just_me" ? t.clarify_just_me : opt.label }, opt.othersValue));
                }) })] }));
}
