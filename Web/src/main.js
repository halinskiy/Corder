import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import React from "react";
import { createRoot } from "react-dom/client";
function App() {
    const [meetings, setMeetings] = React.useState([]);
    const [error, setError] = React.useState(null);
    React.useEffect(() => {
        fetch("/api/meetings")
            .then((r) => r.json())
            .then(setMeetings)
            .catch((e) => setError(String(e)));
    }, []);
    return (_jsxs("main", { style: { padding: 32 }, children: [_jsx("h1", { style: { fontWeight: 500, letterSpacing: -0.5 }, children: "Corder" }), _jsx("p", { style: { opacity: 0.6 }, children: "Plan 1 skeleton. Server is up if you see this." }), error ? (_jsxs("pre", { style: { color: "#f88" }, children: ["error: ", error] })) : (_jsx("pre", { style: { background: "#fff", color: "#0a0a0a", padding: 16, borderRadius: 8 }, children: JSON.stringify(meetings, null, 2) }))] }));
}
createRoot(document.getElementById("root")).render(_jsx(App, {}));
