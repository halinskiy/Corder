/// Chapters tab for the share page.
///
/// A list of jump points, in the document's own type. Each row is one seek
/// action (the whole row is the target, like a transcript line), and the row
/// whose window contains the playhead lights up — the same active-chapter rule
/// the app's ChaptersPane uses, minus the toolbar / regenerate / gates that
/// only make sense inside the app.
export type ShareChapter = { startMs: number; title: string };

export function ShareChapters({
  chapters, currentTimeSec, onSeek,
}: {
  chapters: ShareChapter[];
  currentTimeSec: number;
  onSeek: (sec: number) => void;
}) {
  const nowMs = currentTimeSec * 1000;
  // Active = the last chapter that has started. Chapters are start-ordered.
  let activeIdx = -1;
  for (let i = 0; i < chapters.length; i++) {
    if (chapters[i].startMs <= nowMs) activeIdx = i;
    else break;
  }

  return (
    <div className="sp-chapters">
      {chapters.map((c, i) => (
        <button
          key={i}
          type="button"
          className={"sp-chapter" + (i === activeIdx ? " is-active" : "")}
          onClick={() => onSeek(Math.max(0, c.startMs / 1000))}
        >
          <span className="sp-chapter-time">{fmtTime(c.startMs)}</span>
          <span className="sp-chapter-title">{c.title}</span>
        </button>
      ))}
    </div>
  );
}

function fmtTime(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  return `${m}:${String(s).padStart(2, "0")}`;
}
