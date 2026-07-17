import React from "react";
import type { MeetingDetail } from "../api";
import { displaySpeakerName } from "../format";

/// The player, and the whole point of the window.
///
/// Granola's public page has no audio and no transcript at all; Loom's has a
/// video and a plain timestamped list. Neither shows what a Corder recording
/// actually knows: WHO spoke WHEN. So the scrubber here isn't a line — it's the
/// conversation itself, one lane per speaker, and every lane is seekable. That
/// is the one thing on this page neither of them can copy.
///
/// An earlier attempt drew these lanes 4px tall inside the existing scrub bar
/// and it read as static: 60+ short turns became noise. The fix wasn't to drop
/// them, it was to make them the primary object — at 22px a lane reads as a
/// map of the conversation.
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
  const [hover, setHover] = React.useState<{ pct: number; time: number } | null>(null);

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

  const ratioFrom = (e: React.MouseEvent<HTMLElement>) => {
    const rect = e.currentTarget.getBoundingClientRect();
    return Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
  };

  const pct = duration > 0 ? Math.min(100, Math.max(0, (currentTimeSec / duration) * 100)) : 0;

  const lanes = React.useMemo(() => {
    const totalMs = (duration || 1) * 1000;
    // The hero window's speaker palette, in its order.
    const palette = ["var(--hl-speaker-purple)", "var(--hl-accent)", "var(--hl-speaker-self)", "var(--hl-avatar-admin)"];
    return detail.speakers.map((sp, i) => {
      const segs = detail.segments.filter((s) => s.speaker_id === sp.id);
      const spokenMs = segs.reduce((acc, s) => acc + (s.end_ms - s.start_ms), 0);
      const name = displaySpeakerName(sp.custom_name, sp.label, null);
      return {
        id: sp.id,
        name,
        initials: initialsOf(name),
        color: palette[i % palette.length],
        share: Math.round((spokenMs / totalMs) * 100),
        segs: segs.map((s) => ({
          left: (s.start_ms / totalMs) * 100,
          // A 300ms "yeah" is a hairline at this scale; floor it so short turns
          // stay visible instead of vanishing into the lane.
          width: Math.max(0.35, ((s.end_ms - s.start_ms) / totalMs) * 100),
        })),
      };
    });
  }, [detail.speakers, detail.segments, duration]);

  return (
    <div className="sp-player">
      <button
        type="button"
        className="sp-play"
        onClick={togglePlay}
        aria-label={playing ? "Pause" : "Play"}
        disabled={!audioUrl}
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

      <div className="sp-lanes-wrap">
        <div
          className="sp-lanes"
          onClick={(e) => { if (duration) onSeek(ratioFrom(e) * duration); }}
          onMouseMove={(e) => { if (duration) { const r = ratioFrom(e); setHover({ pct: r * 100, time: r * duration }); } }}
          onMouseLeave={() => setHover(null)}
        >
          {lanes.map((l) => (
            <div className="sp-lane" key={l.id}>
              <span className="sp-lane-badge" style={{ background: l.color }}>{l.initials}</span>
              <div className="sp-lane-track">
                {l.segs.map((s, i) => (
                  <span
                    key={i}
                    className="sp-lane-seg"
                    style={{ left: `${s.left}%`, width: `${s.width}%`, background: l.color }}
                  />
                ))}
              </div>
              <span className="sp-lane-share">{l.share}%</span>
            </div>
          ))}

          <span className="sp-playhead" style={{ left: `${pct}%` }} aria-hidden />
          {hover && <span className="sp-hover-line" style={{ left: `${hover.pct}%` }} aria-hidden />}
        </div>

        <div className="sp-times">
          <span>{fmt(currentTimeSec)}</span>
          {hover && <span className="sp-times-hover">{fmt(hover.time)}</span>}
          <span>{fmt(duration)}</span>
        </div>
      </div>

      {!!audioUrl && (
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
      )}
    </div>
  );
}

function initialsOf(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return "?";
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
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
