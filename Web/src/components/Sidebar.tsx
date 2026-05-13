import React from "react";
import { Search } from "lucide-react";
import { MeetingSummary, MeetingStatus, retranscribe } from "../api";
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
  onToast: (msg: string, kind?: "success" | "error") => void;
  t: T;
  lang: Lang;
}

interface MenuState { x: number; y: number; meetingId: string }

export function Sidebar({ meetings, loaded, activeId, query, onQueryChange, onSelect, onDeleted, onToast, t, lang }: Props) {
  const [menu, setMenu] = React.useState<MenuState | null>(null);

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
    for (const m of filtered) {
      const label = dateBucket(m.started_at, lang);
      const last = out[out.length - 1];
      if (last && last.label === label) last.items.push(m);
      else out.push({ label, items: [m] });
    }
    return out;
  }, [filtered, lang]);

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
            {g.items.map((m) => (
              <div
                key={m.id}
                className={"meeting-item" + (m.id === activeId ? " active" : "")}
                onClick={() => onSelect(m.id)}
                onContextMenu={(e) => {
                  e.preventDefault();
                  setMenu({ x: e.clientX, y: e.clientY, meetingId: m.id });
                }}
              >
                <div className="meeting-row">
                  <div className="meeting-title">{formatDate(m.started_at, lang)}</div>
                  {m.speaker_count > 0 && (
                    <div className="meeting-people" title={t.participants(m.speaker_count)}>
                      <span className="meeting-people-count">{m.speaker_count}</span>
                      <UserFilledIcon />
                    </div>
                  )}
                </div>
                <div className="meeting-meta">
                  <span className={`status-dot ${m.status}`} />
                  <span>{formatDuration(m.duration_ms, lang)}</span>
                  {m.status !== "ready" && <span>· {statusLabel(m.status, t)}</span>}
                </div>
                {m.preview && <div className="meeting-preview">{m.preview}</div>}
              </div>
            ))}
          </React.Fragment>
        ))}
        <div className="sidebar-list-spacer" />
      </div>
      {menu && (
        <ContextMenu
          x={menu.x}
          y={menu.y}
          t={t}
          onDelete={() => {
            const id = menu.meetingId;
            setMenu(null);
            // Actual DELETE is scheduled by the parent (10s undo window).
            onDeleted(id);
          }}
          onRetranscribe={async () => {
            const id = menu.meetingId;
            setMenu(null);
            try { await retranscribe(id); onToast(t.toast_retranscribe_started, "success"); }
            catch { onToast(t.toast_retranscribe_failed, "error"); }
          }}
        />
      )}
    </aside>
  );
}

function ContextMenu({ x, y, onDelete, onRetranscribe, t }: {
  x: number; y: number; onDelete: () => void; onRetranscribe: () => void; t: T;
}) {
  return (
    <div
      className="ctx-menu"
      style={{ top: y, left: x }}
      onClick={(e) => e.stopPropagation()}
      onContextMenu={(e) => e.preventDefault()}
    >
      <button className="ctx-item" onClick={onRetranscribe}>{t.ctx_retranscribe}</button>
      <div className="ctx-sep" />
      <button className="ctx-item" onClick={onDelete}>{t.ctx_archive}</button>
    </div>
  );
}
