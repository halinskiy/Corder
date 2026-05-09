import { jsx as _jsx, jsxs as _jsxs, Fragment as _Fragment } from "react/jsx-runtime";
import React from "react";
import { Download } from "lucide-react";
import { audioSrc } from "../api";
import { formatDuration } from "../format";
export function RightPanel({ detail, videoRef, onTimeUpdate, currentTimeSec, onSeek, t, lang = "ru" }) {
    const audioRef = videoRef;
    return (_jsxs("div", { className: "right-panel", children: [_jsx(AudioCard, { detail: detail, audioRef: audioRef, onTimeUpdate: onTimeUpdate, t: t }), _jsx(SpeakerTimeline, { detail: detail, currentTimeSec: currentTimeSec, onSeek: onSeek, t: t, lang: lang })] }));
}
/** Custom audio player shaped like the old video card: 16/10 box with a
 *  big centred play button, ±10s skip buttons in the bottom bar, current
 *  time / duration, and a clickable scrub line. The native <audio>
 *  element is kept hidden — we drive it through React state. */
function AudioCard({ detail, audioRef, onTimeUpdate, t, }) {
    const [playing, setPlaying] = React.useState(false);
    const [duration, setDuration] = React.useState((detail.duration_ms ?? 0) / 1000);
    const [time, setTime] = React.useState(0);
    const togglePlay = () => {
        const a = audioRef.current;
        if (!a)
            return;
        if (a.paused)
            a.play().catch(() => { });
        else
            a.pause();
    };
    const onScrubClick = (e) => {
        const a = audioRef.current;
        if (!a || !duration)
            return;
        const rect = e.currentTarget.getBoundingClientRect();
        const ratio = (e.clientX - rect.left) / rect.width;
        a.currentTime = Math.max(0, Math.min(1, ratio)) * duration;
    };
    const [hover, setHover] = React.useState(null);
    const onScrubMove = (e) => {
        if (!duration)
            return;
        const rect = e.currentTarget.getBoundingClientRect();
        const ratio = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
        setHover({ pct: ratio * 100, time: ratio * duration });
    };
    const cursorPct = duration > 0 ? Math.min(100, Math.max(0, (time / duration) * 100)) : 0;
    // Empty / not-yet-finalised meetings have nothing to play — disable the
    // primary control instead of letting the user click into nothing.
    const playable = duration > 0 &&
        detail.status !== "recording" &&
        !!detail.duration_ms;
    return (_jsxs(_Fragment, { children: [_jsxs("div", { className: "audio-controls", children: [_jsx("button", { className: "audio-btn audio-btn-primary", onClick: togglePlay, disabled: !playable, children: playing ? _jsx(PauseSmall, {}) : _jsx(PlaySmall, {}) }), _jsxs("div", { className: "audio-time", children: [fmtTime(time), " / ", fmtTime(duration)] }), _jsxs("div", { className: "audio-scrub", onClick: onScrubClick, onMouseMove: onScrubMove, onMouseLeave: () => setHover(null), children: [_jsx("div", { className: "audio-scrub-fill", style: { width: `${cursorPct}%` } }), hover && (_jsx("div", { className: "audio-scrub-tooltip", style: { left: `${hover.pct}%` }, children: fmtTime(hover.time) }))] }), _jsx("a", { className: "toolbar-icon-btn audio-download-btn", href: audioSrc(detail.id), download: `corder-${detail.id}.wav`, title: t.download_audio_title, "aria-label": t.download_audio_title, children: _jsx(Download, { size: 16, strokeWidth: 2 }) })] }), _jsx("audio", { ref: audioRef, src: audioSrc(detail.id), preload: "auto", style: { display: "none" }, onPlay: () => setPlaying(true), onPause: () => setPlaying(false), onEnded: () => setPlaying(false), onLoadedMetadata: (e) => {
                    const d = e.target.duration;
                    if (isFinite(d) && d > 0)
                        setDuration(d);
                }, onTimeUpdate: (e) => {
                    const t = e.target.currentTime;
                    setTime(t);
                    onTimeUpdate(t);
                } })] }));
}
function fmtTime(sec) {
    if (!isFinite(sec) || sec < 0)
        sec = 0;
    const total = Math.floor(sec);
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    return h > 0
        ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
        : `${m}:${String(s).padStart(2, "0")}`;
}
function PlaySmall() {
    return (_jsx("svg", { viewBox: "0 0 16 16", width: "14", height: "14", fill: "currentColor", "aria-hidden": true, children: _jsx("path", { d: "M4 2.5v11c0 .6.7 1 1.2.6l8.4-5.5a.7.7 0 0 0 0-1.2L5.2 1.9C4.7 1.5 4 1.9 4 2.5z" }) }));
}
function PauseSmall() {
    return (_jsxs("svg", { viewBox: "0 0 16 16", width: "14", height: "14", fill: "currentColor", "aria-hidden": true, children: [_jsx("rect", { x: "4", y: "2.5", width: "3", height: "11", rx: "0.6" }), _jsx("rect", { x: "9", y: "2.5", width: "3", height: "11", rx: "0.6" })] }));
}
const PALETTE = [
    "#5a3aa6", // purple
    "#a51d4f", // crimson
    "#7a1f1f", // dark red
    "#1a4f8a", // blue
    "#1f7a4f", // green
    "#7a4f1a", // brown
];
function colorForSpeaker(name) {
    let h = 0;
    for (let i = 0; i < name.length; i++)
        h = (h * 31 + name.charCodeAt(i)) >>> 0;
    return PALETTE[h % PALETTE.length];
}
/// For each speech segment, lay down ~2-3 px ticks every 220 ms. This gives
/// the Grain look — natural pauses (silent gaps in the source) become gaps
/// between ticks; long monologues turn into a dense run of ticks.
function ticksFor(segs, totalMs) {
    const TICK_MS = 220;
    const out = [];
    for (const s of segs) {
        const dur = s.end_ms - s.start_ms;
        const n = Math.max(1, Math.floor(dur / TICK_MS));
        for (let i = 0; i < n; i++) {
            const t = s.start_ms + (i + 0.5) * (dur / n);
            if (t < 0 || t > totalMs)
                continue;
            out.push((t / totalMs) * 100);
        }
    }
    return out;
}
function SpeakerTimeline({ detail, currentTimeSec, onSeek, t, lang, }) {
    const totalMs = detail.duration_ms || 0;
    if (totalMs === 0 || detail.segments.length === 0)
        return null;
    const totals = new Map();
    for (const s of detail.segments) {
        const dur = s.end_ms - s.start_ms;
        totals.set(s.speaker_id, (totals.get(s.speaker_id) || 0) + dur);
    }
    const activeSpeakers = detail.speakers.filter((sp) => (totals.get(sp.id) || 0) > 0);
    if (activeSpeakers.length === 0)
        return null;
    const cursorPct = Math.min(100, Math.max(0, (currentTimeSec * 1000 / totalMs) * 100));
    const onBarClick = (e) => {
        const rect = e.currentTarget.getBoundingClientRect();
        const ratio = (e.clientX - rect.left) / rect.width;
        onSeek(Math.max(0, Math.min(1, ratio)) * (totalMs / 1000));
    };
    return (_jsxs("div", { className: "timeline-card", children: [_jsx("div", { className: "timeline-tabs", children: _jsx("span", { className: "timeline-tab active", children: t.timeline_title }) }), activeSpeakers.map((sp) => {
                const segs = detail.segments.filter((s) => s.speaker_id === sp.id);
                const sum = totals.get(sp.id) || 0;
                const pct = Math.round((sum / totalMs) * 100);
                const name = sp.custom_name?.trim() || sp.label;
                const color = sp.color_hex && /^#[0-9a-f]{6}$/i.test(sp.color_hex)
                    ? sp.color_hex
                    : colorForSpeaker(name);
                return (_jsxs("div", { className: "tl-row", children: [_jsxs("div", { className: "tl-row-head", children: [_jsx("span", { className: "tl-name", children: name }), _jsxs("span", { className: "tl-stats", children: [pct, "% \u00B7 ", formatDuration(sum, lang)] })] }), _jsxs("div", { className: "tl-bar", onClick: onBarClick, children: [ticksFor(segs, totalMs).map((leftPct, i) => (_jsx("div", { className: "tl-bar-tick", style: { left: `${leftPct}%`, background: color } }, i))), _jsx("div", { className: "tl-bar-cursor", style: { left: `${cursorPct}%` } })] })] }, sp.id));
            })] }));
}
