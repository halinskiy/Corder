import React from "react";
import { MeetingDetail, summarize } from "../api";
import type { T } from "../i18n";

/// Full-width summary block shown at the top of the transcript. If the
/// meeting has no cached summary yet, generates one on first open (the
/// backend blocks on Gemini, so the first time per meeting takes a few
/// seconds) and shows a spinner meanwhile. Plain prose only.
export function SummaryPane({ detail, t }: { detail: MeetingDetail; t: T }) {
  const [summary, setSummary] = React.useState<string | null>(
    detail.summary?.trim() ? detail.summary!.trim() : null
  );
  const [loading, setLoading] = React.useState(false);
  const [failed, setFailed] = React.useState(false);

  const run = React.useCallback(() => {
    setLoading(true);
    setFailed(false);
    summarize(detail.id)
      .then((s) => setSummary(s))
      .catch(() => setFailed(true))
      .finally(() => setLoading(false));
  }, [detail.id]);

  // Auto-generate on first open when there's nothing cached. Re-armed
  // per meeting id (the pane remounts via the parent when the meeting
  // changes, but guard anyway).
  React.useEffect(() => {
    const cached = detail.summary?.trim();
    if (cached) { setSummary(cached); return; }
    if (!summary && !loading && !failed) run();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [detail.id]);

  // Plain prose only — split into paragraphs on blank lines (or single
  // newlines as a fallback). No Markdown, no lists, no headings.
  const paras = (summary || "")
    .replace(/\r/g, "")
    .split(/\n{2,}/)
    .map((p) => p.replace(/\s*\n\s*/g, " ").trim())
    .filter(Boolean);

  return (
    <div className="summary-card">
      <div className="summary-card-head">{t.tab_summary}</div>
      {loading ? (
        <div className="summary-card-state">
          <span className="summary-spinner" />
          <span>{t.summary_generating}</span>
        </div>
      ) : failed ? (
        <div className="summary-card-state">
          <span>{t.summary_failed}</span>
          <button className="summary-retry" onClick={run}>{t.summary_retry}</button>
        </div>
      ) : paras.length === 0 ? (
        <div className="summary-card-state">
          <span className="summary-spinner" />
          <span>{t.summary_generating}</span>
        </div>
      ) : (
        <div className="summary-card-body">
          {paras.map((p, i) => (
            <p key={i} className="summary-p">{p}</p>
          ))}
        </div>
      )}
    </div>
  );
}
