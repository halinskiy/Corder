import { useEffect, useRef, useState } from "react";
import { RefreshCw, Copy, Search } from "lucide-react";
import { MeetingDetail, generateChapters } from "../api";
import type { T } from "../i18n";
import { OverlayScrollbar } from "./OverlayScrollbar";
import { Tooltip } from "./Tooltip";

declare global {
  interface Window {
    corderCopy?: (text: string) => void;
  }
}

interface Props {
  detail: MeetingDetail;
  /// Click on a chapter row → seek the audio scrubber to that
  /// timestamp. Same callback the transcript-line click uses.
  onSeek: (sec: number) => void;
  /// Current playback position (seconds) — drives the active-chapter
  /// highlight (the chapter whose window contains `now`).
  currentTimeSec?: number;
  onToast?: (msg: string, kind?: "success" | "error") => void;
  t: T;
}

type Chapter = { startMs: number; title: string };

/// Loom-style Chapters pane. Mirrors `SummaryPane` exactly — same
/// `.summary-wrap` shell, same `.summary-wrap-empty` banner family
/// for empty/loading/error states, same `.transcript-toolbar`
/// (Copy + Regenerate) on top, same `.summary-content` body.
/// Reads chapters off the meeting row (server pre-generates via
/// `GeminiChapters` after every successful transcribe when
/// `auto_chapters` is on); the Regenerate button forces a fresh
/// run via `/api/meetings/:id/chapters?force=1`.
export function ChaptersPane({ detail, onSeek, currentTimeSec = 0, onToast, t }: Props) {
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const [chapters, setChapters] = useState<Chapter[]>(() => parse(detail.chapters));
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState("");

  useEffect(() => {
    setChapters(parse(detail.chapters));
    setError(null);
    setLoading(false);
    setSearch("");
  }, [detail.id, detail.chapters]);

  const ready = detail.status === "ready" && detail.segments.length > 0;

  async function generate(force: boolean) {
    if (!ready) return;
    setLoading(true);
    setError(null);
    try {
      const raw = await generateChapters(detail.id, force);
      setChapters(parse(raw));
    } catch {
      setError(t.chapters_error ?? t.summary_error);
    } finally {
      setLoading(false);
    }
  }

  // ── EMPTY STATES — identical shell to SummaryPane.SummaryBanner ──
  if (!ready) {
    return (
      <div className="summary-wrap summary-wrap-empty">
        <ChaptersBanner
          title={t.chapters_empty_title ?? "Chapters appear here"}
          body={t.chapters_empty_body ?? "Ready after the transcript."}
        />
      </div>
    );
  }
  if (loading && chapters.length === 0) {
    return (
      <div className="summary-wrap summary-wrap-empty">
        <ChaptersBanner
          title={t.chapters_pending_title ?? "Generating chapters…"}
          body={t.chapters_loading ?? "Hang tight."}
          spinner
        />
      </div>
    );
  }
  if (error && chapters.length === 0) {
    return (
      <div className="summary-wrap summary-wrap-empty">
        <ChaptersBanner
          title={t.chapters_empty_title ?? "Chapters appear here"}
          body={error}
          action={{
            label: t.chapters_generate ?? "Generate chapters",
            onClick: () => generate(false),
            disabled: loading,
            accent: true,
          }}
        />
      </div>
    );
  }
  if (chapters.length === 0) {
    return (
      <div className="summary-wrap summary-wrap-empty">
        <ChaptersBanner
          title={t.chapters_empty_title ?? "Chapters appear here"}
          body={t.chapters_empty_ready_body ?? "Split the transcript into chapters."}
          action={{
            label: t.chapters_generate ?? "Generate chapters",
            onClick: () => generate(false),
            disabled: loading,
            accent: true,
          }}
        />
      </div>
    );
  }

  const plain = chapters.map((c) => `[${fmtTime(c.startMs)}] ${c.title}`).join("\n");
  const q = search.trim().toLowerCase();
  const filtered = q
    ? chapters.filter((c) => c.title.toLowerCase().includes(q) || fmtTime(c.startMs).includes(q))
    : chapters;

  // Active chapter = the last one whose start is at/under the playhead.
  // Keyed by startMs so it still matches inside the filtered subset.
  const nowMs = currentTimeSec * 1000;
  let activeStartMs = -1;
  let activeIdx = -1;
  for (let i = 0; i < chapters.length; i++) {
    if (chapters[i].startMs <= nowMs) { activeStartMs = chapters[i].startMs; activeIdx = i; }
    else break;
  }
  // Progress THROUGH the active chapter (0…1): playhead position within
  // [thisChapter.start, nextChapter.start) — or the recording end for the
  // last chapter. Drives the darker-green fill on the active timecode pill,
  // full right as it's time to move to the next chapter.
  let activeProgress = 0;
  if (activeIdx >= 0) {
    const start = chapters[activeIdx].startMs;
    const end = activeIdx + 1 < chapters.length
      ? chapters[activeIdx + 1].startMs
      : (detail.duration_ms && detail.duration_ms > start ? detail.duration_ms : start + 1);
    activeProgress = Math.max(0, Math.min(1, (nowMs - start) / Math.max(1, end - start)));
  }

  // ── READY STATE — toolbar + chapter list inside .summary-content ──
  return (
    <div className="summary-wrap">
      <div className="transcript-toolbar">
        <div className="search-field">
          <Search size={14} strokeWidth={2} />
          <input
            type="search"
            placeholder={t.chapters_search ?? t.summary_search}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
        </div>
        <span className="toolbar-sep" />
        <Tooltip label={t.btn_copy}>
          <button
            className="toolbar-icon-btn"
            onClick={() => {
              try {
                if (window.corderCopy) window.corderCopy(plain);
                else navigator.clipboard?.writeText(plain);
                onToast?.(t.toast_copied, "success");
              } catch {
                onToast?.(t.toast_copy_failed, "error");
              }
            }}
            disabled={chapters.length === 0}
            aria-label={t.btn_copy}
          >
            <Copy size={16} strokeWidth={2} />
          </button>
        </Tooltip>
        <Tooltip label={t.chapters_regenerate ?? t.summary_regenerate}>
          <button
            className="toolbar-icon-btn"
            onClick={() => generate(true)}
            disabled={loading}
            aria-label={t.chapters_regenerate ?? t.summary_regenerate}
          >
            <RefreshCw size={16} strokeWidth={2} className={loading ? "summary-spin" : ""} />
          </button>
        </Tooltip>
      </div>
      <div className="summary-content ovsb-scroll" ref={scrollRef}>
        {filtered.map((c, i) => (
          // The whole row is the click target and lights up on hover,
          // not just the time pill — a chapter is one seek action.
          <button
            key={i}
            type="button"
            className={"chapter-block" + (c.startMs === activeStartMs ? " is-active" : "")}
            onClick={() => onSeek(Math.max(0, c.startMs / 1000))}
            aria-label={`${fmtTime(c.startMs)} ${c.title}`}
          >
            <span className="chapter-time">
              {c.startMs === activeStartMs && (
                <span
                  className="chapter-time-fill"
                  style={{ width: `${Math.round(activeProgress * 100)}%` }}
                  aria-hidden
                />
              )}
              <span className="chapter-time-text">{fmtTime(c.startMs)}</span>
            </span>
            <span className="md-p chapter-title">{c.title}</span>
          </button>
        ))}
      </div>
      <OverlayScrollbar scrollRef={scrollRef} name="corder-sb-chapters" />
    </div>
  );
}

function ChaptersBanner({
  title, body, action, spinner,
}: {
  title: string;
  body: string;
  action?: { label: string; onClick: () => void; disabled?: boolean; accent?: boolean };
  spinner?: boolean;
}) {
  return (
    <div className="trans-banner clarify-banner summary-banner">
      <div className="clarify-text">
        <div className="clarify-body">{title}</div>
        <div className="summary-banner-sub">{body}</div>
      </div>
      {spinner && (
        <div className="summary-banner-spinner-row">
          <span className="summary-banner-spinner" aria-hidden />
        </div>
      )}
      {action && (
        <div className="clarify-actions clarify-actions-stack">
          <button
            type="button"
            className={"clarify-btn" + (action.accent ? " accent" : "")}
            onClick={action.onClick}
            disabled={!!action.disabled}
          >
            {action.label}
          </button>
        </div>
      )}
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
