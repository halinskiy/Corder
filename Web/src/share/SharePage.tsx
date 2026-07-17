import React from "react";
import { Loader2 } from "lucide-react";
import { ShareTranscript } from "./ShareTranscript";
import { SharePlayer } from "./SharePlayer";
import { ShareGate } from "./ShareGate";
import { ShareDownload } from "./ShareDownload";
import { ShareExport } from "./ShareExport";
import { ShareSearch } from "./ShareSearch";
import { formatDuration } from "../format";
import { fetchShare, tokenFromLocation, ShareGone, type Share } from "./shareApi";

const DOWNLOAD_URL = "https://getcorder.com";

/// The public share page.
///
/// A document, not an app window. The page is a canvas — the landing's dot-grid
/// and blobs — and on it sits a single sheet carrying the transcript, the way a
/// Google Doc sits on its own backdrop. Everything else is pinned to a corner
/// and never touches the reading column:
///
///   top-left      the brand mark. There is no nav bar: on a page whose whole
///                 job is to be read, a marketing strip competes with the text.
///   bottom-left   the audio, fixed, so any moment of the meeting is playable
///                 while reading any part of it.
///   bottom-right  the download orb — the landing's own CorderPresence orb
///                 (state B of its morph): same 56px, same accent, same icon,
///                 same hover. Its mirror on the landing is the cookie circle,
///                 which is why the audio takes that side.
///
/// Earlier cuts built this as an app window with tabs and rails, and it kept
/// fighting itself. A shared meeting is a document, and a document wants a page.
export function SharePage() {
  const [share, setShare] = React.useState<Share | null>(null);
  const [state, setState] = React.useState<"loading" | "ready" | "gone" | "error">("loading");
  const [currentTimeSec, setCurrentTimeSec] = React.useState(0);
  const [query, setQuery] = React.useState("");
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
          <a className="sp-cta sp-cta--primary" href={DOWNLOAD_URL}>Get Corder</a>
        </div>
      </div>
    );
  }

  const { detail, ownerName, audioUrl } = share;
  const started = new Date(detail.started_at);
  const q = query.trim().toLowerCase();
  const matchCount = q ? detail.segments.filter((s) => s.text.toLowerCase().includes(q)).length : null;

  return (
    <div className="sp-page">
      <Atmosphere />
      <ShareGate ownerName={ownerName} downloadUrl={DOWNLOAD_URL} />

      <a className="sp-brand" href={DOWNLOAD_URL} aria-label="Corder">
        <img src="/brand-mark-128.png" width={56} height={56} alt="" />
      </a>

      <div className="sp-tools">
        <ShareSearch query={query} onQuery={setQuery} count={matchCount} />
        <ShareExport detail={detail} audioUrl={audioUrl} />
      </div>

      <main className="sp-sheet-wrap">
        <article className="sp-sheet">
          <header className="sp-doc-head">
            <h1 className="sp-doc-title">{detail.title || "Untitled meeting"}</h1>
            <p className="sp-doc-meta">
              {started.toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" })}
              <i aria-hidden />
              {formatDuration(detail.duration_ms ?? 0)}
              {detail.speakers.length > 0 && (
                <>
                  <i aria-hidden />
                  {detail.speakers.length} {detail.speakers.length === 1 ? "speaker" : "speakers"}
                </>
              )}
              {ownerName && (
                <>
                  <i aria-hidden />
                  <span className="sp-doc-by">shared by {ownerName}</span>
                </>
              )}
            </p>
          </header>

          <ShareTranscript
            detail={detail}
            currentTimeSec={currentTimeSec}
            onSeek={seek}
            query={query}
          />
        </article>
      </main>

      <SharePlayer
        audioRef={audioRef}
        audioUrl={audioUrl}
        durationMs={detail.duration_ms ?? 0}
        currentTimeSec={currentTimeSec}
        onTimeUpdate={setCurrentTimeSec}
        onSeek={seek}
        detail={detail}
      />

      <ShareDownload downloadUrl={DOWNLOAD_URL} ownerName={ownerName} />
    </div>
  );
}

/// The landing's hero atmosphere: two un-blurred blobs (blur + animation were
/// dropped there in May, when six animated blurred fills pinned Speed Index at
/// 12.9s) under a masked dot-grid.
function Atmosphere() {
  return (
    <div className="sp-atmos" aria-hidden>
      <span className="sp-blob sp-blob--tr" />
      <span className="sp-blob sp-blob--bl" />
      <div className="sp-dots" />
    </div>
  );
}
