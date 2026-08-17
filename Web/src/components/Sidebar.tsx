import React from "react";
import { Search } from "lucide-react";
import { MeetingSummary, MeetingStatus, retranscribe, retitle, pinMeeting, renameMeeting } from "../api";
import { OverlayScrollbar } from "./OverlayScrollbar";
import { formatDate, formatDuration, dateBucket } from "../format";
import type { Lang, T } from "../i18n";

function statusLabel(s: MeetingStatus, t: T): string {
  switch (s) {
    case "recording":    return t.status_recording;
    case "transcribing": return t.status_transcribing;
    case "ready":        return t.status_ready;
    case "failed":       return t.status_failed;
  }
}

function UserFilledIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor" aria-hidden>
      <circle cx="6" cy="3.5" r="2.2" />
      <path d="M1.5 11c0-2.3 2-4 4.5-4s4.5 1.7 4.5 4v0.5h-9V11z" />
    </svg>
  );
}

function PlayingIcon() {
  return (
    <span className="meeting-playing" title="Playing" aria-hidden>
      <svg width="15" height="15" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
        <path d="M8 5.5v13c0 .8.9 1.3 1.6.9l10.2-6.5a1 1 0 0 0 0-1.8L9.6 4.6C8.9 4.2 8 4.7 8 5.5z" />
      </svg>
    </span>
  );
}

interface Props {
  meetings: MeetingSummary[];
  /// False during the very first /api/meetings fetch, drives the
  /// shimmer skeleton so the empty-list state doesn't flash before the
  /// first response arrives.
  loaded: boolean;
  activeId: string | null;
  /// Meeting whose audio is currently playing, gets a red play glyph
  /// next to its title so it's obvious where the sound comes from.
  playingId?: string | null;
  query: string;
  onQueryChange: (q: string) => void;
  onSelect: (id: string) => void;
  onDeleted: (id: string) => void;
  /// Fired after a successful re-transcribe POST so the parent can tell
  /// the open MeetingView to start polling for the new transcript.
  onRetranscribed?: (id: string) => void;
  /// Fired after pin/unpin so the parent re-fetches the list (the
  /// pinned group reorders immediately instead of waiting for the poll).
  onChanged?: () => void;
  onToast: (msg: string, kind?: "success" | "error") => void;
  t: T;
  lang: Lang;
  /// Current paid-tier rung. Kept on the props for future use even
  /// though the upgrade card is gone, callers in main.tsx already
  /// pass it through, removing it here would cascade through other
  /// files for no benefit.
  /// Plumbed from main.tsx; consumed by no surface right now (the
  /// Upgrade card that used to read it was removed). Left on the
  /// prop bag so a future "Free-tier only" affordance has a
  /// wiring point that doesn't need to recompute the value.
  tier?: "free" | "pro" | "max";
}

interface MenuState { x: number; y: number; meetingId: string }

export function Sidebar({ meetings, loaded, activeId, playingId, query, onQueryChange, onSelect, onDeleted, onRetranscribed, onChanged, onToast, t, lang }: Props) {
  const [menu, setMenu] = React.useState<MenuState | null>(null);
  const [editing, setEditing] = React.useState<{ id: string; value: string } | null>(null);
  const listRef = React.useRef<HTMLDivElement>(null);
  const sidebarRef = React.useRef<HTMLElement>(null);

  // Multi-select: plain click → set of {id}, anchor = id. Cmd-click
  // toggles. Shift-click extends from anchor to the clicked row using
  // the currently-visible (filtered + grouped) order. No checkboxes
  // visual selection is just the existing `.meeting-item.active` style
  // applied to every member. Right-click on a row that's part of a
  // multi-selection swaps the context menu for an Archive-all variant.
  const [selectedIds, setSelectedIds] = React.useState<Set<string>>(() => new Set());
  const [anchorId, setAnchorId] = React.useState<string | null>(null);

  // A single click on a row stores its id in `selectedIds` so the row
  // wears the active style. When the user navigates back to the
  // Dashboard (activeId becomes null) that selection should clear too
  // otherwise the sidebar keeps the old row highlighted even though
  // nothing is open. Multi-select (Cmd/Shift) is a separate code path
  // and survives, only the implicit single-row selection is wiped.
  React.useEffect(() => {
    if (activeId === null) {
      setSelectedIds((cur) => (cur.size === 0 ? cur : new Set()));
      setAnchorId(null);
    }
  }, [activeId]);

  const commitRename = async () => {
    if (!editing) return;
    const { id, value } = editing;
    setEditing(null);
    try {
      await renameMeeting(id, value.trim());
      onChanged?.();
    } catch {
      onToast(t.toast_settings_failed, "error");
    }
  };

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

  const filtered = React.useMemo(() => {
    if (!query.trim()) return meetings;
    const q = query.toLowerCase();
    return meetings.filter((m) =>
      (m.preview || "").toLowerCase().includes(q) ||
      (m.speaker_names || "").toLowerCase().includes(q) ||
      formatDate(m.started_at, lang).toLowerCase().includes(q)
    );
  }, [meetings, query, lang]);

  const groups = React.useMemo(() => {
    const out: { label: string; items: MeetingSummary[] }[] = [];
    // Pinned sessions float to their own group at the very top,
    // regardless of date (server already orders them first).
    const pinned = filtered.filter((m) => m.pinned);
    if (pinned.length) out.push({ label: t.sidebar_pinned, items: pinned });
    for (const m of filtered) {
      if (m.pinned) continue;
      const label = dateBucket(m.started_at, lang);
      const last = out[out.length - 1];
      if (last && last.label === label && last.label !== t.sidebar_pinned) {
        last.items.push(m);
      } else {
        out.push({ label, items: [m] });
      }
    }
    return out;
  }, [filtered, lang, t]);

  // Flat list of meeting ids in the order they're VISIBLY rendered
  // (pinned group → date buckets). Shift-select uses this to fill the
  // contiguous range between anchor and clicked id.
  const visibleOrder = React.useMemo(
    () => groups.flatMap((g) => g.items.map((m) => m.id)),
    [groups]
  );

  const handleSelect = (e: React.MouseEvent, id: string) => {
    if (e.shiftKey && anchorId && anchorId !== id) {
      const a = visibleOrder.indexOf(anchorId);
      const b = visibleOrder.indexOf(id);
      if (a >= 0 && b >= 0) {
        const [lo, hi] = a < b ? [a, b] : [b, a];
        setSelectedIds(new Set(visibleOrder.slice(lo, hi + 1)));
        onSelect(id);
        return;
      }
    }
    if (e.metaKey || e.ctrlKey) {
      const next = new Set(selectedIds);
      if (next.has(id)) next.delete(id); else next.add(id);
      // Anchor moves to the most recently clicked id even on toggle
      // matches Finder's behaviour.
      setSelectedIds(next);
      setAnchorId(id);
      onSelect(id);
      return;
    }
    setSelectedIds(new Set([id]));
    setAnchorId(id);
    onSelect(id);
  };

  // When the user opens a context menu on a row that ISN'T part of the
  // current multi-selection, the menu acts on JUST that row, same as
  // before. When the right-clicked row IS in a multi-selection, we
  // collapse the menu to a single "Archive N selected" action.
  const menuIds: string[] = menu
    ? (selectedIds.size > 1 && selectedIds.has(menu.meetingId)
        ? Array.from(selectedIds)
        : [menu.meetingId])
    : [];
  const isBatchMenu = menuIds.length > 1;

  const archiveAllSelected = () => {
    const ids = Array.from(selectedIds);
    setSelectedIds(new Set());
    setAnchorId(null);
    setMenu(null);
    // Re-use the parent's per-id archive + undo flow. The 5-second
    // undo window applies to each individually; this is loud on the
    // toast stack but matches what right-click → Archive on a single
    // row already does, just N times.
    for (const id of ids) onDeleted(id);
  };

  return (
    <aside className="sidebar" ref={sidebarRef}>
      <div className="sidebar-titlebar-pad" />
      <div className="sidebar-search">
        <div className="search-field">
          <Search size={14} strokeWidth={2} />
          <input
            type="search"
            placeholder={t.sidebar_search}
            value={query}
            onChange={(e) => onQueryChange(e.target.value)}
          />
        </div>
      </div>
      <div className="sidebar-list ovsb-scroll" ref={listRef}>
        {!loaded && (
          <div className="sidebar-skeleton" aria-hidden>
            {Array.from({ length: 5 }).map((_, i) => (
              <div className="meeting-item skeleton-item" key={i}>
                <div className="skel-line skel-line-title" />
                <div className="skel-line skel-line-meta" />
                <div className="skel-line skel-line-preview" />
              </div>
            ))}
          </div>
        )}
        {loaded && filtered.length === 0 && (
          meetings.length === 0 ? (
            // Empty library → ghost placeholder row instead of a wall
            // of help text. Same `.meeting-item` shell as real rows so
            // sizes / paddings line up with everything else in the
            // sidebar (the search field above, the future first
            // recording below), faded to read as "this is where your
            // recordings will live".
            <>
              <div className="sidebar-section-label">{t.sidebar_today ?? "Today"}</div>
              <div className="meeting-item ghost" aria-hidden>
                <div className="meeting-row">
                  <div className="meeting-title">{t.ghost_title ?? "Your first recording"}</div>
                </div>
                <div className="meeting-meta">
                  <span className="status-dot ready" />
                  <span>{t.ghost_duration ?? "0:00"}</span>
                </div>
                <div className="meeting-preview">{t.ghost_preview ?? "Hit Start to begin."}</div>
              </div>
            </>
          ) : (
            <div className="sidebar-no-match">{t.sidebar_no_match}</div>
          )
        )}
        {groups.map((g) => (
          <React.Fragment key={g.label}>
            <div className="sidebar-section-label">{g.label}</div>
            {g.items.map((m) => {
              const titled = m.title?.trim();
              return (
              <div
                key={m.id}
                className={"meeting-item"
                  + ((m.id === activeId || selectedIds.has(m.id)) ? " active" : "")
                  + (m.status === "failed" ? " failed" : "")
                  + (m.pinned ? " pinned" : "")
                  + (m.viewed === false && m.status === "ready" ? " unseen" : "")}
                onClick={(e) => handleSelect(e, m.id)}
                onContextMenu={(e) => {
                  e.preventDefault();
                  setMenu({ x: e.clientX, y: e.clientY, meetingId: m.id });
                }}
              >
                <div className="meeting-row">
                  {editing?.id === m.id ? (
                    <input
                      className="meeting-title-edit"
                      autoFocus
                      value={editing.value}
                      placeholder={formatDate(m.started_at, lang)}
                      onClick={(e) => e.stopPropagation()}
                      onChange={(e) => setEditing({ id: m.id, value: e.target.value })}
                      onKeyDown={(e) => {
                        if (e.key === "Enter") { e.preventDefault(); commitRename(); }
                        else if (e.key === "Escape") { e.preventDefault(); setEditing(null); }
                      }}
                      onBlur={commitRename}
                    />
                  ) : (
                    <div className="meeting-title">
                      {titled || formatDate(m.started_at, lang)}
                    </div>
                  )}
                  {m.id === playingId && <PlayingIcon />}
                </div>
                <div className="meeting-meta">
                  <span className={`status-dot ${m.status}`} />
                  {m.duration_ms ? <span>{formatDuration(m.duration_ms, lang)}</span> : null}
                  {/* Drop the "transcribing" word from the meta, the
                      hollow status dot already tells the user there's
                      no transcript yet, and the literal word kept
                      reading as "work in progress" even after the
                      pipeline had already stopped (e.g. auto-transcribe
                      off, or a backend stall). recording / failed
                      still surface their label because those states
                      benefit from a name. */}
                  {m.status !== "ready" && m.status !== "transcribing" && (
                    <span>· {statusLabel(m.status, t)}</span>
                  )}
                  {m.speaker_count > 0 && (
                    <span className="meeting-people" title={t.participants(m.speaker_count)}>
                      <span className="meeting-people-count">{m.speaker_count}</span>
                      <UserFilledIcon />
                    </span>
                  )}
                </div>
                {m.preview && <div className="meeting-preview">{m.preview}</div>}
              </div>
              );
            })}
          </React.Fragment>
        ))}
        <div className="sidebar-list-spacer" />
      </div>
      {/* Upgrade CTA card removed, it overpowered the sidebar and the
          tier badge inside the profile popover already conveys plan
          state without selling. Re-introduce only if conversion data
          points at it. */}
      <OverlayScrollbar scrollRef={listRef} dividerRef={sidebarRef} name="corder-sb-list" />
      {menu && (
        isBatchMenu ? (
          <BatchContextMenu
            x={menu.x}
            y={menu.y}
            count={menuIds.length}
            onArchive={archiveAllSelected}
            t={t}
          />
        ) : (
          <ContextMenu
            x={menu.x}
            y={menu.y}
            t={t}
            pinned={!!meetings.find((m) => m.id === menu.meetingId)?.pinned}
            onRename={() => {
              const id = menu.meetingId;
              const cur = meetings.find((m) => m.id === id)?.title?.trim() ?? "";
              setMenu(null);
              setEditing({ id, value: cur });
            }}
            onPin={async () => {
              const id = menu.meetingId;
              const isPinned = !!meetings.find((m) => m.id === id)?.pinned;
              setMenu(null);
              try {
                await pinMeeting(id, !isPinned);
                onChanged?.();
              } catch {
                onToast(t.toast_settings_failed, "error");
              }
            }}
            onDelete={() => {
              const id = menu.meetingId;
              setMenu(null);
              // Actual DELETE is scheduled by the parent (10s undo window).
              onDeleted(id);
            }}
            onRetranscribe={async () => {
              const id = menu.meetingId;
              setMenu(null);
              try {
                await retranscribe(id);
                onToast(t.toast_retranscribe_started, "success");
                onRetranscribed?.(id);
              }
              catch { onToast(t.toast_retranscribe_failed, "error"); }
            }}
            onRetitle={async () => {
              const id = menu.meetingId;
              setMenu(null);
              onToast(t.toast_retitle_started, "success");
              try {
                await retitle(id);
                onChanged?.();
              }
              catch { onToast(t.toast_retitle_failed, "error"); }
            }}
          />
        )
      )}
    </aside>
  );
}

function ContextMenu({ x, y, pinned, onRename, onPin, onDelete, onRetranscribe, onRetitle, t }: {
  x: number; y: number; pinned: boolean;
  onRename: () => void; onPin: () => void; onDelete: () => void;
  onRetranscribe: () => void; onRetitle: () => void; t: T;
}) {
  return (
    <div
      className="ctx-menu"
      style={{ top: y, left: x }}
      onClick={(e) => e.stopPropagation()}
      onContextMenu={(e) => e.preventDefault()}
    >
      <button className="ctx-item" onClick={onRename}>{t.ctx_rename}</button>
      <button className="ctx-item" onClick={onRetitle}>{t.ctx_retitle}</button>
      <button className="ctx-item" onClick={onPin}>
        {pinned ? t.ctx_unpin : t.ctx_pin}
      </button>
      <button className="ctx-item" onClick={onRetranscribe}>{t.ctx_retranscribe}</button>
      <div className="ctx-sep" />
      <button className="ctx-item" onClick={onDelete}>{t.ctx_archive}</button>
    </div>
  );
}

/// Right-click menu when the user opened the context on a row that's
/// part of a multi-selection, collapse to a single batch action so
/// per-row operations (rename, pin, re-transcribe) don't try to apply
/// to N rows at once.
function BatchContextMenu({ x, y, count, onArchive, t }: {
  x: number; y: number; count: number; onArchive: () => void; t: T;
}) {
  return (
    <div
      className="ctx-menu"
      style={{ top: y, left: x }}
      onClick={(e) => e.stopPropagation()}
      onContextMenu={(e) => e.preventDefault()}
    >
      <button className="ctx-item" onClick={onArchive}>
        {t.ctx_archive_selected(count)}
      </button>
    </div>
  );
}
