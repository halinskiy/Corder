import React from "react";
import { retranscribe } from "../api";
import type { T } from "../i18n";

interface Props {
  meetingId: string;
  onDeleted: (id: string) => void;
  /// True when the pipeline ended in an error rather than just emitting an
  /// empty transcript. Adds a "Re-transcribe" action above the destructive
  /// one so the user can retry before deleting.
  failed?: boolean;
  onRetranscribed?: () => void;
  onToast?: (msg: string, kind?: "success" | "error") => void;
  t: T;
}

/// Card shown when a meeting has nothing useful to read — either the model
/// produced zero segments (silent recording) or the pipeline failed
/// outright. Same outline-card visual as the other banners. Primary action
/// is Delete (with the parent's 5-second Undo window). For the failed
/// variant we offer Re-transcribe above the destructive Delete.
export function EmptyDeleteBanner({ meetingId, onDeleted, failed, onRetranscribed, onToast, t }: Props) {
  const [busy, setBusy] = React.useState(false);

  const onDelete = () => {
    if (busy) return;
    setBusy(true);
    onDeleted(meetingId);
  };

  const onRetry = async () => {
    if (busy) return;
    setBusy(true);
    try {
      await retranscribe(meetingId);
      onToast?.(t.toast_retranscribe_started, "success");
      onRetranscribed?.();
    } catch {
      setBusy(false);
      onToast?.(t.toast_retranscribe_failed, "error");
    }
  };

  return (
    <div className="trans-banner clarify-banner">
      <div className="clarify-text">
        <div className="clarify-body">
          {failed ? t.transcript_empty_failed : t.empty_delete_question}
        </div>
      </div>
      <div className="clarify-actions clarify-actions-stack">
        {failed && (
          <button className="clarify-btn" onClick={onRetry} disabled={busy}>
            {t.btn_retranscribe}
          </button>
        )}
        <button className="clarify-btn danger" onClick={onDelete} disabled={busy}>
          {t.empty_archive_btn}
        </button>
      </div>
    </div>
  );
}
