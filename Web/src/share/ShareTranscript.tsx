import React from "react";
import { Search } from "lucide-react";
import type { MeetingDetail } from "../api";
import { displaySpeakerName } from "../format";

/// Transcript for the share page — a readable document, not the app's pane.
///
/// The app's TranscriptPane groups a speaker's consecutive lines into one
/// paragraph and shows no timestamps, which works inside the window because
/// the right rail carries the timeline. On a public page the timestamp IS the
/// navigation, so every line gets a clickable time in a left gutter (Loom's
/// pattern) and the line currently being spoken is highlighted, so a reader can
/// follow along or jump into the audio anywhere.
export function ShareTranscript({
  detail, currentTimeSec, onSeek, hidden,
}: {
  detail: MeetingDetail;
  currentTimeSec: number;
  onSeek: (sec: number) => void;
  hidden?: boolean;
}) {
  const [query, setQuery] = React.useState("");
  const scrollRef = React.useRef<HTMLDivElement>(null);
  const activeRef = React.useRef<HTMLDivElement>(null);

  const speakerById = React.useMemo(() => {
    const m = new Map<string, { name: string; idx: number }>();
    detail.speakers.forEach((s, i) =>
      m.set(s.id, { name: displaySpeakerName(s.custom_name, s.label, null), idx: i }));
    return m;
  }, [detail.speakers]);

  const q = query.trim().toLowerCase();
  const shown = React.useMemo(
    () => (q ? detail.segments.filter((s) => s.text.toLowerCase().includes(q)) : detail.segments),
    [detail.segments, q],
  );

  // The line being spoken now. Segments are sorted by start_ms (shareApi sorts
  // defensively), so it's the last one that started before "now".
  const activeId = React.useMemo(() => {
    const ms = currentTimeSec * 1000;
    let found: number | null = null;
    for (const s of detail.segments) {
      if (s.start_ms <= ms) found = s.id; else break;
    }
    return found;
  }, [detail.segments, currentTimeSec]);

  // Follow the audio, but only within this scroller — `scrollIntoView` on the
  // element would drag the whole page when the card is taller than the window.
  React.useEffect(() => {
    const el = activeRef.current, box = scrollRef.current;
    if (!el || !box || q) return;
    const top = el.offsetTop - box.offsetTop;
    const visible = top >= box.scrollTop && top + el.offsetHeight <= box.scrollTop + box.clientHeight;
    if (!visible) box.scrollTo({ top: top - box.clientHeight / 2.5, behavior: "smooth" });
  }, [activeId, q]);

  return (
    <div className="sp-pane" style={hidden ? { display: "none" } : undefined}>
      <div className="sp-search">
        <Search size={14} strokeWidth={2} aria-hidden />
        <input
          type="search"
          placeholder="Search the transcript…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
        {!!q && <span className="sp-search-count">{shown.length}</span>}
      </div>

      <div className="sp-scroll" ref={scrollRef}>
        {shown.length === 0 ? (
          <div className="sp-none">Nothing matches “{query}”.</div>
        ) : (
          shown.map((s, i) => {
            const sp = speakerById.get(s.speaker_id);
            const prev = i > 0 ? shown[i - 1] : null;
            // Repeat the name only when the speaker changes: a label on every
            // line turns the transcript into a wall of names.
            const newSpeaker = !prev || prev.speaker_id !== s.speaker_id;
            const isActive = s.id === activeId;
            return (
              <div
                key={s.id}
                ref={isActive ? activeRef : undefined}
                className={"sp-line" + (isActive ? " is-active" : "") + (newSpeaker ? " is-turn" : "")}
              >
                <button
                  type="button"
                  className="sp-stamp"
                  onClick={() => onSeek(s.start_ms / 1000)}
                  title="Jump to this moment"
                >
                  {stamp(s.start_ms)}
                </button>
                <div className="sp-say">
                  {newSpeaker && sp && (
                    <div className="sp-who" style={{ color: `var(--speaker-${(sp.idx % 4) + 1})` }}>
                      {sp.name}
                    </div>
                  )}
                  <p className="sp-text">{highlight(s.text, q)}</p>
                </div>
              </div>
            );
          })
        )}
      </div>
    </div>
  );
}

function stamp(ms: number): string {
  const total = Math.floor(ms / 1000);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return h > 0
    ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
    : `${m}:${String(s).padStart(2, "0")}`;
}

function highlight(text: string, q: string): React.ReactNode {
  if (!q) return text;
  const out: React.ReactNode[] = [];
  const lower = text.toLowerCase();
  let from = 0;
  for (let at = lower.indexOf(q, from); at !== -1; at = lower.indexOf(q, from)) {
    if (at > from) out.push(text.slice(from, at));
    out.push(<mark key={at}>{text.slice(at, at + q.length)}</mark>);
    from = at + q.length;
  }
  out.push(text.slice(from));
  return out;
}
