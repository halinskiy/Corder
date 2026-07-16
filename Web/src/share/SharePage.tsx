import React from "react";
import { Loader2 } from "lucide-react";
import { ShareTranscript } from "./ShareTranscript";
import { ShareSummary } from "./ShareSummary";
import { SharePlayer } from "./SharePlayer";
import { ShareGate } from "./ShareGate";
import { formatDuration } from "../format";
import { fetchShare, tokenFromLocation, ShareGone, type Share } from "./shareApi";

const DOWNLOAD_URL = "https://getcorder.com";

/// The landing's AppleIcon, verbatim — same path, same 0.5px optical nudge
/// (the leaf makes the glyph read top-heavy next to text).
function AppleGlyph({ size = 20 }: { size?: number }) {
  return (
    <svg
      width={size} height={size} viewBox="0 0 24 24" fill="currentColor"
      aria-hidden role="img" style={{ transform: "translateY(0.5px)" }}
    >
      <path d="M17.05 20.28c-.98.95-2.05.88-3.08.41-1.09-.47-2.09-.48-3.24 0-1.44.62-2.2.44-3.06-.41C2.79 15.25 3.51 7.59 9.05 7.31c1.35.07 2.29.74 3.08.8 1.18-.24 2.31-.93 3.57-.84 1.51.12 2.65.72 3.4 1.8-3.12 1.87-2.38 5.98.48 7.13-.57 1.5-1.31 2.99-2.54 4.09l.01-.01zM12 7.25c-.15-2.23 1.66-4.07 3.74-4.25.29 2.58-2.34 4.5-3.74 4.25z" />
    </svg>
  );
}

/// The public share page.
///
/// It IS the landing's hero window with real data in it. `hero-window.css` is
/// vendored from corder-landing verbatim and this markup uses its `.hl-*`
/// classes, so the geometry, type scale, buttons and colours are the ones the
/// brand already ships — not numbers invented here. Around the window: the
/// landing's dot-grid, its blobs, its nav pill, its serif display heading.
///
/// Two earlier shapes were wrong and are worth not repeating: the app's own
/// layout (transcript tracked the window width — ~150 characters a line at
/// 2560), and a plain 720px column (readable, but nothing of Corder in it).
///
/// The sidebar of the hero window is dropped: it lists YOUR meetings, and a
/// visitor has none. The window keeps the transcript column + the recording
/// rail, which is what a shared meeting actually is.
export function SharePage() {
  const [share, setShare] = React.useState<Share | null>(null);
  const [state, setState] = React.useState<"loading" | "ready" | "gone" | "error">("loading");
  const [tab, setTab] = React.useState<"transcript" | "summary">("transcript");
  const [currentTimeSec, setCurrentTimeSec] = React.useState(0);
  const audioRef = React.useRef<HTMLAudioElement>(null);

  React.useEffect(() => {
    const token = tokenFromLocation();
    if (!token) { setState("gone"); return; }
    let alive = true;
    fetchShare(token)
      .then((s) => { if (alive) { setShare(s); setState("ready"); } })
      .catch((e) => { if (alive) setState(e instanceof ShareGone ? "gone" : "error"); });
    return () => { alive = false; };
  }, []);

  const seek = (sec: number) => {
    const a = audioRef.current;
    if (!a) return;
    try { a.currentTime = sec; void a.play(); } catch { /* not seekable yet */ }
  };

  if (state === "loading") {
    return (
      <div className="sp-page sp-page--center">
        <Loader2 size={22} strokeWidth={2.5} className="sp-spin" aria-hidden />
      </div>
    );
  }

  if (state === "gone" || state === "error" || !share) {
    const gone = state === "gone";
    return (
      <div className="sp-page sp-page--center">
        <Atmosphere />
        <div className="sp-notice">
          <h1 className="sp-notice-title">
            {gone ? "This link has expired" : "Something went wrong"}
          </h1>
          <p className="sp-notice-body">
            {gone
              ? "Shared links last 30 days. Ask whoever sent it for a fresh one."
              : "The link could not be loaded. Try again in a moment."}
          </p>
          <a className="sp-cta sp-cta--primary" href={DOWNLOAD_URL}>
            <AppleGlyph size={24} />
            Download for Mac
          </a>
        </div>
      </div>
    );
  }

  const { detail, ownerName, audioUrl } = share;
  const hasSummary = !!(detail.summary && detail.summary.trim());
  const started = new Date(detail.started_at);

  return (
    <div className="sp-page">
      <Atmosphere />

      {/* Granola's move: the first thing a visitor meets is the pitch, not the
          transcript. They dismiss it and read. This is the highest-intent
          moment on the page — someone just received a Corder link from a
          person they know. */}
      <ShareGate ownerName={ownerName} downloadUrl={DOWNLOAD_URL} />

      {/* The landing's nav pill, value-for-value (Nav.tsx). Its CTA is
          transparent until scrollY > 8; this page's window doesn't scroll, so
          it ships in the scrolled (filled) state. */}
      <header className="sp-nav-wrap">
        <div className="sp-nav">
          <a className="sp-nav-brand" href={DOWNLOAD_URL} aria-label="Corder, home">
            <img src="/brand-mark-128.png" width={32} height={32} alt="" aria-hidden />
            <span className="sp-nav-word">Corder</span>
          </a>
          <span className="sp-nav-sep" aria-hidden />
          <span className="sp-nav-note">
            {ownerName ? <><b>{ownerName}</b> shared this recording</> : "Shared with you"}
          </span>
          <a className="sp-nav-cta" href={DOWNLOAD_URL}>
            <AppleGlyph size={18} />
            Download
          </a>
        </div>
      </header>

      <main className="sp-container">
        <div className="sp-head">
          <h1 className="sp-title">{detail.title || "Untitled meeting"}</h1>
          <p className="sp-sub">
            {started.toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" })}
            {" · "}{formatDuration(detail.duration_ms ?? 0)}
            {detail.speakers.length > 0 && <>{" · "}{detail.speakers.length} {detail.speakers.length === 1 ? "speaker" : "speakers"}</>}
          </p>
        </div>

        {/* The hero window itself. `.hero-library-demo` brings the whole thing:
            1180px, 12px radius, the two-layer shadow, the app type scale. */}
        <div className="hero-library-demo sp-demo">
          <div className="hl-titlebar" aria-hidden="true">
            <span className="hl-traffic close">
              <svg viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round">
                <path d="M3.7 3.7 8.3 8.3M8.3 3.7 3.7 8.3" />
              </svg>
            </span>
            <span className="hl-traffic minimize">
              <svg viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round">
                <path d="M3.2 6h5.6" />
              </svg>
            </span>
            <span className="hl-traffic maximize">
              <svg viewBox="0 0 12 12" fill="currentColor">
                <path d="M3 3 3 6.4 6.4 3Z" /><path d="M9 9 9 5.6 5.6 9Z" />
              </svg>
            </span>
          </div>

          <div className="hl-app sp-app">
            <div className="hl-main">
              <div className="hl-main-header">
                <div className="hl-breadcrumb">
                  <span className="hl-breadcrumb-current">{detail.title || "Untitled meeting"}</span>
                </div>
                <div className="hl-spacer" />
                <div className="hl-header-actions">
                  <a className="sp-cta sp-cta--nav" href={DOWNLOAD_URL}>
                    <AppleGlyph size={16} />
                    Download Corder
                  </a>
                </div>
              </div>

              <div className="hl-detail-tabs sp-tabs-row">
                <div className="hl-detail-tab-col">
                  <button
                    type="button"
                    className={"hl-tab" + (tab === "transcript" ? " active" : "")}
                    onClick={() => setTab("transcript")}
                  >
                    Transcript
                  </button>
                  {hasSummary && (
                    <button
                      type="button"
                      className={"hl-tab" + (tab === "summary" ? " active" : "")}
                      onClick={() => setTab("summary")}
                    >
                      Summary
                    </button>
                  )}
                </div>
                <div className="hl-detail-tab-col">
                  <span className="hl-tab active">Recording</span>
                </div>
              </div>

              <div className="hl-detail-body sp-body">
                {tab === "transcript" ? (
                  <ShareTranscript
                    detail={detail}
                    currentTimeSec={currentTimeSec}
                    onSeek={seek}
                  />
                ) : (
                  <div className="hl-transcript-wrap">
                    <ShareSummary markdown={detail.summary!} />
                  </div>
                )}

                <div className="hl-right-panel">
                  <SharePlayer
                    audioRef={audioRef}
                    audioUrl={audioUrl}
                    durationMs={detail.duration_ms ?? 0}
                    currentTimeSec={currentTimeSec}
                    onTimeUpdate={setCurrentTimeSec}
                    onSeek={seek}
                    detail={detail}
                  />
                </div>
              </div>
            </div>
          </div>
        </div>

        <p className="sp-hint">
          Recorded with Corder. Nothing joined the call.
        </p>
      </main>
    </div>
  );
}

/// The landing's hero atmosphere: two un-blurred blobs (they were blurred +
/// animated until 2026-05-22, when six animated blurred fills pinned Speed
/// Index at 12.9s) under a masked dot-grid.
function Atmosphere() {
  return (
    <div className="sp-atmos" aria-hidden>
      <span className="sp-blob sp-blob--tr" />
      <span className="sp-blob sp-blob--bl" />
      <div className="sp-dots" />
    </div>
  );
}
