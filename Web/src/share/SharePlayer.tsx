import React from "react";

/// Player for the share page: one strip across the top of the window card.
///
/// The app's AudioCard is built for a 380px side rail and pairs with a separate
/// per-speaker timeline card. There is no rail here (in this category a rail
/// only earns its width when there's video in it — Loom), so the controls run
/// across the card instead.
///
/// The per-speaker timeline is deliberately absent. It was here, drawn as bands
/// inside the scrubber, and on a real 4-minute meeting with 60+ short turns it
/// rendered as noise rather than information. Neither Loom nor Granola shows
/// anything like it on a public page, and the speaker count in the hero carries
/// the same fact without the visual static.
///
/// Not a copy of AudioCard: no `has_audio` gate (the page only mounts this when
/// the share HAS audio) and no Share/clip actions. The <audio> element is the
/// master clock, exactly as in the app.
export function SharePlayer({
  audioRef, audioUrl, durationMs, currentTimeSec, onTimeUpdate, onSeek,
}: {
  audioRef: React.RefObject<HTMLAudioElement>;
  audioUrl: string;
  durationMs: number;
  currentTimeSec: number;
  onTimeUpdate: (sec: number) => void;
  onSeek: (sec: number) => void;
}) {
  const [playing, setPlaying] = React.useState(false);
  const [duration, setDuration] = React.useState(durationMs / 1000);
  const [hover, setHover] = React.useState<{ pct: number; time: number } | null>(null);

  const togglePlay = () => {
    const a = audioRef.current;
    if (!a) return;
    if (a.paused) {
      // Recover a stuck element: if the src was fetched before the object was
      // ready the element sticks in an error state and play() stays silent.
      if (a.error || a.readyState === 0) { try { a.load(); } catch { /* ignore */ } }
      a.play().catch(() => {});
    } else {
      a.pause();
    }
  };

  const ratioFrom = (e: React.MouseEvent<HTMLDivElement>) => {
    const rect = e.currentTarget.getBoundingClientRect();
    return Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
  };

  const pct = duration > 0 ? Math.min(100, Math.max(0, (currentTimeSec / duration) * 100)) : 0;

  return (
    <div className="sp-player">
      <button
        type="button"
        className="sp-play"
        onClick={togglePlay}
        aria-label={playing ? "Pause" : "Play"}
      >
        {playing ? <PauseGlyph /> : <PlayGlyph />}
      </button>

      <div className="sp-time">{fmt(currentTimeSec)} / {fmt(duration)}</div>

      <div className="sp-track-wrap">
        <div
          className="sp-track"
          onClick={(e) => { if (duration) onSeek(ratioFrom(e) * duration); }}
          onMouseMove={(e) => { if (duration) { const r = ratioFrom(e); setHover({ pct: r * 100, time: r * duration }); } }}
          onMouseLeave={() => setHover(null)}
        >
          <div className="sp-track-fill" style={{ width: `${pct}%` }} />
          <div className="sp-track-head" style={{ left: `${pct}%` }} />
          {hover && (
            <div className="sp-track-tip" style={{ left: `${hover.pct}%` }}>{fmt(hover.time)}</div>
          )}
        </div>
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
    </div>
  );
}

function PlayGlyph() {
  return (
    <svg viewBox="0 0 16 16" width="13" height="13" fill="currentColor" aria-hidden>
      <path d="M4 2.5v11c0 .6.7 1 1.2.6l8.4-5.5a.7.7 0 0 0 0-1.2L5.2 1.9C4.7 1.5 4 1.9 4 2.5z" />
    </svg>
  );
}
function PauseGlyph() {
  return (
    <svg viewBox="0 0 16 16" width="13" height="13" fill="currentColor" aria-hidden>
      <rect x="4" y="2.5" width="3" height="11" rx="0.6" />
      <rect x="9" y="2.5" width="3" height="11" rx="0.6" />
    </svg>
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
