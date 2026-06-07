import React from "react";
import { MeetingDetail, SegmentDTO, SpeakerDTO, RecordingState, renameSpeaker, getSettings } from "../api";
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

export function TranscriptPane({ detail, currentTimeSec, onSeek, onSpeakersUpdated, query, boostOn, recordingState, onRecordingStopped, onDeleted, clarifyOpen, onClarifyDismiss, onClarifyChosen, onToast, t }: Props) {
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

  // Filter when search query is set: hide groups with no matching segment.
  const q = query.trim().toLowerCase();
  const filteredGroups = React.useMemo(() => {
    if (!q) return groups;
    return groups.filter((g) => g.segs.some((s) => s.text.toLowerCase().includes(q)));
  }, [groups, q]);

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
    const tms = Math.round(currentTimeSec * 1000);
    let active: number | null = null;
    for (const s of detail.segments) {
      if (s.start_ms <= tms) active = s.id;
      else break;            // segments are monotonic by start_ms
    }
    return active;
  }, [currentTimeSec, detail.segments]);

  const containerRef = React.useRef<HTMLDivElement | null>(null);
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

  if (detail.segments.length === 0) {
    return (
      <div className="transcript ovsb-scroll" ref={containerRef}>
        {isLiveRecording ? (
          <RecordingBanner
            state={recordingState}
            onStopped={onRecordingStopped}
            onToast={onToast}
            t={t}
          />
        ) : detail.status === "recording" ? (
          // Recording session that isn't currently live (we already pressed
          // Stop and the pipeline hasn't yet flipped status to transcribing).
          // Hold the rec-card visual so the UI doesn't flash a text-only
          // placeholder during that race window.
          <RecordingPlaceholder t={t} />
        ) : detail.status === "transcribing" ? (
          <TranscribingBanner
            meetingId={detail.id}
            startedAtMs={detail.transcribing_started_at ?? null}
            durationMs={detail.duration_ms ?? null}
            onCancelled={onRecordingStopped}
            onToast={onToast}
            t={t}
          />
        ) : detail.status === "ready" || detail.status === "failed" ? (
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
      {filteredGroups.map((g, gi) => {
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
                const display = boostOn && s.text_boost ? s.text_boost : s.text;
                return (
                  <React.Fragment key={s.id}>
                    <span
                      data-segid={s.id}
                      className={"segment-line" + (s.id === activeSegmentId ? " active" : "")}
                      onClick={() => onSeek(s.start_ms / 1000)}
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
      {filteredGroups.length === 0 && q && (
        <div className="transcript-empty">{t.transcript_no_match(q)}</div>
      )}
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
