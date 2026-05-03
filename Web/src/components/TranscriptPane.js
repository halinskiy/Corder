import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import React from "react";
import { renameSpeaker } from "../api";
import { RecordingBanner } from "./RecordingBanner";
export function TranscriptPane({ detail, currentTimeSec, onSeek, onSpeakersUpdated, query, boostOn, recordingState, onRecordingStopped, onToast }) {
    const speakerById = React.useMemo(() => {
        const map = new Map();
        detail.speakers.forEach((s) => map.set(s.id, s));
        return map;
    }, [detail.speakers]);
    // Group consecutive segments by the same speaker for paragraph layout.
    const groups = React.useMemo(() => {
        const out = [];
        for (const s of detail.segments) {
            const last = out[out.length - 1];
            if (last && last.speakerId === s.speaker_id)
                last.segs.push(s);
            else
                out.push({ speakerId: s.speaker_id, segs: [s] });
        }
        return out;
    }, [detail.segments]);
    // Filter when search query is set: hide groups with no matching segment.
    const q = query.trim().toLowerCase();
    const filteredGroups = React.useMemo(() => {
        if (!q)
            return groups;
        return groups.filter((g) => g.segs.some((s) => s.text.toLowerCase().includes(q)));
    }, [groups, q]);
    const activeSegmentId = React.useMemo(() => {
        const t = currentTimeSec * 1000;
        for (const s of detail.segments) {
            if (t >= s.start_ms && t < s.end_ms)
                return s.id;
        }
        return null;
    }, [currentTimeSec, detail.segments]);
    const containerRef = React.useRef(null);
    React.useEffect(() => {
        if (!activeSegmentId || !containerRef.current)
            return;
        const el = containerRef.current.querySelector(`[data-segid="${activeSegmentId}"]`);
        if (el)
            el.scrollIntoView({ block: "center", behavior: "smooth" });
    }, [activeSegmentId]);
    // While the active recording is the one we're viewing, replace the empty
    // "Идёт запись…" placeholder with a live status card that includes a Stop
    // button — same layout as the popover's RecordingStatus block.
    const isLiveRecording = detail.status === "recording" &&
        recordingState.active &&
        recordingState.meeting_id === detail.id;
    if (detail.segments.length === 0) {
        return (_jsx("div", { className: "transcript", ref: containerRef, children: isLiveRecording ? (_jsx(RecordingBanner, { state: recordingState, onStopped: onRecordingStopped, onToast: onToast })) : (_jsx("div", { className: "transcript-empty", children: detail.status === "ready"
                    ? "Транскрипт пуст — Whisper не распознал речь."
                    : detail.status === "transcribing"
                        ? "Расшифровка…"
                        : detail.status === "failed"
                            ? "Расшифровка не удалась. Нажми «Расшифровать заново»."
                            : "Идёт запись…" })) }));
    }
    return (_jsxs("div", { className: "transcript", ref: containerRef, children: [filteredGroups.map((g, gi) => {
                const sp = speakerById.get(g.speakerId);
                const name = sp?.custom_name?.trim() || sp?.label || "Speaker";
                const color = avatarColor(name);
                return (_jsxs("div", { className: "segment-group", children: [_jsxs("div", { className: "segment-head", children: [_jsx("div", { className: "speaker-avatar", style: { background: color }, children: initial(name) }), _jsx(SpeakerName, { meetingId: detail.id, speaker: sp, display: name === "you" ? "Я" : name, onUpdated: onSpeakersUpdated })] }), _jsx("div", { className: "segment-paragraph", children: g.segs.map((s, i) => {
                                const display = boostOn && s.text_boost ? s.text_boost : s.text;
                                return (_jsxs(React.Fragment, { children: [_jsx("span", { "data-segid": s.id, className: "segment-line" + (s.id === activeSegmentId ? " active" : ""), onClick: () => onSeek(s.start_ms / 1000), children: highlight(display, q) }), i < g.segs.length - 1 ? " " : ""] }, s.id));
                            }) })] }, gi));
            }), filteredGroups.length === 0 && q && (_jsxs("div", { className: "transcript-empty", children: ["\u041D\u0435\u0442 \u0441\u043E\u0432\u043F\u0430\u0434\u0435\u043D\u0438\u0439 \u043F\u043E \u00AB", q, "\u00BB."] }))] }));
}
function initial(name) {
    const parts = name.trim().split(/\s+/);
    if (parts.length === 1)
        return parts[0][0]?.toUpperCase() || "?";
    return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}
const PALETTE = [
    "#5a3aa6", // purple
    "#1f7a4f", // green
    "#b03a3a", // red
    "#1a4f8a", // blue
    "#7a4f1a", // orange-brown
];
function avatarColor(name) {
    let h = 0;
    for (let i = 0; i < name.length; i++)
        h = (h * 31 + name.charCodeAt(i)) >>> 0;
    return PALETTE[h % PALETTE.length];
}
function highlight(text, q) {
    if (!q)
        return text;
    const lower = text.toLowerCase();
    const out = [];
    let i = 0;
    while (i < text.length) {
        const idx = lower.indexOf(q, i);
        if (idx < 0) {
            out.push(text.slice(i));
            break;
        }
        if (idx > i)
            out.push(text.slice(i, idx));
        out.push(_jsx("mark", { style: { background: "#fff099", color: "inherit", padding: 0 }, children: text.slice(idx, idx + q.length) }, idx));
        i = idx + q.length;
    }
    return out;
}
function SpeakerName({ meetingId, speaker, display, onUpdated }) {
    const [editing, setEditing] = React.useState(false);
    const [draft, setDraft] = React.useState(speaker?.custom_name || "");
    const inputRef = React.useRef(null);
    React.useEffect(() => { if (editing)
        inputRef.current?.focus(); }, [editing]);
    if (!speaker)
        return _jsx("span", { className: "speaker-name", children: display });
    if (editing) {
        return (_jsx("input", { ref: inputRef, className: "inline-editor", value: draft, placeholder: "\u0418\u043C\u044F", onChange: (e) => setDraft(e.target.value), onBlur: async () => {
                setEditing(false);
                const trimmed = draft.trim();
                const next = trimmed.length === 0 ? null : trimmed;
                if (next !== (speaker.custom_name || null)) {
                    try {
                        await renameSpeaker(meetingId, speaker.id, next);
                        onUpdated();
                    }
                    catch { }
                }
            }, onKeyDown: (e) => {
                if (e.key === "Enter")
                    e.target.blur();
                if (e.key === "Escape") {
                    setDraft(speaker.custom_name || "");
                    setEditing(false);
                }
            } }));
    }
    return (_jsx("span", { className: "speaker-name editable", onClick: () => { setDraft(speaker.custom_name || ""); setEditing(true); }, title: "\u041A\u043B\u0438\u043A\u043D\u0438 \u0447\u0442\u043E\u0431\u044B \u043F\u0435\u0440\u0435\u0438\u043C\u0435\u043D\u043E\u0432\u0430\u0442\u044C", children: display }));
}
