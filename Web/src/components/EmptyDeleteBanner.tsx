import React from "react";
import { Loader2 } from "lucide-react";
import { archiveMeeting, retranscribe } from "../api";
import type { T } from "../i18n";

interface Props {
  meetingId: string;
  /// Parent's "tidy up" callback — fires AFTER `archiveMeeting`
  /// returns. Removes the row from the sidebar list optimistically
  /// and shows the 5-second Undo toast. Wrapped in a Promise-aware
  /// caller here so the spinner stays up until the real archive HTTP
  /// call resolves, not just until the optimistic UI flip happens.
  onDeleted: (id: string) => void;
  /// True when the pipeline ended in an error rather than just emitting an
  /// empty transcript. Adds a "Re-transcribe" action above the destructive
  /// one so the user can retry before deleting.
  failed?: boolean;
  onRetranscribed?: () => void;
  onToast?: (msg: string, kind?: "success" | "error") => void;
  t: T;
}

type Busy = null | "transcribe" | "archive";

/// Card shown when a meeting has nothing useful to read — either the model
/// produced zero segments (silent recording) or the pipeline failed
/// outright. Same outline-card visual as the other banners.
///
/// The Archive button OWNS the HTTP call (`archiveMeeting`) so the
/// spinner stays visible until the server actually moves the row.
/// Previously the parent ran `archiveMeeting` in the background and
/// jumped to Dashboard the same tick — the spinner then either
/// vanished too fast or, if the call hung, never went away because
/// the banner re-mounted in a new context. Now: stay on this page,
/// show the spinner, wait for confirmation, then call `onDeleted` to
/// let the parent do its sidebar cleanup + Undo toast.
export function EmptyDeleteBanner({ meetingId, onDeleted, failed, onRetranscribed, onToast, t }: Props) {
  const [busy, setBusy] = React.useState<Busy>(null);

  /// `archiveMeeting` is a tiny local SQLite UPDATE — it returns in
  /// ~20 ms, faster than the eye can register a spinner. We pair it
  /// with a minimum-visible delay so the user sees "loading… done"
  /// instead of the page just jumping away on click. 350 ms reads as
  /// "the system did something" without feeling sluggish.
  const MIN_VISIBLE_MS = 350;
  const withMinDelay = <T,>(p: Promise<T>): Promise<T> =>
    Promise.all([p, new Promise((r) => setTimeout(r, MIN_VISIBLE_MS))]).then(([v]) => v as T);

  const onArchive = async () => {
    if (busy) return;
    setBusy("archive");
    try {
      await withMinDelay(archiveMeeting(meetingId));
      // Parent now does its post-archive housekeeping (soft-hide the
      // row, surface the Undo toast, navigate away). We don't reset
      // `busy` — the banner unmounts a frame later.
      onDeleted(meetingId);
    } catch {
      setBusy(null);
      onToast?.(t.toast_settings_failed, "error");
    }
  };

  const onRetry = async () => {
    if (busy) return;
    setBusy("transcribe");
    try {
      await withMinDelay(retranscribe(meetingId));
      onToast?.(t.toast_retranscribe_started, "success");
      onRetranscribed?.();
    } catch {
      setBusy(null);
      onToast?.(t.toast_retranscribe_failed, "error");
    }
  };

  const transcribing = busy === "transcribe";
  const archiving = busy === "archive";
  const disableAll = busy !== null;

  return (
    <div className="trans-banner clarify-banner">
      <div className="clarify-text">
        <div className="clarify-body">
          {failed ? t.transcript_empty_failed : t.transcript_not_transcribed}
        </div>
      </div>
      <div className="clarify-actions clarify-actions-stack">
        {/* Always offer to transcribe: `failed` = retry after an error,
            otherwise the recording was kept un-transcribed (auto-
            transcribe off) and this is the manual "do it now". */}
        <button
          className="clarify-btn"
          onClick={onRetry}
          disabled={disableAll}
          aria-busy={transcribing}
        >
          {transcribing && (
            <Loader2 size={14} strokeWidth={2.5} className="dash-primary-spin" aria-hidden />
          )}
          <span>{failed ? t.btn_retranscribe : t.btn_transcribe}</span>
        </button>
        <button
          className="clarify-btn danger"
          onClick={onArchive}
          disabled={disableAll}
          aria-busy={archiving}
        >
          {archiving && (
            <Loader2 size={14} strokeWidth={2.5} className="dash-primary-spin" aria-hidden />
          )}
          <span>{t.empty_archive_btn}</span>
        </button>
      </div>
    </div>
  );
}
