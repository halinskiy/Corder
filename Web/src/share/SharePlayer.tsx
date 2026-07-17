import React from "react";
import type { MeetingDetail } from "../api";
import { displaySpeakerName } from "../format";

/// The audio, pinned along the bottom of the page.
///
/// Three separate bodies, not one bar: a play circle in the bottom-left corner
/// (the landing's cookie-circle slot), the track spanning the middle, and the
/// download orb in the bottom-right. Play and download are the same 56px
/// circle, so the row reads as a pair of controls with the conversation
/// stretched between them — rather than a play button crammed inside a pill,
/// where its left inset could never match its top and bottom.
///
/// Fixed, not part of the sheet: the point is to play any moment of the meeting
/// while reading any part of it.
///
/// ONE track, sampled into ticks. Two earlier versions failed here: a lane per
/// speaker read as two rows of stripes, and one line of per-turn blocks read as
/// dirt — rounded rectangles at 60 different widths colliding into shapes that
/// were never in the data. A uniform tick grid fixes both: the rhythm comes
/// from the conversation, the geometry stays still.
///
/// Corder is the only one of these products that can draw this at all: Loom
/// ships a plain scrub bar, Granola has no audio on the web.
/// Tick count. 240 across a track that's ~1000px wide lands each tick at ~3px
/// plus a 1px gap — dense enough to read as texture, coarse enough that a
/// 4-minute meeting doesn't turn into noise.
const TICKS = 240;

export function SharePlayer({
  audioRef, audioUrl, durationMs, currentTimeSec, onTimeUpdate, onSeek, detail, readingMs,
}: {
  audioRef: React.RefObject<HTMLAudioElement>;
  audioUrl: string | null;
  durationMs: number;
  currentTimeSec: number;
  onTimeUpdate: (sec: number) => void;
  onSeek: (sec: number) => void;
  detail: MeetingDetail;
  /// Where the reader is, in meeting time. Drives the track while paused.
  readingMs: number;
}) {
  const [playing, setPlaying] = React.useState(false);
  const [duration, setDuration] = React.useState(durationMs / 1000);
  const [hover, setHover] = React.useState<{ pct: number; time: number; who: string | null } | null>(null);

  const togglePlay = () => {
    const a = audioRef.current;
    if (!a) return;
    if (a.paused) {
      if (a.error || a.readyState === 0) { try { a.load(); } catch { /* ignore */ } }
      a.play().catch(() => {});
    } else {
      a.pause();
    }
  };

  const speakerById = React.useMemo(() => {
    const palette = ["var(--sp-speaker-1)", "var(--sp-speaker-2)", "var(--sp-speaker-3)", "var(--sp-speaker-4)"];
    const m = new Map<string, { name: string; color: string }>();
    detail.speakers.forEach((s, i) =>
      m.set(s.id, { name: displaySpeakerName(s.custom_name, s.label, null), color: palette[i % palette.length] }));
    return m;
  }, [detail.speakers]);

  // The track is sampled, not drawn from the segments directly.
  //
  // Drawing one rounded block per turn is what made this dirty: 60+ turns at
  // wildly different widths, each with its own radius, overlapping into shapes
  // that aren't in the data. Instead the timeline is a fixed grid of ticks —
  // each tick asks "who was speaking at this instant?" and takes that colour.
  // Uniform width, uniform gap, no radius fighting a neighbour: the texture
  // comes from the conversation, not from the rendering.
  const ticks = React.useMemo(() => {
    const totalMs = (duration || 1) * 1000;
    const out: (string | null)[] = [];
    for (let i = 0; i < TICKS; i++) {
      // Sample mid-tick, so a tick represents its own slice rather than its
      // left edge.
      const ms = ((i + 0.5) / TICKS) * totalMs;
      const seg = detail.segments.find((x) => x.start_ms <= ms && x.end_ms >= ms);
      out.push(seg ? speakerById.get(seg.speaker_id)?.color ?? null : null);
    }
    return out;
  }, [detail.segments, duration, speakerById]);

  const pct = duration > 0 ? Math.min(100, Math.max(0, (currentTimeSec / duration) * 100)) : 0;

  // While nothing is playing the track follows the READER instead: scroll the
  // transcript and the marker walks the meeting with you, so the dock doubles
  // as a minimap. The moment audio starts, the audio wins — one marker, and it
  // always shows the thing that's actually moving.
  const readPct = duration > 0 ? Math.min(100, Math.max(0, (readingMs / 1000 / duration) * 100)) : 0;
  const headPct = playing ? pct : readPct;

  const readHover = (e: React.MouseEvent<HTMLElement>) => {
    if (!duration) return;
    const rect = e.currentTarget.getBoundingClientRect();
    const r = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
    const ms = r * duration * 1000;
    const seg = detail.segments.find((s) => s.start_ms <= ms && s.end_ms >= ms);
    setHover({
      pct: r * 100,
      time: r * duration,
      who: seg ? speakerById.get(seg.speaker_id)?.name ?? null : null,
    });
  };

  if (!audioUrl) return null;

  return (
    <>
      <button
        type="button"
        className="sp-play-orb"
        onClick={togglePlay}
        aria-label={playing ? "Pause" : "Play"}
      >
        {playing ? (
          <svg viewBox="0 0 16 16" fill="currentColor" aria-hidden>
            <rect x="4" y="2.5" width="3" height="11" rx="0.6" />
            <rect x="9" y="2.5" width="3" height="11" rx="0.6" />
          </svg>
        ) : (
          <svg viewBox="0 0 16 16" fill="currentColor" aria-hidden>
            <path d="M4 2.5v11c0 .6.7 1 1.2.6l8.4-5.5a.7.7 0 0 0 0-1.2L5.2 1.9C4.7 1.5 4 1.9 4 2.5z" />
          </svg>
        )}
      </button>

      <div className="sp-dock">
        <span className="sp-dock-time">{fmt(currentTimeSec)}</span>

        <div
          className="sp-dock-track"
          onClick={(e) => {
            if (!duration) return;
            const rect = e.currentTarget.getBoundingClientRect();
            onSeek(Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width)) * duration);
          }}
          onMouseMove={readHover}
          onMouseLeave={() => setHover(null)}
        >
          {ticks.map((color, i) => (
            <span
              key={i}
              className={"sp-tick" + (color ? "" : " is-quiet")}
              style={{
                background: color ?? undefined,
                // Ticks rise left to right as the dock settles, so the shape of
                // the conversation draws itself.
                animationDelay: `${380 + i * 3}ms`,
              }}
            />
          ))}
          <span className="sp-dock-played" style={{ width: `${pct}%` }} aria-hidden />
          <span
            className={"sp-dock-head" + (playing ? "" : " is-reading")}
            style={{ left: `${headPct}%` }}
            aria-hidden
          />
          {hover && (
            <span className="sp-dock-tip" style={{ left: `${hover.pct}%` }}>
              {hover.who && <b>{hover.who}</b>}
              {fmt(hover.time)}
            </span>
          )}
        </div>

        <span className="sp-dock-time sp-dock-time--end">{fmt(duration)}</span>
      </div>

      <audio
        ref={audioRef}
        src={audioUrl}
        preload="auto"
        style={{ display: "none" }}
        onPlay={() => setPlaying(true)}
        onPause={() => setPlaying(false)}
        onEnded={() => setPlaying(false)}
        onLoadedMetadata={(e) => {
          const d = (e.target as HTMLAudioElement).duration;
          if (isFinite(d) && d > 0) setDuration(d);
        }}
        onTimeUpdate={(e) => onTimeUpdate((e.target as HTMLAudioElement).currentTime)}
      />
    </>
  );
}

function fmt(sec: number): string {
  if (!isFinite(sec) || sec < 0) sec = 0;
  const total = Math.floor(sec);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return h > 0
    ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
    : `${m}:${String(s).padStart(2, "0")}`;
}
