import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import React from "react";
import { retranscribe } from "../api";
/// Card shown when a meeting has nothing useful to read — either the model
/// produced zero segments (silent recording) or the pipeline failed
/// outright. Same outline-card visual as the other banners. Primary action
/// is Delete (with the parent's 5-second Undo window). For the failed
/// variant we offer Re-transcribe above the destructive Delete.
export function EmptyDeleteBanner({ meetingId, onDeleted, failed, onRetranscribed, onToast, t }) {
    const [busy, setBusy] = React.useState(false);
    const onDelete = () => {
        if (busy)
            return;
        setBusy(true);
        onDeleted(meetingId);
    };
    const onRetry = async () => {
        if (busy)
            return;
        setBusy(true);
        try {
            await retranscribe(meetingId);
            onToast?.(t.toast_retranscribe_started, "success");
            onRetranscribed?.();
        }
        catch {
            setBusy(false);
            onToast?.(t.toast_retranscribe_failed, "error");
        }
    };
    return (_jsxs("div", { className: "trans-banner clarify-banner", children: [_jsx("div", { className: "clarify-text", children: _jsx("div", { className: "clarify-body", children: failed ? t.transcript_empty_failed : t.empty_delete_question }) }), _jsxs("div", { className: "clarify-actions clarify-actions-stack", children: [failed && (_jsx("button", { className: "clarify-btn", onClick: onRetry, disabled: busy, children: t.btn_retranscribe })), _jsx("button", { className: "clarify-btn danger", onClick: onDelete, disabled: busy, children: t.empty_archive_btn })] })] }));
}
