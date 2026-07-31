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
/// jump, invisible while you read. The whole turn is the jump target, not just
/// the timestamp — same as clicking a line in the app.
///
/// Search doesn't filter. Filtering a conversation to matching lines destroys
/// the thing you're reading; matches are highlighted in place and the first one
/// is scrolled to instead.
///
/// Scrolling reports the turn nearest the middle of the viewport, which lets
/// the docked track double as a minimap: read anywhere and the track shows
/// where you are in the meeting.
export function ShareTranscript({
  detail, currentTimeSec, onSeek, query, onReading,
}: {
  detail: MeetingDetail;
  currentTimeSec: number;
  onSeek: (sec: number) => void;
  query: string;
  /// Where the reader is, in meeting time. Reported on scroll so the track can
  /// act as a minimap while nothing is playing.
  onReading: (ms: number) => void;
}) {
  const activeRef = React.useRef<HTMLElement>(null);
  const firstHitRef = React.useRef<HTMLElement>(null);
  const q = query.trim().toLowerCase();

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
    const el = firstHitRef.current;
    if (!q || !el) return;
    const r = el.getBoundingClientRect();
    if (r.top < 80 || r.bottom > window.innerHeight - 110) {
      window.scrollTo({ top: window.scrollY + r.top - window.innerHeight / 3, behavior: "smooth" });
    }
  }, [q]);

  React.useEffect(() => {
    const el = activeRef.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    if (r.top < 80 || r.bottom > window.innerHeight - 110) {
      window.scrollTo({ top: window.scrollY + r.top - window.innerHeight / 3, behavior: "smooth" });
    }
  }, [activeId]);

  const firstHitId = React.useMemo(
    () => (q ? (detail.segments.find((s) => s.text.toLowerCase().includes(q))?.id ?? null) : null),
    [detail.segments, q],
  );

  // Group consecutive same-speaker segments into ONE block, exactly like the
  // app's transcript. Each segment's text then flows as a run inside one
  // paragraph (separated by a space) instead of sitting on its own line — a
  // wall of one-phrase-per-line was unreadable. Every run stays its own inline
  // span, so per-phrase seek / active-highlight / minimap position are intact.
  const groups = React.useMemo(() => {
    const out: { speakerId: string; segs: typeof detail.segments }[] = [];
    for (const s of detail.segments) {
      const last = out[out.length - 1];
      if (last && last.speakerId === s.speaker_id) last.segs.push(s);
      else out.push({ speakerId: s.speaker_id, segs: [s] });
    }
    return out;
  }, [detail.segments]);

  // Report the reading position: the turn closest to the middle of the screen.
  // Reads are batched into one rAF, so a fast scroll doesn't measure the DOM on
  // every event.
  const listRef = React.useRef<HTMLDivElement>(null);
  React.useEffect(() => {
    let raf = 0;
    const measure = () => {
      raf = 0;
      const nodes = listRef.current?.querySelectorAll<HTMLElement>("[data-ms]");
      if (!nodes?.length) return;
      const middle = window.innerHeight / 2;
      let bestMs = 0, bestDist = Infinity;
      nodes.forEach((n) => {
        const r = n.getBoundingClientRect();
        const d = Math.abs(r.top + r.height / 2 - middle);
        if (d < bestDist) { bestDist = d; bestMs = Number(n.dataset.ms); }
      });
      onReading(bestMs);
    };
    const onScroll = () => { if (!raf) raf = requestAnimationFrame(measure); };
    measure();
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll);
    return () => {
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", onScroll);
      if (raf) cancelAnimationFrame(raf);
    };
  }, [onReading, detail.segments]);

  return (
    <div className="sp-turns" ref={listRef}>
      {groups.map((g, gi) => {
        const sp = speakerById.get(g.speakerId);
        return (
          <div
            key={g.segs[0].id}
            className="sp-turn"
            // Blocks stagger in as the sheet settles, then rest. Capped at 12 so
            // a long transcript doesn't animate for two seconds.
            style={{ animationDelay: `${140 + Math.min(gi, 12) * 45}ms` }}
          >
            <span className="sp-avatar" style={{ background: sp?.color }}>{sp?.initials}</span>
            <div className="sp-turn-body">
              <div className="sp-turn-head">
                <span className="sp-turn-name" style={{ color: sp?.color }}>{sp?.name}</span>
                <span className="sp-turn-time">{stamp(g.segs[0].start_ms)}</span>
              </div>
              <p className="sp-turn-text">
                {g.segs.map((s, i) => {
                  const isActive = s.id === activeId;
                  const isFirstHit = s.id === firstHitId;
                  return (
                    <React.Fragment key={s.id}>
                      <span
                        ref={isActive ? activeRef : (isFirstHit ? firstHitRef : undefined)}
                        data-ms={s.start_ms}
                        className={"sp-line" + (isActive ? " is-active" : "") + (hit(s.text, q) ? " is-hit" : "")}
                        onClick={() => onSeek(s.start_ms / 1000)}
                        role="button"
                        tabIndex={0}
                        onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); onSeek(s.start_ms / 1000); } }}
                        title="Jump to this moment"
                      >
                        {highlight(s.text, q)}
                      </span>
                      {i < g.segs.length - 1 ? " " : ""}
                    </React.Fragment>
                  );
                })}
              </p>
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

function hit(text: string, q: string): boolean {
  return !!q && text.toLowerCase().includes(q);
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
