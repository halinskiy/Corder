import { useEffect, useRef, useState } from "react";
import { MeetingDetail } from "../api";
import type { T } from "../i18n";
import { OverlayScrollbar } from "./OverlayScrollbar";

interface Props {
  detail: MeetingDetail;
  /// Click on a chapter row → seek the audio scrubber to that
  /// timestamp. Same callback the transcript-line click uses.
  onSeek: (sec: number) => void;
  t: T;
}

type Chapter = { startMs: number; title: string };

/// Loom-style Chapters pane. Shares the exact `.transcript-wrap`
/// shell as Transcript and Summary so the tab switch never
/// changes the column geometry. Reads chapters off the meeting
/// row (server pre-generates via `GeminiChapters` after every
/// successful transcribe when `auto_chapters` is on). No
/// frontend-side fetch — if the row is empty we render the
/// standard empty-state banner.
export function ChaptersPane({ detail, onSeek, t }: Props) {
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const [chapters, setChapters] = useState<Chapter[]>(() => parse(detail.chapters));

  useEffect(() => {
    setChapters(parse(detail.chapters));
  }, [detail.id, detail.chapters]);

  const ready = detail.status === "ready" && detail.segments.length > 0;

  if (!ready) {
    return (
      <div className="transcript ovsb-scroll" ref={scrollRef}>
        <div className="trans-banner clarify-banner">
          <div className="clarify-text">
            <div className="clarify-body">{t.chapters_empty_title ?? "Chapters appear here"}</div>
            <div className="clarify-sub">
              {t.chapters_empty_body ?? "After the transcript is ready we'll split it into chapters automatically."}
            </div>
          </div>
        </div>
        <OverlayScrollbar scrollRef={scrollRef} name="corder-sb-chapters" />
      </div>
    );
  }

  if (chapters.length === 0) {
    return (
      <div className="transcript ovsb-scroll" ref={scrollRef}>
        <div className="trans-banner clarify-banner">
          <div className="clarify-text">
            <div className="clarify-body">{t.chapters_pending_title ?? "Generating chapters…"}</div>
            <div className="clarify-sub">
              {t.chapters_pending_body ?? "The transcript is ready — chapters land here on the next pipeline sweep. If they don't show up, re-transcribe from the meeting toolbar."}
            </div>
          </div>
        </div>
        <OverlayScrollbar scrollRef={scrollRef} name="corder-sb-chapters" />
      </div>
    );
  }

  return (
    <div className="transcript ovsb-scroll" ref={scrollRef}>
      <ol className="chapters-list">
        {chapters.map((c, i) => (
          <li key={i} className="chapter-row" onClick={() => onSeek(Math.max(0, c.startMs / 1000))}>
            <span className="chapter-time">{fmtTime(c.startMs)}</span>
            <span className="chapter-title">{c.title}</span>
          </li>
        ))}
      </ol>
      <div className="transcript-spacer" />
      <OverlayScrollbar scrollRef={scrollRef} name="corder-sb-chapters" />
    </div>
  );
}

function parse(raw: string | null | undefined): Chapter[] {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed
      .map((c: unknown) => {
        if (typeof c !== "object" || c === null) return null;
        const o = c as Record<string, unknown>;
        const startMs = typeof o.startMs === "number" ? o.startMs
          : typeof o.start_ms === "number" ? (o.start_ms as number)
          : 0;
        const title = typeof o.title === "string" ? (o.title as string) : "";
        if (!title) return null;
        return { startMs, title };
      })
      .filter((c): c is Chapter => c !== null);
  } catch {
    return [];
  }
}

function fmtTime(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  return `${m}:${String(s).padStart(2, "0")}`;
}
