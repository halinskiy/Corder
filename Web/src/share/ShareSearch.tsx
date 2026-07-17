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
  const wrapRef = React.useRef<HTMLDivElement>(null);

  React.useEffect(() => {
    if (open) inputRef.current?.focus();
  }, [open]);

  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape" && open) { onQuery(""); setOpen(false); }
      // The document shortcut everyone already has in their fingers.
      if ((e.metaKey || e.ctrlKey) && e.key === "f") { e.preventDefault(); setOpen(true); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, onQuery]);

  // Click anywhere else — collapse and clear.
  //
  // `onBlur` on the input isn't enough: clicking a transcript turn (to seek)
  // doesn't take focus, so the field just sat there open. Collapsing also
  // CLEARS, because a collapsed circle next to still-highlighted text is a
  // state nobody can explain.
  React.useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (!wrapRef.current?.contains(e.target as Node)) {
        onQuery("");
        setOpen(false);
      }
    };
    document.addEventListener("mousedown", onDown);
    return () => document.removeEventListener("mousedown", onDown);
  }, [open, onQuery]);

  return (
    <div className={"sp-search" + (open ? " is-open" : "")} ref={wrapRef}>
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
        tabIndex={open ? 0 : -1}
        aria-hidden={!open}
      />
      {open && !!query && (
        <span className="sp-search-count">{count === 0 ? "none" : count}</span>
      )}
    </div>
  );
}
