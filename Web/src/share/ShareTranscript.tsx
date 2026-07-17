import React from "react";
import type { MeetingDetail } from "../api";
import { displaySpeakerName } from "../format";

/// The transcript, as the body of the document.
///
/// One turn is one block: avatar, name, timestamp, and what was said, tight
/// together. The vendored hero markup groups a speaker's lines into a paragraph
/// under a shared head and separates speakers by 24px — right for its three
/// mock turns, rhythmless across a real 24-turn transcript, where a name ended
/// up further from its own words than from the next speaker's.
///
/// Timestamps show on hover and on the line playing now: there when you want to
/// jump, invisible while you read.
export function ShareTranscript({
  detail, currentTimeSec, onSeek,
}: {
  detail: MeetingDetail;
  currentTimeSec: number;
  onSeek: (sec: number) => void;
}) {
  const activeRef = React.useRef<HTMLDivElement>(null);

  const speakerById = React.useMemo(() => {
    const m = new Map<string, { name: string; initials: string; color: string }>();
    const palette = ["var(--sp-speaker-1)", "var(--sp-speaker-2)", "var(--sp-speaker-3)", "var(--sp-speaker-4)"];
    detail.speakers.forEach((s, i) => {
      const name = displaySpeakerName(s.custom_name, s.label, null);
      m.set(s.id, { name, initials: initialsOf(name), color: palette[i % palette.length] });
    });
    return m;
  }, [detail.speakers]);

  // Segments are sorted by start_ms (shareApi sorts defensively), so the line
  // playing now is the last one that started before "now".
  const activeId = React.useMemo(() => {
    const ms = currentTimeSec * 1000;
    let found: number | null = null;
    for (const s of detail.segments) {
      if (s.start_ms <= ms) found = s.id; else break;
    }
    return found;
  }, [detail.segments, currentTimeSec]);

  // Keep the playing line in view. The scroller is the PAGE now (the sheet is a
  // document), so this scrolls the window — and stops short of the bottom,
  // where the docked audio covers ~110px.
  React.useEffect(() => {
    const el = activeRef.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    if (r.top < 80 || r.bottom > window.innerHeight - 110) {
      window.scrollTo({ top: window.scrollY + r.top - window.innerHeight / 3, behavior: "smooth" });
    }
  }, [activeId]);

  return (
    <div className="sp-turns">
      {detail.segments.map((s, i) => {
        const sp = speakerById.get(s.speaker_id);
        const isActive = s.id === activeId;
        return (
          <div
            key={s.id}
            ref={isActive ? activeRef : undefined}
            className={"sp-turn" + (isActive ? " is-active" : "")}
            // Turns stagger in as the sheet settles, then rest. Capped at 12 so
            // a long transcript doesn't animate for two seconds.
            style={{ animationDelay: `${140 + Math.min(i, 12) * 45}ms` }}
          >
            <span className="sp-avatar" style={{ background: sp?.color }}>{sp?.initials}</span>
            <div className="sp-turn-body">
              <div className="sp-turn-head">
                <span className="sp-turn-name" style={{ color: sp?.color }}>{sp?.name}</span>
                <button
                  type="button"
                  className="sp-turn-time"
                  onClick={() => onSeek(s.start_ms / 1000)}
                  title="Jump to this moment"
                >
                  {stamp(s.start_ms)}
                </button>
              </div>
              <p className="sp-turn-text">{s.text}</p>
            </div>
          </div>
        );
      })}
    </div>
  );
}

function initialsOf(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return "?";
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

function stamp(ms: number): string {
  const total = Math.floor(ms / 1000);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}
