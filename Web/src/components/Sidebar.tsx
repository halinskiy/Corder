import React from "react";
import { Search } from "lucide-react";
import { MeetingSummary, MeetingStatus, deleteMeeting, retranscribe } from "../api";
import { formatDate, formatDuration, dateBucket } from "../format";

function statusLabel(s: MeetingStatus): string {
  switch (s) {
    case "recording":    return "запись";
    case "transcribing": return "расшифровка";
    case "ready":        return "готово";
    case "failed":       return "ошибка";
  }
}

function plural(n: number): string {
  // Russian plural for участник: 1 участник, 2-4 участника, 5+ участников.
  const mod10 = n % 10, mod100 = n % 100;
  if (mod10 === 1 && mod100 !== 11) return "";
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return "а";
  return "ов";
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
  activeId: string | null;
  query: string;
  onQueryChange: (q: string) => void;
  onSelect: (id: string) => void;
  onDeleted: (id: string) => void;
  onToast: (msg: string, kind?: "success" | "error") => void;
}

interface MenuState { x: number; y: number; meetingId: string }

export function Sidebar({ meetings, activeId, query, onQueryChange, onSelect, onDeleted, onToast }: Props) {
  const [menu, setMenu] = React.useState<MenuState | null>(null);

  // Close the menu on any click outside or Escape. We deliberately do NOT
  // subscribe to `contextmenu` here — that exact handler is what was
  // killing the menu the moment it opened: the meeting-item's onContextMenu
  // fires, setMenu({...}) runs, the effect mounts and immediately receives
  // the same event bubbling up to window, and the menu closes again.
  // A fresh right-click on another item will open it for that item via the
  // `setMenu` path, which replaces the previous state anyway.
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
      formatDate(m.started_at).toLowerCase().includes(q)
    );
  }, [meetings, query]);

  // Group by date bucket while preserving sort order (newest first).
  const groups = React.useMemo(() => {
    const out: { label: string; items: MeetingSummary[] }[] = [];
    for (const m of filtered) {
      const label = dateBucket(m.started_at);
      const last = out[out.length - 1];
      if (last && last.label === label) last.items.push(m);
      else out.push({ label, items: [m] });
    }
    return out;
  }, [filtered]);

  return (
    <aside className="sidebar">
      <div className="sidebar-titlebar-pad" />
      <div className="sidebar-search">
        <div className="search-field">
          <Search size={14} strokeWidth={2} />
          <input
            type="search"
            placeholder="Поиск записей…"
            value={query}
            onChange={(e) => onQueryChange(e.target.value)}
          />
        </div>
      </div>
      <div className="sidebar-list">
        {filtered.length === 0 && (
          <div style={{ padding: 16, color: "var(--fg-muted)", fontSize: 13 }}>
            {meetings.length === 0
              ? "Записей пока нет. Нажми Start в menu bar."
              : "Нет совпадений."}
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
                  <div className="meeting-title">{formatDate(m.started_at)}</div>
                  {m.speaker_count > 0 && (
                    <div className="meeting-people" title={`${m.speaker_count} участник${plural(m.speaker_count)}`}>
                      <span className="meeting-people-count">{m.speaker_count}</span>
                      <UserFilledIcon />
                    </div>
                  )}
                </div>
                <div className="meeting-meta">
                  <span className={`status-dot ${m.status}`} />
                  <span>{formatDuration(m.duration_ms)}</span>
                  {m.status !== "ready" && <span>· {statusLabel(m.status)}</span>}
                </div>
                {m.preview && <div className="meeting-preview">{m.preview}</div>}
              </div>
            ))}
          </React.Fragment>
        ))}
      </div>
      {menu && (
        <ContextMenu
          x={menu.x}
          y={menu.y}
          onDelete={async () => {
            const id = menu.meetingId;
            setMenu(null);
            try { await deleteMeeting(id); onDeleted(id); }
            catch { onToast("Не удалось удалить", "error"); }
          }}
          onRetranscribe={async () => {
            const id = menu.meetingId;
            setMenu(null);
            try { await retranscribe(id); onToast("Запускаю расшифровку…", "success"); }
            catch { onToast("Не удалось запустить расшифровку", "error"); }
          }}
        />
      )}
    </aside>
  );
}

function ContextMenu({ x, y, onDelete, onRetranscribe }: {
  x: number; y: number; onDelete: () => void; onRetranscribe: () => void;
}) {
  return (
    <div
      className="ctx-menu"
      style={{ top: y, left: x }}
      onClick={(e) => e.stopPropagation()}
      onContextMenu={(e) => e.preventDefault()}
    >
      <button className="ctx-item" onClick={onRetranscribe}>Расшифровать заново</button>
      <div className="ctx-sep" />
      <button className="ctx-item ctx-danger" onClick={onDelete}>Удалить</button>
    </div>
  );
}
