import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import React from "react";
import { renameSpeaker } from "../api";
import { RecordingBanner } from "./RecordingBanner";
import { RecordingPlaceholder } from "./RecordingPlaceholder";
import { TranscribingBanner } from "./TranscribingBanner";
import { SpeakersClarifyBanner } from "./SpeakersClarifyBanner";
import { EmptyDeleteBanner } from "./EmptyDeleteBanner";
export function TranscriptPane({ detail, currentTimeSec, onSeek, onSpeakersUpdated, query, boostOn, recordingState, onRecordingStopped, onDeleted, clarifyOpen, onClarifyDismiss, onClarifyChosen, onToast, t }) {
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
    // When the clarify banner opens, glide the transcript to the top so the
    // user actually sees the card that just appeared. Without this, opening
    // the banner mid-scroll silently expands a region above the viewport
    // and reads as "the button does nothing".
    React.useEffect(() => {
        if (clarifyOpen) {
            containerRef.current?.scrollTo({ top: 0, behavior: "smooth" });
        }
    }, [clarifyOpen]);
    // While the active recording is the one we're viewing, replace the empty
    // "Идёт запись…" placeholder with a live status card that includes a Stop
    // button — same layout as the popover's RecordingStatus block.
    const isLiveRecording = detail.status === "recording" &&
        recordingState.active &&
        recordingState.meeting_id === detail.id;
    if (detail.segments.length === 0) {
        return (_jsx("div", { className: "transcript", ref: containerRef, children: isLiveRecording ? (_jsx(RecordingBanner, { state: recordingState, onStopped: onRecordingStopped, onToast: onToast, t: t })) : detail.status === "recording" ? (
            // Recording session that isn't currently live (we already pressed
            // Stop and the pipeline hasn't yet flipped status to transcribing).
            // Hold the rec-card visual so the UI doesn't flash a text-only
            // placeholder during that race window.
            _jsx(RecordingPlaceholder, { t: t })) : detail.status === "transcribing" ? (_jsx(TranscribingBanner, { meetingId: detail.id, onCancelled: onRecordingStopped, onToast: onToast, t: t })) : detail.status === "ready" || detail.status === "failed" ? (_jsx(EmptyDeleteBanner, { meetingId: detail.id, onDeleted: onDeleted, failed: detail.status === "failed", onRetranscribed: onSpeakersUpdated, onToast: onToast, t: t })) : (_jsx("div", { className: "transcript-empty", children: t.transcript_empty_recording })) }));
    }
    // The clarify banner is now driven by the parent (MeetingView) so the
    // toolbar's icon button can toggle it on/off with the same source of
    // truth. The local component only renders the wrapper that animates
    // its max-height in and out.
    return (_jsxs("div", { className: "transcript", ref: containerRef, children: [clarifyOpen && (
            // Mounted/unmounted directly. We tried wrapping it in a max-height
            // collapsible and a grid-rows collapsible — both leaked the banner's
            // own padding/border as 28-30 px of dead space when closed, because
            // the wrapper sits inside `.transcript`'s flex column with `gap: 28px`
            // and an item that close-to-zero still attracts a gap on each side.
            // Conditional render is the cleanest fix: when the user dismisses,
            // the gap goes away because the element goes away.
            _jsx(SpeakersClarifyBanner, { meetingId: detail.id, currentOthers: detail.expected_other_speakers ?? Math.max(0, detail.speakers.length - 1), onChanged: onClarifyChosen, onDismiss: onClarifyDismiss, onToast: onToast, t: t })), filteredGroups.map((g, gi) => {
                const sp = speakerById.get(g.speakerId);
                const name = sp?.custom_name?.trim() || sp?.label || "Speaker";
                const color = avatarColor(name);
                return (_jsxs("div", { className: "segment-group", children: [_jsxs("div", { className: "segment-head", children: [_jsx("div", { className: "speaker-avatar", style: { background: color }, children: initial(name) }), _jsx(SpeakerName, { meetingId: detail.id, speaker: sp, display: name === "you" ? t.speaker_self : name, onUpdated: onSpeakersUpdated, t: t })] }), _jsx("div", { className: "segment-paragraph", children: g.segs.map((s, i) => {
                                const display = boostOn && s.text_boost ? s.text_boost : s.text;
                                return (_jsxs(React.Fragment, { children: [_jsx("span", { "data-segid": s.id, className: "segment-line" + (s.id === activeSegmentId ? " active" : ""), onClick: () => onSeek(s.start_ms / 1000), children: highlight(display, q) }), i < g.segs.length - 1 ? " " : ""] }, s.id));
                            }) })] }, gi));
            }), filteredGroups.length === 0 && q && (_jsx("div", { className: "transcript-empty", children: t.transcript_no_match(q) })), _jsx("div", { className: "transcript-spacer" })] }));
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
        out.push(_jsx("mark", { style: { background: "#cdebd9", color: "inherit", padding: 0 }, children: text.slice(idx, idx + q.length) }, idx));
        i = idx + q.length;
    }
    return out;
}
function SpeakerName({ meetingId, speaker, display, onUpdated, t }) {
    const [editing, setEditing] = React.useState(false);
    const [draft, setDraft] = React.useState(speaker?.custom_name || "");
    const inputRef = React.useRef(null);
    React.useEffect(() => { if (editing)
        inputRef.current?.focus(); }, [editing]);
    if (!speaker)
        return _jsx("span", { className: "speaker-name", children: display });
    if (editing) {
        return (_jsx("input", { ref: inputRef, className: "inline-editor", value: draft, placeholder: t.inline_editor_placeholder, onChange: (e) => setDraft(e.target.value), onBlur: async () => {
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
    return (_jsx("span", { className: "speaker-name editable", onClick: () => { setDraft(speaker.custom_name || ""); setEditing(true); }, title: t.speaker_rename_title, children: display }));
}
