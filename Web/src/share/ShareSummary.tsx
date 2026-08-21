import React from "react";

/// Summary tab for the share page.
///
/// Renders the meeting recap (the same structured Markdown the app's
/// SummaryPane shows) in the document's OWN type scale — no app chrome, no
/// toolbar, no card. The recap format only ever uses three things: `###`
/// section headings, `-` bullets with one optional level of two-space nesting,
/// and `**bold**` runs. We parse exactly those and nothing else, so a stray
/// Markdown construct degrades to plain text instead of breaking the page.
export function ShareSummary({ markdown }: { markdown: string }) {
  const blocks = React.useMemo(() => parse(markdown), [markdown]);
  return (
    <div className="sp-summary">
      {blocks.map((b, i) =>
        b.kind === "h" ? (
          <h2 key={i} className="sp-sum-h">{inline(b.text)}</h2>
        ) : (
          <ul key={i} className="sp-sum-list">
            {b.items.map((it, j) => (
              <li key={j} className={"sp-sum-li" + (it.depth ? " sp-sum-li--sub" : "")}>
                {inline(it.text)}
              </li>
            ))}
          </ul>
        ),
      )}
    </div>
  );
}

type Block =
  | { kind: "h"; text: string }
  | { kind: "ul"; items: { text: string; depth: number }[] };

/// Group consecutive bullets into one list block; headings are their own block.
/// A list stays open across blank lines and closes at the next heading, which
/// is exactly how the recap is shaped (heading, then its bullets).
function parse(md: string): Block[] {
  const out: Block[] = [];
  let list: { text: string; depth: number }[] | null = null;
  const flush = () => {
    if (list && list.length) out.push({ kind: "ul", items: list });
    list = null;
  };
  for (const raw of md.split("\n")) {
    const line = raw.replace(/\s+$/, "");
    if (!line.trim()) continue;
    const h = line.match(/^#{1,6}\s+(.*)$/);
    if (h) { flush(); out.push({ kind: "h", text: h[1] }); continue; }
    const b = line.match(/^(\s*)[-*]\s+(.*)$/);
    if (b) { (list ??= []).push({ text: b[2], depth: b[1].length >= 2 ? 1 : 0 }); continue; }
    // A plain line under a section still reads as an item rather than vanishing.
    (list ??= []).push({ text: line.trim(), depth: 0 });
  }
  flush();
  return out;
}

/// Split a line into plain text and `**bold**` runs.
function inline(text: string): React.ReactNode {
  return text.split(/(\*\*[^*]+\*\*)/g).map((p, i) =>
    /^\*\*[^*]+\*\*$/.test(p)
      ? <strong key={i}>{p.slice(2, -2)}</strong>
      : <React.Fragment key={i}>{p}</React.Fragment>,
  );
}
