import type { Lang } from "./i18n";

const SHORT_M_RU = ["янв","фев","мар","апр","май","июн","июл","авг","сен","окт","ноя","дек"];
const LONG_M_RU = ["январь","февраль","март","апрель","май","июнь","июль","август","сентябрь","октябрь","ноябрь","декабрь"];
const SHORT_M_EN = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
const LONG_M_EN  = ["January","February","March","April","May","June","July","August","September","October","November","December"];

function pad(n: number) { return n.toString().padStart(2, "0"); }

export function formatDuration(ms?: number, lang: Lang = "ru"): string {
  if (!ms || ms < 0) return "—";
  const sec = Math.round(ms / 1000);
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  const sUnit = lang === "ru" ? "с" : "s";
  const mUnit = lang === "ru" ? "м" : "m";
  if (m === 0) return `${s}${sUnit}`;
  return `${m}${mUnit} ${s.toString().padStart(2, "0")}${sUnit}`;
}

/// Just the clock time, `HH:MM`. Shown in the sidebar meta line after
/// the duration ("how long" · "when"). Language-agnostic.
export function formatClock(ms: number): string {
  const d = new Date(ms);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function formatDate(ms: number, lang: Lang = "ru"): string {
  const d = new Date(ms);
  const now = new Date();
  const sameDay = d.toDateString() === now.toDateString();
  const yesterday = new Date(now); yesterday.setDate(now.getDate() - 1);
  const isYesterday = d.toDateString() === yesterday.toDateString();
  const time = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  if (sameDay) return lang === "ru" ? `Сегодня, ${time}` : `Today, ${time}`;
  if (isYesterday) return lang === "ru" ? `Вчера, ${time}` : `Yesterday, ${time}`;
  const months = lang === "ru" ? SHORT_M_RU : SHORT_M_EN;
  const sameYear = d.getFullYear() === now.getFullYear();
  const dateText = lang === "ru"
    ? `${d.getDate()} ${months[d.getMonth()]}${sameYear ? "" : ` ${d.getFullYear()}`}`
    : `${months[d.getMonth()]} ${d.getDate()}${sameYear ? "" : `, ${d.getFullYear()}`}`;
  return `${dateText}, ${time}`;
}

export function dateBucket(ms: number, lang: Lang = "ru"): string {
  const d = new Date(ms);
  const now = new Date();
  const diffDays = Math.floor((now.getTime() - d.getTime()) / 86_400_000);
  if (d.toDateString() === now.toDateString()) return lang === "ru" ? "СЕГОДНЯ" : "TODAY";
  const yesterday = new Date(now); yesterday.setDate(now.getDate() - 1);
  if (d.toDateString() === yesterday.toDateString()) return lang === "ru" ? "ВЧЕРА" : "YESTERDAY";
  if (diffDays < 7) return lang === "ru" ? "НА ЭТОЙ НЕДЕЛЕ" : "THIS WEEK";
  if (diffDays < 30) return lang === "ru" ? "В ЭТОМ МЕСЯЦЕ" : "THIS MONTH";
  const months = lang === "ru" ? LONG_M_RU : LONG_M_EN;
  return `${months[d.getMonth()].toUpperCase()} ${d.getFullYear()}`;
}
