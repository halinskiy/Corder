export function formatDuration(ms?: number): string {
  if (!ms || ms < 0) return "—";
  const sec = Math.round(ms / 1000);
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  if (m === 0) return `${s}с`;
  return `${m}м ${s.toString().padStart(2, "0")}с`;
}

export function formatTimestamp(ms: number): string {
  const sec = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  if (h > 0) return `${h}:${pad(m)}:${pad(s)}`;
  return `${m}:${pad(s)}`;
}
function pad(n: number) { return n.toString().padStart(2, "0"); }

export function formatDate(ms: number): string {
  const d = new Date(ms);
  const now = new Date();
  const sameDay = d.toDateString() === now.toDateString();
  const yesterday = new Date(now); yesterday.setDate(now.getDate() - 1);
  const isYesterday = d.toDateString() === yesterday.toDateString();
  const time = d.toLocaleTimeString("ru-RU", { hour: "2-digit", minute: "2-digit" });
  if (sameDay) return `Сегодня, ${time}`;
  if (isYesterday) return `Вчера, ${time}`;
  const sameYear = d.getFullYear() === now.getFullYear();
  return d.toLocaleDateString("ru-RU", {
    month: "short",
    day: "numeric",
    year: sameYear ? undefined : "numeric",
  }) + `, ${time}`;
}

export function dateBucket(ms: number): string {
  const d = new Date(ms);
  const now = new Date();
  const diffDays = Math.floor((now.getTime() - d.getTime()) / 86_400_000);
  if (d.toDateString() === now.toDateString()) return "Сегодня";
  const yesterday = new Date(now); yesterday.setDate(now.getDate() - 1);
  if (d.toDateString() === yesterday.toDateString()) return "Вчера";
  if (diffDays < 7) return "На этой неделе";
  if (diffDays < 30) return "В этом месяце";
  return d.toLocaleDateString("ru-RU", { month: "long", year: "numeric" });
}
