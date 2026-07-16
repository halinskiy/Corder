import React from "react";
import { Loader2 } from "lucide-react";
import { TranscriptPane } from "../components/TranscriptPane";
import { SummaryPane } from "../components/SummaryPane";
import { AudioCard } from "../components/AudioCard";
import { SpeakerTimeline } from "../components/RightPanel";
import { pickStrings } from "../i18n";
import { formatDuration } from "../format";
import { fetchShare, tokenFromLocation, ShareGone, type Share } from "./shareApi";

const DOWNLOAD_URL = "https://getcorder.com";

/// The public share page: the real Corder panes, fed by one public GET instead
/// of the local app server. Everything that writes, polls, or talks to a local
/// Corder is off (see the `readOnly` props); what's left is exactly what a
/// viewer should get — the transcript, the summary, and the audio.
export function SharePage() {
  const t = pickStrings("en");
  const [share, setShare] = React.useState<Share | null>(null);
  const [state, setState] = React.useState<"loading" | "ready" | "gone" | "error">("loading");
  const [leftTab, setLeftTab] = React.useState<"transcript" | "summary">("transcript");
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
    if (a) { try { a.currentTime = sec; } catch { /* not seekable yet */ } }
  };

  if (state === "loading") {
    return (
      <div className="share-page share-page-center">
        <Loader2 size={22} strokeWidth={2.5} className="summary-spin" aria-hidden />
      </div>
    );
  }
  if (state === "gone" || state === "error" || !share) {
    const gone = state === "gone";
    return (
      <div className="share-page share-page-center">
        <div className="trans-banner clarify-banner share-gone-card">
          <div className="clarify-text">
            <div className="clarify-body">
              {gone ? "This link has expired" : "Something went wrong"}
            </div>
            <div className="dash-sub">
              {gone
                ? "Shared links last 30 days. Ask for a fresh one."
                : "The link could not be loaded. Try again in a moment."}
            </div>
          </div>
          <div className="clarify-actions clarify-actions-stack">
            <a className="clarify-btn accent" href={DOWNLOAD_URL}>
              <span>Get Corder</span>
            </a>
          </div>
        </div>
      </div>
    );
  }

  const { detail, ownerName, audioUrl } = share;
  const hasSummary = !!(detail.summary && detail.summary.trim());
  const started = new Date(detail.started_at);

  return (
    <div className="share-page">
      <header className="share-top">
        <div className="share-top-meta">
          <div className="share-owner">
            {ownerName ? `${ownerName} shared this with you` : "Shared with you"}
          </div>
          <h1 className="share-title">{detail.title || "Untitled meeting"}</h1>
          <div className="share-sub">
            {started.toLocaleDateString(undefined, { day: "numeric", month: "long", year: "numeric" })}
            {detail.duration_ms ? ` · ${formatDuration(detail.duration_ms)}` : ""}
          </div>
        </div>
        <a className="clarify-btn accent share-cta" href={DOWNLOAD_URL}>
          <span>Download Corder</span>
        </a>
      </header>

      <div className="detail share-detail">
        <div className="detail-tabs">
          <div className="detail-tab-col detail-tab-col-left">
            <span
              className={"tab" + (leftTab === "transcript" ? " active" : "")}
              onClick={() => setLeftTab("transcript")}
            >
              {t.tab_transcript}
            </span>
            {hasSummary && (
              <span
                className={"tab" + (leftTab === "summary" ? " active" : "")}
                onClick={() => setLeftTab("summary")}
              >
                {t.tab_summary}
              </span>
            )}
          </div>
          <div className="detail-tab-col detail-tab-col-right">
            <span className="tab active">{t.audio_card_title}</span>
          </div>
        </div>

        <div className="detail-body share-body">
          <div
            className="transcript-wrap"
            style={{ display: leftTab === "transcript" ? "flex" : "none" }}
          >
            <TranscriptPane
              detail={detail}
              currentTimeSec={currentTimeSec}
              onSeek={seek}
              query=""
              boostOn={false}
              recordingState={{ active: false }}
              clarifyOpen={false}
              readOnly
              // Every callback below drives app-only state (sidebar refresh,
              // toasts, the clarify flow). There is no app here.
              onSpeakersUpdated={() => {}}
              onRecordingStopped={() => {}}
              onDeleted={() => {}}
              onClarifyDismiss={() => {}}
              onClarifyChosen={() => {}}
              onToast={() => {}}
              t={t}
            />
          </div>
          {hasSummary && (
            <div
              className="transcript-wrap summary-wrap-host"
              style={{ display: leftTab === "summary" ? "flex" : "none" }}
            >
              <SummaryPane detail={detail} readOnly t={t} />
            </div>
          )}

          <div className="right-panel share-right">
            <AudioCard
              detail={detail}
              audioRef={audioRef}
              onTimeUpdate={setCurrentTimeSec}
              audioUrl={audioUrl ?? undefined}
              t={t}
            />
            <SpeakerTimeline
              detail={detail}
              currentTimeSec={currentTimeSec}
              onSeek={seek}
              t={t}
              lang="en"
            />
          </div>
        </div>
      </div>
    </div>
  );
}
