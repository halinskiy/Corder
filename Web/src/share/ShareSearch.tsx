import React from "react";
import { Search, X } from "lucide-react";

/// Search, pinned top-right beside Export.
///
/// Collapsed it's a 56px circle — the same body as the export button, the orb
/// and the brand mark, so the page's four corners are one set. Clicking expands
/// it into a field of the same height and morphs the icon into a clear button;
/// nothing appears or disappears, the circle just becomes the field.
export function ShareSearch({
  query, onQuery, count,
}: {
  query: string;
  onQuery: (q: string) => void;
  count: number | null;
}) {
  const [open, setOpen] = React.useState(false);
  const inputRef = React.useRef<HTMLInputElement>(null);

  React.useEffect(() => {
    if (open) inputRef.current?.focus();
  }, [open]);

  // Esc clears and collapses; a stray click outside collapses only if empty, so
  // an active search isn't lost by clicking the page.
  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape" && open) { onQuery(""); setOpen(false); }
      // The document shortcut everyone already has in their fingers.
      if ((e.metaKey || e.ctrlKey) && e.key === "f") { e.preventDefault(); setOpen(true); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, onQuery]);

  return (
    <div className={"sp-search" + (open ? " is-open" : "")}>
      <button
        type="button"
        className="sp-corner-btn sp-search-btn"
        onClick={() => (open ? (query ? onQuery("") : setOpen(false)) : setOpen(true))}
        aria-label={open ? "Close search" : "Search the transcript"}
        title="Search the transcript"
      >
        {open && query ? <X size={20} strokeWidth={2} /> : <Search size={20} strokeWidth={2} />}
      </button>
      <input
        ref={inputRef}
        className="sp-search-input"
        type="search"
        placeholder="Search the transcript"
        value={query}
        onChange={(e) => onQuery(e.target.value)}
        onBlur={() => { if (!query) setOpen(false); }}
        tabIndex={open ? 0 : -1}
        aria-hidden={!open}
      />
      {open && !!query && (
        <span className="sp-search-count">{count === 0 ? "none" : count}</span>
      )}
    </div>
  );
}
