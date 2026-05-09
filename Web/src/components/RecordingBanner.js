import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import React from "react";
import { stopRecordingNow } from "../api";
/// Status card pinned to the top of the sidebar while a recording is active —
/// mirrors the IdleStatus / RecordingStatus blocks from the menu-bar popover so
/// the user can see "RECORDING <timer>" and tap Stop without leaving the
/// Library window.
export function RecordingBanner({ state, onStopped, onToast, t }) {
    const [now, setNow] = React.useState(Date.now());
    React.useEffect(() => {
        const t = setInterval(() => setNow(Date.now()), 1000);
        return () => clearInterval(t);
    }, []);
    if (!state.active)
        return null;
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
        }
        catch {
            onToast(t.toast_settings_failed, "error");
        }
    };
    return (_jsxs("div", { className: "rec-banner", children: [_jsxs("div", { className: "rec-banner-row", children: [_jsx("span", { className: "rec-dot" + (blink ? " on" : "") }), _jsxs("div", { className: "rec-text", children: [_jsx("div", { className: "rec-label", children: t.rec_label }), _jsxs("div", { className: "rec-time", children: [m, ":", s] })] })] }), _jsxs("button", { className: "rec-stop", onClick: onStop, disabled: stopping, children: [_jsx("span", { className: "rec-stop-square" }), t.rec_stop] })] }));
}
