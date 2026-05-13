import React from "react";
import { Copy, Archive as ArchiveIcon, Globe, Users } from "lucide-react";
import { MeetingDetail, RecordingState, getMeeting, getTranscriptText, getLastError } from "../api";
import type { Lang, T } from "../i18n";

// We persist the *whichever* state the user last saw the banner in
// (open or closed) so the next visit to that meeting matches what
// they're expecting. "open" entries override the auto-open heuristic
// (banner stays visible even when diarization is confident); "closed"
// entries override it the other way (banner stays hidden even when
// diarization is uncertain).
const CLARIFY_STATE_KEY = "corder.clarify_state";  // { [id]: "open" | "closed" }

function readClarifyState(meetingId: string): "open" | "closed" | null {
  try {
    const m = JSON.parse(localStorage.getItem(CLARIFY_STATE_KEY) || "{}");
    const v = m[meetingId];
    return v === "open" || v === "closed" ? v : null;
  } catch { return null; }
}

function writeClarifyState(meetingId: string, state: "open" | "closed") {
  try {
    const m = JSON.parse(localStorage.getItem(CLARIFY_STATE_KEY) || "{}");
    m[meetingId] = state;
    localStorage.setItem(CLARIFY_STATE_KEY, JSON.stringify(m));
  } catch {}
}

function BoostSwitch({
  active, onToggle, t,
}: {
  active: boolean; onToggle: () => void; t: T;
}) {
  return (
    <button
      className={"boost-switch" + (active ? " on" : "")}
      onClick={onToggle}
      title={t.btn_boost_title}
    >
      <span className="boost-track">
        <span className="boost-thumb" />
      </span>
      <span className="boost-label">{t.btn_boost}</span>
    </button>
  );
}

function LangSwitch({ lang, onToggle, t }: { lang: Lang; onToggle: () => void; t: T }) {
  return (
    <button onClick={onToggle} title={t.btn_lang_title}>
      <Globe size={14} strokeWidth={2} /> {lang.toUpperCase()}
    </button>
  );
}


/// Clipboard via native bridge. WKWebView blocks both
/// `navigator.clipboard.writeText` and `document.execCommand('copy')` in our
/// Library window, so we ask Swift to write to NSPasteboard. Falls back to
/// the web APIs when the bridge isn't available (e.g. running in a regular
/// browser during dev with `npm run dev`).
async function copyText(text: string): Promise<void> {
  const native = (window as any).corderCopy;
  if (typeof native === "function") {
    if (native(text)) return;
  }
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return;
    }
  } catch {}
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.style.position = "fixed";
  ta.style.left = "-9999px";
  document.body.appendChild(ta);
  ta.focus();
  ta.select();
  const ok = document.execCommand("copy");
  document.body.removeChild(ta);
  if (!ok) throw new Error("clipboard unavailable");
}
import { formatDate } from "../format";
import { TranscriptPane } from "./TranscriptPane";
import { RightPanel } from "./RightPanel";

interface Props {
  meetingId: string;
  onDeleted: (id?: string) => void;
  /// Opens the global archive panel — toolbar's Archive button hands off
  /// to this. Archiving the *current* meeting happens via Sidebar's
  /// context menu or via the EmptyDeleteBanner on failed transcripts.
  onOpenArchive: () => void;
  onToast: (msg: string, kind?: "success" | "error") => void;
  recordingState: RecordingState;
  onRecordingStopped: () => void;
  boostMode: boolean;
  onBoostModeChange: (next: boolean) => void;
  lang: Lang;
  onLangChange: (next: Lang) => void;
  t: T;
}

export function MeetingView({ meetingId, onDeleted, onOpenArchive, onToast, recordingState, onRecordingStopped, boostMode, onBoostModeChange, lang, onLangChange, t }: Props) {
  const [detail, setDetail] = React.useState<MeetingDetail | null>(null);
  const [error, setError] = React.useState<string | null>(null);
  const [currentTime, setCurrentTime] = React.useState(0);
  const [search, setSearch] = React.useState("");
  // Speakers-clarify banner visibility — controlled here so the toolbar
  // icon button can toggle it. Auto-opens once per meeting if the diarizer
  // looks over-segmented and the user hasn't already dismissed for this id.
  const [clarifyOpen, setClarifyOpen] = React.useState(false);
  const videoRef = React.useRef<HTMLVideoElement>(null);

  const load = React.useCallback(async () => {
    setError(null);
    try { setDetail(await getMeeting(meetingId)); }
    catch (e) { setError(String(e)); }
  }, [meetingId]);

  // Show a "Loading…" fallback only if the fetch takes long enough to
  // be perceptibly slow. Below that threshold the screen briefly flashed
  // an empty loader before the new meeting painted, which read as jank.
  const [showLoading, setShowLoading] = React.useState(false);
  React.useEffect(() => {
    setDetail(null);
    setSearch("");
    setClarifyOpen(false);
    setShowLoading(false);
    const slow = window.setTimeout(() => setShowLoading(true), 250);
    load().finally(() => window.clearTimeout(slow));
    return () => window.clearTimeout(slow);
  }, [load]);

  // Decide whether the clarify banner is open on first paint. Priority:
  //   1. Persisted per-meeting state — whatever we left it as last time
  //      wins. Toggling via the toolbar icon or dismissing via X both
  //      write here.
  //   2. Auto-open heuristic — only when the diarizer looks unsure
  //      (≥2 detected "others" AND user never told us how many people
  //      were on the call). This is the original Granola-style nudge:
  //      "I noticed multiple speakers — was it really N?"
  //   3. Otherwise stay closed; the toolbar icon reopens it on demand.
  React.useEffect(() => {
    if (!detail) return;
    if (detail.status !== "ready" || detail.segments.length === 0) return;
    const persisted = readClarifyState(detail.id);
    if (persisted === "open")  { setClarifyOpen(true);  return; }
    if (persisted === "closed") { setClarifyOpen(false); return; }
    const detected = Math.max(0, detail.speakers.length - 1);
    const uncertain =
      detected >= 2 &&
      (detail.expected_other_speakers === null ||
       detail.expected_other_speakers === undefined);
    setClarifyOpen(uncertain);
  }, [detail?.id, detail?.status, detail?.expected_other_speakers, detail?.speakers.length]);

  const toggleClarify = () => {
    setClarifyOpen((open) => {
      const next = !open;
      if (detail) writeClarifyState(detail.id, next ? "open" : "closed");
      return next;
    });
  };

  const onClarifyDismiss = () => {
    if (detail) writeClarifyState(detail.id, "closed");
    setClarifyOpen(false);
  };

  const onClarifyChosen = () => {
    // Keep the banner open on purpose: the active pill shows the user
    // what they just picked, and one more click on a neighbour switches
    // immediately. Closing it here used to leave people stranded — they
    // didn't realise the toolbar's Users icon reopens it. Dismiss only
    // happens via the explicit X button or the toolbar toggle.
    load();
  };

  React.useEffect(() => {
    if (!detail) return;
    // Re-poll while a transcription or recording is in flight, or while we're
    // waiting on auto-boost — segments only get text_boost asynchronously.
    const hasBoostNow = detail.segments.some((s) => s.text_boost);
    const awaitingBoost = boostMode && detail.status === "ready" && detail.segments.length > 0 && !hasBoostNow;
    if (detail.status === "transcribing" || detail.status === "recording" || awaitingBoost) {
      const t = setInterval(load, 2000);
      return () => clearInterval(t);
    }
  }, [detail, load, boostMode]);

  // Surface backend transcription errors (Gemini quota / billing, missing
  // key, timeout) as a red toast. Polled once per meeting load — server
  // clears the marker on the next successful run.
  const lastErrorShown = React.useRef<string | null>(null);
  React.useEffect(() => {
    if (!detail || detail.status !== "failed") return;
    let cancelled = false;
    (async () => {
      try {
        const err = await getLastError(detail.id);
        if (cancelled || !err) return;
        if (lastErrorShown.current === err) return;
        lastErrorShown.current = err;
        onToast(err, "error");
      } catch {}
    })();
    return () => { cancelled = true; };
  }, [detail?.id, detail?.status, onToast]);

  if (error) return <div className="empty"><div className="empty-title">{t.error_label}</div><div>{error}</div></div>;
  if (!detail) {
    // Skeleton during the first detail fetch — keeps the layout stable
    // so the header/columns don't flash in on arrival. We only show
    // the skeleton once `showLoading` flips (delayed ~150 ms so fast
    // local fetches don't strobe), and only on the very first load
    // (when no detail has ever arrived); subsequent re-fetches preserve
    // the previous detail as `detail` is non-null.
    return showLoading ? <MeetingSkeleton /> : <div className="empty" />;
  }

  const onSeek = (sec: number) => {
    const v = videoRef.current;
    if (v) {
      // currentTime is only meaningful once metadata has loaded; setting it
      // before that quietly snaps back to 0. Wait for `loadedmetadata` if
      // we're not there yet, then seek + play. play() may reject in some
      // states (e.g. while still loading); we silently ignore — the click
      // counts as a user gesture so the next call usually succeeds.
      const apply = () => {
        try { v.currentTime = sec; } catch {}
        v.play().catch(() => {});
      };
      if (v.readyState >= 1) {
        apply();
      } else {
        v.addEventListener("loadedmetadata", apply, { once: true });
        // Make sure metadata actually loads — `preload="auto"` does this
        // already, but calling load() guards against browsers that paused
        // it after the previous error/seek.
        try { v.load(); } catch {}
      }
    }
    setCurrentTime(sec);
  };

  const onCopy = async () => {
    try {
      const text = await getTranscriptText(detail.id);
      await copyText(text);
      onToast(t.toast_copied, "success");
    } catch { onToast(t.toast_copy_failed, "error"); }
  };

  // Toolbar's Archive button opens the archive panel (the bin itself).
  // Archiving *this* meeting goes through the sidebar's right-click menu
  // or, for failed/empty meetings, the in-pane "В архив" button.

  const hasBoost = !!detail?.segments.some((s) => s.text_boost);
  // Boost is now a global mode: the switch reflects the persisted setting and
  // toggling it never triggers work on the currently-viewed meeting. The
  // existing meeting only renders polished text when both the global switch is
  // on AND it actually has text_boost rows (left over from a previous run with
  // the switch on, or freshly auto-boosted after retranscribe).
  const boostOn = boostMode && hasBoost;

  return (
    <>
      <div className="main-header">
        <div className="breadcrumb">
          <span>{t.breadcrumb_records}</span>
          <span style={{ opacity: 0.4 }}>›</span>
          <span className="breadcrumb-current">{formatDate(detail.started_at, lang)}</span>
        </div>
        <BoostSwitch
          active={boostMode}
          onToggle={() => onBoostModeChange(!boostMode)}
          t={t}
        />
        <div className="spacer" />
        <div className="toolbar">
          <LangSwitch lang={lang} onToggle={() => onLangChange(lang === "ru" ? "en" : "ru")} t={t} />
          <button onClick={onCopy} disabled={detail.segments.length === 0}>
            <Copy size={14} strokeWidth={2} /> {t.btn_copy}
          </button>
          <button className="ghost" onClick={onOpenArchive} title={t.archive_open_title}>
            <ArchiveIcon size={14} strokeWidth={2} /> {t.btn_archive}
          </button>
        </div>
      </div>
      <div className="detail">
        <div className="detail-tabs">
          <div className="detail-tab-col detail-tab-col-left">
            <span className="tab active">{t.tab_transcript}</span>
          </div>
          <div className="detail-tab-col detail-tab-col-right">
            <span className="tab active">{t.audio_card_title}</span>
          </div>
        </div>
        <div className="detail-body">
          <div className="transcript-wrap">
            <div className="transcript-toolbar">
              <input
                type="search"
                placeholder={t.transcript_search}
                value={search}
                onChange={(e) => setSearch(e.target.value)}
              />
              {detail.status === "ready" && detail.segments.length > 0 && (
                <button
                  className={"toolbar-icon-btn" + (clarifyOpen ? " active" : "")}
                  onClick={toggleClarify}
                  title={t.clarify_question}
                  aria-label={t.clarify_question}
                >
                  <Users size={16} strokeWidth={2} />
                </button>
              )}
            </div>
            <TranscriptPane
              detail={detail}
              currentTimeSec={currentTime}
              onSeek={onSeek}
              onSpeakersUpdated={load}
              query={search}
              boostOn={boostOn}
              recordingState={recordingState}
              onRecordingStopped={onRecordingStopped}
              onDeleted={onDeleted}
              clarifyOpen={clarifyOpen}
              onClarifyDismiss={onClarifyDismiss}
              onClarifyChosen={onClarifyChosen}
              onToast={onToast}
              t={t}
            />
          </div>
          <RightPanel
            detail={detail}
            videoRef={videoRef}
            onTimeUpdate={setCurrentTime}
            currentTimeSec={currentTime}
            onSeek={onSeek}
            t={t}
          />
        </div>
      </div>
    </>
  );
}

/// Placeholder rendered while the first GET /api/meetings/:id is in
/// flight. Mirrors the real layout (header + two-column body + audio
/// card on the right) so the eventual content slides in without a
/// layout jump.
function MeetingSkeleton() {
  return (
    <>
      <div className="main-header">
        <div className="breadcrumb">
          <span className="skel-pill skel-pill-sm" />
        </div>
        <div className="spacer" />
      </div>
      <div className="detail">
        <div className="detail-tabs">
          <div className="detail-tab-col detail-tab-col-left">
            <span className="skel-pill skel-pill-tab" />
          </div>
          <div className="detail-tab-col detail-tab-col-right">
            <span className="skel-pill skel-pill-tab" />
          </div>
        </div>
        <div className="detail-body">
          <div className="transcript-wrap">
            <div className="transcript-toolbar">
              <span className="skel-line skel-line-input" />
            </div>
            <div className="meeting-skeleton-transcript">
              {Array.from({ length: 6 }).map((_, i) => (
                <div className="skel-paragraph" key={i}>
                  <div className="skel-line skel-line-meta-sm" />
                  <div className="skel-line skel-line-text" />
                  <div className="skel-line skel-line-text skel-line-text-short" />
                </div>
              ))}
            </div>
          </div>
          <div className="right-panel">
            <div className="audio-controls">
              <span className="skel-circle" />
              <span className="skel-line skel-line-time" />
              <span className="skel-line skel-line-scrub" />
            </div>
            <div className="timeline-card">
              <div className="timeline-tabs">
                <span className="skel-pill skel-pill-tab" />
              </div>
              <div className="timeline-rows">
                {Array.from({ length: 3 }).map((_, i) => (
                  <div className="tl-row" key={i}>
                    <div className="tl-row-head">
                      <span className="skel-line skel-line-name" />
                      <span className="skel-line skel-line-stats" />
                    </div>
                    <div className="skel-line skel-line-bar" />
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>
      </div>
    </>
  );
}
