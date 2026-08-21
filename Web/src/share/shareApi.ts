import type { MeetingDetail, SpeakerDTO, SegmentDTO } from "../api";

const WORKER = "https://corder-api.empqwork.workers.dev";

/// What `GET /share/<token>` actually returns. Deliberately NOT MeetingDetail:
/// the Worker speaks the Postgres column names (`display_name`, `position`),
/// the frontend speaks its own DTOs (`custom_name`, `id`), and mapping between
/// them is this module's whole job.
interface ShareResponse {
  ok: boolean;
  meeting: { id: string; title: string | null; started_at: string; duration_ms: number | null };
  speakers: Array<{
    id: string; label: string; display_name: string | null;
    kind: string; position: number;
  }>;
  segments: Array<{
    speaker_id: string; start_ms: number; end_ms: number;
    text: string; position: number;
  }>;
  summary: string | null;
  // Chapters ride the share as a plain array (the Worker reads them off the
  // meeting row). Older shares / meetings without chapters send null, so the
  // Chapters tab simply doesn't appear.
  chapters: Array<{ start_ms: number; title: string }> | null;
  owner_name: string | null;
  expires_at: string;
  audio_url: string | null;
}

export interface Share {
  detail: MeetingDetail;
  chapters: Array<{ startMs: number; title: string }>;
  ownerName: string | null;
  audioUrl: string | null;
  expiresAt: string;
}

export class ShareGone extends Error {}

/// Fetch + adapt one share. Throws `ShareGone` for a revoked/expired/unknown
/// token (the Worker answers 410) so the page can show the "link expired"
/// state instead of a generic error.
export async function fetchShare(token: string): Promise<Share> {
  const r = await fetch(`${WORKER}/share/${encodeURIComponent(token)}`);
  if (r.status === 410 || r.status === 404) throw new ShareGone("This link has expired.");
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  const d = (await r.json()) as ShareResponse;
  if (!d.ok) throw new ShareGone("This link is no longer available.");

  const speakers: SpeakerDTO[] = d.speakers.map((s) => ({
    id: s.id,
    label: s.label,
    // The panes read `custom_name` (via `displaySpeakerName`), the DB column
    // is `display_name`.
    custom_name: s.display_name,
  }));

  // `SegmentDTO.id` is a required number used as the React key, the `data-segid`
  // attribute, and the binary-search probe for the currently-playing line. The
  // share payload has no segment id (the app's are local autoincrement rowids
  // that mean nothing here), so `position` becomes the id.
  const segments: SegmentDTO[] = d.segments.map((s) => ({
    id: s.position,
    speaker_id: s.speaker_id,
    start_ms: s.start_ms,
    end_ms: s.end_ms,
    text: s.text,
  }));
  // TranscriptPane binary-searches the active line and assumes segments are
  // monotonic by start_ms. Sort defensively rather than trust the row order.
  segments.sort((a, b) => a.start_ms - b.start_ms);

  const detail: MeetingDetail = {
    id: d.meeting.id,
    started_at: Date.parse(d.meeting.started_at),
    duration_ms: d.meeting.duration_ms ?? 0,
    // Synthesised: the Worker only ever shares finished meetings, and both
    // panes gate their real content on `status === "ready"`.
    status: "ready",
    title: d.meeting.title,
    summary: d.summary,
    speakers,
    segments,
    has_audio: !!d.audio_url,
    has_video: false,   // Phase 1 is audio-only
  };

  const chapters = (d.chapters ?? [])
    .map((c) => ({ startMs: c.start_ms, title: (c.title || "").trim() }))
    .filter((c) => c.title)
    .sort((a, b) => a.startMs - b.startMs);

  return {
    detail,
    chapters,
    ownerName: d.owner_name,
    audioUrl: d.audio_url,
    expiresAt: d.expires_at,
  };
}

/// Token = the whole path: share.getcorder.com/<token>.
export function tokenFromLocation(): string | null {
  const raw = window.location.pathname.replace(/^\/+|\/+$/g, "");
  return /^[A-Za-z0-9_-]{16,}$/.test(raw) ? raw : null;
}
