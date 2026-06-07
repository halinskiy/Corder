-- Bug reports + AI summaries — June 2026.
--
-- Backs the admin panel's "Logs" tab (3rd tab after News). Every time a
-- user taps the 🐞 Send-report button, the Worker (/submit-logs) still
-- emails the maintainer AND files a GitHub issue as before, but now ALSO
-- writes the report here and — in the background (ctx.waitUntil) — asks
-- Gemini Flash for a short summary so the admin can skim "what's most
-- important" without reading the raw log. Clicking a row reveals the
-- full `log_tail` with a Copy button.
--
-- Depends on `public.is_admin()` from 20260601_admin_news.sql.
--
-- Run in the Supabase SQL editor against the Corder project:
--   https://supabase.com/dashboard/project/cfsajlsctzxgixjwslni/sql

begin;

create table if not exists public.bug_reports (
  id              uuid primary key default gen_random_uuid(),
  created_at      timestamptz not null default now(),
  -- Reporter + environment, as sent by the Corder client.
  email           text not null default 'anonymous',
  app_version     text,
  macos_version   text,
  -- The raw tail of the user's log (already filtered client-side to the
  -- "interesting" lines). Capped by the Worker before insert.
  log_tail        text not null,
  -- AI summary, filled in asynchronously after insert. Null until the
  -- background Gemini call lands (or if it failed — the admin can
  -- re-trigger via POST /admin/logs/:id/summarize).
  title           text,                              -- ≤ ~8-word headline
  summary         text,                              -- 1-3 sentence digest
  severity        text check (severity in ('low', 'medium', 'high', 'critical')),
  summary_model   text,                              -- which model produced it
  summarized_at   timestamptz
);

comment on table public.bug_reports is
  'User-submitted 🐞 bug reports (raw log tail) + an async Gemini summary. Admin-only read; the Worker writes via service_role.';

-- Newest-first is the only access pattern the admin list needs.
create index if not exists bug_reports_created_idx
  on public.bug_reports (created_at desc);

-- ---------------------------------------------------------------------
-- RLS: admins read everything; nobody else sees reports. The Worker
-- inserts/updates with the service_role key, which bypasses RLS, so we
-- intentionally add NO insert/update policy (defence in depth — there's
-- no path for a normal JWT to write or read here).
-- ---------------------------------------------------------------------
alter table public.bug_reports enable row level security;

drop policy if exists bug_reports_admin_read on public.bug_reports;
create policy bug_reports_admin_read
  on public.bug_reports
  for select
  using (public.is_admin());

commit;
