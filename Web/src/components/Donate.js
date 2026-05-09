import { jsx as _jsx, jsxs as _jsxs, Fragment as _Fragment } from "react/jsx-runtime";
import React from "react";
import { Coffee } from "lucide-react";
const BMC_USER = "3mpq";
/// Floating "Buy me a coffee" button anchored to the bottom-right of the
/// Library window. Clicking it opens a small overlay with three preset
/// amounts that link straight into the author's Buy Me a Coffee page.
export function Donate({ t }) {
    const [open, setOpen] = React.useState(false);
    /// BMC ignores `?amount=` but honours `?coffees=N`, which preselects the
    /// quantity. The page's per-coffee price is whatever the creator set in
    /// BMC settings — for the buttons here to read as $1/$3/$5 literally, the
    /// account must be configured with "One coffee = $1".
    const url = (n) => `https://www.buymeacoffee.com/${BMC_USER}?coffees=${n}`;
    /// WKWebView doesn't honour `target="_blank"` without a UIDelegate, so we
    /// route every donate click through the native bridge installed in
    /// LibraryWindow.swift. Falls back to plain window.open when running in a
    /// regular browser (npm run dev) so the dev experience still works.
    const goTo = (href) => (e) => {
        e.preventDefault();
        const native = window.corderOpenExternal;
        if (typeof native === "function" && native(href)) {
            setOpen(false);
            return;
        }
        window.open(href, "_blank", "noopener,noreferrer");
        setOpen(false);
    };
    React.useEffect(() => {
        if (!open)
            return;
        const onKey = (e) => { if (e.key === "Escape")
            setOpen(false); };
        window.addEventListener("keydown", onKey);
        return () => window.removeEventListener("keydown", onKey);
    }, [open]);
    return (_jsxs(_Fragment, { children: [_jsx("button", { className: "donate-fab", onClick: () => setOpen(true), title: t.donate_button_title, "aria-label": t.donate_button_title, children: _jsx(Coffee, { size: 18, strokeWidth: 2 }) }), open && (_jsx("div", { className: "donate-overlay", onClick: () => setOpen(false), children: _jsxs("div", { className: "donate-card", role: "dialog", "aria-label": t.donate_card_title, onClick: (e) => e.stopPropagation(), children: [_jsx("div", { className: "donate-card-title", children: t.donate_card_title }), _jsx("div", { className: "donate-card-body", children: t.donate_card_body }), _jsxs("div", { className: "donate-amounts", children: [_jsx("a", { href: url(1), onClick: goTo(url(1)), className: "donate-amount", children: "$1" }), _jsx("a", { href: url(3), onClick: goTo(url(3)), className: "donate-amount", children: "$3" }), _jsx("a", { href: url(5), onClick: goTo(url(5)), className: "donate-amount", children: "$5" })] }), _jsx("button", { className: "donate-dismiss", onClick: () => setOpen(false), children: t.donate_dismiss })] }) }))] }));
}
