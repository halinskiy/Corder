import React from "react";
import { MeetingDetail, SegmentDTO, SpeakerDTO, RecordingState, renameSpeaker, getSettings,
  editSegmentText } from "../api";
import { displaySpeakerName } from "../format";
import { RecordingBanner } from "./RecordingBanner";
import { RecordingPlaceholder } from "./RecordingPlaceholder";
import { TranscribingBanner } from "./TranscribingBanner";
import { SpeakersClarifyBanner } from "./SpeakersClarifyBanner";
import { EmptyDeleteBanner } from "./EmptyDeleteBanner";
import { RatingBanner } from "./RatingBanner";
import { OverlayScrollbar } from "./OverlayScrollbar";
import type { T } from "../i18n";

// ──────────────────────────────────────────────────────────────────
// Rating prompt state — surfaced once the user has seen N transcripts
// so we ask for feedback only after they have actually used Corder.
// All state lives in localStorage; no server round-trip until the
// user clicks Send.
// ──────────────────────────────────────────────────────────────────
type RatingState = {
  state: "pending" | "submitted" | "dismissed";
  dismissedAt?: number;
  transcriptsViewed: number;
};

const RATING_STATE_KEY = "corder.ratingPromptState";
const RATING_SEEN_KEY = "corder.ratingPromptSeenIds";
const RATING_SHOWN_FOR_KEY = "corder.ratingPromptShownForId";
// Show once the user has read 3 distinct ready transcripts —
// the first 1-2 might just be tests, and we don't want to ask
// for feedback on a 5-second smoke recording.
const RATING_THRESHOLD = 1;
const RATING_API_URL = "https://corder-api.empqwork.workers.dev/feedback";
// Bumped manually when the native shell version moves. The wizard
// already POSTs `version` to /signup so once we wire it through the
// Swift bridge we can drop the hardcode; until then it stays in sync
// with `Info.plist`.
const RATING_APP_VERSION = "0.13.10";

function readRatingState(): RatingState {
  try {
    const raw = localStorage.getItem(RATING_STATE_KEY);
    if (!raw) return { state: "pending", transcriptsViewed: 0 };
    const parsed = JSON.parse(raw) as RatingState;
    if (!parsed || typeof parsed.transcriptsViewed !== "number") {
      return { state: "pending", transcriptsViewed: 0 };
    }
    return parsed;
  } catch {
    return { state: "pending", transcriptsViewed: 0 };
  }
}

function writeRatingState(s: RatingState) {
  try { localStorage.setItem(RATING_STATE_KEY, JSON.stringify(s)); } catch {}
}

function readSeenIds(): Set<string> {
  try {
    const raw = localStorage.getItem(RATING_SEEN_KEY);
    if (!raw) return new Set();
    const arr = JSON.parse(raw) as unknown;
    if (!Array.isArray(arr)) return new Set();
    return new Set(arr.filter((x) => typeof x === "string"));
  } catch {
    return new Set();
  }
}

function writeSeenIds(ids: Set<string>) {
  try { localStorage.setItem(RATING_SEEN_KEY, JSON.stringify(Array.from(ids))); } catch {}
}

function shouldShowRatingBanner(s: RatingState, currentMeetingId: string): boolean {
  // Submitted OR dismissed → never again, full stop. Per Kostya's
  // call: a single rating prompt per user, ever; once they engage
  // (good or skip) we leave them alone.
  if (s.state === "submitted") return false;
  if (s.state === "dismissed") return false;
  if (s.transcriptsViewed < RATING_THRESHOLD) return false;
  // Pin the prompt to the FIRST meeting it appeared on so opening
  // the SAME meeting later or revisiting OTHER meetings doesn't
  // re-render it. Mounted once on its anchor meeting; if the
  // anchor meeting goes away the prompt is gone with it.
  let pinned: string | null = null;
  try { pinned = localStorage.getItem(RATING_SHOWN_FOR_KEY); } catch {}
  if (pinned === null) {
    try { localStorage.setItem(RATING_SHOWN_FOR_KEY, currentMeetingId); } catch {}
    return true;
  }
  return pinned === currentMeetingId;
}

interface Props {
  detail: MeetingDetail;
  currentTimeSec: number;
  onSeek: (sec: number) => void;
  onSpeakersUpdated: () => void;
  query: string;
  /// The segment id of the CURRENT search match (cmd+F-style nav). The
  /// pane scrolls it into view and emphasises it; all matches stay
  /// highlighted, nothing is filtered out.
  activeMatchId?: number | null;
  boostOn: boolean;
  recordingState: RecordingState;
  onRecordingStopped: () => void;
  onDeleted: (id: string) => void;
  clarifyOpen: boolean;
  onClarifyDismiss: () => void;
  onClarifyChosen: () => void;
  onToast: (msg: string, kind?: "success" | "error") => void;
  t: T;
}

export function TranscriptPane({ detail, currentTimeSec, onSeek, onSpeakersUpdated, query, activeMatchId, boostOn, recordingState, onRecordingStopped, onDeleted, clarifyOpen, onClarifyDismiss, onClarifyChosen, onToast, t }: Props) {
  const speakerById = React.useMemo(() => {
    const map = new Map<string, SpeakerDTO>();
    detail.speakers.forEach((s) => map.set(s.id, s));
    return map;
  }, [detail.speakers]);

  // Signed-in user's display name — used to replace the "you" /
  // "I" first-person placeholders the Swift pipeline writes into the
  // user speaker's `custom_name` so the transcript reads with the
  // user's real identity, not a placeholder.
  const [profileName, setProfileName] = React.useState<string | null>(null);
  React.useEffect(() => {
    let alive = true;
    getSettings().then((s) => { if (alive) setProfileName((s.user_name ?? "").trim() || null); }).catch(() => {});
    return () => { alive = false; };
  }, [detail.id]);

  // ── Right-click transcript editing ──────────────────────────────
  // Single action: right-click a line to edit its text. Speaker
  // reassignment / merge were intentionally dropped — with mislabelled
  // "Speaker 2/3/4" the user can't tell which is which, so those actions
  // only created confusion.
  const [editing, setEditing] = React.useState<{ segId: number; value: string } | null>(null);
  // Editing only makes sense on a finished transcript.
  const canEdit = detail.status === "ready";
  const startEdit = (e: React.MouseEvent, segId: number, currentText: string) => {
    if (!canEdit) return;
    e.preventDefault(); e.stopPropagation();
    setEditing({ segId, value: currentText });
  };
  const saveEdit = async () => {
    const ed = editing;
    setEditing(null);
    if (!ed) return;
    const v = ed.value.trim();
    if (!v) return;
    try { await editSegmentText(detail.id, ed.segId, v); onSpeakersUpdated(); }
    catch { onToast?.(t.edit_failed ?? "Couldn't save the edit"); }
  };

  // Rating prompt: count UNIQUE ready-with-segments transcripts the
  // user has seen, surface the banner once we cross the threshold.
  // `ratingState` is mirrored in component state so onSubmit/onDismiss
  // hide the banner immediately without a remount; localStorage is
  // the source of truth across sessions.
  const [ratingState, setRatingState] = React.useState<RatingState>(() => readRatingState());
  React.useEffect(() => {
    if (detail.status !== "ready" || detail.segments.length === 0) return;
    const seen = readSeenIds();
    if (seen.has(detail.id)) return;
    seen.add(detail.id);
    writeSeenIds(seen);
    setRatingState((prev) => {
      // Already submitted? Stop counting. Counting forever leaks
      // localStorage and serves no purpose.
      if (prev.state === "submitted") return prev;
      const next: RatingState = { ...prev, transcriptsViewed: prev.transcriptsViewed + 1 };
      writeRatingState(next);
      return next;
    });
  }, [detail.id, detail.status, detail.segments.length]);

  const showRating = shouldShowRatingBanner(ratingState, detail.id);

  const handleRatingSubmit = React.useCallback((rating: number, comment: string) => {
    // Fire-and-forget so the UI flips instantly. The signed-in
    // user's email comes from /api/settings (best-effort: anonymous
    // if not signed in or the call fails). We don't await the
    // response — the user has already seen "Thanks!" via the toast.
    void (async () => {
      let email: string | null = null;
      try {
        const s = await getSettings();
        email = (s.user_email ?? null) || null;
      } catch { /* anonymous */ }
      const body = JSON.stringify({ rating, comment, email, source: "corder-mac", version: RATING_APP_VERSION });
      void fetch(RATING_API_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body,
      }).catch(() => { /* swallow */ });
    })();
    const next: RatingState = { state: "submitted", transcriptsViewed: ratingState.transcriptsViewed };
    writeRatingState(next);
    setRatingState(next);
    onToast(t.rating_thanks || "Thanks for the feedback!", "success");
  }, [onToast, ratingState.transcriptsViewed, t]);

  const handleRatingDismiss = React.useCallback(() => {
    const next: RatingState = {
      state: "dismissed",
      dismissedAt: Date.now(),
      transcriptsViewed: ratingState.transcriptsViewed,
    };
    writeRatingState(next);
    setRatingState(next);
  }, [ratingState.transcriptsViewed]);

  // Group consecutive segments by the same speaker for paragraph layout.
  const groups = React.useMemo(() => {
    const out: { speakerId: string; segs: SegmentDTO[] }[] = [];
    for (const s of detail.segments) {
      const last = out[out.length - 1];
      if (last && last.speakerId === s.speaker_id) last.segs.push(s);
      else out.push({ speakerId: s.speaker_id, segs: [s] });
    }
    return out;
  }, [detail.segments]);

  // Search no longer FILTERS the transcript — it highlights matches in
  // place (cmd+F style). The toolbar drives which match is current via
  // `activeMatchId`; we just scroll to it and emphasise it below.
  const q = query.trim().toLowerCase();

  // The segment that is currently playing = the LAST one whose
  // start_ms is at/before now. The old half-open test
  // (`t >= start && t < end`) broke on click-to-seek: the click sends
  // `start_ms / 1000` seconds, the round-trip back to ms lands a hair
  // BELOW start_ms (float error), so the clicked segment failed
  // `t >= start` while the previous one still passed `t < end` — the
  // green highlight landed one line ABOVE the click. `Math.round`
  // kills the epsilon; "last started" also keeps the highlight stable
  // through the silent gaps between segments instead of vanishing.
  const activeSegmentId = React.useMemo(() => {
    // Find the last segment whose start_ms <= playhead. Segments are
    // monotonic by start_ms, so a binary search gives the identical
    // result as the old linear scan in O(log n) — this recomputes on
    // every playback tick (~tens of times/second), so the scan added up
    // on long transcripts.
    const tms = Math.round(currentTimeSec * 1000);
    const segs = detail.segments;
    let lo = 0, hi = segs.length - 1, idx = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (segs[mid].start_ms <= tms) { idx = mid; lo = mid + 1; }
      else hi = mid - 1;
    }
    return idx >= 0 ? segs[idx].id : null;
  }, [currentTimeSec, detail.segments]);

  // Scroll the current search match into view (cmd+F-style anchoring).
  // Separate from the playback auto-scroll below; fires only when the
  // toolbar moves the active match.
  const containerRef = React.useRef<HTMLDivElement | null>(null);
  React.useEffect(() => {
    if (!activeMatchId || !containerRef.current) return;
    const el = containerRef.current.querySelector<HTMLElement>(`[data-segid="${activeMatchId}"]`);
    if (el) el.scrollIntoView({ block: "center", behavior: "smooth" });
  }, [activeMatchId]);

  React.useEffect(() => {
    if (!activeSegmentId || !containerRef.current) return;
    const el = containerRef.current.querySelector<HTMLElement>(`[data-segid="${activeSegmentId}"]`);
    if (el) el.scrollIntoView({ block: "center", behavior: "smooth" });
  }, [activeSegmentId]);

  // When the clarify banner opens, glide the transcript to the top so the
  // user actually sees the card that just appeared. Without this, opening
  // the banner mid-scroll silently expands a region above the viewport
  // and reads as "the button does nothing".
  React.useEffect(() => {
    if (clarifyOpen) {
      containerRef.current?.scrollTo({ top: 0, behavior: "smooth" });
    }
  }, [clarifyOpen]);

  // While the active recording is the one we're viewing, replace the empty
  // "Идёт запись…" placeholder with a live status card that includes a Stop
  // button — same layout as the popover's RecordingStatus block.
  const isLiveRecording =
    detail.status === "recording" &&
    recordingState.active &&
    recordingState.meeting_id === detail.id;

  // Recording / transcribing states take over the pane EVEN IF old
  // segments still exist. A re-transcribe of an already-ready meeting
  // keeps the previous transcript in the DB until the new run succeeds,
  // so we must key the live banner off status, not an empty list —
  // otherwise the user would stare at the stale transcript with no sign
  // that a new run is underway.
  if (isLiveRecording) {
    return (
      <div className="transcript ovsb-scroll" ref={containerRef}>
        <RecordingBanner state={recordingState} onStopped={onRecordingStopped} onToast={onToast} t={t} />
      </div>
    );
  }
  if (detail.status === "recording") {
    // Stopped but the pipeline hasn't flipped to transcribing yet — hold
    // the rec-card so the UI doesn't flash a text placeholder.
    return (
      <div className="transcript ovsb-scroll" ref={containerRef}>
        <RecordingPlaceholder t={t} />
      </div>
    );
  }
  if (detail.status === "transcribing") {
    return (
      <div className="transcript ovsb-scroll" ref={containerRef}>
        <TranscribingBanner
          meetingId={detail.id}
          startedAtMs={detail.transcribing_started_at ?? null}
          durationMs={detail.duration_ms ?? null}
          progress={detail.transcribe_progress ?? null}
          modelDownloadProgress={detail.model_download_progress ?? null}
          modelPreparing={detail.model_preparing ?? false}
          onCancelled={onRecordingStopped}
          onToast={onToast}
          t={t}
        />
      </div>
    );
  }

  // No transcript at all (and not recording/transcribing) → the empty /
  // failed banner. When a FAILED meeting still HAS segments (an
  // interrupted re-transcribe), we fall through to render that previous
  // transcript below; the red header/sidebar still mark it failed.
  if (detail.segments.length === 0) {
    return (
      <div className="transcript ovsb-scroll" ref={containerRef}>
        {detail.status === "ready" || detail.status === "failed" ? (
          <EmptyDeleteBanner
            meetingId={detail.id}
            onDeleted={onDeleted}
            failed={detail.status === "failed"}
            onRetranscribed={onSpeakersUpdated}
            onToast={onToast}
            t={t}
          />
        ) : (
          <div className="transcript-empty">{t.transcript_empty_recording}</div>
        )}
      </div>
    );
  }

  // The clarify banner is now driven by the parent (MeetingView) so the
  // toolbar's icon button can toggle it on/off with the same source of
  // truth. The local component only renders the wrapper that animates
  // its max-height in and out.

  return (
    <div className="transcript ovsb-scroll" ref={containerRef}>
      {clarifyOpen && (
        // Mounted/unmounted directly. We tried wrapping it in a max-height
        // collapsible and a grid-rows collapsible — both leaked the banner's
        // own padding/border as 28-30 px of dead space when closed, because
        // the wrapper sits inside `.transcript`'s flex column with `gap: 28px`
        // and an item that close-to-zero still attracts a gap on each side.
        // Conditional render is the cleanest fix: when the user dismisses,
        // the gap goes away because the element goes away.
        <SpeakersClarifyBanner
          meetingId={detail.id}
          pickedOthers={detail.expected_other_speakers ?? null}
          onChanged={onClarifyChosen}
          onDismiss={onClarifyDismiss}
          onToast={onToast}
          t={t}
        />
      )}
      {groups.map((g, gi) => {
        const sp = speakerById.get(g.speakerId);
        const name = displaySpeakerName(sp?.custom_name, sp?.label, profileName);
        const color = avatarColor(name);
        return (
          <div key={gi} className="segment-group">
            <div className="segment-head">
              <div className="speaker-avatar" style={{ background: color }}>
                {initial(name)}
              </div>
              <SpeakerName
                meetingId={detail.id}
                speaker={sp}
                display={name === "you" ? t.speaker_self : name}
                onUpdated={onSpeakersUpdated}
                t={t}
              />
            </div>
            <div className="segment-paragraph">
              {g.segs.map((s, i) => {
                const display = cleanSegmentText(boostOn && s.text_boost ? s.text_boost : s.text);
                if (editing && s.id === editing.segId) {
                  return (
                    <React.Fragment key={s.id}>
                      <input
                        className="segment-edit-input"
                        value={editing.value}
                        autoFocus
                        onChange={(e) => setEditing({ segId: editing.segId, value: e.target.value })}
                        onKeyDown={(e) => {
                          if (e.key === "Enter") { e.preventDefault(); saveEdit(); }
                          else if (e.key === "Escape") { e.preventDefault(); setEditing(null); }
                        }}
                        onBlur={saveEdit}
                        onClick={(e) => e.stopPropagation()}
                      />
                      {i < g.segs.length - 1 ? " " : ""}
                    </React.Fragment>
                  );
                }
                return (
                  <React.Fragment key={s.id}>
                    <span
                      data-segid={s.id}
                      className={"segment-line"
                        + (s.id === activeSegmentId ? " active" : "")
                        + (q && s.id === activeMatchId ? " search-hit" : "")}
                      onClick={() => onSeek(s.start_ms / 1000)}
                      onContextMenu={(e) => s.id != null && startEdit(e, s.id, display)}
                    >
                      {highlight(display, q)}
                    </span>
                    {i < g.segs.length - 1 ? " " : ""}
                  </React.Fragment>
                );
              })}
            </div>
          </div>
        );
      })}
      {showRating && (
        <RatingBanner
          t={t}
          onSubmit={handleRatingSubmit}
          onDismiss={handleRatingDismiss}
        />
      )}
      <div className="transcript-spacer" />
      <OverlayScrollbar scrollRef={containerRef} name="corder-sb-transcript" />
    </div>
  );
}

function initial(name: string): string {
  const parts = name.trim().split(/\s+/);
  if (parts.length === 1) return parts[0][0]?.toUpperCase() || "?";
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

const PALETTE = [
  "#5a3aa6", // purple
  "#1f7a4f", // green
  "#b03a3a", // red
  "#1a4f8a", // blue
  "#7a4f1a", // orange-brown
];
function avatarColor(name: string): string {
  let h = 0;
  for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) >>> 0;
  return PALETTE[h % PALETTE.length];
}

// Whisper/WhisperKit artefacts that survive the server-side whole-segment
// hallucination filter: a lone leading punctuation mark (". Ну, …") and a
// YouTube-style outro appended over trailing silence ("…до связи. Thank
// you."). Strip both for display so the transcript reads clean. Leading
// strip is punctuation-only (keeps dialogue dashes/quotes); trailing strip
// targets the specific Whisper outros, anchored to the end.
const TRAILING_OUTRO =
  /(?:[\s.,!?…]*\b(?:thank you(?: very much| so much)?(?: for watching)?|thanks(?: for watching)?|see you (?:next time|in the next (?:video|one))|have a (?:nice|good|great|wonderful) day)\b[\s.!?…]*)+$/iu;
// Whisper/WhisperKit loop hallucination: a short phrase repeated back-to-back
// ("Bye-bye. Bye-bye. Bye-bye.", "Спасибо. Спасибо. Спасибо."). Real speech
// almost never repeats a SHORT phrase 3+ times verbatim, so collapse such a run
// to a single instance. Conservative on purpose (short phrase + ≥3 repeats)
// so emphatic "No. No." or a repeated long sentence is left untouched. Display
// only — the stored transcript is unchanged.
function collapseRepeatHallucination(s: string): string {
  const parts = s.match(/[^.!?…]+[.!?…]*\s*/gu);
  if (!parts || parts.length < 3) return s;
  const norm = (p: string) => p.trim().toLowerCase().replace(/[\s.!?…,]+$/u, "");
  const out: string[] = [];
  let i = 0;
  while (i < parts.length) {
    const key = norm(parts[i]);
    let j = i + 1;
    while (j < parts.length && norm(parts[j]) === key) j++;
    if (j - i >= 3 && key.length > 0 && key.length <= 30) {
      out.push(parts[i]); // keep one
    } else {
      for (let k = i; k < j; k++) out.push(parts[k]);
    }
    i = j;
  }
  return out.join("").trim();
}
function cleanSegmentText(t: string): string {
  let s = t.trim();
  s = s.replace(/^[\s.,;:!?·•*]+/u, "");
  s = s.replace(TRAILING_OUTRO, "").trim();
  s = collapseRepeatHallucination(s);
  return s;
}

function highlight(text: string, q: string): React.ReactNode {
  if (!q) return text;
  const lower = text.toLowerCase();
  const out: React.ReactNode[] = [];
  let i = 0;
  while (i < text.length) {
    const idx = lower.indexOf(q, i);
    if (idx < 0) { out.push(text.slice(i)); break; }
    if (idx > i) out.push(text.slice(i, idx));
    out.push(<mark key={idx} className="tp-hl">{text.slice(idx, idx + q.length)}</mark>);
    i = idx + q.length;
  }
  return out;
}

interface SpeakerNameProps {
  meetingId: string;
  speaker: SpeakerDTO | undefined;
  display: string;
  onUpdated: () => void;
  t: T;
}

function SpeakerName({ meetingId, speaker, display, onUpdated, t }: SpeakerNameProps) {
  const [editing, setEditing] = React.useState(false);
  const [draft, setDraft] = React.useState(speaker?.custom_name || "");
  const inputRef = React.useRef<HTMLInputElement | null>(null);

  React.useEffect(() => { if (editing) inputRef.current?.focus(); }, [editing]);

  if (!speaker) return <span className="speaker-name">{display}</span>;

  if (editing) {
    return (
      <input
        ref={inputRef}
        className="inline-editor"
        value={draft}
        placeholder={t.inline_editor_placeholder}
        onChange={(e) => setDraft(e.target.value)}
        onBlur={async () => {
          setEditing(false);
          const trimmed = draft.trim();
          const next = trimmed.length === 0 ? null : trimmed;
          if (next !== (speaker.custom_name || null)) {
            try { await renameSpeaker(meetingId, speaker.id, next); onUpdated(); } catch {}
          }
        }}
        onKeyDown={(e) => {
          if (e.key === "Enter") (e.target as HTMLInputElement).blur();
          if (e.key === "Escape") { setDraft(speaker.custom_name || ""); setEditing(false); }
        }}
      />
    );
  }
  return (
    <span
      className="speaker-name editable"
      onClick={() => { setDraft(speaker.custom_name || ""); setEditing(true); }}
      title={t.speaker_rename_title}
    >
      {display}
    </span>
  );
}
