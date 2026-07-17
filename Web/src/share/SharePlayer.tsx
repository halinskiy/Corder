import React from "react";
import type { MeetingDetail } from "../api";
import { displaySpeakerName } from "../format";

/// The audio, pinned to the bottom-left and running the width of the page.
///
/// Fixed, not part of the sheet: the point is to play any moment of the meeting
/// while reading any part of it. It mirrors the landing's bottom-left cookie
/// circle in position and padding (left 32, bottom 32), and stops short of the
/// download orb, which owns the bottom-right.
///
/// ONE track, not one lane per speaker. The two-lane version was honest but
/// busy — two rows of blocks reading as stripes. Here every turn is drawn on a
/// single line in its speaker's colour, so the shape of the conversation is one
/// object: who held the floor, when it went back and forth, where the silences
/// are. Corder is the only one of these products that can draw that at all;
/// Loom shows a plain scrub bar and Granola has no audio on the web.
export function SharePlayer({
  audioRef, audioUrl, durationMs, currentTimeSec, onTimeUpdate, onSeek, detail,
}: {
  audioRef: React.RefObject<HTMLAudioElement>;
  audioUrl: string | null;
  durationMs: number;
  currentTimeSec: number;
  onTimeUpdate: (sec: number) => void;
  onSeek: (sec: number) => void;
  detail: MeetingDetail;
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

  // Every turn on one line, positioned by time, coloured by speaker.
  const marks = React.useMemo(() => {
    const totalMs = (duration || 1) * 1000;
    return detail.segments.map((s) => ({
      id: s.id,
      left: (s.start_ms / totalMs) * 100,
      // A 300ms "yeah" is sub-pixel at this scale; floor it so short turns stay
      // visible instead of dropping out of the picture.
      width: Math.max(0.25, ((s.end_ms - s.start_ms) / totalMs) * 100),
      color: speakerById.get(s.speaker_id)?.color,
    }));
  }, [detail.segments, duration, speakerById]);

  const pct = duration > 0 ? Math.min(100, Math.max(0, (currentTimeSec / duration) * 100)) : 0;

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
    <div className="sp-dock">
      <button
        type="button"
        className="sp-dock-play"
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
        {marks.map((m, i) => (
          <span
            key={m.id}
            className="sp-dock-mark"
            style={{
              left: `${m.left}%`,
              width: `${m.width}%`,
              background: m.color,
              // Turns draw in left to right as the page settles.
              animationDelay: `${420 + Math.min(i, 40) * 12}ms`,
            }}
          />
        ))}
        <span className="sp-dock-played" style={{ width: `${pct}%` }} aria-hidden />
        <span className="sp-dock-head" style={{ left: `${pct}%` }} aria-hidden />
        {hover && (
          <span className="sp-dock-tip" style={{ left: `${hover.pct}%` }}>
            {hover.who && <b>{hover.who}</b>}
            {fmt(hover.time)}
          </span>
        )}
      </div>

      <span className="sp-dock-time sp-dock-time--end">{fmt(duration)}</span>

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
    </div>
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
