import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import React from "react";
import { Search } from "lucide-react";
import { retranscribe } from "../api";
import { formatDate, formatDuration, dateBucket } from "../format";
function statusLabel(s, t) {
    switch (s) {
        case "recording": return t.status_recording;
        case "transcribing": return t.status_transcribing;
        case "ready": return t.status_ready;
        case "failed": return t.status_failed;
    }
}
function UserFilledIcon() {
    return (_jsxs("svg", { width: "12", height: "12", viewBox: "0 0 12 12", fill: "currentColor", "aria-hidden": true, children: [_jsx("circle", { cx: "6", cy: "3.5", r: "2.2" }), _jsx("path", { d: "M1.5 11c0-2.3 2-4 4.5-4s4.5 1.7 4.5 4v0.5h-9V11z" })] }));
}
export function Sidebar({ meetings, activeId, query, onQueryChange, onSelect, onDeleted, onToast, t, lang }) {
    const [menu, setMenu] = React.useState(null);
    React.useEffect(() => {
        if (!menu)
            return;
        const close = () => setMenu(null);
        const onKey = (e) => { if (e.key === "Escape")
            close(); };
        window.addEventListener("click", close);
        window.addEventListener("keydown", onKey);
        return () => {
            window.removeEventListener("click", close);
            window.removeEventListener("keydown", onKey);
        };
    }, [menu]);
    const filtered = React.useMemo(() => {
        if (!query.trim())
            return meetings;
        const q = query.toLowerCase();
        return meetings.filter((m) => (m.preview || "").toLowerCase().includes(q) ||
            (m.speaker_names || "").toLowerCase().includes(q) ||
            formatDate(m.started_at, lang).toLowerCase().includes(q));
    }, [meetings, query, lang]);
    const groups = React.useMemo(() => {
        const out = [];
        for (const m of filtered) {
            const label = dateBucket(m.started_at, lang);
            const last = out[out.length - 1];
            if (last && last.label === label)
                last.items.push(m);
            else
                out.push({ label, items: [m] });
        }
        return out;
    }, [filtered, lang]);
    return (_jsxs("aside", { className: "sidebar", children: [_jsx("div", { className: "sidebar-titlebar-pad" }), _jsx("div", { className: "sidebar-search", children: _jsxs("div", { className: "search-field", children: [_jsx(Search, { size: 14, strokeWidth: 2 }), _jsx("input", { type: "search", placeholder: t.sidebar_search, value: query, onChange: (e) => onQueryChange(e.target.value) })] }) }), _jsxs("div", { className: "sidebar-list", children: [filtered.length === 0 && (_jsx("div", { style: { padding: 16, color: "var(--fg-muted)", fontSize: 13 }, children: meetings.length === 0 ? t.sidebar_empty : t.sidebar_no_match })), groups.map((g) => (_jsxs(React.Fragment, { children: [_jsx("div", { className: "sidebar-section-label", children: g.label }), g.items.map((m) => (_jsxs("div", { className: "meeting-item" + (m.id === activeId ? " active" : ""), onClick: () => onSelect(m.id), onContextMenu: (e) => {
                                    e.preventDefault();
                                    setMenu({ x: e.clientX, y: e.clientY, meetingId: m.id });
                                }, children: [_jsxs("div", { className: "meeting-row", children: [_jsx("div", { className: "meeting-title", children: formatDate(m.started_at, lang) }), m.speaker_count > 0 && (_jsxs("div", { className: "meeting-people", title: t.participants(m.speaker_count), children: [_jsx("span", { className: "meeting-people-count", children: m.speaker_count }), _jsx(UserFilledIcon, {})] }))] }), _jsxs("div", { className: "meeting-meta", children: [_jsx("span", { className: `status-dot ${m.status}` }), _jsx("span", { children: formatDuration(m.duration_ms, lang) }), m.status !== "ready" && _jsxs("span", { children: ["\u00B7 ", statusLabel(m.status, t)] })] }), m.preview && _jsx("div", { className: "meeting-preview", children: m.preview })] }, m.id)))] }, g.label))), _jsx("div", { className: "sidebar-list-spacer" })] }), menu && (_jsx(ContextMenu, { x: menu.x, y: menu.y, t: t, onDelete: () => {
                    const id = menu.meetingId;
                    setMenu(null);
                    // Actual DELETE is scheduled by the parent (10s undo window).
                    onDeleted(id);
                }, onRetranscribe: async () => {
                    const id = menu.meetingId;
                    setMenu(null);
                    try {
                        await retranscribe(id);
                        onToast(t.toast_retranscribe_started, "success");
                    }
                    catch {
                        onToast(t.toast_retranscribe_failed, "error");
                    }
                } }))] }));
}
function ContextMenu({ x, y, onDelete, onRetranscribe, t }) {
    return (_jsxs("div", { className: "ctx-menu", style: { top: y, left: x }, onClick: (e) => e.stopPropagation(), onContextMenu: (e) => e.preventDefault(), children: [_jsx("button", { className: "ctx-item", onClick: onRetranscribe, children: t.ctx_retranscribe }), _jsx("div", { className: "ctx-sep" }), _jsx("button", { className: "ctx-item", onClick: onDelete, children: t.ctx_archive })] }));
}
