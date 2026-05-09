import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import React from "react";
import { Loader2 } from "lucide-react";
import { cancelTranscription } from "../api";
/// Mirrors RecordingBanner but for the transcribing phase: green spinner
/// instead of a red blinking dot, "TRANSCRIBING" + elapsed timer, and a
/// "Stop transcription" button that cancels the pipeline server-side.
export function TranscribingBanner({ meetingId, onCancelled, onToast, t }) {
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
        }
        catch {
            setStopping(false);
            onToast(t.toast_settings_failed, "error");
        }
    };
    return (_jsxs("div", { className: "trans-banner", children: [_jsxs("div", { className: "trans-banner-row", children: [_jsx(Loader2, { size: 16, className: "trans-spinner" }), _jsxs("div", { className: "trans-text", children: [_jsx("div", { className: "trans-label", children: t.trans_label }), _jsxs("div", { className: "trans-time", children: [m, ":", s] })] })] }), _jsxs("button", { className: "trans-stop", onClick: onStop, disabled: stopping, children: [_jsx("span", { className: "trans-stop-square" }), t.trans_stop] })] }));
}
