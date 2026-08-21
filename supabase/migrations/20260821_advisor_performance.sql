-- Supabase Performance Advisor cleanup, August 2026 (all WARNING level).
-- Companion to 20260821_news_active_security_invoker.sql and
-- 20260821_advisor_security_hardening.sql.
--
-- A) "Auth RLS Initialization Plan" — a policy that calls auth.uid() (or
--    is_admin(), which reads auth.jwt()) directly re-evaluates it once PER
--    ROW. Wrapping the call in a scalar subquery, (select auth.uid()),
--    makes Postgres treat it as an InitPlan evaluated ONCE per statement.
--    Behaviour is identical; only the per-row multiplier disappears.
--
-- B) "Multiple Permissive Policies" — the child tables (recordings_meta,
--    segments, speakers, summaries) each carried a FOR ALL policy AND a
--    redundant standalone FOR SELECT policy with the identical expression,
--    so every SELECT evaluated both. FOR ALL already grants SELECT, so the
--    standalone one is dropped (zero behaviour change). news_items is
--    restructured from ALL+SELECT into one policy per action so no
--    (role, action) pair has two permissive policies.
--
-- C) "Unindexed foreign keys" — news_items.created_by and
--    segments.speaker_id had no covering index. Add btree indexes so a
--    cascade / join on them does not fall back to a sequential scan.
--
-- NOT touched: "Unused Index" on meetings_user_archive_idx and
-- shares_meeting_clip_idx. Both back real features (the archive filter and
-- clip sharing) that simply have not accumulated query traffic yet; scans=0
-- means "unexercised", not "useless".
--
-- All RLS here is bypassed by the Worker's service-role key, so these
-- changes only affect direct anon/authenticated PostgREST access from the
-- Corder app. Verified end-to-end: owner still sees own rows, a stranger
-- sees zero, anon still reads news_active.
--
-- Run in the Supabase SQL editor against the Corder project:
--   https://supabase.com/dashboard/project/cfsajlsctzxgixjwslni/sql

begin;

-- ── profiles
drop policy if exists "profiles: select own" on public.profiles;
create policy "profiles: select own" on public.profiles
  for select using ((select auth.uid()) = id);
drop policy if exists "profiles: update own" on public.profiles;
create policy "profiles: update own" on public.profiles
  for update using ((select auth.uid()) = id);

-- ── meetings
drop policy if exists "meetings: select own" on public.meetings;
create policy "meetings: select own" on public.meetings
  for select using ((select auth.uid()) = user_id);
drop policy if exists "meetings: insert own" on public.meetings;
create policy "meetings: insert own" on public.meetings
  for insert with check ((select auth.uid()) = user_id);
drop policy if exists "meetings: update own" on public.meetings;
create policy "meetings: update own" on public.meetings
  for update using ((select auth.uid()) = user_id);
drop policy if exists "meetings: delete own" on public.meetings;
create policy "meetings: delete own" on public.meetings
  for delete using ((select auth.uid()) = user_id);

-- ── recordings_meta: drop redundant SELECT, keep the single FOR ALL
drop policy if exists "recordings_meta: select via meeting" on public.recordings_meta;
drop policy if exists "recordings_meta: write via meeting" on public.recordings_meta;
create policy "recordings_meta: write via meeting" on public.recordings_meta
  for all
  using (exists (select 1 from public.meetings m
                 where m.id = recordings_meta.meeting_id and m.user_id = (select auth.uid())))
  with check (exists (select 1 from public.meetings m
                 where m.id = recordings_meta.meeting_id and m.user_id = (select auth.uid())));

-- ── segments
drop policy if exists "segments: select via meeting" on public.segments;
drop policy if exists "segments: write via meeting" on public.segments;
create policy "segments: write via meeting" on public.segments
  for all
  using (exists (select 1 from public.meetings m
                 where m.id = segments.meeting_id and m.user_id = (select auth.uid())))
  with check (exists (select 1 from public.meetings m
                 where m.id = segments.meeting_id and m.user_id = (select auth.uid())));

-- ── speakers
drop policy if exists "speakers: select via meeting" on public.speakers;
drop policy if exists "speakers: write via meeting" on public.speakers;
create policy "speakers: write via meeting" on public.speakers
  for all
  using (exists (select 1 from public.meetings m
                 where m.id = speakers.meeting_id and m.user_id = (select auth.uid())))
  with check (exists (select 1 from public.meetings m
                 where m.id = speakers.meeting_id and m.user_id = (select auth.uid())));

-- ── summaries
drop policy if exists "summaries: select via meeting" on public.summaries;
drop policy if exists "summaries: write via meeting" on public.summaries;
create policy "summaries: write via meeting" on public.summaries
  for all
  using (exists (select 1 from public.meetings m
                 where m.id = summaries.meeting_id and m.user_id = (select auth.uid())))
  with check (exists (select 1 from public.meetings m
                 where m.id = summaries.meeting_id and m.user_id = (select auth.uid())));

-- ── shares
drop policy if exists "shares_owner_select" on public.shares;
create policy "shares_owner_select" on public.shares
  for select using ((select auth.uid()) = owner_id);
drop policy if exists "shares_owner_delete" on public.shares;
create policy "shares_owner_delete" on public.shares
  for delete using ((select auth.uid()) = owner_id);

-- ── bug_reports (single admin-read policy; wrap is_admin())
drop policy if exists "bug_reports_admin_read" on public.bug_reports;
create policy "bug_reports_admin_read" on public.bug_reports
  for select using ((select public.is_admin()));

-- ── news_items: one permissive policy per (role, action)
drop policy if exists "news_items_admin_all" on public.news_items;
drop policy if exists "news_items_authenticated_read" on public.news_items;
create policy "news_items_read" on public.news_items
  for select to anon, authenticated
  using ((select public.is_admin())
         or (is_draft = false and now() between starts_at and ends_at));
create policy "news_items_admin_insert" on public.news_items
  for insert to authenticated
  with check ((select public.is_admin()));
create policy "news_items_admin_update" on public.news_items
  for update to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));
create policy "news_items_admin_delete" on public.news_items
  for delete to authenticated
  using ((select public.is_admin()));

-- ── covering indexes for the two unindexed foreign keys
create index if not exists news_items_created_by_idx on public.news_items (created_by);
create index if not exists segments_speaker_id_idx    on public.segments (speaker_id);

commit;
