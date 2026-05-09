import { jsx as _jsx, jsxs as _jsxs, Fragment as _Fragment } from "react/jsx-runtime";
import React from "react";
import { X, RotateCcw, Trash2 } from "lucide-react";
import { listArchive, restoreMeeting, deleteMeeting } from "../api";
import { formatDate, formatDuration } from "../format";
/// Full-screen overlay listing archived meetings. Soft-archived meetings
/// linger here for 7 days before automatic hard-delete on next launch.
/// User can pick rows (or master-toggle all) and either restore them back
/// to the main library or wipe them immediately.
export function ArchiveView({ onClose, onChanged, onToast, t, lang }) {
    const [items, setItems] = React.useState([]);
    const [selected, setSelected] = React.useState(new Set());
    const [busy, setBusy] = React.useState(false);
    const load = React.useCallback(async () => {
        try {
            setItems(await listArchive());
        }
        catch {
            setItems([]);
        }
    }, []);
    React.useEffect(() => { load(); }, [load]);
    // Esc closes the overlay (matches the Donate modal behaviour we replaced).
    React.useEffect(() => {
        const onKey = (e) => { if (e.key === "Escape")
            onClose(); };
        window.addEventListener("keydown", onKey);
        return () => window.removeEventListener("keydown", onKey);
    }, [onClose]);
    const allSelected = items.length > 0 && selected.size === items.length;
    const someSelected = selected.size > 0 && !allSelected;
    const toggleAll = () => {
        setSelected(allSelected ? new Set() : new Set(items.map((it) => it.id)));
    };
    const toggleOne = (id) => {
        setSelected((prev) => {
            const n = new Set(prev);
            if (n.has(id))
                n.delete(id);
            else
                n.add(id);
            return n;
        });
    };
    const restoreSelected = async () => {
        if (busy || selected.size === 0)
            return;
        setBusy(true);
        const ids = Array.from(selected);
        try {
            await Promise.all(ids.map((id) => restoreMeeting(id)));
            onToast(t.toast_archive_restored(ids.length), "success");
            setSelected(new Set());
            await load();
            onChanged();
        }
        finally {
            setBusy(false);
        }
    };
    const deleteSelected = async () => {
        if (busy || selected.size === 0)
            return;
        const ids = Array.from(selected);
        if (!window.confirm(t.confirm_delete_forever(ids.length)))
            return;
        setBusy(true);
        try {
            // Hard-delete: same endpoint we used pre-archive feature. It wipes
            // the DB row, the local recording dir and best-effort the Dropbox
            // copies. Doing them in parallel is fine — they're independent.
            await Promise.all(ids.map((id) => deleteMeeting(id)));
            onToast(t.toast_archive_deleted(ids.length), "success");
            setSelected(new Set());
            await load();
            onChanged();
        }
        finally {
            setBusy(false);
        }
    };
    return (_jsx("div", { className: "donate-overlay", onClick: onClose, children: _jsxs("div", { className: "donate-card archive-card", role: "dialog", "aria-label": t.archive_title, onClick: (e) => e.stopPropagation(), children: [_jsx("button", { className: "archive-close", onClick: onClose, title: t.archive_close_title, "aria-label": t.archive_close_title, children: _jsx(X, { size: 16, strokeWidth: 2 }) }), _jsx("div", { className: "donate-card-title", children: t.archive_title }), _jsx("div", { className: "donate-card-body", children: t.archive_retention_note }), items.length === 0 ? (_jsx("div", { className: "archive-empty", children: t.archive_empty })) : (_jsxs(_Fragment, { children: [_jsxs("div", { className: "archive-row archive-row-head", children: [_jsx("label", { className: "archive-check", children: _jsx("input", { type: "checkbox", checked: allSelected, ref: (el) => { if (el)
                                            el.indeterminate = someSelected; }, onChange: toggleAll }) }), _jsx("div", { className: "archive-cell-date archive-head-label", children: t.archive_select_all }), _jsx("div", { className: "archive-cell-purge" })] }), _jsx("div", { className: "archive-list", children: items.map((it) => {
                                const checked = selected.has(it.id);
                                const daysLeft = Math.max(0, Math.ceil((it.purge_at - Date.now()) / 86_400_000));
                                return (_jsxs("label", { className: "archive-row" + (checked ? " selected" : ""), children: [_jsx("span", { className: "archive-check", children: _jsx("input", { type: "checkbox", checked: checked, onChange: () => toggleOne(it.id) }) }), _jsxs("span", { className: "archive-cell-date", children: [_jsx("span", { className: "archive-row-title", children: formatDate(it.started_at, lang) }), it.duration_ms != null && (_jsx("span", { className: "archive-row-meta", children: formatDuration(it.duration_ms) }))] }), _jsx("span", { className: "archive-cell-purge", children: t.archive_purge_in(daysLeft) })] }, it.id));
                            }) })] })), selected.size > 0 && (_jsxs("div", { className: "archive-actions", children: [_jsxs("button", { className: "ghost", onClick: restoreSelected, disabled: busy, children: [_jsx(RotateCcw, { size: 14, strokeWidth: 2 }), " ", t.archive_action_restore] }), _jsxs("button", { className: "ghost danger", onClick: deleteSelected, disabled: busy, children: [_jsx(Trash2, { size: 14, strokeWidth: 2 }), " ", t.archive_action_delete_forever] })] }))] }) }));
}
