import React from "react";
import { Search } from "lucide-react";
import type { MeetingDetail } from "../api";
import { displaySpeakerName } from "../format";

/// The transcript column.
///
/// One turn is one block: avatar, name, timestamp, and what was said, tight
/// together. The vendored hero markup groups a speaker's lines into a paragraph
/// under a head and separates speakers by 24px — right for its three mock
/// turns, rhythmless across a real 24-turn transcript, where the name ended up
/// further from its own words than from the next speaker's.
///
/// Timestamps only appear on hover (and on the line playing now), so they're
/// there when you want to jump and invisible when you're reading.
export function ShareTranscript({
  detail, currentTimeSec, onSeek,
}: {
  detail: MeetingDetail;
  currentTimeSec: number;
  onSeek: (sec: number) => void;
}) {
  const [query, setQuery] = React.useState("");
  const scrollRef = React.useRef<HTMLDivElement>(null);
  const activeRef = React.useRef<HTMLDivElement>(null);

  const speakerById = React.useMemo(() => {
    const m = new Map<string, { name: string; initials: string; color: string }>();
    const palette = ["var(--hl-speaker-purple)", "var(--hl-accent)", "var(--hl-speaker-self)", "var(--hl-avatar-admin)"];
    detail.speakers.forEach((s, i) => {
      const name = displaySpeakerName(s.custom_name, s.label, null);
      m.set(s.id, { name, initials: initialsOf(name), color: palette[i % palette.length] });
    });
    return m;
  }, [detail.speakers]);

  const q = query.trim().toLowerCase();
  const shown = React.useMemo(
    () => (q ? detail.segments.filter((s) => s.text.toLowerCase().includes(q)) : detail.segments),
    [detail.segments, q],
  );

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

  // Follow the audio inside this scroller only — scrollIntoView on the element
  // would drag the window, and the page must not move.
  React.useEffect(() => {
    const el = activeRef.current, box = scrollRef.current;
    if (!el || !box || q) return;
    const top = el.offsetTop - box.offsetTop;
    if (top < box.scrollTop || top > box.scrollTop + box.clientHeight - 60) {
      box.scrollTo({ top: top - box.clientHeight / 2.5, behavior: "smooth" });
    }
  }, [activeId, q]);

  return (
    <>
      <div className="sp-search">
        <Search aria-hidden />
        <input
          type="search"
          placeholder="Search the transcript"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
      </div>

      <div className="sp-transcript" ref={scrollRef}>
        {shown.length === 0 ? (
          <div className="sp-empty-line">Nothing matches “{query}”.</div>
        ) : (
          shown.map((s, i) => {
            const sp = speakerById.get(s.speaker_id);
            const isActive = s.id === activeId;
            return (
              <div
                key={s.id}
                ref={isActive ? activeRef : undefined}
                className={"sp-turn" + (isActive ? " is-active" : "")}
                // Turns stagger in on load, then rest. Capped at 12 so a long
                // transcript doesn't animate for two seconds.
                style={{ animationDelay: `${Math.min(i, 12) * 45}ms` }}
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
                  <p className="sp-turn-text">{highlight(s.text, q)}</p>
                </div>
              </div>
            );
          })
        )}
      </div>
    </>
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

function highlight(text: string, q: string): React.ReactNode {
  if (!q) return text;
  const out: React.ReactNode[] = [];
  const lower = text.toLowerCase();
  let from = 0;
  for (let at = lower.indexOf(q, from); at !== -1; at = lower.indexOf(q, from)) {
    if (at > from) out.push(text.slice(from, at));
    out.push(<mark className="sp-mark" key={at}>{text.slice(at, at + q.length)}</mark>);
    from = at + q.length;
  }
  out.push(text.slice(from));
  return out;
}
