import React from "react";
import { Copy, Trash2, Globe, Users } from "lucide-react";
import { MeetingDetail, RecordingState, getMeeting, getTranscriptText, getLastError } from "../api";
import type { Lang, T } from "../i18n";

const CLARIFY_DISMISS_KEY = "corder.clarify_dismissed";

function isClarifyDismissed(meetingId: string): boolean {
  try {
    const arr: string[] = JSON.parse(localStorage.getItem(CLARIFY_DISMISS_KEY) || "[]");
    return arr.includes(meetingId);
  } catch { return false; }
}

function persistClarifyDismiss(meetingId: string) {
  try {
    const arr: string[] = JSON.parse(localStorage.getItem(CLARIFY_DISMISS_KEY) || "[]");
    if (!arr.includes(meetingId)) arr.push(meetingId);
    localStorage.setItem(CLARIFY_DISMISS_KEY, JSON.stringify(arr));
  } catch {}
}

function clearClarifyDismiss(meetingId: string) {
  try {
    const arr: string[] = JSON.parse(localStorage.getItem(CLARIFY_DISMISS_KEY) || "[]");
    const next = arr.filter((x) => x !== meetingId);
    localStorage.setItem(CLARIFY_DISMISS_KEY, JSON.stringify(next));
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
  onToast: (msg: string, kind?: "success" | "error") => void;
  recordingState: RecordingState;
  onRecordingStopped: () => void;
  boostMode: boolean;
  onBoostModeChange: (next: boolean) => void;
  lang: Lang;
  onLangChange: (next: Lang) => void;
  t: T;
}

export function MeetingView({ meetingId, onDeleted, onToast, recordingState, onRecordingStopped, boostMode, onBoostModeChange, lang, onLangChange, t }: Props) {
  const [detail, setDetail] = React.useState<MeetingDetail | null>(null);
  const [error, setError] = React.useState<string | null>(null);
  const [currentTime, setCurrentTime] = React.useState(0);
  const [search, setSearch] = React.useState("");
  // Speakers-clarify banner visibility, controlled here so the toolbar
  // icon button can toggle it. Auto-opens once per meeting if the diarizer
  // looks over-segmented and the user hasn't already dismissed for this id.
  const [clarifyOpen, setClarifyOpen] = React.useState(false);
  const videoRef = React.useRef<HTMLVideoElement>(null);

  const load = React.useCallback(async () => {
    setError(null);
    try { setDetail(await getMeeting(meetingId)); }
    catch (e) { setError(String(e)); }
  }, [meetingId]);

  React.useEffect(() => {
    setDetail(null);
    setSearch("");
    setClarifyOpen(false);
    load();
  }, [load]);

  // Auto-open the clarify banner the first time we see a meeting that the
  // diarizer over-segmented. After that it's user-controlled (toolbar icon
  // toggles, X dismisses, dismissals persist in localStorage).
  React.useEffect(() => {
    if (!detail) return;
    const detected = Math.max(0, detail.speakers.length - 1);
    const auto =
      detail.status === "ready" &&
      (detail.expected_other_speakers === null || detail.expected_other_speakers === undefined) &&
      detected >= 2 &&
      !isClarifyDismissed(detail.id);
    if (auto) setClarifyOpen(true);
  }, [detail?.id, detail?.status, detail?.expected_other_speakers, detail?.speakers.length]);

  const toggleClarify = () => {
    setClarifyOpen((open) => {
      const next = !open;
      // Opening clears any prior dismissal so the banner stays open until
      // either the user picks an option or X-es out again.
      if (next && detail) clearClarifyDismiss(detail.id);
      return next;
    });
  };

  const onClarifyDismiss = () => {
    if (detail) persistClarifyDismiss(detail.id);
    setClarifyOpen(false);
  };

  const onClarifyChosen = () => {
    setClarifyOpen(false);
    load();
  };

  React.useEffect(() => {
    if (!detail) return;
    // Re-poll while a transcription or recording is in flight, or while we're
    // waiting on auto-boost, segments only get text_boost asynchronously.
    const hasBoostNow = detail.segments.some((s) => s.text_boost);
    const awaitingBoost = boostMode && detail.status === "ready" && detail.segments.length > 0 && !hasBoostNow;
    if (detail.status === "transcribing" || detail.status === "recording" || awaitingBoost) {
      const t = setInterval(load, 2000);
      return () => clearInterval(t);
    }
  }, [detail, load, boostMode]);

  // Surface backend transcription errors (Gemini quota / billing, missing
  // key, timeout) as a red toast. Polled once per meeting load, server
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
  if (!detail) return <div className="empty"><div>{t.loading}</div></div>;

  const onSeek = (sec: number) => {
    const v = videoRef.current;
    if (v) {
      // currentTime is only meaningful once metadata has loaded; setting it
      // before that quietly snaps back to 0. Wait for `loadedmetadata` if
      // we're not there yet, then seek + play. play() may reject in some
      // states (e.g. while still loading); we silently ignore, the click
      // counts as a user gesture so the next call usually succeeds.
      const apply = () => {
        try { v.currentTime = sec; } catch {}
        v.play().catch(() => {});
      };
      if (v.readyState >= 1) {
        apply();
      } else {
        v.addEventListener("loadedmetadata", apply, { once: true });
        // Make sure metadata actually loads, `preload="auto"` does this
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

  const onDelete = () => {
    // The actual REST DELETE is scheduled by the parent's `onDeleted`
    // handler with a 10-second Undo window, we just hand it the id.
    onDeleted(detail.id);
  };

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
          <button className="ghost danger" onClick={onDelete}>
            <Trash2 size={14} strokeWidth={2} /> {t.btn_delete}
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
