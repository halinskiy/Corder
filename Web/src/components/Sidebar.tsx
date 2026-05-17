import React from "react";
import { Search } from "lucide-react";
import { MeetingSummary, MeetingStatus, retranscribe, pinMeeting, renameMeeting } from "../api";
import { formatDate, formatClock, formatDuration, dateBucket } from "../format";
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

interface Props {
  meetings: MeetingSummary[];
  /// False during the very first /api/meetings fetch — drives the
  /// shimmer skeleton so the empty-list state doesn't flash before the
  /// first response arrives.
  loaded: boolean;
  activeId: string | null;
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
}

interface MenuState { x: number; y: number; meetingId: string }

export function Sidebar({ meetings, loaded, activeId, query, onQueryChange, onSelect, onDeleted, onRetranscribed, onChanged, onToast, t, lang }: Props) {
  const [menu, setMenu] = React.useState<MenuState | null>(null);
  const [editing, setEditing] = React.useState<{ id: string; value: string } | null>(null);

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

  return (
    <aside className="sidebar">
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
      <div className="sidebar-list">
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
          <div style={{ padding: 16, color: "var(--fg-muted)", fontSize: 13 }}>
            {meetings.length === 0 ? t.sidebar_empty : t.sidebar_no_match}
          </div>
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
                  + (m.id === activeId ? " active" : "")
                  + (m.status === "failed" ? " failed" : "")
                  + (m.pinned ? " pinned" : "")}
                onClick={() => onSelect(m.id)}
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
                    <>
                      <div className="meeting-title">
                        {titled || formatDate(m.started_at, lang)}
                      </div>
                      {m.pinned && <span className="pin-dot" aria-hidden />}
                    </>
                  )}
                </div>
                <div className="meeting-meta">
                  <span className={`status-dot ${m.status}`} />
                  {m.duration_ms ? <span>{formatDuration(m.duration_ms, lang)}</span> : null}
                  <span className="meeting-date">{formatClock(m.started_at)}</span>
                  {m.status !== "ready" && <span>· {statusLabel(m.status, t)}</span>}
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
      {menu && (
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
        />
      )}
    </aside>
  );
}

function ContextMenu({ x, y, pinned, onRename, onPin, onDelete, onRetranscribe, t }: {
  x: number; y: number; pinned: boolean;
  onRename: () => void; onPin: () => void; onDelete: () => void;
  onRetranscribe: () => void; t: T;
}) {
  return (
    <div
      className="ctx-menu"
      style={{ top: y, left: x }}
      onClick={(e) => e.stopPropagation()}
      onContextMenu={(e) => e.preventDefault()}
    >
      <button className="ctx-item" onClick={onRename}>{t.ctx_rename}</button>
      <button className="ctx-item" onClick={onPin}>
        {pinned ? t.ctx_unpin : t.ctx_pin}
      </button>
      <button className="ctx-item" onClick={onRetranscribe}>{t.ctx_retranscribe}</button>
      <div className="ctx-sep" />
      <button className="ctx-item" onClick={onDelete}>{t.ctx_archive}</button>
    </div>
  );
}
