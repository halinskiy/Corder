import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
/// Static rec-style card shown for the brief window between "user pressed
/// Stop" and "pipeline flipped meeting status to transcribing in the DB".
/// Without it the UI flashes the empty-state text "Recording…" — which the
/// user finds visually inconsistent with the live RecordingBanner above.
/// No timer, no Stop button — the action is over, we just hold the visual.
export function RecordingPlaceholder({ t }) {
    return (_jsx("div", { className: "rec-banner", children: _jsxs("div", { className: "rec-banner-row", children: [_jsx("span", { className: "rec-dot on" }), _jsx("div", { className: "rec-text", children: _jsx("div", { className: "rec-label", children: t.rec_label }) })] }) }));
}
