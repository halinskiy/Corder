import { jsx as _jsx, jsxs as _jsxs, Fragment as _Fragment } from "react/jsx-runtime";
import React from "react";
import { createRoot } from "react-dom/client";
import { listMeetings, getRecordingState, getSettings, setSettings } from "./api";
import { Sidebar } from "./components/Sidebar";
import { MeetingView } from "./components/MeetingView";
function App() {
    const [meetings, setMeetings] = React.useState([]);
    const [activeId, setActiveId] = React.useState(null);
    const [query, setQuery] = React.useState("");
    const [toast, setToast] = React.useState(null);
    const [recState, setRecState] = React.useState({ active: false });
    const [boostMode, setBoostModeState] = React.useState(false);
    const refresh = React.useCallback(async () => {
        try {
            const m = await listMeetings();
            setMeetings(m);
            // Auto-select the newest meeting on first load.
            setActiveId((cur) => cur && m.some((x) => x.id === cur) ? cur : (m[0]?.id ?? null));
        }
        catch { }
    }, []);
    React.useEffect(() => { refresh(); }, [refresh]);
    // Periodic refresh so new recordings + status transitions show up live.
    React.useEffect(() => {
        const t = setInterval(refresh, 5000);
        return () => clearInterval(t);
    }, [refresh]);
    // Poll recording state every second so the in-app Stop banner stays in sync
    // with whatever the menu-bar popover is doing.
    React.useEffect(() => {
        const tick = async () => {
            try {
                setRecState(await getRecordingState());
            }
            catch { }
        };
        tick();
        const t = setInterval(tick, 1000);
        return () => clearInterval(t);
    }, []);
    const showToast = React.useCallback((msg, kind = "success") => {
        setToast({ msg, kind });
        setTimeout(() => setToast(null), 2200);
    }, []);
    // Load persisted Boost setting once on mount.
    React.useEffect(() => {
        (async () => {
            try {
                const s = await getSettings();
                setBoostModeState(s.boost_mode);
            }
            catch { }
        })();
    }, []);
    const handleBoostModeChange = React.useCallback(async (next) => {
        setBoostModeState(next); // optimistic
        try {
            await setSettings({ boost_mode: next });
            showToast(next
                ? "Boost включён — следующая расшифровка через Gemini"
                : "Boost выключен", "success");
        }
        catch {
            setBoostModeState(!next); // rollback
            showToast("Не удалось сохранить настройку", "error");
        }
    }, [showToast]);
    const handleDeleted = React.useCallback(async (deletedId) => {
        setActiveId((prev) => (prev && (!deletedId || prev === deletedId) ? null : prev));
        await refresh();
        showToast("Запись удалена", "success");
    }, [refresh, showToast]);
    return (_jsxs("div", { className: "app", children: [_jsx(Sidebar, { meetings: meetings, activeId: activeId, query: query, onQueryChange: setQuery, onSelect: setActiveId, onDeleted: handleDeleted, onToast: showToast }), _jsx("main", { className: "main", children: activeId ? (_jsx(MeetingView, { meetingId: activeId, onDeleted: handleDeleted, onToast: showToast, recordingState: recState, onRecordingStopped: () => { setRecState({ active: false }); refresh(); }, boostMode: boostMode, onBoostModeChange: handleBoostModeChange }, activeId)) : (_jsxs(_Fragment, { children: [_jsx("div", { className: "main-header", children: _jsx("div", { className: "breadcrumb", children: _jsx("span", { className: "breadcrumb-current", children: "\u0417\u0430\u043F\u0438\u0441\u0438" }) }) }), _jsxs("div", { className: "empty", children: [_jsx("div", { className: "empty-title", children: "\u0417\u0430\u043F\u0438\u0441\u044C \u043D\u0435 \u0432\u044B\u0431\u0440\u0430\u043D\u0430" }), _jsx("div", { children: "\u0412\u044B\u0431\u0435\u0440\u0438 \u0437\u0430\u043F\u0438\u0441\u044C \u0438\u0437 \u0441\u043F\u0438\u0441\u043A\u0430 \u0441\u043B\u0435\u0432\u0430, \u0438\u043B\u0438 \u043D\u0430\u0436\u043C\u0438 Start \u0432 menu bar." })] })] })) }), toast && _jsx("div", { className: `toast toast-${toast.kind}`, children: toast.msg })] }));
}
createRoot(document.getElementById("root")).render(_jsx(App, {}));
