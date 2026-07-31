-- Corder share clips — add the time range to `shares`.
-- Paste into Supabase SQL Editor (project cfsajlsctzxgixjwslni) and Run.
--
-- A share is now either the WHOLE meeting (both columns NULL) or one time
-- range of it (both set, in milliseconds from the meeting start). The app cuts
-- the .m4a to the same range before upload, so a clip's audio physically
-- contains only the shared part. The Worker derives everything from these two
-- columns: it filters segments to the range, re-bases their timings to zero,
-- and keys "one link per meeting" separately for full shares vs each clip.

alter table public.shares
  add column if not exists clip_start_ms bigint,
  add column if not exists clip_end_ms   bigint;

-- The Worker's "reuse the live token" lookup filters by (meeting_id, owner_id,
-- clip range), so this composite index serves both the full-share path
-- (clip_start_ms IS NULL) and each clip.
create index if not exists shares_meeting_clip_idx
  on public.shares (meeting_id, owner_id, clip_start_ms, clip_end_ms);
