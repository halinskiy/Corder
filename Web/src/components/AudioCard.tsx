import React from "react";
import { Share2, Scissors } from "lucide-react";
import { MeetingDetail, audioSrc } from "../api";
import type { T } from "../i18n";

/// Playback controls + the hidden <audio> that is the master clock for the
/// whole right column (the video element, when present, is slaved to it).
///
/// Extracted from RightPanel so the public share page can render the REAL
/// player instead of a copy that would drift from this one. Two props carry
/// that split: `audioUrl` (the share page passes the Worker's signed URL;
/// in-app it defaults to the local server route) and `onShare` (absent on the
/// share page, which hides the Share + clip actions — a viewer cannot re-share
/// or clip someone else's meeting).
export function AudioCard({
  detail, audioRef, onTimeUpdate, onShare, onClip, clipActive = false, audioUrl, t,
}: {
  detail: MeetingDetail;
  audioRef: React.RefObject<HTMLAudioElement>;
  onTimeUpdate: (sec: number) => void;
  /// Omit to hide the Share + clip buttons entirely (read-only viewer).
  onShare?: () => void;
  /// Toggles clip-select mode (pick a range in the transcript). Omit to hide
  /// the Scissors button (read-only viewer).
  onClip?: () => void;
  /// Reflects whether clip mode is currently on, so the Scissors button lights
  /// up active the same way the transcript toolbar buttons do.
  clipActive?: boolean;
  /// Defaults to the app's local `/api/meetings/:id/audio` route.
  audioUrl?: string;
  t: T;
}) {
  const [playing, setPlaying] = React.useState(false);
  const [duration, setDuration] = React.useState((detail.duration_ms ?? 0) / 1000);
  const [time, setTime] = React.useState(0);

  // The <audio> element is reused across meeting switches (RightPanel
  // never unmounts), so changing its `src` doesn't reliably zero
  // `currentTime` until new metadata loads, meanwhile the scrubber
  // showed the previous session's position. Hard-reset element +
  // local state the instant the meeting id changes.
  React.useEffect(() => {
    setTime(0);
    setPlaying(false);
    setDuration((detail.duration_ms ?? 0) / 1000);
    const a = audioRef.current;
    if (a) {
      try { a.pause(); a.currentTime = 0; } catch { /* not seekable yet */ }
    }
  }, [detail.id]);

  // Retry timer for a reload that never reaches `canplay` (a starved
  // request, a dead keep-alive socket). One extra load() 5s later turns a
  // silently dead click into a self-healing one; the canplay listener stays
  // armed so playback starts whenever data finally arrives.
  const recoverTimer = React.useRef<number | null>(null);
  React.useEffect(() => () => {
    if (recoverTimer.current) window.clearTimeout(recoverTimer.current);
  }, []);

  const playViaReload = (a: HTMLAudioElement) => {
    const onReady = () => { a.removeEventListener("canplay", onReady); a.play().catch(() => {}); };
    a.addEventListener("canplay", onReady);
    try { a.load(); } catch { /* not ready */ }
    if (recoverTimer.current) window.clearTimeout(recoverTimer.current);
    recoverTimer.current = window.setTimeout(() => {
      if (a.readyState === 0 && a.paused) { try { a.load(); } catch { /* still not ready */ } }
    }, 5000);
  };

  const togglePlay = () => {
    const a = audioRef.current; if (!a) return;
    if (!a.paused) { a.pause(); return; }
    // Recover a stuck element: the browser preloads the audio src, and if it
    // was fetched WHILE the meeting was still recording (the playback mix is
    // produced only at stop) it 404s and the element sticks in an error state,
    // so play() stays silent even once the file exists. Reload it, then play
    // once it can — calling play() SYNCHRONOUSLY right after load() is a no-op
    // in WKWebView, because load() resets the element to HAVE_NOTHING and the
    // media isn't fetched yet, so the click did nothing and the user had to
    // press twice. Deferring play() to `canplay` makes a single click work.
    if (a.error || a.readyState === 0) {
      playViaReload(a);
      return;
    }
    // A rejected play() (WKWebView's media stack can wedge after a starved
    // load) gets one reload-and-retry instead of dying silently.
    a.play().catch(() => playViaReload(a));
  };
  // Press-and-drag scrubbing with pointer capture: once the button is
  // down, the position follows the pointer even OUTSIDE the track, so
  // dragging past the left edge lands exactly on 0:00 instead of
  // pixel-hunting the first millimetre. A plain click still seeks (the
  // down event itself seeks). While dragging, the fill follows the
  // pointer ratio, not the audio clock — a seek on a long file can lag
  // a frame and the bar must never rubber-band under the cursor.
  const [drag, setDrag] = React.useState<number | null>(null);
  const [hover, setHover] = React.useState<{ pct: number; time: number } | null>(null);

  const scrubRatio = (e: React.PointerEvent<HTMLDivElement>) => {
    const rect = e.currentTarget.getBoundingClientRect();
    return Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
  };
  const seekTo = (ratio: number) => {
    const a = audioRef.current; if (!a) return;
    try { a.currentTime = ratio * duration; } catch { /* not seekable yet */ }
  };
  const onScrubDown = (e: React.PointerEvent<HTMLDivElement>) => {
    if (!duration) return;
    e.currentTarget.setPointerCapture(e.pointerId);
    const r = scrubRatio(e);
    setDrag(r);
    seekTo(r);
    setHover({ pct: r * 100, time: r * duration });
  };
  const onScrubMove = (e: React.PointerEvent<HTMLDivElement>) => {
    if (!duration) return;
    const r = scrubRatio(e);
    if (drag !== null) {
      setDrag(r);
      seekTo(r);
    }
    setHover({ pct: r * 100, time: r * duration });
  };
  const onScrubUp = (e: React.PointerEvent<HTMLDivElement>) => {
    if (drag !== null) {
      seekTo(scrubRatio(e));
      setDrag(null);
    }
    try { e.currentTarget.releasePointerCapture(e.pointerId); } catch { /* never captured */ }
  };

  const cursorPct =
    drag !== null
      ? drag * 100
      : duration > 0 ? Math.min(100, Math.max(0, (time / duration) * 100)) : 0;

  // Playable = a finished recording that has audio ON DISK. We gate on
  // `has_audio` (server checks the mix / mic / archived file exists), NOT on
  // `duration_ms > 0`: an orphaned or crash-rescued row can carry a 0/nil
  // duration yet still have a perfectly playable file, and the old
  // duration-based gate greyed the Play button out on real recordings (a
  // tester hit exactly this on an in-person phone-call capture). Fall back to
  // the duration check only for older backends that don't send `has_audio`.
  const playable =
    detail.status !== "recording" &&
    (detail.has_audio ?? ((detail.duration_ms ?? 0) > 0));

  // Bust a stale early preload. If the meeting was OPEN while it was still
  // recording / transcribing (the common case — you watch it transcribe), this
  // <audio> already fetched `/audio` before the playback mix existed (a 404, or
  // a half-built on-demand mix) and stuck there. Its src is otherwise CONSTANT
  // across the meeting's whole life (keyed only on the id, which never changes),
  // so it never re-fetches once the finished file lands and play stays silent.
  // Tying the src to `has_audio` flips it the instant the mix becomes available,
  // which reloads the element onto the real, complete file. The share page
  // passes its own signed `audioUrl` (never mid-processing), so it's untouched.
  const resolvedSrc = audioUrl ?? (audioSrc(detail.id) + (detail.has_audio ? "?ready=1" : ""));

  return (
    <>
      <div className="audio-controls">
        <button
          className="audio-btn audio-btn-primary"
          onClick={togglePlay}
          disabled={!playable}
        >
          {playing ? <PauseSmall /> : <PlaySmall />}
        </button>
        <div className="audio-time">
          {fmtTime(time)} / {fmtTime(duration)}
        </div>
        <div
          className={"audio-scrub" + (drag !== null ? " dragging" : "")}
          onPointerDown={onScrubDown}
          onPointerMove={onScrubMove}
          onPointerUp={onScrubUp}
          onPointerLeave={() => { if (drag === null) setHover(null); }}
        >
          <div className="audio-scrub-fill" style={{ width: `${cursorPct}%` }} />
          <div className="audio-scrub-thumb" style={{ left: `${cursorPct}%` }} />
          {hover && (
            <div className="audio-scrub-tooltip" style={{ left: `${hover.pct}%` }}>
              {fmtTime(hover.time)}
            </div>
          )}
        </div>
        {/* Share = one link carrying the whole meeting (transcript + audio +
            summary). Scissors turns on clip mode: you then pick the range by
            clicking lines in the transcript. Both hidden on the read-only
            share page (a viewer can't re-share or clip someone else's call). */}
        {onShare && (
          <button
            className="toolbar-icon-btn audio-share-btn"
            onClick={onShare}
            title={t.share_btn_title ?? "Share a link"}
            aria-label={t.share_btn_title ?? "Share a link"}
          >
            <Share2 size={16} strokeWidth={2} />
          </button>
        )}
        {onClip && (
          <button
            className={"toolbar-icon-btn audio-clip-btn" + (clipActive ? " active" : "")}
            onClick={onClip}
            title={clipActive ? (t.clip_exit ?? "Cancel clip") : (t.clip_enter ?? "Share a clip")}
            aria-label={clipActive ? (t.clip_exit ?? "Cancel clip") : (t.clip_enter ?? "Share a clip")}
          >
            <Scissors size={16} strokeWidth={2} />
          </button>
        )}
      </div>
      <audio
        ref={audioRef}
        src={resolvedSrc}
        preload="auto"
        style={{ display: "none" }}
        onPlay={() => setPlaying(true)}
        onPause={() => setPlaying(false)}
        onEnded={() => setPlaying(false)}
        onLoadedMetadata={(e) => {
          const d = (e.target as HTMLAudioElement).duration;
          if (isFinite(d) && d > 0) setDuration(d);
        }}
        onTimeUpdate={(e) => {
          const t = (e.target as HTMLAudioElement).currentTime;
          setTime(t);
          onTimeUpdate(t);
        }}
      />
    </>
  );
}

function PlaySmall() {
  return (
    <svg viewBox="0 0 16 16" width="14" height="14" fill="currentColor" aria-hidden>
      <path d="M4 2.5v11c0 .6.7 1 1.2.6l8.4-5.5a.7.7 0 0 0 0-1.2L5.2 1.9C4.7 1.5 4 1.9 4 2.5z" />
    </svg>
  );
}
function PauseSmall() {
  return (
    <svg viewBox="0 0 16 16" width="14" height="14" fill="currentColor" aria-hidden>
      <rect x="4" y="2.5" width="3" height="11" rx="0.6" />
      <rect x="9" y="2.5" width="3" height="11" rx="0.6" />
    </svg>
  );
}

function fmtTime(sec: number): string {
  if (!isFinite(sec) || sec < 0) sec = 0;
  const total = Math.floor(sec);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return h > 0
    ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
    : `${m}:${String(s).padStart(2, "0")}`;
}
