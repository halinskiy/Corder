import React from "react";
import { createPortal } from "react-dom";
import { Globe, Search, Check } from "lucide-react";
import { LANGS, type Lang, type T } from "../i18n";

/// Language picker — Globe icon button that opens a portal popover
/// with a live search filter and the full LANGS list. Active language
/// shows a check; locales without a full Strings table still appear
/// in the list (they fall back to English at runtime).
///
/// Lives in its own file so it can be reused both as the toolbar
/// dropdown in MainHeader AND as a row inside the ProfileMenu
/// popover. The shape is identical; the parent decides where it goes.
export function LangPicker({
  lang, onChange, t, className, label,
}: {
  lang: Lang;
  onChange: (next: Lang) => void;
  t: T;
  /// Optional class to override the trigger's styling. Defaults to
  /// `toolbar-icon-btn`, matching the original MainHeader placement.
  className?: string;
  /// Optional label rendered next to the Globe icon inside the
  /// trigger. Used by the profile popover where the picker reads as
  /// a normal row (icon + text), not a bare toolbar icon button.
  label?: React.ReactNode;
}) {
  const [open, setOpen] = React.useState(false);
  const [q, setQ] = React.useState("");
  const btnRef = React.useRef<HTMLButtonElement>(null);
  const [pos, setPos] = React.useState<{ top: number; right: number } | null>(null);

  const place = React.useCallback(() => {
    const r = btnRef.current?.getBoundingClientRect();
    if (r) setPos({ top: r.bottom + 8, right: window.innerWidth - r.right });
  }, []);

  /// Measure synchronously inside the click handler — see SortPicker
  /// in Dashboard.tsx for the rationale: doing this in a useEffect
  /// renders the popover at the previous position for one frame and
  /// snaps it into place on the next, which the user reads as "the
  /// menu twitches when I open it".
  const toggle = React.useCallback(() => {
    setOpen((v) => {
      if (!v) {
        const r = btnRef.current?.getBoundingClientRect();
        if (r) setPos({ top: r.bottom + 8, right: window.innerWidth - r.right });
      }
      return !v;
    });
  }, []);

  React.useEffect(() => {
    if (!open) return;
    setQ("");
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    const onDown = (e: MouseEvent) => {
      if (!btnRef.current?.contains(e.target as Node)) setOpen(false);
    };
    window.addEventListener("keydown", onKey);
    window.addEventListener("resize", place);
    const id = window.setTimeout(() => window.addEventListener("mousedown", onDown), 0);
    return () => {
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("resize", place);
      window.clearTimeout(id);
      window.removeEventListener("mousedown", onDown);
    };
  }, [open, place]);

  const query = q.trim().toLowerCase();
  const filtered = query.length === 0
    ? LANGS
    : LANGS.filter((l) =>
        l.code.toLowerCase().includes(query) ||
        l.name.toLowerCase().includes(query) ||
        l.native.toLowerCase().includes(query));

  return (
    <>
      <button
        ref={btnRef}
        className={className ?? "toolbar-icon-btn"}
        onClick={toggle}
        title={t.btn_lang_title}
        aria-label={t.btn_lang_title}
        aria-haspopup="menu"
        aria-expanded={open}
      >
        <Globe size={label ? 15 : 16} strokeWidth={2} />
        {label}
      </button>
      {open && pos && createPortal(
        <div
          className="profile-pop lang-picker-pop"
          role="menu"
          style={{ top: pos.top, right: pos.right }}
          onMouseDown={(e) => e.stopPropagation()}
          onClick={(e) => e.stopPropagation()}
        >
          {/* Same .search-field shell as the sidebar / transcript /
              app-picker so every search affordance in the product
              reads identically — flat outlined input, icon glued to
              the left, no capsule pill around it. */}
          <label className="search-field lang-picker-search">
            <Search size={14} strokeWidth={2} />
            <input
              autoFocus
              type="search"
              placeholder={t.lang_picker_search}
              value={q}
              onChange={(e) => setQ(e.target.value)}
            />
          </label>
          <div className="lang-picker-list">
            {filtered.length === 0 ? (
              <div className="lang-picker-empty">{t.lang_picker_empty}</div>
            ) : filtered.map((l) => (
              <button
                key={l.code}
                type="button"
                className={"profile-pop-item lang-picker-item" + (l.code === lang ? " is-active" : "")}
                role="menuitemradio"
                aria-checked={l.code === lang}
                onClick={() => { onChange(l.code); setOpen(false); }}
              >
                <span className={`fi fi-${l.cc} lang-picker-flag`} aria-hidden />
                <span className="lang-picker-name">{l.native}</span>
                <span className="lang-picker-sub">{l.name}</span>
                {l.code === lang && <Check size={14} strokeWidth={2.5} className="lang-picker-check" />}
              </button>
            ))}
          </div>
        </div>,
        document.body
      )}
    </>
  );
}
