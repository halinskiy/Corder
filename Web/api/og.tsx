import { ImageResponse } from "@vercel/og";

/// The link-preview card for a shared meeting (`og:image`).
///
/// Pasting a Corder link into iMessage / Slack / Telegram used to unfurl as
/// "Shared meeting · Corder" with no picture — the same three words for every
/// link anyone ever sent. This renders the meeting itself: its title, when it
/// happened, how long it ran, who shared it.
///
/// The card is the share page's own vocabulary, not a new design: the white
/// sheet, the accent green spine down the left edge (a document's binding),
/// IBM Plex Serif for the title and Plex Sans for the metadata line — the
/// exact pairing `share.css` uses. Values come from `share.css` tokens.
///
/// Every parameter is supplied by the middleware that renders the page's
/// meta tags, so the card and the text a crawler shows always agree.
export const config = { runtime: "edge" };

const ACCENT = "#217a50";
const SHEET = "#fbfbfa";
const TEXT = "#0e0e0d";
const MUTED = "#6b6b68";

/// Fonts are subset to Latin + Cyrillic (53 KB each) because the titles are
/// whatever language the meeting was in, and a missing Cyrillic glyph renders
/// as tofu in every unfurl a Russian-speaking user ever sends.
const serifFont = fetch(new URL("../og-fonts/IBMPlexSerif-Medium.ttf", import.meta.url)).then((r) =>
  r.arrayBuffer(),
);
const sansFont = fetch(new URL("../og-fonts/IBMPlexSans-Medium.ttf", import.meta.url)).then((r) =>
  r.arrayBuffer(),
);

/// Title size steps down with length instead of wrapping into a wall: a card
/// is read at thumbnail size, so four lines of 44px beat seven of 30px.
function titleSize(title: string): number {
  if (title.length <= 34) return 76;
  if (title.length <= 60) return 64;
  if (title.length <= 95) return 54;
  return 46;
}

export default async function handler(request: Request) {
  const { searchParams, origin } = new URL(request.url);
  const title = (searchParams.get("title") || "Shared meeting").slice(0, 160);
  // Pre-formatted by the caller: it holds the meeting's own locale-free
  // wording ("17 August 2026 · 1h 5m · Ilia Khud") so this route never has to
  // agree with the page about date formatting.
  const meta = (searchParams.get("meta") || "").slice(0, 120);
  const [serif, sans] = await Promise.all([serifFont, sansFont]);

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          background: SHEET,
          fontFamily: "IBM Plex Sans",
        }}
      >
        {/* The spine: the accent edge that reads as a bound document. */}
        <div style={{ width: 20, height: "100%", background: ACCENT, display: "flex" }} />
        <div
          style={{
            flex: 1,
            display: "flex",
            flexDirection: "column",
            justifyContent: "space-between",
            padding: "56px 64px 52px 56px",
            background: SHEET,
          }}
        >
          <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
            {/* The BORDERED mark: the plain one is a white squircle and
                disappears on this sheet. */}
            <img src={`${origin}/brand-mark-bordered-256.png`} width={44} height={44} />
            <div style={{ fontSize: 27, color: TEXT, letterSpacing: "-0.01em" }}>Corder</div>
          </div>

          <div
            style={{
              display: "flex",
              fontFamily: "IBM Plex Serif",
              fontSize: titleSize(title),
              lineHeight: 1.14,
              letterSpacing: "-0.018em",
              color: TEXT,
              // A title longer than the card gets clipped, not shrunk to
              // illegibility; the description under the card carries the rest.
              maxHeight: 340,
              overflow: "hidden",
            }}
          >
            {title}
          </div>

          <div style={{ display: "flex", flexDirection: "column", gap: 18 }}>
            <div style={{ display: "flex", width: 92, height: 3, background: ACCENT }} />
            <div style={{ display: "flex", fontSize: 25, color: MUTED, letterSpacing: "-0.005em" }}>
              {meta}
            </div>
          </div>
        </div>
      </div>
    ),
    {
      width: 1200,
      height: 630,
      fonts: [
        { name: "IBM Plex Serif", data: serif, weight: 500, style: "normal" },
        { name: "IBM Plex Sans", data: sans, weight: 500, style: "normal" },
      ],
      headers: {
        // A share's title never changes after it is minted, and crawlers
        // re-fetch the card on every paste, so let the CDN keep it.
        "Cache-Control": "public, max-age=3600, s-maxage=86400, stale-while-revalidate=604800",
      },
    },
  );
}
