import React from "react";
import { RotateCcw, Search } from "lucide-react";
import { OverlayScrollbar } from "./OverlayScrollbar";
import { Tooltip } from "./Tooltip";
import { listArchive, restoreMeeting, deleteMeeting, ArchivedMeeting } from "../api";
import { formatDate, formatDuration } from "../format";
import type { Lang, T } from "../i18n";

interface Props {
  /// Click on `← Library` returns to the normal meeting sidebar.
  onClose: () => void;
  /// Called after restore / delete so the parent refreshes the main
  /// library list (restored items reappear there immediately).
  onChanged: () => void;
  onToast: (msg: string, kind?: "success" | "error") => void;
  t: T;
  lang: Lang;
}

interface MenuState { x: number; y: number; meetingId: string }

/// Sidebar in "archive mode" — replaces the normal meeting sidebar
/// when the user opens the archive. Visually identical to `Sidebar`:
/// same `.meeting-item` rows, same hover/active fill, no checkboxes
/// or per-row chrome. Multi-select via Cmd-click + Shift-click; right-
/// click on the selection opens a Restore / Delete-forever menu.
export function ArchiveSidebar({ onClose, onChanged, onToast, t, lang }: Props) {
  const [items, setItems] = React.useState<ArchivedMeeting[]>([]);
  const [query, setQuery] = React.useState("");
  const [selectedIds, setSelectedIds] = React.useState<Set<string>>(() => new Set());
  const [anchorId, setAnchorId] = React.useState<string | null>(null);
  const [menu, setMenu] = React.useState<MenuState | null>(null);
  const [busy, setBusy] = React.useState(false);
  const listRef = React.useRef<HTMLDivElement>(null);
  const sidebarRef = React.useRef<HTMLElement>(null);

  const load = React.useCallback(async () => {
    try { setItems(await listArchive()); }
    catch { setItems([]); }
  }, []);

  React.useEffect(() => { load(); }, [load]);

  // Esc returns to library; matches the modal it replaced.
  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  // Click-outside closes the context menu (mirrors Sidebar).
  React.useEffect(() => {
    if (!menu) return;
    const close = () => setMenu(null);
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") close(); };
    window.addEventListener("click", close);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("click", close);
      window.removeEventListener("keydown", onKey);
    };
  }, [menu]);

  // Archive rows carry only a date + duration (no transcript preview),
  // so search matches the formatted date string — the same field the
  // row actually shows. Mirrors the Sidebar's search-as-you-type.
  const filtered = React.useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return items;
    return items.filter((it) => formatDate(it.started_at, lang).toLowerCase().includes(q));
  }, [items, query, lang]);

  const visibleOrder = React.useMemo(() => filtered.map((it) => it.id), [filtered]);

  const handleSelect = (e: React.MouseEvent, id: string) => {
    if (e.shiftKey && anchorId && anchorId !== id) {
      const a = visibleOrder.indexOf(anchorId);
      const b = visibleOrder.indexOf(id);
      if (a >= 0 && b >= 0) {
        const [lo, hi] = a < b ? [a, b] : [b, a];
        setSelectedIds(new Set(visibleOrder.slice(lo, hi + 1)));
        return;
      }
    }
    if (e.metaKey || e.ctrlKey) {
      const next = new Set(selectedIds);
      if (next.has(id)) next.delete(id); else next.add(id);
      setSelectedIds(next);
      setAnchorId(id);
      return;
    }
    setSelectedIds(new Set([id]));
    setAnchorId(id);
  };

  // The menu acts on the multi-selection if the right-clicked row is
  // part of it; otherwise on just that single row.
  const menuIds: string[] = menu
    ? (selectedIds.size > 1 && selectedIds.has(menu.meetingId)
        ? Array.from(selectedIds)
        : [menu.meetingId])
    : [];

  const restore = async () => {
    if (busy || menuIds.length === 0) return;
    setBusy(true);
    const ids = menuIds;
    setMenu(null);
    try {
      await Promise.all(ids.map((id) => restoreMeeting(id)));
      onToast(t.toast_archive_restored(ids.length), "success");
      setSelectedIds(new Set());
      setAnchorId(null);
      await load();
      onChanged();
    } finally {
      setBusy(false);
    }
  };

  const removeForever = async () => {
    if (busy || menuIds.length === 0) return;
    const ids = menuIds;
    if (!window.confirm(t.confirm_delete_forever(ids.length))) return;
    setBusy(true);
    setMenu(null);
    try {
      await Promise.all(ids.map((id) => deleteMeeting(id)));
      onToast(t.toast_archive_deleted(ids.length), "success");
      setSelectedIds(new Set());
      setAnchorId(null);
      await load();
      onChanged();
    } finally {
      setBusy(false);
    }
  };

  return (
    <aside className="sidebar arc-sidebar" ref={sidebarRef}>
      <div className="sidebar-titlebar-pad" />
      {/* Identical search header to the meeting Sidebar — no "Archive"
          title, no "< Library" back button (leaving archive is the
          Archive icon in the main header, which toggles). Just the
          same search field so the two panels read as one surface. */}
      <div className="sidebar-search">
        <div className="search-field">
          <Search size={14} strokeWidth={2} />
          <input
            type="search"
            placeholder={t.sidebar_search}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </div>
      </div>
      <div className="sidebar-list ovsb-scroll" ref={listRef}>
        {filtered.length === 0 ? (
          <div className="arc-sb-empty">{t.archive_empty}</div>
        ) : (
          filtered.map((it) => (
            <div
              key={it.id}
              className={"meeting-item arc-item" + (selectedIds.has(it.id) ? " active" : "")}
              onClick={(e) => handleSelect(e, it.id)}
              onContextMenu={(e) => {
                e.preventDefault();
                setMenu({ x: e.clientX, y: e.clientY, meetingId: it.id });
              }}
            >
              <div className="arc-item-text">
                <div className="meeting-row">
                  <div className="meeting-title">{formatDate(it.started_at, lang)}</div>
                </div>
                <div className="meeting-meta">
                  <span className="status-dot ready" />
                  {it.duration_ms != null && (
                    <span>{formatDuration(it.duration_ms, lang)}</span>
                  )}
                </div>
              </div>
              {/* Inline Restore — matches the `.toolbar-icon-btn`
                  look from the main header (outlined square, 16 px
                  icon). Stops click propagation so it does not also
                  toggle the row selection. */}
              <Tooltip label={t.archive_action_restore}>
                <button
                  type="button"
                  className="toolbar-icon-btn arc-item-restore"
                  onClick={async (e) => {
                    e.stopPropagation();
                    if (busy) return;
                    setBusy(true);
                    try {
                      await restoreMeeting(it.id);
                      onToast(t.toast_archive_restored(1), "success");
                      await load();
                      onChanged();
                    } finally {
                      setBusy(false);
                    }
                  }}
                  aria-label={t.archive_action_restore}
                  disabled={busy}
                >
                  <RotateCcw size={16} strokeWidth={2} />
                </button>
              </Tooltip>
            </div>
          ))
        )}
        <div className="sidebar-list-spacer" />
      </div>
      <OverlayScrollbar scrollRef={listRef} dividerRef={sidebarRef} name="corder-arc-list" />
      {menu && (
        <ArchiveContextMenu
          x={menu.x}
          y={menu.y}
          count={menuIds.length}
          disabled={busy}
          onRestore={restore}
          onDelete={removeForever}
          t={t}
        />
      )}
    </aside>
  );
}

/// Right-click menu for archive rows. Restore + Delete-forever, with
/// a count when the action targets multiple rows. Same `.ctx-*` chrome
/// as the library sidebar's context menu for visual parity.
function ArchiveContextMenu({ x, y, count, disabled, onRestore, onDelete, t }: {
  x: number; y: number; count: number; disabled: boolean;
  onRestore: () => void; onDelete: () => void; t: T;
}) {
  const isBatch = count > 1;
  return (
    <div
      className="ctx-menu"
      style={{ top: y, left: x }}
      onClick={(e) => e.stopPropagation()}
      onContextMenu={(e) => e.preventDefault()}
    >
      <button className="ctx-item" disabled={disabled} onClick={onRestore}>
        {isBatch ? `${t.archive_action_restore} (${count})` : t.archive_action_restore}
      </button>
      <div className="ctx-sep" />
      <button className="ctx-item" disabled={disabled} onClick={onDelete}>
        {isBatch
          ? `${t.archive_action_delete_forever} (${count})`
          : t.archive_action_delete_forever}
      </button>
    </div>
  );
}
