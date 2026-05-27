import React from "react";
import { Copy, Users, Search } from "lucide-react";
import { MeetingDetail, RecordingState, getMeeting, getTranscriptText, getLastError, renameMeeting } from "../api";
import { MainHeader } from "./MainHeader";
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
import { SummaryPane } from "./SummaryPane";
import { SettingsPane } from "./SettingsPane";
// IntegrationsPane import removed while the Integrations tab is
// hidden (see the tab strip below). Re-add when bringing it back.
import { ResizeHandle } from "./ResizeHandle";
import { RightPanel } from "./RightPanel";
// Header toolbar (UpdatePill / ProfileMenu / theme + lang switches)
// lives in `MainHeader`; this file only renders the breadcrumb
// content via the `breadcrumb` prop.

interface Props {
  /// Click on the `Recordings` breadcrumb returns the user to the
  /// dashboard (parent clears activeId). Optional so the prop can be
  /// dropped later without breaking the file.
  onBackToDashboard?: () => void;
  meetingId: string;
  onDeleted: (id?: string) => void;
  /// Opens the global archive panel — toolbar's Archive button hands off
  /// to this. Archiving the *current* meeting happens via Sidebar's
  /// context menu or via the EmptyDeleteBanner on failed transcripts.
  onOpenArchive: () => void;
  /// Mirrors `archiveOpen` from parent — drives the toolbar Archive
  /// button's `.active` state so a second click leaves the archive
  /// surface (toggle semantics replacing the old "< Library" back).
  archiveOpen?: boolean;
  /// Profile-menu "Settings" handoff — flips the right tab to Settings.
  onOpenSettings: () => void;
  /// Profile-menu "Dashboard" handoff — clears `activeId` upstream.
  onOpenDashboard: () => void;
  /// Bumped whenever the profile menu's Settings item is clicked. The
  /// view watches changes (not value) and flips `rightTab = "settings"`.
  openSettingsNonce: number;
  onToast: (msg: string, kind?: "success" | "error") => void;
  recordingState: RecordingState;
  onRecordingStopped: () => void;
  /// Bumped by the parent whenever THIS meeting is re-transcribed from
  /// the sidebar context menu. Without it the open view never learns a
  /// re-transcribe happened (its local status stays "ready"), so it
  /// never re-polls and the page looked frozen.
  reloadSignal?: number;
  lang: Lang;
  onLangChange: (next: Lang) => void;
  /// Cumulative pointer dx while dragging the transcript/right-panel
  /// divider (negative dx = handle moved left = right panel widens).
  onResizeSplit: (dx: number) => void;
  onResetSplit: () => void;
  /// Fired when this meeting's audio starts/stops so the sidebar can
  /// mark which session the sound is coming from.
  onPlayingChange?: (playing: boolean) => void;
  t: T;
}

export function MeetingView({ meetingId, onDeleted, onOpenArchive, archiveOpen, onOpenSettings, onOpenDashboard, onToast, recordingState, onRecordingStopped, reloadSignal, openSettingsNonce, lang, onLangChange, onResizeSplit, onResetSplit, onPlayingChange, onBackToDashboard, t }: Props) {
  const [detail, setDetail] = React.useState<MeetingDetail | null>(null);
  const [error, setError] = React.useState<string | null>(null);
  const [currentTime, setCurrentTime] = React.useState(0);
  const [search, setSearch] = React.useState("");
  const [rightTab, setRightTab] = React.useState<"recording" | "settings" | "integrations">("recording");
  // Profile-menu Settings handoff: bumping `openSettingsNonce` flips
  // the right tab to settings. Skip the initial mount tick so the
  // first render doesn't auto-open Settings on `openSettingsNonce = 0`.
  const lastSettingsNonceRef = React.useRef(openSettingsNonce);
  React.useEffect(() => {
    if (openSettingsNonce !== lastSettingsNonceRef.current) {
      lastSettingsNonceRef.current = openSettingsNonce;
      setRightTab("settings");
    }
  }, [openSettingsNonce]);
  // Left-column tab: Transcript (default) | Summary. Summary is rendered
  // by `SummaryPane`, which lazily fetches `/summarize` on first open.
  const [leftTab, setLeftTab] = React.useState<"transcript" | "summary">("transcript");
  // Speakers-clarify banner visibility — controlled here so the toolbar
  // icon button can toggle it. Auto-opens once per meeting if the diarizer
  // looks over-segmented and the user hasn't already dismissed for this id.
  const [clarifyOpen, setClarifyOpen] = React.useState(false);
  const videoRef = React.useRef<HTMLVideoElement>(null);

  // Report play/pause of this meeting's media (videoRef is the master
  // clock element) up so the sidebar can flag the playing session.
  // Re-attaches once `detail` loads (by then RightPanel is mounted and
  // the ref is set); cleanup on meeting switch/unmount clears the flag.
  React.useEffect(() => {
    const el = videoRef.current;
    if (!el || !onPlayingChange) return;
    const sync = () => onPlayingChange(!el.paused && !el.ended);
    el.addEventListener("play", sync);
    el.addEventListener("pause", sync);
    el.addEventListener("ended", sync);
    el.addEventListener("emptied", sync);
    sync();
    return () => {
      el.removeEventListener("play", sync);
      el.removeEventListener("pause", sync);
      el.removeEventListener("ended", sync);
      el.removeEventListener("emptied", sync);
      onPlayingChange(false);
    };
  }, [onPlayingChange, detail?.id]);

  // Inline rename of the open meeting via the header breadcrumb title.
  // `null` = not editing; a string = the in-progress edit value.
  const [titleEdit, setTitleEdit] = React.useState<string | null>(null);
  const commitTitle = async () => {
    if (titleEdit === null) return;
    const v = titleEdit.trim();
    setTitleEdit(null);
    try {
      await renameMeeting(meetingId, v);
      setDetail((d) => (d ? { ...d, title: v || null } : d));
      onToast(t.settings_saved, "success");
    } catch {
      onToast(t.toast_settings_failed, "error");
    }
  };

  const load = React.useCallback(async () => {
    setError(null);
    try { setDetail(await getMeeting(meetingId)); }
    catch (e) { setError(String(e)); }
  }, [meetingId]);

  // Show the skeleton on the very first load; on subsequent meeting
  // switches we KEEP the previous detail visible until the new one
  // arrives so the user doesn't see the layout strobe through a
  // skeleton on every sidebar click.
  const [showLoading, setShowLoading] = React.useState(true);
  React.useEffect(() => {
    // Reset only the UI bits that are scoped to a meeting (search
    // input, clarify banner). DO NOT setDetail(null) — clearing it
    // pops the skeleton on every click ("прогрузка всех элементов"
    // bug). The previous detail stays on screen until `load()` swaps
    // it for the new one; a stale 50-100 ms preview beats a blank
    // skeleton flash.
    setSearch("");
    setClarifyOpen(false);
    setTitleEdit(null);
    load();
  }, [load]);
  // Hide the skeleton as soon as the first detail arrives. After
  // that it stays hidden for the rest of this MeetingView's lifetime
  // (subsequent switches keep the prior detail visible).
  React.useEffect(() => {
    if (detail) setShowLoading(false);
  }, [detail]);

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

  // A re-transcribe was just kicked off for THIS meeting. Optimistically
  // flip to the "transcribing" state: gives instant feedback (the
  // Transcribing banner) AND engages the status-based poll below, which
  // then auto-refreshes to the new transcript when the backend finishes
  // (cache-hit re-map ≈1 s, full re-run longer). Skip the initial mount
  // so opening a meeting doesn't fake-transcribe it.
  const firstReloadSignal = React.useRef(reloadSignal);
  React.useEffect(() => {
    if (reloadSignal === undefined) return;
    if (reloadSignal === firstReloadSignal.current) return;
    setDetail((d) => (d ? { ...d, status: "transcribing" } : d));
    load();
  }, [reloadSignal, load]);

  React.useEffect(() => {
    if (!detail) return;
    // Re-poll while a transcription or recording is in flight.
    if (detail.status === "transcribing" || detail.status === "recording") {
      const t = setInterval(load, 2000);
      return () => clearInterval(t);
    }
  }, [detail, load]);

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

  return (
    <>
      <MainHeader
        breadcrumb={(
          <>
            <span
              className="breadcrumb-root"
              onClick={onBackToDashboard}
              role={onBackToDashboard ? "button" : undefined}
              tabIndex={onBackToDashboard ? 0 : undefined}
            >
              {t.breadcrumb_dashboard}
            </span>
            <span style={{ opacity: 0.4 }}>›</span>
            {titleEdit !== null ? (
              <input
                className="breadcrumb-edit"
                autoFocus
                value={titleEdit}
                placeholder={formatDate(detail.started_at, lang)}
                onChange={(e) => setTitleEdit(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") { e.preventDefault(); commitTitle(); }
                  else if (e.key === "Escape") { e.preventDefault(); setTitleEdit(null); }
                }}
                onBlur={commitTitle}
              />
            ) : (
              <span
                className={"breadcrumb-current breadcrumb-rename" + (detail.status === "failed" ? " failed" : "")}
                title={t.ctx_rename}
                onClick={() => setTitleEdit(detail.title?.trim() ?? "")}
              >
                {detail.title?.trim() || formatDate(detail.started_at, lang)}
              </span>
            )}
          </>
        )}
        onOpenArchive={onOpenArchive}
        archiveOpen={archiveOpen}
        onOpenSettings={onOpenSettings}
        onOpenDashboard={onOpenDashboard}
        lang={lang}
        onLangChange={onLangChange}
        onToast={onToast}
        t={t}
      />
      <div className="detail">
        <ResizeHandle
          className="resizer-split"
          onDrag={onResizeSplit}
          onReset={onResetSplit}
        />
        <div className="detail-tabs">
          <div className="detail-tab-col detail-tab-col-left">
            <span
              className={"tab" + (leftTab === "transcript" ? " active" : "")}
              onClick={() => setLeftTab("transcript")}
            >
              {t.tab_transcript}
            </span>
            <span
              className={"tab" + (leftTab === "summary" ? " active" : "")}
              onClick={() => setLeftTab("summary")}
            >
              {t.tab_summary}
            </span>
          </div>
          <div className="detail-tab-col detail-tab-col-right">
            <span
              className={"tab" + (rightTab === "recording" ? " active" : "")}
              onClick={() => setRightTab("recording")}
            >
              {t.audio_card_title}
            </span>
            <span
              className={"tab" + (rightTab === "settings" ? " active" : "")}
              onClick={() => setRightTab("settings")}
            >
              {t.tab_settings}
            </span>
            {/* Integrations tab hidden for now — `IntegrationsPane`
                kept around so wiring it back is a one-line toggle. */}
          </div>
        </div>
        <div className="detail-body">
          {/* Transcript and Summary share the left column. Like the
              right-pane panels, both stay MOUNTED across left-tab
              switches (display toggled, not unmounted) — TranscriptPane
              keeps its scroll position, SummaryPane keeps its
              already-fetched markdown without re-firing /summarize. */}
          <div
            className="transcript-wrap"
            style={{ display: leftTab === "transcript" ? "flex" : "none" }}
          >
            <div className="transcript-toolbar">
              <div className="search-field">
                <Search size={14} strokeWidth={2} />
                <input
                  type="search"
                  placeholder={t.transcript_search}
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                />
              </div>
              <span className="toolbar-sep" />
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
              <button
                className="toolbar-icon-btn"
                onClick={onCopy}
                disabled={detail.segments.length === 0}
                title={t.btn_copy}
                aria-label={t.btn_copy}
              >
                <Copy size={16} strokeWidth={2} />
              </button>
            </div>
            <TranscriptPane
              detail={detail}
              currentTimeSec={currentTime}
              onSeek={onSeek}
              onSpeakersUpdated={load}
              query={search}
              boostOn={false}
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
          {/* Summary occupies the SAME grid cell as `.transcript-wrap`
              above — they're siblings inside `.detail-body` but only
              one is `display: flex` at a time. Mount-stable so the
              fetched markdown survives a flip back to Transcript. */}
          <div
            className="transcript-wrap summary-wrap-host"
            style={{ display: leftTab === "summary" ? "flex" : "none" }}
          >
            <SummaryPane detail={detail} onToast={onToast} t={t} />
          </div>
          {/* All three right-pane panels stay MOUNTED across tab
              switches (display toggled, not unmounted) — RightPanel
              keeps its <video>/<audio> alive, SettingsPane keeps its
              loaded toggle state (no more "loading" flash on every
              switch back to Settings), Integrations is dirt cheap
              either way. */}
          <div style={{ display: rightTab === "recording" ? "contents" : "none" }}>
            <RightPanel
              detail={detail}
              videoRef={videoRef}
              onTimeUpdate={setCurrentTime}
              currentTimeSec={currentTime}
              onSeek={onSeek}
              t={t}
            />
          </div>
          <div style={{ display: rightTab === "settings" ? "contents" : "none" }}>
            <SettingsPane t={t} />
          </div>
          {/* IntegrationsPane mount disabled while the tab is
              hidden (see the comment in the tab strip above). */}
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
