import React from "react";
import { Loader2 } from "lucide-react";
import { ShareTranscript } from "./ShareTranscript";
import { ShareSummary } from "./ShareSummary";
import { SharePlayer } from "./SharePlayer";
import { ShareGate } from "./ShareGate";
import { fetchShare, tokenFromLocation, ShareGone, type Share } from "./shareApi";

const DOWNLOAD_URL = "https://getcorder.com";

/// The landing's nav.links, verbatim (corder-landing/content/copy.json).
const NAV_LINKS = [
  { label: "How it works", href: "#how-it-works" },
  { label: "Features", href: "#features" },
  { label: "Pricing", href: "#pricing" },
  { label: "FAQ", href: "#faq" },
];

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
  // Nav.tsx flips this at scrollY > 8 and the CTA fills with accent. The page
  // does scroll (hero + a 720px window), so the state is real here, not faked.
  const [scrolled, setScrolled] = React.useState(false);
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

  React.useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 8);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
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

  return (
    <div className="sp-page">
      <Atmosphere />

      {/* Granola's move: the first thing a visitor meets is the pitch, not the
          transcript. They dismiss it and read. This is the highest-intent
          moment on the page — someone just received a Corder link from a
          person they know. */}
      <ShareGate ownerName={ownerName} downloadUrl={DOWNLOAD_URL} />

      {/* The landing's Nav, copied. Not "inspired by": the same brand mark with
          NO wordmark beside it (the landing shows the word only on mobile), the
          same four links, the same hairline separator, and the same CTA with
          its scroll-state — transparent hairline at the top of the page,
          accent fill past 8px. Links point at the landing's anchors, since
          this page has no sections of its own. */}
      <header className="sp-nav-wrap" data-scrolled={scrolled ? "true" : "false"}>
        <div className="sp-nav">
          <a className="sp-nav-brand" href={DOWNLOAD_URL} aria-label="Corder, home">
            <img src="/brand-mark-128.png" width={32} height={32} alt="" aria-hidden />
          </a>
          <span className="sp-nav-sep" aria-hidden />
          <nav className="sp-nav-links">
            {NAV_LINKS.map((l) => (
              <a key={l.href} className="sp-nav-link" href={DOWNLOAD_URL + "/" + l.href}>{l.label}</a>
            ))}
          </nav>
          <a className="sp-nav-cta" href={DOWNLOAD_URL}>
            <AppleGlyph size={20} />
            Download
          </a>
        </div>
      </header>

      <main className="sp-container">
        <div className="sp-head">
          {ownerName && (
            <p className="sp-shared-by"><span>{ownerName}</span> shared this recording with you</p>
          )}
        </div>

        {/* The hero window itself. `.hero-library-demo` brings the whole thing:
            1180px, 12px radius, the two-layer shadow, the app type scale. */}
        <div className="hero-library-demo sp-demo">
          <div className="hl-app sp-app">
            <div className="hl-main">
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
          Recorded with Corder.
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
