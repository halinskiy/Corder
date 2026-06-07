import React from "react";
import { createPortal } from "react-dom";
import { Download, Maximize2, X } from "lucide-react";
import {
  MeetingDetail, audioSrc, videoSrc,
  transcriptSrc, transcriptMdSrc, transcriptJsonSrc, bundleSrc,
} from "../api";
import { formatDuration } from "../format";
import type { Lang, T } from "../i18n";
import { Tooltip } from "./Tooltip";
import { SettingsSelect, type SettingsSelectOption } from "./SettingsSelect";
import { displaySpeakerName } from "../format";
import { getSettings } from "../api";

interface Props {
  detail: MeetingDetail;
  videoRef: React.RefObject<HTMLVideoElement>;
  onTimeUpdate: (sec: number) => void;
  currentTimeSec: number;
  onSeek: (sec: number) => void;
  /// Download mode is a sibling of "Recording" inside this column —
  /// state lives in the parent so the tab strip's `← Download`
  /// back-chip can drive it without a ref-chain.
  downloadOpen: boolean;
  onDownloadChange: (open: boolean) => void;
  t: T;
  lang?: Lang;
}

export function RightPanel({ detail, videoRef, onTimeUpdate, currentTimeSec, onSeek, downloadOpen, onDownloadChange, t, lang = "ru" }: Props) {
  const audioRef = videoRef as unknown as React.RefObject<HTMLAudioElement>;
  const screenVideoRef = React.useRef<HTMLVideoElement | null>(null);
  return (
    <div className="right-panel">
      {/* Download is its own view, not an overlay: when it's open the
          screen-video preview and the speaker Timeline are hidden so
          the panel reads as a dedicated "Download" tab — only the
          audio scrubber (which carries the toggle back) stays mounted
          so playback never stops. */}
      {detail.has_video && !downloadOpen && (
        <ScreenVideo
          detail={detail}
          videoRef={screenVideoRef}
          audioRef={audioRef}
          currentTimeSec={currentTimeSec}
        />
      )}
      <AudioCard
        detail={detail}
        audioRef={audioRef}
        onTimeUpdate={onTimeUpdate}
        downloadOpen={downloadOpen}
        onToggleDownload={() => onDownloadChange(!downloadOpen)}
        t={t}
      />
      {downloadOpen
        ? <DownloadView detail={detail} t={t} />
        : <SpeakerTimeline detail={detail} currentTimeSec={currentTimeSec} onSeek={onSeek} t={t} lang={lang} />}
    </div>
  );
}

/// Inline download chooser: replaces the Recording-tab content in
/// place. Same `.clarify-btn` outline-card vocabulary as the rest of
/// the design system, no icons (consistency with the other inline
/// banners). The audio element lives a sibling level up and stays
/// mounted while this view is on screen, so playback continues.
/// Solid Download glyph for the active-state Download button on the
/// audio scrubber — same Heroicons Solid path used by SettingsFilled /
/// ArchiveFilled in MainHeader. Inline so we don't pull a fresh
/// dependency for a single icon.
function DownloadFilled({ size = 16 }: { size?: number }) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="currentColor"
      aria-hidden
    >
      <path fillRule="evenodd" clipRule="evenodd" d="M12 2.25a.75.75 0 0 1 .75.75v11.69l3.22-3.22a.75.75 0 1 1 1.06 1.06l-4.5 4.5a.75.75 0 0 1-1.06 0l-4.5-4.5a.75.75 0 1 1 1.06-1.06l3.22 3.22V3a.75.75 0 0 1 .75-.75Zm-9 13.5a.75.75 0 0 1 .75.75v2.25a1.5 1.5 0 0 0 1.5 1.5h13.5a1.5 1.5 0 0 0 1.5-1.5V16.5a.75.75 0 0 1 1.5 0v2.25a3 3 0 0 1-3 3H5.25a3 3 0 0 1-3-3V16.5a.75.75 0 0 1 .75-.75Z" />
    </svg>
  );
}

function DownloadView({
  detail, t,
}: {
  detail: MeetingDetail;
  t: T;
}) {
  type Row = { value: string; label: string; href: string; file: string; show: boolean };
  const rows: Row[] = [
    { value: "video",      label: t.download_video,      href: videoSrc(detail.id),         file: `corder-${detail.id}.mov`,  show: !!detail.has_video },
    { value: "audio",      label: t.download_audio,      href: audioSrc(detail.id),         file: `corder-${detail.id}.wav`,  show: true },
    { value: "transcript", label: t.download_transcript, href: transcriptSrc(detail.id),    file: `corder-${detail.id}.txt`,  show: detail.segments.length > 0 },
    { value: "markdown",   label: t.download_markdown,   href: transcriptMdSrc(detail.id),  file: `corder-${detail.id}.md`,   show: detail.segments.length > 0 },
    { value: "json",       label: t.download_json,       href: transcriptJsonSrc(detail.id),file: `corder-${detail.id}.json`, show: detail.segments.length > 0 },
    { value: "bundle",     label: t.download_all,        href: bundleSrc(detail.id),        file: `corder-${detail.id}.zip`,  show: true },
  ];
  const visible = rows.filter((r) => r.show);
  const [picked, setPicked] = React.useState<string>(visible[0]?.value ?? "audio");
  const active = visible.find((r) => r.value === picked) ?? visible[0];
  const options: SettingsSelectOption<string>[] = visible.map((r) => ({
    value: r.value,
    label: r.label,
  }));
  return (
    <div className="inline-view download-view">
      <div className="hk-block mic-block download-block" aria-label={t.download_title}>
        <div className="settings-row-label">{t.download_title}</div>
        <div className="settings-row-desc">
          {t.download_format_desc ?? "Pick which file to save."}
        </div>
        <SettingsSelect
          value={picked}
          options={options}
          onChange={setPicked}
          ariaLabel={t.download_title}
        />
        <button
          type="button"
          className="clarify-btn accent bigbtn-full download-cta"
          onClick={() => {
            if (!active?.href) return;
            // `<a href download>` in WKWebView silently no-ops on
            // some macOS versions — the `download` attribute isn't
            // honoured. Forcing a navigation to the same-origin file
            // endpoint is the path that DOES reliably trip
            // `WebDownloadDelegate.decidePolicyFor → .download` and
            // opens the native Save panel.
            window.location.assign(active.href);
          }}
          disabled={!active}
        >
          {t.download_title}
        </button>
      </div>
    </div>
  );
}

/// Silent screen-capture preview that sits above the audio controls.
/// The audio element is the master clock: its play / pause / seek
/// events drive the video, never the other way around. We mute the
/// video so the muxed-in track (which is empty in our writer config,
/// but defensive belt-and-braces) can't double up with mix.wav.
function ScreenVideo({
  detail, videoRef, audioRef, currentTimeSec,
}: {
  detail: MeetingDetail;
  videoRef: React.MutableRefObject<HTMLVideoElement | null>;
  audioRef: React.RefObject<HTMLAudioElement>;
  currentTimeSec: number;
}) {
  // `has_video` is set on the backend by checking the file path + the
  // Dropbox archive flag, but the actual fetch can still 404 — the
  // Dropbox copy may have been pruned, the meeting may pre-date the
  // video-recording feature, etc. We hide the whole card the moment
  // the <video> element fires its `error` event so empty black boxes
  // never show up in the layout.
  const [failed, setFailed] = React.useState(false);
  // False until the <video> has a paintable frame. Drives a ghost
  // shimmer where the video will be, so switching back to the
  // Recording tab never shows an empty hole during decode.
  const [loaded, setLoaded] = React.useState(false);
  // In-memory poster cache: first painted frame of each meeting,
  // captured into a <canvas> data-URL after first load. Subsequent
  // mounts of the same meeting paint the poster instantly while the
  // <video> element re-decodes, killing the grey-flash on tab switch.
  // Window-scope so it survives component remounts within one session.
  const cachedPoster = React.useMemo(() => {
    const w = window as unknown as { corderPosterCache?: Map<string, string> };
    if (!w.corderPosterCache) w.corderPosterCache = new Map();
    return w.corderPosterCache.get(detail.id) ?? null;
  }, [detail.id]);
  // Tracks whether the audio (master clock) is currently playing.
  // Drives the Apple-style centred play overlay: visible while paused,
  // hidden during playback so the video is unobstructed.
  const [paused, setPaused] = React.useState(true);
  React.useEffect(() => { setFailed(false); setLoaded(false); }, [detail.id]);

  React.useEffect(() => {
    const a = audioRef.current;
    if (!a) return;
    setPaused(a.paused);
    const onPlay = () => setPaused(false);
    const onPause = () => setPaused(true);
    a.addEventListener("play", onPlay);
    a.addEventListener("pause", onPause);
    a.addEventListener("ended", onPause);
    return () => {
      a.removeEventListener("play", onPlay);
      a.removeEventListener("pause", onPause);
      a.removeEventListener("ended", onPause);
    };
  }, [audioRef]);
  // Pull the video clock toward the audio clock whenever they drift
  // by more than ~0.3 s. Setting currentTime on every audio
  // timeupdate (4-5 Hz) would cause stutter from the keyframe seeks.
  React.useEffect(() => {
    const v = videoRef.current;
    if (!v) return;
    if (Math.abs(v.currentTime - currentTimeSec) > 0.3) {
      v.currentTime = currentTimeSec;
    }
  }, [currentTimeSec, videoRef]);

  // Mirror play / pause from audio onto video. The two media
  // elements end up moving together; only the audio one is "real"
  // for transport purposes.
  React.useEffect(() => {
    const a = audioRef.current;
    const v = videoRef.current;
    if (!a || !v) return;
    const onPlay = () => { v.play().catch(() => {}); };
    const onPause = () => { v.pause(); };
    a.addEventListener("play", onPlay);
    a.addEventListener("pause", onPause);
    a.addEventListener("seeking", onPause);
    return () => {
      a.removeEventListener("play", onPlay);
      a.removeEventListener("pause", onPause);
      a.removeEventListener("seeking", onPause);
    };
  }, [audioRef, videoRef]);

  // Fullscreen lightbox, Telegram-style: the video physically GROWS
  // out of the inline card's rect to fill the screen and shrinks back
  // into it on close (a FLIP transform), with a dark backdrop fading
  // alongside. Not OS fullscreen.
  const [expanded, setExpanded] = React.useState(false);
  const [backdropShown, setBackdropShown] = React.useState(false);
  const fsVideoRef = React.useRef<HTMLVideoElement | null>(null);
  const cardRef = React.useRef<HTMLDivElement | null>(null);
  const fsInnerRef = React.useRef<HTMLDivElement | null>(null);
  const originRect = React.useRef<DOMRect | null>(null);
  const closeTimer = React.useRef<number | null>(null);
  const FS_MS = 320;

  // Map the lightbox inner box back onto a target rect (the card) as a
  // translate+scale transform. Used both for the open (start state) and
  // close (end state) of the FLIP.
  const transformToRect = (inner: HTMLElement, rect: DOMRect): string => {
    const end = inner.getBoundingClientRect();
    if (end.width === 0 || end.height === 0) return "none";
    const sx = rect.width / end.width;
    const sy = rect.height / end.height;
    const tx = (rect.left + rect.width / 2) - (end.left + end.width / 2);
    const ty = (rect.top + rect.height / 2) - (end.top + end.height / 2);
    return `translate(${tx}px, ${ty}px) scale(${sx}, ${sy})`;
  };

  const openFullscreen = React.useCallback(() => {
    if (closeTimer.current !== null) {
      window.clearTimeout(closeTimer.current);
      closeTimer.current = null;
    }
    // Snapshot where the card is right now — the FLIP grows from here.
    originRect.current = cardRef.current?.getBoundingClientRect() ?? null;
    // Native inline blob is stacked above the web layer; hide it so it
    // doesn't punch through the dimmed overlay.
    (window as any).corderSetBlobVisible?.(false);
    setExpanded(true);
    // Opening the viewer starts playback — the video mirrors the audio
    // master clock, so without this the fullscreen just shows a frozen
    // frame ("нажимаю на видео но оно не воспроизводится").
    audioRef.current?.play().catch(() => {});
  }, [audioRef]);

  const closeFullscreen = React.useCallback(() => {
    // Pause on exit: leaving the fullscreen view should stop playback,
    // not keep it running invisibly in the collapsed card. The audio is
    // the master clock, so pausing it stops the mirrored <video> too.
    audioRef.current?.pause();
    const inner = fsInnerRef.current;
    const rect = cardRef.current?.getBoundingClientRect() ?? originRect.current;
    if (inner && rect) {
      inner.style.transition = `transform ${FS_MS}ms cubic-bezier(0.22, 1, 0.36, 1)`;
      inner.style.transform = transformToRect(inner, rect);
    }
    setBackdropShown(false);
    closeTimer.current = window.setTimeout(() => {
      setExpanded(false);
      (window as any).corderSetBlobVisible?.(true);
      closeTimer.current = null;
    }, FS_MS);
  }, [audioRef]);

  // Play/pause the audio master clock (the muted <video>s mirror it).
  // Bound to Space and to a click on the video itself; the dark margin
  // and the × button close instead.
  const togglePlay = React.useCallback(() => {
    const a = audioRef.current;
    if (!a) return;
    if (a.paused) a.play().catch(() => {}); else a.pause();
  }, [audioRef]);

  // FLIP open: once the overlay is mounted, place the inner box at the
  // card's rect (inverse transform, no transition), force a reflow,
  // then release to identity so it animates outward.
  React.useLayoutEffect(() => {
    if (!expanded) return;
    const inner = fsInnerRef.current;
    const rect = originRect.current;
    if (!inner) return;
    if (rect) {
      inner.style.transition = "none";
      inner.style.transform = transformToRect(inner, rect);
      // Force reflow so the start transform is committed before we
      // animate to identity.
      void inner.getBoundingClientRect();
    }
    requestAnimationFrame(() => {
      inner.style.transition = `transform ${FS_MS}ms cubic-bezier(0.22, 1, 0.36, 1)`;
      inner.style.transform = "none";
      setBackdropShown(true);
    });
  }, [expanded]);

  // Esc closes the lightbox; Space toggles play/pause (preventDefault
  // so the page doesn't also scroll).
  React.useEffect(() => {
    if (!expanded) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") closeFullscreen();
      else if (e.key === " " || e.code === "Space") { e.preventDefault(); togglePlay(); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [expanded, closeFullscreen, togglePlay]);

  // Keep the fullscreen <video> glued to the audio master clock for as
  // long as the lightbox is open — mirror play/pause/seek and seed its
  // position when it mounts. Same contract as the inline preview.
  React.useEffect(() => {
    if (!expanded) return;
    const a = audioRef.current;
    const v = fsVideoRef.current;
    if (!a || !v) return;
    try { v.currentTime = a.currentTime; } catch {}
    if (!a.paused) v.play().catch(() => {});
    const onPlay = () => { v.play().catch(() => {}); };
    const onPause = () => { v.pause(); };
    const onSeeking = () => { try { v.currentTime = a.currentTime; } catch {} };
    a.addEventListener("play", onPlay);
    a.addEventListener("pause", onPause);
    a.addEventListener("seeking", onSeeking);
    return () => {
      a.removeEventListener("play", onPlay);
      a.removeEventListener("pause", onPause);
      a.removeEventListener("seeking", onSeeking);
    };
  }, [expanded, audioRef]);

  React.useEffect(() => {
    if (!expanded) return;
    const v = fsVideoRef.current;
    if (!v) return;
    if (Math.abs(v.currentTime - currentTimeSec) > 0.3) {
      v.currentTime = currentTimeSec;
    }
  }, [expanded, currentTimeSec]);

  // Transient play/pause badge in fullscreen: pop the current state
  // icon for ~1.1s on open and on every toggle, then fade it out — so
  // the user always gets a moment of "you're paused / playing" feedback
  // even though the controls are otherwise hidden.
  const [fsHint, setFsHint] = React.useState<"play" | "pause" | null>(null);
  React.useEffect(() => {
    if (!expanded) return;
    setFsHint(paused ? "pause" : "play");
    const id = window.setTimeout(() => setFsHint(null), 1100);
    return () => window.clearTimeout(id);
  }, [expanded, paused]);

  if (failed) return null;

  // A click on the inline video goes straight to fullscreen; a click on
  // the fullscreen video closes it, exactly like clicking the dark
  // margin. No play/pause-on-video and no debounce — transport is the
  // audio card's job; the video is a viewer you pop open and dismiss.

  // Force a single frame to decode and paint the moment metadata is
  // ready, so the card shows an actual preview of what was on screen
  // instead of a blank surface. We seek 0.1 s in rather than 0 because
  // screen recordings often start on a dark fade-in frame, and 0.1 s
  // lands inside the first decoded GOP without conflicting with the
  // audio-driven time-sync (threshold is 0.3 s, our seek is below
  // that, so the sync effect won't rubber-band it back to 0).
  const onLoadedMetadata = () => {
    const v = videoRef.current;
    if (!v) return;
    if (v.currentTime < 0.01) {
      try { v.currentTime = 0.1; } catch {}
    }
  };

  return (
    <>
      <div
        ref={cardRef}
        className={"screen-video-card" + (paused ? " paused" : "")}
        onClick={openFullscreen}
      >
        <video
          ref={videoRef}
          src={videoSrc(detail.id)}
          muted
          playsInline
          preload="metadata"
          className="screen-video"
          onLoadedMetadata={onLoadedMetadata}
          onLoadedData={(e) => {
            setLoaded(true);
            // Snapshot first frame into the session poster cache so
            // the next time the user opens this meeting we paint a
            // real preview instead of the grey ghost while the
            // <video> element re-decodes.
            try {
              const v = e.currentTarget as HTMLVideoElement;
              const w = window as unknown as { corderPosterCache?: Map<string, string> };
              if (!w.corderPosterCache) w.corderPosterCache = new Map();
              if (!w.corderPosterCache.has(detail.id) && v.videoWidth > 0) {
                const c = document.createElement("canvas");
                // Half-resolution is plenty for the card-size preview
                // and keeps the data URL tiny (~30-60 kB per meeting).
                c.width = Math.max(1, Math.round(v.videoWidth / 2));
                c.height = Math.max(1, Math.round(v.videoHeight / 2));
                const ctx = c.getContext("2d");
                if (ctx) {
                  ctx.drawImage(v, 0, 0, c.width, c.height);
                  w.corderPosterCache.set(detail.id, c.toDataURL("image/jpeg", 0.7));
                }
              }
            } catch {}
          }}
          onError={() => setFailed(true)}
        />
        {/* Poster overlay: instant preview from cache while <video>
            re-decodes on meeting switch. Hidden the moment loaded
            flips, so it never sticks around past the real frame. */}
        {!loaded && !failed && cachedPoster && (
          <img
            src={cachedPoster}
            className="screen-video-poster"
            alt=""
            aria-hidden
            draggable={false}
          />
        )}
        {!loaded && !failed && !cachedPoster && <div className="screen-video-ghost" aria-hidden />}
        {/* No more paused scrim — the frosted play puck reads clearly
            on its own, and the white veil broke the theme cross-fade
            (it lived in front of the <video>, so during the wipe the
            play button's backdrop-filter sampled the disappearing
            scrim and snapped back in). */}
        {paused && (
          <div className="screen-video-play" aria-hidden>
            <svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor" aria-hidden>
              <path d="M8 5.5v13c0 .8.9 1.3 1.6.9l10.2-6.5a1 1 0 0 0 0-1.8L9.6 4.6C8.9 4.2 8 4.7 8 5.5z" />
            </svg>
          </div>
        )}
        <Tooltip label="Fullscreen">
          <button
            type="button"
            className="screen-video-fs-btn"
            onClick={(e) => { e.stopPropagation(); openFullscreen(); }}
            aria-label="Fullscreen"
          >
            <Maximize2 size={15} strokeWidth={2.2} />
          </button>
        </Tooltip>
      </div>

      {expanded && createPortal(
        <div
          className={"video-fs-overlay" + (backdropShown ? " shown" : "")}
          onClick={closeFullscreen}
        >
          <Tooltip label="Close (Esc)">
            <button
              type="button"
              className="video-fs-close"
              onClick={(e) => { e.stopPropagation(); closeFullscreen(); }}
              aria-label="Close"
            >
              <X size={20} strokeWidth={2.2} />
            </button>
          </Tooltip>
          {/* FLIP target: this wrapper is what we translate+scale from
              the card's rect to its natural centred size and back. */}
          <div className="video-fs-inner" ref={fsInnerRef}>
            <video
              ref={fsVideoRef}
              src={videoSrc(detail.id)}
              muted
              playsInline
              preload="auto"
              className="video-fs-video"
              // Click on the video itself = play/pause. Closing is the
              // dark margin (overlay) or the × button. stopPropagation
              // so this click doesn't bubble to the overlay's close.
              onClick={(e) => { e.stopPropagation(); togglePlay(); }}
            />
            {fsHint && (
              <div className={"video-fs-hint " + fsHint} aria-hidden>
                {fsHint === "pause" ? (
                  <svg viewBox="0 0 24 24" width="34" height="34" fill="currentColor">
                    <rect x="6" y="5" width="4" height="14" rx="1" />
                    <rect x="14" y="5" width="4" height="14" rx="1" />
                  </svg>
                ) : (
                  <svg viewBox="0 0 24 24" width="34" height="34" fill="currentColor">
                    <path d="M8 5.5v13c0 .8.9 1.3 1.6.9l10.2-6.5a1 1 0 0 0 0-1.8L9.6 4.6C8.9 4.2 8 4.7 8 5.5z" />
                  </svg>
                )}
              </div>
            )}
          </div>
          {/* Scrubber is a SIBLING of `.video-fs-inner`, not its
              child — keeping it out of the FLIP box lets the inner
              morph onto the inline card without distortion, and
              anchoring to the overlay's bottom edge guarantees the
              bar is on-screen regardless of how the centred video
              + max-height-percentage cascade resolves (the previous
              `top: calc(100% + 14px)` of `.video-fs-inner` slid the
              bar off the bottom of the viewport on tall videos).
              Same opacity fade via `.video-fs-overlay.shown`. */}
          <FsScrubber
            detail={detail}
            currentTimeSec={currentTimeSec}
            audioRef={audioRef}
          />
        </div>,
        document.body
      )}
    </>
  );
}

/// Fullscreen seek bar. Lays every speech segment down as a block at
/// its position on the timeline, tinted with that speaker's colour, so
/// the bar doubles as a "who spoke when" map. Click or drag anywhere on
/// it to scrub — it drives the master clock (the hidden <audio>), which
/// the fullscreen video already follows via the drift sync.
function FsScrubber({
  detail, currentTimeSec, audioRef,
}: {
  detail: MeetingDetail;
  currentTimeSec: number;
  audioRef: React.RefObject<HTMLAudioElement>;
}) {
  // Base the bar on whichever is longer: the recorded duration or the
  // latest segment end. In-person ASR timestamps (VAD-projected) can
  // run slightly past duration_ms; without this a stray late segment
  // computed left/width > 100% and shot a solid block off the right
  // edge ("улетает куда-то вправо").
  const maxEnd = detail.segments.reduce((mx, s) => Math.max(mx, s.end_ms), 0);
  const totalMs = Math.max(detail.duration_ms || 0, maxEnd);

  const colorOf = React.useMemo(() => {
    const m = new Map<string, string>();
    for (const sp of detail.speakers) {
      const name = sp.custom_name?.trim() || sp.label;
      m.set(
        sp.id,
        sp.color_hex && /^#[0-9a-f]{6}$/i.test(sp.color_hex)
          ? sp.color_hex
          : colorForSpeaker(name)
      );
    }
    return m;
  }, [detail.speakers]);

  const barRef = React.useRef<HTMLDivElement | null>(null);
  const dragging = React.useRef(false);

  if (totalMs <= 0 || detail.segments.length === 0) return null;

  const seekTo = (clientX: number) => {
    const el = barRef.current;
    const a = audioRef.current;
    if (!el || !a) return;
    const r = el.getBoundingClientRect();
    const ratio = Math.max(0, Math.min(1, (clientX - r.left) / r.width));
    try { a.currentTime = ratio * (totalMs / 1000); } catch { /* not seekable yet */ }
  };
  const onDown = (e: React.PointerEvent<HTMLDivElement>) => {
    e.stopPropagation();
    dragging.current = true;
    try { e.currentTarget.setPointerCapture(e.pointerId); } catch { /* unsupported */ }
    seekTo(e.clientX);
  };
  const onMove = (e: React.PointerEvent<HTMLDivElement>) => {
    if (!dragging.current) return;
    e.stopPropagation();
    seekTo(e.clientX);
  };
  const onUp = (e: React.PointerEvent<HTMLDivElement>) => {
    dragging.current = false;
    try { e.currentTarget.releasePointerCapture(e.pointerId); } catch { /* noop */ }
  };

  const cursorPct = Math.min(100, Math.max(0, (currentTimeSec * 1000 / totalMs) * 100));

  return (
    <div
      className="video-fs-scrub"
      ref={barRef}
      onClick={(e) => e.stopPropagation()}
      onPointerDown={onDown}
      onPointerMove={onMove}
      onPointerUp={onUp}
      onPointerCancel={onUp}
    >
      <div className="video-fs-scrub-track" />
      {detail.segments.map((s, i) => {
        const left = Math.max(0, Math.min(100, (s.start_ms / totalMs) * 100));
        const raw = ((s.end_ms - s.start_ms) / totalMs) * 100;
        // Clamp so left + width never exceeds the track.
        const w = Math.max(0.25, Math.min(raw, 100 - left));
        return (
          <div
            key={i}
            className="video-fs-scrub-seg"
            style={{
              left: `${left}%`,
              width: `${w}%`,
              background: colorOf.get(s.speaker_id) || "#888",
            }}
          />
        );
      })}
      <div className="video-fs-scrub-cursor" style={{ left: `${cursorPct}%` }} />
    </div>
  );
}

/** Custom audio player shaped like the old video card: 16/10 box with a
 *  big centred play button, ±10s skip buttons in the bottom bar, current
 *  time / duration, and a clickable scrub line. The native <audio>
 *  element is kept hidden — we drive it through React state. */
function AudioCard({
  detail, audioRef, onTimeUpdate, downloadOpen, onToggleDownload, t,
}: {
  detail: MeetingDetail;
  audioRef: React.RefObject<HTMLAudioElement>;
  onTimeUpdate: (sec: number) => void;
  downloadOpen: boolean;
  onToggleDownload: () => void;
  t: T;
}) {
  const [playing, setPlaying] = React.useState(false);
  const [duration, setDuration] = React.useState((detail.duration_ms ?? 0) / 1000);
  const [time, setTime] = React.useState(0);

  const togglePlay = () => {
    const a = audioRef.current; if (!a) return;
    if (a.paused) a.play().catch(() => {});
    else a.pause();
  };
  const onScrubClick = (e: React.MouseEvent<HTMLDivElement>) => {
    const a = audioRef.current; if (!a || !duration) return;
    const rect = e.currentTarget.getBoundingClientRect();
    const ratio = (e.clientX - rect.left) / rect.width;
    a.currentTime = Math.max(0, Math.min(1, ratio)) * duration;
  };

  const [hover, setHover] = React.useState<{ pct: number; time: number } | null>(null);
  const onScrubMove = (e: React.MouseEvent<HTMLDivElement>) => {
    if (!duration) return;
    const rect = e.currentTarget.getBoundingClientRect();
    const ratio = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
    setHover({ pct: ratio * 100, time: ratio * duration });
  };

  const cursorPct = duration > 0 ? Math.min(100, Math.max(0, (time / duration) * 100)) : 0;

  // Empty / not-yet-finalised meetings have nothing to play — disable the
  // primary control instead of letting the user click into nothing.
  const playable =
    duration > 0 &&
    detail.status !== "recording" &&
    !!detail.duration_ms;

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
          className="audio-scrub"
          onClick={onScrubClick}
          onMouseMove={onScrubMove}
          onMouseLeave={() => setHover(null)}
        >
          <div className="audio-scrub-fill" style={{ width: `${cursorPct}%` }} />
          {hover && (
            <div className="audio-scrub-tooltip" style={{ left: `${hover.pct}%` }}>
              {fmtTime(hover.time)}
            </div>
          )}
        </div>
        <button
          className={"toolbar-icon-btn audio-download-btn" + (downloadOpen ? " active" : "")}
          onClick={onToggleDownload}
          title={t.download_title}
          aria-label={t.download_title}
          aria-pressed={downloadOpen}
        >
          {downloadOpen
            ? <DownloadFilled size={16} />
            : <Download size={16} strokeWidth={2} />}
        </button>
      </div>
      <audio
        ref={audioRef}
        src={audioSrc(detail.id)}
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

const PALETTE = [
  "#5a3aa6", // purple
  "#a51d4f", // crimson
  "#7a1f1f", // dark red
  "#1a4f8a", // blue
  "#1f7a4f", // green
  "#7a4f1a", // brown
];
function colorForSpeaker(name: string): string {
  let h = 0;
  for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) >>> 0;
  return PALETTE[h % PALETTE.length];
}

/// Speech segments → positioned bars (% of timeline). Consecutive
/// segments separated by less than MERGE_MS are coalesced into one
/// block: ASR splits continuous speech into many sub-segments with
/// near-zero gaps, and rendering each as its own rounded pill produced
/// ugly seams between touching pills. A real conversational pause
/// (> MERGE_MS) still breaks the bar, so the granular rhythm of a long
/// session is preserved. `end_ms` can run slightly past `totalMs`, so
/// width is clamped so a near-end block never bleeds past the edge.
function segBlocks(
  segs: { start_ms: number; end_ms: number }[],
  totalMs: number,
): Array<{ left: number; width: number }> {
  const MERGE_MS = 280;
  const sorted = [...segs].sort((a, b) => a.start_ms - b.start_ms);
  const merged: Array<{ start: number; end: number }> = [];
  for (const s of sorted) {
    const last = merged[merged.length - 1];
    if (last && s.start_ms - last.end <= MERGE_MS) {
      last.end = Math.max(last.end, s.end_ms);
    } else {
      merged.push({ start: s.start_ms, end: s.end_ms });
    }
  }
  const out: Array<{ left: number; width: number }> = [];
  for (const m of merged) {
    const left = Math.max(0, (m.start / totalMs) * 100);
    if (left >= 100) continue;
    const raw = ((m.end - m.start) / totalMs) * 100;
    const width = Math.max(0.4, Math.min(raw, 100 - left));
    out.push({ left, width });
  }
  return out;
}

function SpeakerTimeline({
  detail,
  currentTimeSec,
  onSeek,
  t,
  lang,
}: {
  detail: MeetingDetail;
  currentTimeSec: number;
  onSeek: (sec: number) => void;
  t: T;
  lang: Lang;
}) {
  // Hooks must run before any conditional return — moving the early
  // `if (...) return null` below this state/effect block fixes a
  // "Rendered fewer hooks than expected" crash that took the whole
  // Library window down to a white screen.
  const [profileName, setProfileName] = React.useState<string | null>(null);
  React.useEffect(() => {
    let alive = true;
    getSettings().then((s) => { if (alive) setProfileName((s.user_name ?? "").trim() || null); }).catch(() => {});
    return () => { alive = false; };
  }, [detail.id]);

  const totalMs = detail.duration_ms || 0;
  if (totalMs === 0 || detail.segments.length === 0) return null;

  const totals = new Map<string, number>();
  for (const s of detail.segments) {
    const dur = s.end_ms - s.start_ms;
    totals.set(s.speaker_id, (totals.get(s.speaker_id) || 0) + dur);
  }

  const activeSpeakers = detail.speakers.filter((sp) => (totals.get(sp.id) || 0) > 0);
  if (activeSpeakers.length === 0) return null;

  const cursorPct = Math.min(100, Math.max(0, (currentTimeSec * 1000 / totalMs) * 100));

  const onBarClick = (e: React.MouseEvent<HTMLDivElement>) => {
    const rect = (e.currentTarget as HTMLDivElement).getBoundingClientRect();
    const ratio = (e.clientX - rect.left) / rect.width;
    onSeek(Math.max(0, Math.min(1, ratio)) * (totalMs / 1000));
  };

  return (
    <div className="timeline-card">
      <div className="timeline-tabs">
        <span className="timeline-tab active">{t.timeline_title}</span>
      </div>
      <div className="timeline-rows">
      {activeSpeakers.map((sp) => {
        const segs = detail.segments.filter((s) => s.speaker_id === sp.id);
        const sum = totals.get(sp.id) || 0;
        const pct = Math.round((sum / totalMs) * 100);
        const name = displaySpeakerName(sp.custom_name, sp.label, profileName);
        const color = sp.color_hex && /^#[0-9a-f]{6}$/i.test(sp.color_hex)
          ? sp.color_hex
          : colorForSpeaker(name);
        return (
          <div key={sp.id} className="tl-row">
            <div className="tl-row-head">
              <span className="tl-name">{name}</span>
              <span className="tl-stats">{pct}% · {formatDuration(sum, lang)}</span>
            </div>
            <div className="tl-bar" onClick={onBarClick}>
              {segBlocks(segs, totalMs).map((b, i) => (
                <div
                  key={i}
                  className="tl-seg"
                  style={{ left: `${b.left}%`, width: `${b.width}%`, background: color }}
                />
              ))}
              <div className="tl-bar-cursor" style={{ left: `${cursorPct}%` }} />
            </div>
          </div>
        );
      })}
      </div>
    </div>
  );
}
