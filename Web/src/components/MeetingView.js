import { jsx as _jsx, jsxs as _jsxs, Fragment as _Fragment } from "react/jsx-runtime";
import React from "react";
import { Copy, RotateCcw, Trash2 } from "lucide-react";
import { getMeeting, getTranscriptText, deleteMeeting, retranscribe } from "../api";
function BoostSwitch({ active, onToggle, }) {
    return (_jsxs("button", { className: "boost-switch" + (active ? " on" : ""), onClick: onToggle, title: "\u041A\u043E\u0433\u0434\u0430 \u0432\u043A\u043B\u044E\u0447\u0451\u043D, \u043A\u0430\u0436\u0434\u0430\u044F \u0441\u043B\u0435\u0434\u0443\u044E\u0449\u0430\u044F \u0440\u0430\u0441\u0448\u0438\u0444\u0440\u043E\u0432\u043A\u0430 \u0430\u0432\u0442\u043E\u043C\u0430\u0442\u0438\u0447\u0435\u0441\u043A\u0438 \u0443\u043B\u0443\u0447\u0448\u0430\u0435\u0442\u0441\u044F \u0447\u0435\u0440\u0435\u0437 Gemini Flash", children: [_jsx("span", { className: "boost-track", children: _jsx("span", { className: "boost-thumb" }) }), _jsx("span", { className: "boost-label", children: "\u0423\u0441\u0438\u043B\u0438\u0442\u044C" })] }));
}
/// Clipboard via native bridge. WKWebView blocks both
/// `navigator.clipboard.writeText` and `document.execCommand('copy')` in our
/// Library window, so we ask Swift to write to NSPasteboard. Falls back to
/// the web APIs when the bridge isn't available (e.g. running in a regular
/// browser during dev with `npm run dev`).
async function copyText(text) {
    const native = window.corderCopy;
    if (typeof native === "function") {
        if (native(text))
            return;
    }
    try {
        if (navigator.clipboard?.writeText) {
            await navigator.clipboard.writeText(text);
            return;
        }
    }
    catch { }
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.left = "-9999px";
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    const ok = document.execCommand("copy");
    document.body.removeChild(ta);
    if (!ok)
        throw new Error("clipboard unavailable");
}
import { formatDate } from "../format";
import { TranscriptPane } from "./TranscriptPane";
import { RightPanel } from "./RightPanel";
export function MeetingView({ meetingId, onDeleted, onToast, recordingState, onRecordingStopped, boostMode, onBoostModeChange }) {
    const [detail, setDetail] = React.useState(null);
    const [error, setError] = React.useState(null);
    const [currentTime, setCurrentTime] = React.useState(0);
    const [search, setSearch] = React.useState("");
    const videoRef = React.useRef(null);
    const load = React.useCallback(async () => {
        setError(null);
        try {
            setDetail(await getMeeting(meetingId));
        }
        catch (e) {
            setError(String(e));
        }
    }, [meetingId]);
    React.useEffect(() => {
        setDetail(null);
        setSearch("");
        load();
    }, [load]);
    React.useEffect(() => {
        if (!detail)
            return;
        // Re-poll while a transcription or recording is in flight, or while we're
        // waiting on auto-boost — segments only get text_boost asynchronously.
        const hasBoostNow = detail.segments.some((s) => s.text_boost);
        const awaitingBoost = boostMode && detail.status === "ready" && detail.segments.length > 0 && !hasBoostNow;
        if (detail.status === "transcribing" || detail.status === "recording" || awaitingBoost) {
            const t = setInterval(load, 2000);
            return () => clearInterval(t);
        }
    }, [detail, load, boostMode]);
    if (error)
        return _jsxs("div", { className: "empty", children: [_jsx("div", { className: "empty-title", children: "\u041E\u0448\u0438\u0431\u043A\u0430" }), _jsx("div", { children: error })] });
    if (!detail)
        return _jsx("div", { className: "empty", children: _jsx("div", { children: "\u0417\u0430\u0433\u0440\u0443\u0437\u043A\u0430\u2026" }) });
    const onSeek = (sec) => {
        const v = videoRef.current;
        if (v) {
            // currentTime is only meaningful once metadata has loaded; setting it
            // before that quietly snaps back to 0. Wait for `loadedmetadata` if
            // we're not there yet, then seek + play. play() may reject in some
            // states (e.g. while still loading); we silently ignore — the click
            // counts as a user gesture so the next call usually succeeds.
            const apply = () => {
                try {
                    v.currentTime = sec;
                }
                catch { }
                v.play().catch(() => { });
            };
            if (v.readyState >= 1) {
                apply();
            }
            else {
                v.addEventListener("loadedmetadata", apply, { once: true });
                // Make sure metadata actually loads — `preload="auto"` does this
                // already, but calling load() guards against browsers that paused
                // it after the previous error/seek.
                try {
                    v.load();
                }
                catch { }
            }
        }
        setCurrentTime(sec);
    };
    const onCopy = async () => {
        try {
            const text = await getTranscriptText(detail.id);
            await copyText(text);
            onToast("Транскрипт скопирован", "success");
        }
        catch {
            onToast("Не удалось скопировать", "error");
        }
    };
    const onDelete = async () => {
        // No confirm() — WKWebView's native confirm sheet doesn't fire without
        // a UIDelegate, so the dialog never appeared and the user perceived the
        // button as broken. Toast confirms the action after the fact.
        try {
            await deleteMeeting(detail.id);
            onDeleted(detail.id);
        }
        catch {
            onToast("Не удалось удалить", "error");
        }
    };
    const onRetranscribe = async () => {
        try {
            await retranscribe(detail.id);
            onToast("Запускаю расшифровку…", "success");
            setTimeout(load, 1000);
        }
        catch {
            onToast("Не удалось запустить расшифровку", "error");
        }
    };
    const hasBoost = !!detail?.segments.some((s) => s.text_boost);
    // Boost is now a global mode: the switch reflects the persisted setting and
    // toggling it never triggers work on the currently-viewed meeting. The
    // existing meeting only renders polished text when both the global switch is
    // on AND it actually has text_boost rows (left over from a previous run with
    // the switch on, or freshly auto-boosted after retranscribe).
    const boostOn = boostMode && hasBoost;
    return (_jsxs(_Fragment, { children: [_jsxs("div", { className: "main-header", children: [_jsxs("div", { className: "breadcrumb", children: [_jsx("span", { children: "\u0417\u0430\u043F\u0438\u0441\u0438" }), _jsx("span", { style: { opacity: 0.4 }, children: "\u203A" }), _jsx("span", { className: "breadcrumb-current", children: formatDate(detail.started_at) })] }), _jsx(BoostSwitch, { active: boostMode, onToggle: () => onBoostModeChange(!boostMode) }), _jsx("div", { className: "spacer" }), _jsxs("div", { className: "toolbar", children: [_jsxs("button", { onClick: onCopy, disabled: detail.segments.length === 0, children: [_jsx(Copy, { size: 14, strokeWidth: 2 }), " \u041A\u043E\u043F\u0438\u0440\u043E\u0432\u0430\u0442\u044C"] }), _jsxs("button", { className: "ghost", onClick: onRetranscribe, children: [_jsx(RotateCcw, { size: 14, strokeWidth: 2 }), " \u0420\u0430\u0441\u0448\u0438\u0444\u0440\u043E\u0432\u0430\u0442\u044C \u0437\u0430\u043D\u043E\u0432\u043E"] }), _jsxs("button", { className: "ghost danger", onClick: onDelete, children: [_jsx(Trash2, { size: 14, strokeWidth: 2 }), " \u0423\u0434\u0430\u043B\u0438\u0442\u044C"] })] })] }), _jsxs("div", { className: "detail", children: [_jsxs("div", { className: "transcript-wrap", children: [_jsx("div", { className: "tabs", children: _jsx("span", { className: "tab active", children: "\u0422\u0440\u0430\u043D\u0441\u043A\u0440\u0438\u043F\u0442" }) }), _jsx("div", { className: "transcript-toolbar", children: _jsx("input", { type: "search", placeholder: "\u041F\u043E\u0438\u0441\u043A \u043F\u043E \u0442\u0440\u0430\u043D\u0441\u043A\u0440\u0438\u043F\u0442\u0443\u2026", value: search, onChange: (e) => setSearch(e.target.value) }) }), _jsx(TranscriptPane, { detail: detail, currentTimeSec: currentTime, onSeek: onSeek, onSpeakersUpdated: load, query: search, boostOn: boostOn, recordingState: recordingState, onRecordingStopped: onRecordingStopped, onToast: onToast })] }), _jsx(RightPanel, { detail: detail, videoRef: videoRef, onTimeUpdate: setCurrentTime, currentTimeSec: currentTime, onSeek: onSeek })] })] }));
}
