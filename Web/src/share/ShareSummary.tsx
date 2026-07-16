import { renderMarkdown, pickStructured } from "../components/SummaryPane";

/// Summary for the share page.
///
/// Reuses SummaryPane's `renderMarkdown` (the same ### / bullets / **bold**
/// dialect the app renders) but not the pane itself: that one owns generate /
/// regenerate / report actions, all of which call home to a local Corder that
/// doesn't exist here. This is the read-only half — markdown in, elements out.
export function ShareSummary({ markdown }: { markdown: string }) {
  const structured = pickStructured(markdown);
  // `pickStructured` returns null for prose with no headings or bullets. That
  // is still a perfectly good summary to READ (it just isn't structured), so
  // unlike the app — which offers a Generate button there — we render it as-is.
  const body = structured ?? markdown;
  return <div className="sp-summary-body">{renderMarkdown(body, "")}</div>;
}
