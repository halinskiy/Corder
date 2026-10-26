import React from "react";
import { getMeeting, type MeetingDetail } from "../api";
import { displaySpeakerName, formatDate, formatDuration } from "../format";
import type { Lang, T } from "../i18n";
import type { MeetingGroup } from "../meetingGroups";
import { OverlayScrollbar } from "./OverlayScrollbar";

type TranscriptState = MeetingDetail | "error";

interface Props {
  group: MeetingGroup;
  onSelect: (id: string) => void;
  onRead: (id: string) => void;
  lang: Lang;
  t: T;
}

export function GroupView({ group, onSelect, onRead, lang, t }: Props) {
  const [details, setDetails] = React.useState<Record<string, TranscriptState>>({});
  const [retry, setRetry] = React.useState(0);
  const scrollRef = React.useRef<HTMLDivElement>(null);
  const wrapRef = React.useRef<HTMLDivElement>(null);
  // Polls change viewed flags, which must not restart this queue or reset the scroll.
  const loadKey = JSON.stringify(group.meetings.map(m => [m.id, m.status]));
  React.useEffect(() => {
    let cancelled = false;
    setDetails({});
    const ids = (JSON.parse(loadKey) as [string, string][]).map(([id]) => id);
    void (async () => {
      for (const id of ids) {
        if (cancelled) break;
        try {
          const detail = await getMeeting(id);
          if (cancelled) break;
          setDetails(prev => ({ ...prev, [id]: detail }));
          if (detail.status === "ready") onRead(id);
        } catch {
          if (cancelled) break;
          setDetails(prev => ({ ...prev, [id]: "error" }));
        }
      }
    })();
    return () => { cancelled = true; };
  }, [loadKey, retry, onRead]);

  return (
    <div className="detail group-view">
      <div className="detail-tabs">
        <div className="detail-tab-col">
          <span className="tab active">{t.tab_transcript}</span>
        </div>
      </div>
      <div className="detail-body">
        <div className="transcript-wrap" ref={wrapRef}>
          <div className="transcript ovsb-scroll" ref={scrollRef}>
            <div className="segment-group group-heading">
              <h1>{group.key}</h1>
              <div className="meeting-meta">
                {t.group_recordings(group.meetings.length)} · {formatDuration(group.durationMs, lang)}
              </div>
            </div>
            {group.meetings.map(meeting => {
              const detail = details[meeting.id];
              return (
                <section className="segment-group group-recording" key={meeting.id}>
                  <h2 className="segment-head">
                    <button className="group-recording-link" onClick={() => onSelect(meeting.id)}>
                      {formatDate(meeting.started_at, lang)} · {formatDuration(meeting.duration_ms, lang)}
                    </button>
                  </h2>
                  {!detail ? <div className="transcript-empty">{t.loading}</div>
                    : detail === "error" ? (
                      <div className="trans-banner clarify-banner">
                        <span className="clarify-body">{t.group_load_failed}</span>
                        <button className="clarify-btn" onClick={() => setRetry(n => n + 1)}>{t.group_retry}</button>
                      </div>
                    ) : detail.segments.length === 0 ? (
                      <div className="transcript-empty">{t.group_empty_transcript}</div>
                    ) : <GroupTranscript detail={detail} t={t} />}
                </section>
              );
            })}
            <div className="transcript-spacer" />
          </div>
          <OverlayScrollbar scrollRef={scrollRef} dividerRef={wrapRef} name="corder-group-feed" />
        </div>
      </div>
    </div>
  );
}

function GroupTranscript({ detail, t }: { detail: MeetingDetail; t: T }) {
  const multiSpeaker = new Set(detail.segments.map(s => s.speaker_id)).size > 1;
  const speakers = new Map(detail.speakers.map(s => [s.id, s]));
  return <>
    {detail.segments.map((segment, index) => {
      const speaker = speakers.get(segment.speaker_id);
      const name = displaySpeakerName(speaker?.custom_name, speaker?.label, null);
      const showSpeaker = multiSpeaker && (index === 0 || detail.segments[index - 1].speaker_id !== segment.speaker_id);
      return (
        <div className="segment-group" key={segment.id}>
          {showSpeaker && (
            <div className="segment-head">
              <div className="speaker-avatar" style={{ background: `var(--speaker-${(detail.speakers.findIndex(s => s.id === segment.speaker_id) + 4) % 4 + 1})` }}>
                {name.slice(0, 1).toUpperCase()}
              </div>
              <span className="speaker-name">{name.toLowerCase() === "you" ? t.speaker_self : name}</span>
            </div>
          )}
          <p className="segment-paragraph">{segment.text}</p>
        </div>
      );
    })}
  </>;
}
