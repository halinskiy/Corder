import React from "react";
import type { MeetingDetail } from "../api";
import { displaySpeakerName } from "../format";

/// Player + speaker timeline inside the hero window's right rail.
///
/// Classes are the landing's (`.hl-audio-*`, `.hl-timeline-*`), so the 36px
/// accent play button, the 6px scrub track, the 22px speaker bars and the
/// tabular-nums clock are the shipped ones. The landing's copy of this is a
/// mock — a CSS keyframe animates the fill from 18% to 86%. Here the same
/// markup is driven by a real <audio>, which is the master clock.
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

  const pct = duration > 0 ? Math.min(100, Math.max(0, (currentTimeSec / duration) * 100)) : 0;

  // Per-speaker bars, same shape as the hero's timeline: absolute segments
  // positioned by time, plus a playhead. Real segment data, not a mock.
  const rows = React.useMemo(() => {
    const totalMs = (duration || 1) * 1000;
    const palette = ["var(--hl-speaker-purple)", "var(--hl-accent)", "var(--hl-speaker-self)", "var(--hl-avatar-admin)"];
    return detail.speakers.map((sp, i) => {
      const segs = detail.segments.filter((s) => s.speaker_id === sp.id);
      const spokenMs = segs.reduce((acc, s) => acc + (s.end_ms - s.start_ms), 0);
      return {
        id: sp.id,
        name: displaySpeakerName(sp.custom_name, sp.label, null),
        color: palette[i % palette.length],
        share: Math.round((spokenMs / totalMs) * 100),
        spoken: fmt(spokenMs / 1000),
        segs: segs.map((s) => ({
          left: (s.start_ms / totalMs) * 100,
          width: Math.max(0.5, ((s.end_ms - s.start_ms) / totalMs) * 100),
        })),
      };
    });
  }, [detail.speakers, detail.segments, duration]);

  return (
    <>
      {!!audioUrl && (
        <div className="hl-audio-controls">
          <button
            type="button"
            className="hl-audio-btn-primary"
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

          <span className="hl-audio-time">{fmt(currentTimeSec)} / {fmt(duration)}</span>

          <div
            className="hl-audio-scrub sp-scrub"
            onClick={(e) => {
              if (!duration) return;
              const rect = e.currentTarget.getBoundingClientRect();
              const r = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
              onSeek(r * duration);
            }}
          >
            <span className="hl-audio-scrub-fill sp-scrub-fill" style={{ width: `${pct}%` }} />
          </div>
        </div>
      )}

      {rows.length > 0 && (
        <div className="hl-timeline-card">
          <div className="hl-timeline-section-label">Timeline</div>
          <div className="hl-tl-bars">
            {rows.map((r) => (
              <div className="hl-tl-row" key={r.id}>
                <div className="hl-tl-row-head">
                  <span className="hl-tl-name">{r.name}</span>
                  <span className="hl-tl-stats">{r.share}% · {r.spoken}</span>
                </div>
                <div className="hl-tl-bar">
                  {r.segs.map((s, i) => (
                    <span
                      key={i}
                      className="hl-tl-bar-seg"
                      style={{ left: `${s.left}%`, width: `${s.width}%`, background: r.color }}
                    />
                  ))}
                  <span className="hl-tl-bar-cursor sp-cursor" style={{ left: `${pct}%` }} />
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

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
