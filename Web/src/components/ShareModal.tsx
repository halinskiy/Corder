import React from "react";
import { Loader2, Copy, Check, X } from "lucide-react";
import { shareMeeting } from "../api";
import type { T } from "../i18n";

declare global {
  interface Window {
    corderCopy?: (text: string) => void;
  }
}

interface Props {
  meetingId: string;
  onClose: () => void;
  t: T;
}

/// Share modal. On open it creates a public share link (the backend verifies
/// the transcript is in the cloud, uploads the compact audio, and records the
/// share via the Worker), then shows the copyable URL. Reuses the `.update-card`
/// semi-3D shell used by the sign-in / update modals, so it reads as the same
/// family of surfaces.
export function ShareModal({ meetingId, onClose, t }: Props) {
  const [state, setState] = React.useState<"loading" | "ready" | "error">("loading");
  const [url, setUrl] = React.useState("");
  const [error, setError] = React.useState("");
  const [copied, setCopied] = React.useState(false);

  const create = React.useCallback(() => {
    setState("loading");
    shareMeeting(meetingId)
      .then((u) => { setUrl(u); setState("ready"); })
      .catch((e) => {
        setError((e && (e as Error).message) || "Could not create the link.");
        setState("error");
      });
  }, [meetingId]);

  React.useEffect(() => { create(); }, [create]);

  // Esc closes.
  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const copy = () => {
    try {
      // Native bridge in the WKWebView; navigator.clipboard is the dev fallback.
      if (window.corderCopy) window.corderCopy(url);
      else navigator.clipboard?.writeText(url);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1800);
    } catch { /* ignore */ }
  };

  return (
    <div className="update-overlay share-overlay" onClick={onClose}>
      <div className="update-card share-card" onClick={(e) => e.stopPropagation()}>
        <div className="update-card-sheen" aria-hidden />
        <button
          className="update-close"
          onClick={onClose}
          aria-label={t.btn_dismiss ?? "Close"}
        >
          <X size={16} />
        </button>
        <div className="update-head">
          <div className="update-title">{t.share_title ?? "Share this meeting"}</div>
        </div>

        {state === "loading" && (
          <div className="share-body share-loading">
            <Loader2 size={20} strokeWidth={2.5} className="summary-spin" aria-hidden />
            <span>{t.share_creating ?? "Creating link…"}</span>
          </div>
        )}

        {state === "ready" && (
          <div className="share-body">
            <div className="share-link-row">
              <input
                className="share-link-input"
                readOnly
                value={url}
                onFocus={(e) => e.currentTarget.select()}
                aria-label={t.share_title ?? "Share link"}
              />
              <button type="button" className="clarify-btn accent share-copy" onClick={copy}>
                {copied ? <Check size={14} /> : <Copy size={14} />}
                <span>{copied ? (t.share_copied ?? "Copied") : (t.share_copy ?? "Copy link")}</span>
              </button>
            </div>
            <div className="share-note">
              {t.share_note ?? "Anyone with the link can view. Expires in 30 days."}
            </div>
          </div>
        )}

        {state === "error" && (
          <div className="share-body share-error">
            <div className="share-error-msg">{error}</div>
            <button type="button" className="clarify-btn" onClick={create}>
              {t.share_retry ?? "Try again"}
            </button>
          </div>
        )}
      </div>
    </div>
  );
}
