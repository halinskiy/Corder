import React from "react";
import { Search } from "lucide-react";
import type { MeetingDetail, SegmentDTO } from "../api";
import { displaySpeakerName } from "../format";

/// Transcript inside the hero window.
///
/// Structure and classes are the landing's (`.hl-transcript-wrap`,
/// `.hl-segment-group`, `.hl-speaker-avatar`, `.hl-segment-line`), so the type
/// scale, the 24px gap between speakers and the hover/active treatments are the
/// ones the brand ships. What's added here is what a public page needs and the
/// hero mock doesn't have: real search, and lines that seek the audio.
///
/// Like the app, consecutive lines from one speaker are grouped under a single
/// avatar+name head rather than repeating the name on every line.
export function ShareTranscript({
  detail, currentTimeSec, onSeek,
}: {
  detail: MeetingDetail;
  currentTimeSec: number;
  onSeek: (sec: number) => void;
}) {
  const [query, setQuery] = React.useState("");
  const scrollRef = React.useRef<HTMLDivElement>(null);
  const activeRef = React.useRef<HTMLSpanElement>(null);

  const speakerById = React.useMemo(() => {
    const m = new Map<string, { name: string; initials: string; color: string }>();
    // The hero window's speaker palette, in its own order.
    const palette = ["var(--hl-speaker-purple)", "var(--hl-accent)", "var(--hl-speaker-self)", "var(--hl-avatar-admin)"];
    detail.speakers.forEach((s, i) => {
      const name = displaySpeakerName(s.custom_name, s.label, null);
      m.set(s.id, { name, initials: initialsOf(name), color: palette[i % palette.length] });
    });
    return m;
  }, [detail.speakers]);

  const q = query.trim().toLowerCase();
  const segments = React.useMemo(
    () => (q ? detail.segments.filter((s) => s.text.toLowerCase().includes(q)) : detail.segments),
    [detail.segments, q],
  );

  // Consecutive lines from the same speaker share one head.
  const groups = React.useMemo(() => {
    const out: { speakerId: string; segs: SegmentDTO[] }[] = [];
    for (const s of segments) {
      const last = out[out.length - 1];
      if (last && last.speakerId === s.speaker_id) last.segs.push(s);
      else out.push({ speakerId: s.speaker_id, segs: [s] });
    }
    return out;
  }, [segments]);

  // The line being spoken now: segments are sorted by start_ms (shareApi sorts
  // defensively), so it's the last one that started before "now".
  const activeId = React.useMemo(() => {
    const ms = currentTimeSec * 1000;
    let found: number | null = null;
    for (const s of detail.segments) {
      if (s.start_ms <= ms) found = s.id; else break;
    }
    return found;
  }, [detail.segments, currentTimeSec]);

  // Follow the audio within this scroller only — scrollIntoView would drag the
  // whole page.
  React.useEffect(() => {
    const el = activeRef.current, box = scrollRef.current;
    if (!el || !box || q) return;
    const top = el.offsetTop - box.offsetTop;
    if (top < box.scrollTop || top > box.scrollTop + box.clientHeight - 40) {
      box.scrollTo({ top: top - box.clientHeight / 2.5, behavior: "smooth" });
    }
  }, [activeId, q]);

  return (
    <div className="hl-transcript-wrap">
      <div className="hl-transcript-toolbar">
        <label className="hl-search-field">
          <Search aria-hidden />
          <input
            type="search"
            placeholder="Search the transcript"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </label>
      </div>

      <div className="hl-transcript sp-transcript" ref={scrollRef}>
        {groups.length === 0 ? (
          <div className="sp-empty-line">Nothing matches “{query}”.</div>
        ) : (
          groups.map((g, gi) => {
            const sp = speakerById.get(g.speakerId);
            return (
              <div className="hl-segment-group" key={`${g.speakerId}-${gi}`}>
                <div className="hl-segment-head">
                  <span className="hl-speaker-avatar" style={{ background: sp?.color }}>
                    {sp?.initials}
                  </span>
                  <span className="hl-speaker-name">{sp?.name}</span>
                </div>
                <p className="hl-segment-paragraph">
                  {g.segs.map((s) => (
                    <span
                      key={s.id}
                      ref={s.id === activeId ? activeRef : undefined}
                      className={"hl-segment-line" + (s.id === activeId ? " active" : "")}
                      onClick={() => onSeek(s.start_ms / 1000)}
                      title={stamp(s.start_ms)}
                    >
                      {highlight(s.text, q)}{" "}
                    </span>
                  ))}
                </p>
              </div>
            );
          })
        )}
      </div>
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
