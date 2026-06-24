import type { Lang } from "./i18n";

/// First-person speaker placeholders the Swift pipeline writes into
/// `speakers.custom_name` ("you" by default). We replace them with
/// the signed-in user's display name everywhere the UI surfaces a
/// speaker label — Transcript, Timeline, anywhere a transcript-row
/// shows who said what — so the user reads their actual name, not a
/// placeholder. Case-insensitive list covers historical variants.
const FIRST_PERSON_PLACEHOLDERS = new Set(["you", "i", "me"]);

/// Resolve the on-screen label for a speaker. `customName` wins, but
/// if it's a first-person placeholder AND we know the signed-in
/// user's display name, swap it in. Falls back to the diarization
/// label ("Speaker 1") and finally to a generic "Speaker" sentinel.
export function displaySpeakerName(
  customName: string | null | undefined,
  diarLabel: string | null | undefined,
  profileName: string | null | undefined,
): string {
  const cn = (customName ?? "").trim();
  if (cn) {
    if (FIRST_PERSON_PLACEHOLDERS.has(cn.toLowerCase()) && profileName && profileName.trim()) {
      return profileName.trim();
    }
    return cn;
  }
  return (diarLabel ?? "").trim() || "Speaker";
}

const SHORT_M_EN = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
const LONG_M_EN  = ["January","February","March","April","May","June","July","August","September","October","November","December"];

function pad(n: number) { return n.toString().padStart(2, "0"); }

// English-only build. The `_lang` parameter is retained on the locale-
// aware helpers so the ~13 call sites (and a future locale) stay intact
// without a signature churn; it's intentionally unused for now.
export function formatDuration(ms?: number, _lang: Lang = "en"): string {
  if (!ms || ms < 0) return "—";
  const sec = Math.round(ms / 1000);
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  if (m === 0) return `${s}s`;
  return `${m}m ${s.toString().padStart(2, "0")}s`;
}

/// Just the clock time, `HH:MM`. Shown in the sidebar meta line after
/// the duration ("how long" · "when"). Language-agnostic.
export function formatClock(ms: number): string {
  const d = new Date(ms);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function formatDate(ms: number, _lang: Lang = "en"): string {
  const d = new Date(ms);
  const now = new Date();
  const sameDay = d.toDateString() === now.toDateString();
  const yesterday = new Date(now); yesterday.setDate(now.getDate() - 1);
  const isYesterday = d.toDateString() === yesterday.toDateString();
  const time = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  if (sameDay) return `Today, ${time}`;
  if (isYesterday) return `Yesterday, ${time}`;
  const sameYear = d.getFullYear() === now.getFullYear();
  const dateText = `${SHORT_M_EN[d.getMonth()]} ${d.getDate()}${sameYear ? "" : `, ${d.getFullYear()}`}`;
  return `${dateText}, ${time}`;
}

export function dateBucket(ms: number, _lang: Lang = "en"): string {
  const d = new Date(ms);
  const now = new Date();
  const diffDays = Math.floor((now.getTime() - d.getTime()) / 86_400_000);
  if (d.toDateString() === now.toDateString()) return "TODAY";
  const yesterday = new Date(now); yesterday.setDate(now.getDate() - 1);
  if (d.toDateString() === yesterday.toDateString()) return "YESTERDAY";
  if (diffDays < 7) return "THIS WEEK";
  if (diffDays < 30) return "THIS MONTH";
  return `${LONG_M_EN[d.getMonth()].toUpperCase()} ${d.getFullYear()}`;
}
