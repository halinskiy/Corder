import React from "react";
import { MeetingDetail, SegmentDTO, SpeakerDTO, RecordingState, renameSpeaker } from "../api";
import { RecordingBanner } from "./RecordingBanner";
import { RecordingPlaceholder } from "./RecordingPlaceholder";
import { TranscribingBanner } from "./TranscribingBanner";
import { SpeakersClarifyBanner } from "./SpeakersClarifyBanner";
import { EmptyDeleteBanner } from "./EmptyDeleteBanner";
import type { T } from "../i18n";

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

  const activeSegmentId = React.useMemo(() => {
    const t = currentTimeSec * 1000;
    for (const s of detail.segments) {
      if (t >= s.start_ms && t < s.end_ms) return s.id;
    }
    return null;
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
      <div className="transcript" ref={containerRef}>
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
    <div className="transcript" ref={containerRef}>
      <div className={"clarify-collapsible" + (clarifyOpen ? " open" : "")}>
        <SpeakersClarifyBanner
          meetingId={detail.id}
          currentOthers={
            detail.expected_other_speakers ?? Math.max(0, detail.speakers.length - 1)
          }
          onChanged={onClarifyChosen}
          onDismiss={onClarifyDismiss}
          onToast={onToast}
          t={t}
        />
      </div>
      {filteredGroups.map((g, gi) => {
        const sp = speakerById.get(g.speakerId);
        const name = sp?.custom_name?.trim() || sp?.label || "Speaker";
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
      <div className="transcript-spacer" />
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
    out.push(<mark key={idx} style={{ background: "#cdebd9", color: "inherit", padding: 0 }}>{text.slice(idx, idx + q.length)}</mark>);
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
