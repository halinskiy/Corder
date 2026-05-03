import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import React from "react";
import { Search } from "lucide-react";
import { deleteMeeting, retranscribe } from "../api";
import { formatDate, formatDuration, dateBucket } from "../format";
function statusLabel(s) {
    switch (s) {
        case "recording": return "запись";
        case "transcribing": return "расшифровка";
        case "ready": return "готово";
        case "failed": return "ошибка";
    }
}
function plural(n) {
    // Russian plural for участник: 1 участник, 2-4 участника, 5+ участников.
    const mod10 = n % 10, mod100 = n % 100;
    if (mod10 === 1 && mod100 !== 11)
        return "";
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14))
        return "а";
    return "ов";
}
function UserFilledIcon() {
    return (_jsxs("svg", { width: "12", height: "12", viewBox: "0 0 12 12", fill: "currentColor", "aria-hidden": true, children: [_jsx("circle", { cx: "6", cy: "3.5", r: "2.2" }), _jsx("path", { d: "M1.5 11c0-2.3 2-4 4.5-4s4.5 1.7 4.5 4v0.5h-9V11z" })] }));
}
export function Sidebar({ meetings, activeId, query, onQueryChange, onSelect, onDeleted, onToast }) {
    const [menu, setMenu] = React.useState(null);
    // Close the menu on any click outside or Escape. We deliberately do NOT
    // subscribe to `contextmenu` here — that exact handler is what was
    // killing the menu the moment it opened: the meeting-item's onContextMenu
    // fires, setMenu({...}) runs, the effect mounts and immediately receives
    // the same event bubbling up to window, and the menu closes again.
    // A fresh right-click on another item will open it for that item via the
    // `setMenu` path, which replaces the previous state anyway.
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
            formatDate(m.started_at).toLowerCase().includes(q));
    }, [meetings, query]);
    // Group by date bucket while preserving sort order (newest first).
    const groups = React.useMemo(() => {
        const out = [];
        for (const m of filtered) {
            const label = dateBucket(m.started_at);
            const last = out[out.length - 1];
            if (last && last.label === label)
                last.items.push(m);
            else
                out.push({ label, items: [m] });
        }
        return out;
    }, [filtered]);
    return (_jsxs("aside", { className: "sidebar", children: [_jsx("div", { className: "sidebar-titlebar-pad" }), _jsx("div", { className: "sidebar-search", children: _jsxs("div", { className: "search-field", children: [_jsx(Search, { size: 14, strokeWidth: 2 }), _jsx("input", { type: "search", placeholder: "\u041F\u043E\u0438\u0441\u043A \u0437\u0430\u043F\u0438\u0441\u0435\u0439\u2026", value: query, onChange: (e) => onQueryChange(e.target.value) })] }) }), _jsxs("div", { className: "sidebar-list", children: [filtered.length === 0 && (_jsx("div", { style: { padding: 16, color: "var(--fg-muted)", fontSize: 13 }, children: meetings.length === 0
                            ? "Записей пока нет. Нажми Start в menu bar."
                            : "Нет совпадений." })), groups.map((g) => (_jsxs(React.Fragment, { children: [_jsx("div", { className: "sidebar-section-label", children: g.label }), g.items.map((m) => (_jsxs("div", { className: "meeting-item" + (m.id === activeId ? " active" : ""), onClick: () => onSelect(m.id), onContextMenu: (e) => {
                                    e.preventDefault();
                                    setMenu({ x: e.clientX, y: e.clientY, meetingId: m.id });
                                }, children: [_jsxs("div", { className: "meeting-row", children: [_jsx("div", { className: "meeting-title", children: formatDate(m.started_at) }), m.speaker_count > 0 && (_jsxs("div", { className: "meeting-people", title: `${m.speaker_count} участник${plural(m.speaker_count)}`, children: [_jsx("span", { className: "meeting-people-count", children: m.speaker_count }), _jsx(UserFilledIcon, {})] }))] }), _jsxs("div", { className: "meeting-meta", children: [_jsx("span", { className: `status-dot ${m.status}` }), _jsx("span", { children: formatDuration(m.duration_ms) }), m.status !== "ready" && _jsxs("span", { children: ["\u00B7 ", statusLabel(m.status)] })] }), m.preview && _jsx("div", { className: "meeting-preview", children: m.preview })] }, m.id)))] }, g.label)))] }), menu && (_jsx(ContextMenu, { x: menu.x, y: menu.y, onDelete: async () => {
                    const id = menu.meetingId;
                    setMenu(null);
                    try {
                        await deleteMeeting(id);
                        onDeleted(id);
                    }
                    catch {
                        onToast("Не удалось удалить", "error");
                    }
                }, onRetranscribe: async () => {
                    const id = menu.meetingId;
                    setMenu(null);
                    try {
                        await retranscribe(id);
                        onToast("Запускаю расшифровку…", "success");
                    }
                    catch {
                        onToast("Не удалось запустить расшифровку", "error");
                    }
                } }))] }));
}
function ContextMenu({ x, y, onDelete, onRetranscribe }) {
    return (_jsxs("div", { className: "ctx-menu", style: { top: y, left: x }, onClick: (e) => e.stopPropagation(), onContextMenu: (e) => e.preventDefault(), children: [_jsx("button", { className: "ctx-item", onClick: onRetranscribe, children: "\u0420\u0430\u0441\u0448\u0438\u0444\u0440\u043E\u0432\u0430\u0442\u044C \u0437\u0430\u043D\u043E\u0432\u043E" }), _jsx("div", { className: "ctx-sep" }), _jsx("button", { className: "ctx-item ctx-danger", onClick: onDelete, children: "\u0423\u0434\u0430\u043B\u0438\u0442\u044C" })] }));
}
