import { next } from "@vercel/edge";

/// Server-renders the link preview for `share.getcorder.com/<token>`.
///
/// The page itself is a static SPA: the transcript arrives from the Worker in
/// the browser, which means a crawler (iMessage, Slack, Telegram, WhatsApp,
/// Discord, X) reading the raw HTML saw one hardcoded card — "Shared meeting ·
/// Corder", no picture — for every link anyone ever sent. Granola's links
/// unfurl with the meeting's own title, the first lines of its notes and a
/// rendered card, which is most of why their links get opened.
///
/// So: for a token path, fetch the meeting's PREVIEW metadata (a few hundred
/// bytes — never the full transcript, see `/share/<token>/meta` in the Worker)
/// and rewrite the head of the static shell with it. The <title> is rewritten
/// too, so a browser tab shows the meeting instead of "Shared meeting".
///
/// Fail-open by design: any error, timeout, expired or unknown token falls
/// through to the untouched static page. A preview is never worth a broken
/// share link, and the SPA renders the real "This link has expired" state
/// better than a crawler card could.
export const config = {
  // Everything except the OG route, build assets and any path with a file
  // extension. The token check below is the real filter; this only keeps the
  // middleware off the hot static paths.
  matcher: ["/((?!api/|assets/|.*\\.).*)"],
};

const API = "https://corder-api.empqwork.workers.dev";
const FALLBACK_TITLE = "Shared meeting · Corder";
const FALLBACK_DESC = "Transcript, summary and audio, shared with Corder.";

interface ShareMeta {
  ok: boolean;
  title: string | null;
  started_at: string | null;
  duration_ms: number | null;
  owner_name: string | null;
  speakers: string[];
  is_clip: boolean;
  preview: string | null;
}

function esc(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatDate(iso: string | null): string | null {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  return d.toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" });
}

function formatDuration(ms: number | null): string | null {
  if (!ms || ms < 1000) return null;
  const total = Math.round(ms / 60000);
  const h = Math.floor(total / 60);
  const m = total % 60;
  if (h > 0) return m > 0 ? `${h}h ${m}m` : `${h}h`;
  return `${Math.max(1, m)}m`;
}

export default async function middleware(request: Request) {
  const url = new URL(request.url);
  const token = url.pathname.slice(1);
  if (!/^[A-Za-z0-9_-]{16,}$/.test(token)) return next();

  let meta: ShareMeta | null = null;
  try {
    const res = await fetch(`${API}/share/${token}/meta`, {
      // A crawler waits seconds, not minutes; past that the static shell is
      // the better answer.
      signal: AbortSignal.timeout(3000),
    });
    if (res.ok) meta = (await res.json()) as ShareMeta;
  } catch {
    /* fall through to the static page */
  }
  if (!meta?.ok) return next();

  let html: string;
  try {
    const shell = await fetch(new URL("/index.html", url), { signal: AbortSignal.timeout(3000) });
    if (!shell.ok) return next();
    html = await shell.text();
  } catch {
    return next();
  }

  const title = (meta.title || "").trim() || FALLBACK_TITLE;
  const description = (meta.preview || "").trim() || FALLBACK_DESC;
  const bits = [formatDate(meta.started_at), formatDuration(meta.duration_ms)].filter(Boolean) as string[];
  const owner = (meta.owner_name || "").trim();
  if (owner) bits.push(`Shared by ${owner}`);
  const metaLine = bits.join(" · ");

  const image = `${url.origin}/api/og?title=${encodeURIComponent(title)}&meta=${encodeURIComponent(metaLine)}`;
  const tags = [
    `<title>${esc(title)}</title>`,
    `<meta name="description" content="${esc(description)}" />`,
    `<meta property="og:type" content="article" />`,
    `<meta property="og:site_name" content="Corder" />`,
    `<meta property="og:title" content="${esc(title)}" />`,
    `<meta property="og:description" content="${esc(description)}" />`,
    `<meta property="og:url" content="${esc(url.origin + url.pathname)}" />`,
    `<meta property="og:image" content="${esc(image)}" />`,
    `<meta property="og:image:width" content="1200" />`,
    `<meta property="og:image:height" content="630" />`,
    `<meta name="twitter:card" content="summary_large_image" />`,
    `<meta name="twitter:title" content="${esc(title)}" />`,
    `<meta name="twitter:description" content="${esc(description)}" />`,
    `<meta name="twitter:image" content="${esc(image)}" />`,
  ].join("\n    ");

  // Drop the shell's placeholder head tags rather than leaving duplicates —
  // crawlers differ on which copy wins. The new ones go AFTER <meta charset>,
  // never before it: a Cyrillic title ahead of the encoding declaration is
  // read as mojibake by anything that ignores the HTTP header.
  const stripped = html
    .replace(/<title>[\s\S]*?<\/title>\s*/i, "")
    .replace(/<meta\s+name="description"[^>]*>\s*/i, "")
    .replace(/<meta\s+property="og:[^"]*"[^>]*>\s*/gi, "");
  const head = /<meta\s+charset=/i.test(stripped)
    ? stripped.replace(/(<meta\s+charset=[^>]*>)/i, `$1\n    ${tags}`)
    : stripped.replace(/<head>/i, `<head>\n    ${tags}`);

  return new Response(head, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      // A share link is unguessable but public; keep it out of search results
      // exactly like the static headers in vercel.json do.
      "X-Robots-Tag": "noindex, nofollow",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "strict-origin-when-cross-origin",
      // Short shared cache: the title can change (the owner renames a meeting
      // and re-shares), and an unfurl is a one-shot read anyway.
      "Cache-Control": "public, max-age=0, s-maxage=300, stale-while-revalidate=3600",
    },
  });
}
