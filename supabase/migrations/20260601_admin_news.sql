-- Admin + News rollout, June 2026.
--
-- 1. `news_items` table backs the Library top-banner. Each row carries
--    enough fields to drive the `NewsBanner` React component
--    one-to-one (title, body, primary CTA, secondary CTA, audience,
--    dismissible). `starts_at` / `ends_at` is the live-window, used by
--    the active-news view so the worker just returns rows that are
--    currently in window AND not drafts.
-- 2. `news_active` view is the public read surface, any authenticated
--    user can SELECT from it. INSERT / UPDATE / DELETE on `news_items`
--    itself is gated to admins via RLS.
-- 3. `is_admin()` helper reads `auth.jwt() -> 'app_metadata' -> 'role'`
--    so policies + clients use one consistent definition.
--
-- Run in the Supabase SQL editor against the Corder project:
--   https://supabase.com/dashboard/project/cfsajlsctzxgixjwslni/sql

begin;

-- ---------------------------------------------------------------------
-- 1) Helper: is the requesting JWT an admin?
-- ---------------------------------------------------------------------
create or replace function public.is_admin()
  returns boolean
  language sql
  stable
  security definer
  set search_path = public
as $$
  select coalesce(
    (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin',
    false
  );
$$;

comment on function public.is_admin() is
  'True when the requesting JWT has app_metadata.role = "admin". Used by RLS policies on admin-only tables.';

-- ---------------------------------------------------------------------
-- 2) news_items, single table for both live banners + drafts + history.
-- ---------------------------------------------------------------------
create table if not exists public.news_items (
  id                uuid primary key default gen_random_uuid(),
  -- User-visible copy.
  title             text not null,
  subtitle          text,
  body              text,
  -- Primary CTA. `cta_action` is one of dismiss | open_url | open_settings.
  cta_label         text,
  cta_action        text,
  cta_url           text,
  -- Optional secondary CTA. Same `_action` vocabulary as the primary.
  secondary_label   text,
  secondary_action  text,
  secondary_url     text,
  -- Live window. Admin sets these via the date-range picker.
  -- A row is "active" iff now() is between starts_at and ends_at.
  starts_at         timestamptz not null default now(),
  ends_at           timestamptz not null default (now() + interval '7 days'),
  -- "all" | "free" | "pro" | "max", wire visibility per tier later.
  audience          text not null default 'all'
                       check (audience in ('all', 'free', 'pro', 'max')),
  dismissible       boolean not null default true,
  -- Drafts live in the same table so the admin can write, save, and
  -- publish from one place. `is_draft = true` rows never surface to
  -- end-users regardless of the live window.
  is_draft          boolean not null default false,
  -- Bookkeeping.
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references auth.users(id) on delete set null
);

comment on table public.news_items is
  'Library news banner copy. One row per item; admins write, end-users read via the `news_active` view.';

-- Trigger to keep updated_at fresh on every UPDATE.
create or replace function public.touch_updated_at()
  returns trigger
  language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists news_items_touch_updated on public.news_items;
create trigger news_items_touch_updated
  before update on public.news_items
  for each row
  execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- 3) Indices for the two access patterns we actually run.
-- ---------------------------------------------------------------------
create index if not exists news_items_active_idx
  on public.news_items (starts_at, ends_at)
  where is_draft = false;

create index if not exists news_items_created_at_idx
  on public.news_items (created_at desc);

-- ---------------------------------------------------------------------
-- 4) RLS, table is admin-write, public-read filtered through a view.
-- ---------------------------------------------------------------------
alter table public.news_items enable row level security;

drop policy if exists news_items_admin_all on public.news_items;
create policy news_items_admin_all
  on public.news_items
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- Read access for everyone goes through the `news_active` view below.
-- We still grant SELECT on the raw table to anon/authenticated so the
-- view's underlying query works even when called by a non-admin, -- the view itself adds the "in window AND not draft" filter.
drop policy if exists news_items_authenticated_read on public.news_items;
create policy news_items_authenticated_read
  on public.news_items
  for select
  to authenticated, anon
  using (
    is_draft = false
    and now() between starts_at and ends_at
  );

-- ---------------------------------------------------------------------
-- 5) Public view used by the worker and (eventually) the admin UI's
--    "see what's live" preview.
-- ---------------------------------------------------------------------
create or replace view public.news_active as
select
  id,
  title,
  subtitle,
  body,
  cta_label,
  cta_action,
  cta_url,
  secondary_label,
  secondary_action,
  secondary_url,
  audience,
  dismissible,
  starts_at,
  ends_at
from public.news_items
where is_draft = false
  and now() between starts_at and ends_at
order by created_at desc;

grant select on public.news_active to authenticated, anon;

-- ---------------------------------------------------------------------
-- 6) Seed: keep the existing telemetry-consent banner alive. The
--    worker used to return this item hard-coded; once /news reads from
--    Supabase the row has to come from the table or nothing surfaces.
--    Stable text id is impossible (the column is uuid), so the React
--    side uses the row's uuid for localStorage dedupe instead.
-- ---------------------------------------------------------------------
insert into public.news_items (title, body, cta_label, cta_action, secondary_label, secondary_action, audience, dismissible, starts_at, ends_at)
select 'Diagnostics',
       'Once a day Corder sends a tiny anonymous bug report. No transcripts, no audio.',
       'Got it', 'dismiss',
       'Settings', 'open_settings',
       'all', true,
       now() - interval '1 day',
       now() + interval '365 days'
where not exists (
  select 1 from public.news_items where title = 'Diagnostics' and cta_action = 'dismiss'
);

commit;

-- ---------------------------------------------------------------------
-- 6) One-time: grant yourself the admin role. Run this AFTER the
--    migration succeeds and only for the email you actually use as
--    operator. RLS uses `app_metadata.role = 'admin'`, so the value
--    must live in `raw_app_meta_data` (set by GoTrue, not the user).
-- ---------------------------------------------------------------------
-- update auth.users
--   set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb)
--     || jsonb_build_object('role', 'admin')
--   where email = 'hegona3@gmail.com';
