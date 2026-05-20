import React from "react";
import { X, RotateCcw, Trash2 } from "lucide-react";
import { listArchive, restoreMeeting, deleteMeeting, ArchivedMeeting } from "../api";
import { formatDate, formatDuration } from "../format";
import type { Lang, T } from "../i18n";

interface Props {
  onClose: () => void;
  /// Called after a destructive/restorative action so the parent can refresh
  /// its main library list — restored items reappear there immediately.
  onChanged: () => void;
  onToast: (msg: string, kind?: "success" | "error") => void;
  t: T;
  lang: Lang;
}

/// Full-screen overlay listing archived meetings. Soft-archived meetings
/// linger here for 7 days before automatic hard-delete on next launch.
/// User can pick rows (or master-toggle all) and either restore them back
/// to the main library or wipe them immediately.
///
/// Visually this is in the same family as EmptyDeleteBanner /
/// SpeakersClarifyBanner — outline card on the `--bg`, `.clarify-body`
/// (18/300) heading, `.segment-paragraph` (15/1.7) body type, and
/// `.clarify-btn` actions. Replaces the old 20px-radius / heavy-shadow
/// `donate-card` shell which read as a generic stock popup.
export function ArchiveView({ onClose, onChanged, onToast, t, lang }: Props) {
  const [items, setItems] = React.useState<ArchivedMeeting[]>([]);
  const [selected, setSelected] = React.useState<Set<string>>(new Set());
  const [busy, setBusy] = React.useState(false);

  const load = React.useCallback(async () => {
    try { setItems(await listArchive()); }
    catch { setItems([]); }
  }, []);

  React.useEffect(() => { load(); }, [load]);

  // Esc closes the overlay (matches the Donate modal behaviour we replaced).
  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const allSelected = items.length > 0 && selected.size === items.length;
  const someSelected = selected.size > 0 && !allSelected;

  const toggleAll = () => {
    setSelected(allSelected ? new Set() : new Set(items.map((it) => it.id)));
  };
  const toggleOne = (id: string) => {
    setSelected((prev) => {
      const n = new Set(prev);
      if (n.has(id)) n.delete(id); else n.add(id);
      return n;
    });
  };

  const restoreSelected = async () => {
    if (busy || selected.size === 0) return;
    setBusy(true);
    const ids = Array.from(selected);
    try {
      await Promise.all(ids.map((id) => restoreMeeting(id)));
      onToast(t.toast_archive_restored(ids.length), "success");
      setSelected(new Set());
      await load();
      onChanged();
    } finally {
      setBusy(false);
    }
  };

  const deleteSelected = async () => {
    if (busy || selected.size === 0) return;
    const ids = Array.from(selected);
    if (!window.confirm(t.confirm_delete_forever(ids.length))) return;
    setBusy(true);
    try {
      // Hard-delete: same endpoint we used pre-archive feature. It wipes
      // the DB row, the local recording dir and best-effort the Dropbox
      // copies. Doing them in parallel is fine — they're independent.
      await Promise.all(ids.map((id) => deleteMeeting(id)));
      onToast(t.toast_archive_deleted(ids.length), "success");
      setSelected(new Set());
      await load();
      onChanged();
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="donate-overlay" onClick={onClose}>
      <div
        className="modal-pop archive-pop"
        role="dialog"
        aria-label={t.archive_title}
        onClick={(e) => e.stopPropagation()}
      >
        <button
          className="modal-pop-close"
          onClick={onClose}
          title={t.archive_close_title}
          aria-label={t.archive_close_title}
        >
          <X size={16} strokeWidth={2} />
        </button>
        <div className="modal-pop-title">{t.archive_title}</div>
        <div className="modal-pop-note">{t.archive_retention_note}</div>

        {items.length === 0 ? (
          <div className="archive-pop-empty">{t.archive_empty}</div>
        ) : (
          <>
            <label className="archive-pop-head">
              <span className="archive-pop-check">
                <input
                  type="checkbox"
                  checked={allSelected}
                  ref={(el) => { if (el) el.indeterminate = someSelected; }}
                  onChange={toggleAll}
                />
              </span>
              <span>{t.archive_select_all}</span>
            </label>
            <div className="archive-pop-list">
              {items.map((it) => {
                const checked = selected.has(it.id);
                const daysLeft = Math.max(0, Math.ceil((it.purge_at - Date.now()) / 86_400_000));
                return (
                  <label
                    key={it.id}
                    className={"archive-pop-row" + (checked ? " selected" : "")}
                  >
                    <span className="archive-pop-check">
                      <input
                        type="checkbox"
                        checked={checked}
                        onChange={() => toggleOne(it.id)}
                      />
                    </span>
                    <span className="archive-pop-name">
                      <span className="archive-pop-name-title">{formatDate(it.started_at, lang)}</span>
                      {it.duration_ms != null && (
                        <span className="archive-pop-name-meta">{formatDuration(it.duration_ms, lang)}</span>
                      )}
                    </span>
                    <span className="archive-pop-purge">{t.archive_purge_in(daysLeft)}</span>
                  </label>
                );
              })}
            </div>
          </>
        )}

        {selected.size > 0 && (
          <div className="clarify-actions archive-pop-actions">
            <button
              className="clarify-btn"
              onClick={restoreSelected}
              disabled={busy}
            >
              <RotateCcw size={14} strokeWidth={2} /> {t.archive_action_restore}
            </button>
            <button
              className="clarify-btn danger"
              onClick={deleteSelected}
              disabled={busy}
            >
              <Trash2 size={14} strokeWidth={2} /> {t.archive_action_delete_forever}
            </button>
          </div>
        )}
      </div>
    </div>
  );
}
