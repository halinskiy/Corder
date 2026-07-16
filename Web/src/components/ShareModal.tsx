import React from "react";
import { Loader2, X } from "lucide-react";
import { shareMeeting } from "../api";
import type { T } from "../i18n";

/// Filled glyphs, not Lucide's outline ones: Copy is the green twin of the
/// play button (`.audio-btn-primary`), and a stroked icon inside a solid green
/// circle reads lighter than the filled triangle next to it. Same hand-rolled
/// pattern as RightPanel's PlaySmall / PauseSmall.
function CopyFilled() {
  return (
    <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor" aria-hidden>
      <path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1z" />
      <path d="M19 5H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2z" />
    </svg>
  );
}
function CheckFilled() {
  return (
    <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor" aria-hidden>
      <path d="M9 16.17 4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" />
    </svg>
  );
}

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
/// share via the Worker), then shows the copyable URL. Mirrors the UpdateModal
/// DOM/classes exactly (`.update-card` > `.update-head` > `.update-title` +
/// `.update-status`, then `.update-actions`), INCLUDING the cursor-tilt
/// parallax + sheen and the enter/exit animations, so it reads as the same
/// family of surfaces. Dismissed by the corner X, clicking outside, Esc, or
/// the Done button — all of which play the exit animation first.
export function ShareModal({ meetingId, onClose, t }: Props) {
  const [state, setState] = React.useState<"loading" | "ready" | "error">("loading");
  const [url, setUrl] = React.useState("");
  const [error, setError] = React.useState("");
  const [copied, setCopied] = React.useState(false);
  const [leaving, setLeaving] = React.useState(false);
  const cardRef = React.useRef<HTMLDivElement | null>(null);
  const leaveTimer = React.useRef<number | null>(null);

  // Every dismissal routes through here so the card always plays its exit
  // animation instead of vanishing on the frame (the modal used to just
  // unmount). Duration matches `update-card-out` (200ms).
  const close = React.useCallback(() => {
    if (leaving) return;
    setLeaving(true);
    if (leaveTimer.current != null) window.clearTimeout(leaveTimer.current);
    leaveTimer.current = window.setTimeout(() => { onClose(); }, 200);
  }, [leaving, onClose]);

  React.useEffect(() => () => {
    if (leaveTimer.current != null) window.clearTimeout(leaveTimer.current);
  }, []);

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

  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") close(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [close]);

  // Same cursor-tilt parallax as the update / sign-in cards: pointer position
  // over the overlay → a small rotateX/rotateY pair + sheen origin, written
  // onto the CSS variables the shared `.update-card` rules read. Rects are
  // cached (resize only) and writes coalesced to one per frame — reading
  // getBoundingClientRect per mousemove is the known tilt-stutter cause.
  React.useEffect(() => {
    const overlay = document.querySelector(".update-overlay.share-overlay") as HTMLElement | null;
    const card = cardRef.current;
    if (!overlay || !card) return;
    let oRect = overlay.getBoundingClientRect();
    let cRect = card.getBoundingClientRect();
    const remeasure = () => { oRect = overlay.getBoundingClientRect(); cRect = card.getBoundingClientRect(); };
    let raf = 0;
    let px = 0, py = 0;
    const max = 4;
    const apply = () => {
      raf = 0;
      const nx = ((px - oRect.left) / oRect.width) * 2 - 1;
      const ny = ((py - oRect.top) / oRect.height) * 2 - 1;
      card.style.setProperty("--tilt-x", `${(-ny * max).toFixed(2)}deg`);
      card.style.setProperty("--tilt-y", `${(nx * max).toFixed(2)}deg`);
      card.style.setProperty("--tilt-shine-x", `${(((px - cRect.left) / cRect.width) * 100).toFixed(1)}%`);
      card.style.setProperty("--tilt-shine-y", `${(((py - cRect.top) / cRect.height) * 100).toFixed(1)}%`);
    };
    const onMove = (e: MouseEvent) => {
      px = e.clientX; py = e.clientY;
      card.classList.remove("tilt-snap-back");
      if (!raf) raf = requestAnimationFrame(apply);
    };
    const reset = () => {
      if (raf) { cancelAnimationFrame(raf); raf = 0; }
      card.classList.add("tilt-snap-back");
      card.style.setProperty("--tilt-x", "0deg");
      card.style.setProperty("--tilt-y", "0deg");
      card.style.setProperty("--tilt-shine-x", "50%");
      card.style.setProperty("--tilt-shine-y", "50%");
    };
    overlay.addEventListener("mousemove", onMove);
    overlay.addEventListener("mouseleave", reset);
    window.addEventListener("resize", remeasure);
    return () => {
      overlay.removeEventListener("mousemove", onMove);
      overlay.removeEventListener("mouseleave", reset);
      window.removeEventListener("resize", remeasure);
      if (raf) cancelAnimationFrame(raf);
    };
  }, []);

  const copy = () => {
    try {
      if (window.corderCopy) window.corderCopy(url);
      else navigator.clipboard?.writeText(url);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1800);
    } catch { /* ignore */ }
  };

  return (
    <div
      className={"update-overlay share-overlay" + (leaving ? " is-leaving" : "")}
      role="dialog"
      aria-modal="true"
      aria-label={t.share_title ?? "Share this meeting"}
      onMouseDown={(e) => { if (e.target === e.currentTarget) close(); }}
    >
      <div
        className={"update-card share-card" + (leaving ? " is-leaving" : "")}
        ref={cardRef}
        onMouseDown={(e) => e.stopPropagation()}
      >
        <div className="update-card-sheen" aria-hidden />

        <button
          type="button"
          className="clarify-dismiss"
          onClick={close}
          title={t.share_close ?? "Close"}
          aria-label={t.share_close ?? "Close"}
        >
          <X size={14} strokeWidth={2} />
        </button>

        <div className="update-head">
          <div className="update-title">{t.share_title ?? "Share this meeting"}</div>
          {state === "loading" && (
            <div className="update-status share-status-loading">
              <Loader2 size={15} strokeWidth={2.5} className="summary-spin" aria-hidden />
              <span>{t.share_creating ?? "Creating link…"}</span>
            </div>
          )}
          {state === "ready" && (
            <div className="update-status">
              {t.share_note ?? "Anyone with the link can view. Expires in 30 days."}
            </div>
          )}
          {state === "error" && (
            <div className="update-status error">{error}</div>
          )}
        </div>

        {state === "ready" && (
          <div className="share-link-row">
            <input
              className="share-link-input"
              readOnly
              value={url}
              onFocus={(e) => e.currentTarget.select()}
              aria-label={t.share_title ?? "Share link"}
            />
            <button
              type="button"
              className="share-copy"
              onClick={copy}
              title={copied ? (t.share_copied ?? "Copied") : (t.share_copy ?? "Copy link")}
              aria-label={copied ? (t.share_copied ?? "Copied") : (t.share_copy ?? "Copy link")}
            >
              {copied ? <CheckFilled /> : <CopyFilled />}
            </button>
          </div>
        )}

        <div className="update-actions">
          {state === "error" && (
            <button type="button" className="update-primary" onClick={create}>
              <span className="update-primary-label">{t.share_retry ?? "Try again"}</span>
            </button>
          )}
          {state !== "loading" && (
            <button type="button" className="update-secondary" onClick={close}>
              {t.share_done ?? "Done"}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
