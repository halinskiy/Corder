-- Bug reports — archive support. June 2026.
--
-- Adds a soft-archive flag so the admin can clear a handled / noise
-- report out of the active Logs list without hard-deleting it (the raw
-- log + AI summary stay queryable). `archived_at` null = active; a
-- timestamp = archived. The Worker's GET /admin/logs returns only active
-- rows by default and `?archived=true` for the archive view.
--
-- Run in the Supabase SQL editor against the Corder project:
--   https://supabase.com/dashboard/project/cfsajlsctzxgixjwslni/sql

begin;

alter table public.bug_reports
  add column if not exists archived_at timestamptz;

-- Active list is the hot path — index the "not archived" predicate.
create index if not exists bug_reports_active_idx
  on public.bug_reports (created_at desc)
  where archived_at is null;

commit;
