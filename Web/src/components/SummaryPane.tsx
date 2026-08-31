import { useEffect, useRef, useState, type ReactNode } from "react";
import { RefreshCw, Search } from "lucide-react";
import { MeetingDetail, summarize, submitLogs, openWelcome } from "../api";
import type { T } from "../i18n";
import { OverlayScrollbar } from "./OverlayScrollbar";
import { Tooltip } from "./Tooltip";
import { CopyIconButton } from "./CopyIconButton";

declare global {
  interface Window {
    corderCopy?: (text: string) => void;
  }
}

interface Props {
  detail: MeetingDetail;
  onToast?: (msg: string, kind?: "success" | "error") => void;
  /// Public share page: show the summary the owner already generated, but
  /// nothing that would call home. Generating/regenerating bills the OWNER's
  /// account and needs their JWT, so those actions are hidden outright rather
  /// than left to fail; with no summary the pane renders nothing at all.
  readOnly?: boolean;
  t: T;
}

/// Granola-style summary pane.
///
/// Visual contract (consistency = priority #1):
/// - All EMPTY states (no transcript / no summary yet / loading /
///   error) render as `.trans-banner.clarify-banner` cards, the
///   same outlined block the "Transcription failed" / clarify
///   banners use. Single design language across the app.
/// - When the summary IS present, the layout mirrors `.transcript-wrap`
///   verbatim: a `.transcript-toolbar` with a `.search-field` on the
///   left and a `.toolbar-icon-btn` (Regenerate) on the right, then a
///   `.transcript` scrollable body below. Same chrome and same padding
///   so Transcript and Summary feel like ONE surface with two views.
///
/// Auto-summary generation lives on the SERVER (TranscriptionPipeline
/// fires `GeminiSummarizer.generate` after the transcript is ready
/// when the user opted in). The frontend does NOT auto-fire: clicking
/// the Summary tab on a meeting with no cached summary shows the
/// banner with a "Generate" button, predictable, no surprise spend.
export function SummaryPane({ detail, onToast, readOnly = false, t }: Props) {
  const initial = pickStructured(detail.summary ?? null);
  const [summary, setSummary] = useState<string | null>(initial);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // `locked` = the server refused because this is a paid feature (HTTP
  // 403). We show an upsell instead of the generic "didn't work" error,
  // which read as a bug to free users.
  const [locked, setLocked] = useState(false);
  // `needSignIn` = the server refused because the user is a signed-out guest
  // (Summary needs a Worker JWT). Show a "Sign in to generate" CTA, not an
  // error card, the feature is free, it just needs an account.
  const [needSignIn, setNeedSignIn] = useState(false);
  const [search, setSearch] = useState("");
  const contentRef = useRef<HTMLDivElement | null>(null);

  // When the user opens another meeting (or this one reloads), reset
  // local state from the row's cached summary.
  useEffect(() => {
    setSummary(pickStructured(detail.summary ?? null));
    setError(null);
    setLocked(false);
    setNeedSignIn(false);
    setLoading(false);
    setSearch("");
  }, [detail.id, detail.summary]);

  const ready = detail.status === "ready" && detail.segments.length > 0;

  async function generate(force: boolean) {
    if (!ready) return;
    setLoading(true);
    setError(null);
    setLocked(false);
    setNeedSignIn(false);
    try {
      const s = await summarize(detail.id, force);
      setSummary(s);
    } catch (e) {
      const msg = String((e as Error)?.message || "");
      // Paid-feature gate → upsell, not an error card.
      if (msg.includes("403")) setLocked(true);
      // Signed-out guest → sign-in CTA, not an error card.
      else if (msg.includes("sign_in_required")) setNeedSignIn(true);
      else setError(t.summary_error);
    } finally {
      setLoading(false);
    }
  }

  // Ship the diagnostic log, same backend as the header's bug-report
  // button. Used by the clickable "report" link in the error card.
  function sendReport() {
    // Optimistic toast on click: the POST forwards to the Worker →
    // Resend → GitHub and can take a few seconds, so showing feedback
    // only on resolve felt like nothing happened. Same instant feedback
    // as the header bug-report button.
    onToast?.(t.report_sent ?? "Report sent.", "success");
    submitLogs().catch(() => onToast?.(t.toast_settings_failed, "error"));
  }

  // Error body with a green, clickable "report" link (same vocabulary
  // as the header report action).
  const errorBody: ReactNode = (
    <>
      {t.summary_failed_short ?? "Summary didn't work."}{" "}
      <button type="button" className="report-link" onClick={sendReport}>
        {t.send_report ?? "Send a report"}
      </button>
    </>
  );

  // ── EMPTY STATES, all rendered as `.trans-banner.clarify-banner` ──
  if (!ready) {
    return (
      <div className="summary-wrap summary-wrap-empty">
        <SummaryBanner title={t.summary_empty_title} body={t.summary_no_transcript} />
      </div>
    );
  }
  if (loading && !summary) {
    return (
      <div className="summary-wrap summary-wrap-empty">
        <SummaryBanner title={t.summary_empty_title} body={t.summary_loading} spinner />
      </div>
    );
  }
  if (needSignIn && !summary) {
    return (
      <div className="summary-wrap summary-wrap-empty">
        <SummaryBanner
          title={t.summary_empty_title}
          body={t.summary_signin_body ?? "Sign in to generate a summary. It's free."}
          action={{
            label: t.summary_signin_cta ?? "Sign in",
            onClick: () => { openWelcome().catch(() => {}); },
            accent: true,
          }}
        />
      </div>
    );
  }
  if (locked && !summary) {
    return (
      <div className="summary-wrap summary-wrap-empty">
        <SummaryBanner
          title={t.summary_empty_title}
          body={t.summary_locked_body ?? "Summaries are a Pro feature."}
          action={{
            label: t.pricing_upgrade ?? "Upgrade",
            onClick: () => (window as unknown as { corderOpenExternal?: (u: string) => void }).corderOpenExternal?.("https://getcorder.com/#pricing"),
            accent: true,
          }}
        />
      </div>
    );
  }
  if (error && !summary) {
    return (
      <div className="summary-wrap summary-wrap-empty">
        <SummaryBanner
          title={t.summary_empty_title}
          body={errorBody}
          action={readOnly ? undefined : {
            label: t.summary_generate, onClick: () => generate(false),
            disabled: loading, accent: true,
          }}
        />
      </div>
    );
  }
  if (!summary) {
    return (
      <div className="summary-wrap summary-wrap-empty">
        <SummaryBanner
          title={t.summary_empty_title}
          body={readOnly ? (t.summary_no_transcript ?? "") : t.summary_empty_body}
          action={readOnly ? undefined : {
            label: t.summary_generate, onClick: () => generate(false),
            disabled: loading, accent: true,
          }}
        />
      </div>
    );
  }

  // ── READY STATE, toolbar + markdown content ──
  return (
    <div className="summary-wrap">
      <div className="transcript-toolbar">
        <div className="search-field">
          <Search size={14} strokeWidth={2} />
          <input
            type="search"
            placeholder={t.summary_search}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
        </div>
        <span className="toolbar-sep" />
        <CopyIconButton
          getText={() => summary ?? ""}
          onToast={onToast}
          okText={t.toast_copied}
          failText={t.toast_copy_failed}
          label={t.btn_copy}
          disabled={!summary}
        />
        {!readOnly && (
          <Tooltip label={t.summary_regenerate}>
            <button
              className="toolbar-icon-btn"
              onClick={() => generate(true)}
              disabled={loading}
              aria-label={t.summary_regenerate}
            >
              <RefreshCw size={16} strokeWidth={2} className={loading ? "summary-spin" : ""} />
            </button>
          </Tooltip>
        )}
      </div>
      <div className="summary-content ovsb-scroll" ref={contentRef}>
        {renderMarkdown(summary, search)}
      </div>
      <OverlayScrollbar scrollRef={contentRef} name="corder-sb-summary" />
    </div>
  );
}

/// Empty-state card, `.trans-banner.clarify-banner` shell (same as
/// EmptyDeleteBanner / TranscribingBanner).
function SummaryBanner({
  title, body, action, spinner,
}: {
  title: string;
  body: ReactNode;
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

/// Treat a summary written in a SUPERSEDED format as "no summary", so the
/// pane offers to regenerate instead of rendering last year's shape. The row
/// keeps the old text either way — this only decides what is shown.
///
/// Two generations have been retired this way: the unstructured plain-prose
/// recap (no headings, no bullets at all), and the paragraph-per-section one
/// that followed it, whose only bullets were in the closing "Дальше" list.
/// That format was measured against Granola's notes on the same call and lost
/// the specifics — the reference someone cited, the per-item decision, the bug
/// mentioned once — because prose paraphrases them away. Current format is
/// dense bullets under every heading.
export function pickStructured(s: string | null): string | null {
  if (!s) return null;
  const trimmed = s.trim();
  if (!trimmed) return null;
  const sections = trimmed.split(/\n(?=###\s)/).filter((x) => /^###\s/.test(x.trim()));
  // No headings at all: the oldest format. Keep it only if it is a bullet list.
  if (sections.length === 0) return /(^|\n)\s*[-*]\s/.test(trimmed) ? trimmed : null;
  // Headings present: the body has to be bullets in most of them. The prose
  // format scores 1 of 4 (only its action items were a list).
  const withBullets = sections.filter((x) => /\n\s*[-*]\s/.test(x)).length;
  return withBullets * 2 > sections.length ? trimmed : null;
}

// ──────────────────────────────────────────────────────────────
// Minimal Markdown renderer (no library dependency)
// ──────────────────────────────────────────────────────────────

type Block =
  | { kind: "h2"; text: string }
  | { kind: "h3"; text: string }
  | { kind: "p"; text: string }
  | { kind: "list"; items: ListItem[] };

interface ListItem {
  text: string;
  children: ListItem[];
}

export function renderMarkdown(md: string, query: string): JSX.Element[] {
  const lines = md.replace(/\r\n?/g, "\n").split("\n");
  const blocks: Block[] = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i++; continue; }
    const h3 = /^###\s+(.*)$/.exec(line);
    if (h3) { blocks.push({ kind: "h3", text: h3[1] }); i++; continue; }
    const h2 = /^##\s+(.*)$/.exec(line);
    if (h2) { blocks.push({ kind: "h2", text: h2[1] }); i++; continue; }
    if (/^\s*[-*]\s+/.test(line)) {
      const [items, consumed] = parseList(lines, i, 0);
      blocks.push({ kind: "list", items });
      i = consumed;
      continue;
    }
    const buf: string[] = [line];
    let j = i + 1;
    while (j < lines.length) {
      const l = lines[j];
      if (!l.trim()) break;
      if (/^#{2,3}\s/.test(l)) break;
      if (/^\s*[-*]\s+/.test(l)) break;
      buf.push(l);
      j++;
    }
    blocks.push({ kind: "p", text: buf.join(" ") });
    i = j;
  }
  const q = query.trim();
  return blocks.map((b, idx) => renderBlock(b, idx, q));
}

function parseList(lines: string[], start: number, indent: number): [ListItem[], number] {
  const items: ListItem[] = [];
  let i = start;
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) {
      const next = lines[i + 1] ?? "";
      if (/^\s*[-*]\s+/.test(next)) { i++; continue; }
      break;
    }
    const m = /^(\s*)[-*]\s+(.*)$/.exec(line);
    if (!m) break;
    const thisIndent = m[1].length;
    if (thisIndent !== indent) break;
    const text = m[2];
    i++;
    let children: ListItem[] = [];
    if (i < lines.length) {
      const nm = /^(\s*)[-*]\s+/.exec(lines[i]);
      if (nm && nm[1].length > thisIndent) {
        const [kids, consumed] = parseList(lines, i, nm[1].length);
        children = kids;
        i = consumed;
      }
    }
    items.push({ text, children });
  }
  return [items, i];
}

function renderBlock(b: Block, key: number, q: string): JSX.Element {
  switch (b.kind) {
    case "h2": return <h2 key={key} className="md-h2">{renderInline(b.text, q)}</h2>;
    case "h3": return <h3 key={key} className="md-h3">{renderInline(b.text, q)}</h3>;
    case "p":  return <p  key={key} className="md-p">{renderInline(b.text, q)}</p>;
    case "list":
      return (
        <ul key={key} className="md-ul">
          {b.items.map((it, j) => renderItem(it, j, q))}
        </ul>
      );
  }
}

function renderItem(it: ListItem, key: number, q: string): JSX.Element {
  return (
    <li key={key} className="md-li">
      <span>{renderInline(it.text, q)}</span>
      {it.children.length > 0 && (
        <ul className="md-ul md-ul-nested">
          {it.children.map((c, j) => renderItem(c, j, q))}
        </ul>
      )}
    </li>
  );
}

function renderInline(text: string, q: string): (string | JSX.Element)[] {
  // First pass: bold/italic split. Each text-only token is then
  // run through the query highlighter so matches survive across
  // **bold** ranges.
  const out: (string | JSX.Element)[] = [];
  let rest = text;
  let key = 0;
  const push = (s: string) => { if (s) out.push(...highlight(s, q, key++)); };
  while (rest.length > 0) {
    const bold = /\*\*([^*]+)\*\*/.exec(rest);
    if (bold) {
      if (bold.index > 0) push(rest.slice(0, bold.index));
      out.push(<strong key={`b${key++}`}>{renderInline(bold[1], q)}</strong>);
      rest = rest.slice(bold.index + bold[0].length);
      continue;
    }
    const italic = /(^|[^*])\*([^*\n]+)\*(?!\*)/.exec(rest);
    if (italic) {
      const leadLen = italic[1].length;
      if (italic.index + leadLen > 0) push(rest.slice(0, italic.index + leadLen));
      out.push(<em key={`i${key++}`}>{italic[2]}</em>);
      rest = rest.slice(italic.index + leadLen + italic[2].length + 2);
      continue;
    }
    push(rest);
    break;
  }
  return out;
}

/// Wrap query matches in `<mark>`, case-insensitive, all occurrences.
/// Returns the raw `text` when `q` is empty.
function highlight(text: string, q: string, seed: number): (string | JSX.Element)[] {
  if (!q) return [text];
  const lower = text.toLowerCase();
  const ql = q.toLowerCase();
  const out: (string | JSX.Element)[] = [];
  let i = 0;
  let n = 0;
  while (i < text.length) {
    const idx = lower.indexOf(ql, i);
    if (idx < 0) { out.push(text.slice(i)); break; }
    if (idx > i) out.push(text.slice(i, idx));
    out.push(<mark key={`m${seed}-${n++}`} className="md-mark">{text.slice(idx, idx + q.length)}</mark>);
    i = idx + q.length;
  }
  return out;
}
