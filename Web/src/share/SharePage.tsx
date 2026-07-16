import React from "react";
import { Loader2, Copy, Check } from "lucide-react";
import { ShareTranscript } from "./ShareTranscript";
import { ShareSummary } from "./ShareSummary";
import { SharePlayer } from "./SharePlayer";
import { formatDuration } from "../format";
import { fetchShare, tokenFromLocation, ShareGone, type Share } from "./shareApi";

const DOWNLOAD_URL = "https://getcorder.com";

/// The public share page.
///
/// Built to look like getcorder.com, not like the app window and not like the
/// competition: the landing presents Corder as a floating "window" card over a
/// dot-grid, under a serif display heading and a pill nav — so a share link,
/// which is the product's most-seen public surface, does the same.
///
/// Two things it is deliberately NOT:
///  - not the app's layout (that ran the transcript to the full window width;
///    at 2560 it was ~150 characters a line, twice the readable limit);
///  - not a long single column either (that read as a plain document with
///    nothing of the brand in it).
///
/// Instead the whole meeting lives in ONE window card that fits the viewport:
/// player across the top, transcript in the reading column, summary in the
/// side rail. Scrolling happens INSIDE the card's columns, so the page itself
/// doesn't grow to the length of the transcript.
///
/// Light-only, like every measured page of the category (Loom, Granola, Otter,
/// tl;dv) and like the landing itself. It briefly followed the visitor's OS
/// theme, which nobody does — a share link is a page of the product, not a
/// mirror of the reader's system.
export function SharePage() {
  const [share, setShare] = React.useState<Share | null>(null);
  const [state, setState] = React.useState<"loading" | "ready" | "gone" | "error">("loading");
  const [tab, setTab] = React.useState<"transcript" | "summary">("transcript");
  const [currentTimeSec, setCurrentTimeSec] = React.useState(0);
  const [copied, setCopied] = React.useState(false);
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
        <Loader2 size={22} strokeWidth={2.5} className="summary-spin" aria-hidden />
      </div>
    );
  }

  if (state === "gone" || state === "error" || !share) {
    const gone = state === "gone";
    return (
      <div className="sp-page sp-page--center">
        <div className="sp-notice">
          <h1 className="sp-notice-title">
            {gone ? "This link has expired" : "Something went wrong"}
          </h1>
          <p className="sp-notice-body">
            {gone
              ? "Shared links last 30 days. Ask whoever sent it for a fresh one."
              : "The link could not be loaded. Try again in a moment."}
          </p>
          <a className="sp-btn sp-btn--primary" href={DOWNLOAD_URL}>Get Corder</a>
        </div>
      </div>
    );
  }

  const { detail, ownerName, audioUrl } = share;
  const hasSummary = !!(detail.summary && detail.summary.trim());
  const started = new Date(detail.started_at);

  const copyLink = () => {
    try {
      navigator.clipboard?.writeText(window.location.href);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1800);
    } catch { /* clipboard blocked */ }
  };

  return (
    <div className="sp-page">
      <div className="sp-atmos" aria-hidden>
        <span className="sp-blob sp-blob--a" />
        <span className="sp-blob sp-blob--b" />
      </div>

      {/* The landing's floating pill nav, same silhouette. */}
      <nav className="sp-nav">
        <a className="sp-nav-brand" href={DOWNLOAD_URL} aria-label="Corder">
          <span className="sp-mark" aria-hidden />
        </a>
        <span className="sp-nav-sep" aria-hidden />
        <span className="sp-nav-note">
          {ownerName ? <><b>{ownerName}</b> shared this recording</> : "Shared with you"}
        </span>
        <a className="sp-btn sp-btn--primary sp-btn--sm" href={DOWNLOAD_URL}>Download</a>
      </nav>

      <header className="sp-hero">
        <h1 className="sp-hero-title">{detail.title || "Untitled meeting"}</h1>
        <div className="sp-hero-meta">
          <span>{started.toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" })}</span>
          {!!detail.duration_ms && <><i aria-hidden /> <span>{formatDuration(detail.duration_ms)}</span></>}
          {detail.speakers.length > 0 && (
            <><i aria-hidden /> <span>{detail.speakers.length} {detail.speakers.length === 1 ? "speaker" : "speakers"}</span></>
          )}
        </div>
      </header>

      {/* One window, sized to the viewport. The columns scroll inside it, so
          the page never grows to the length of the transcript. */}
      <div className="sp-window">
        {!!audioUrl && (
          <SharePlayer
            audioRef={audioRef}
            audioUrl={audioUrl}
            durationMs={detail.duration_ms ?? 0}
            currentTimeSec={currentTimeSec}
            onTimeUpdate={setCurrentTimeSec}
            onSeek={seek}
          />
        )}

        <div className={"sp-body" + (hasSummary ? "" : " sp-body--solo")}>
          <section className="sp-main">
            <div className="sp-pane-head">
              <div className="sp-tabs">
                <button
                  type="button"
                  className={"sp-tab" + (tab === "transcript" ? " is-on" : "")}
                  onClick={() => setTab("transcript")}
                >
                  Transcript
                </button>
                {hasSummary && (
                  <button
                    type="button"
                    className={"sp-tab sp-tab--mobile" + (tab === "summary" ? " is-on" : "")}
                    onClick={() => setTab("summary")}
                  >
                    Summary
                  </button>
                )}
              </div>
              <button type="button" className="sp-icon-btn" onClick={copyLink} title="Copy link">
                {copied ? <Check size={15} strokeWidth={2} /> : <Copy size={15} strokeWidth={2} />}
              </button>
            </div>
            <ShareTranscript
              detail={detail}
              currentTimeSec={currentTimeSec}
              onSeek={seek}
              hidden={tab !== "transcript"}
            />
          </section>

          {hasSummary && (
            <aside className={"sp-rail" + (tab === "summary" ? " is-shown" : "")}>
              <div className="sp-pane-head sp-pane-head--rail">
                <span className="sp-rail-title">Summary</span>
              </div>
              <ShareSummary markdown={detail.summary!} />
            </aside>
          )}
        </div>
      </div>

      <footer className="sp-foot">
        <span>Recorded with <a href={DOWNLOAD_URL}>Corder</a> — meeting transcripts that stay on your Mac.</span>
      </footer>
    </div>
  );
}
