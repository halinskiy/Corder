-- Corder share links — Phase 1 (audio-only, no R2, no card).
-- Paste into Supabase SQL Editor (project cfsajlsctzxgixjwslni) and Run.
-- Creates: the `shares` table + a private `shares` Storage bucket for the
-- compact .m4a audio. The Cloudflare Worker (SUPABASE_SERVICE_ROLE) is the
-- writer/reader for the public share flow; RLS below is defense-in-depth.

-- ── 1. shares table ────────────────────────────────────────────────────────
create table if not exists public.shares (
  token        text primary key,              -- >=128-bit base64url, unguessable
  meeting_id   text        not null,
  owner_id     uuid        not null,
  owner_name   text,                           -- for the "X shared this" CTA line
  audio_key    text,                           -- Storage path <uid>/<mid>.m4a, nullable
  video_key    text,                           -- reserved for Phase 1.5 (R2), nullable
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null
);

create index if not exists shares_expires_at_idx on public.shares (expires_at);
create index if not exists shares_owner_idx       on public.shares (owner_id);

alter table public.shares enable row level security;

drop policy if exists shares_owner_select on public.shares;
create policy shares_owner_select on public.shares
  for select using (auth.uid() = owner_id);

drop policy if exists shares_owner_delete on public.shares;
create policy shares_owner_delete on public.shares
  for delete using (auth.uid() = owner_id);
-- No insert policy: create + public read go through the Worker (service role).

-- ── 2. private Storage bucket for the shared .m4a ──────────────────────────
insert into storage.buckets (id, name, public)
values ('shares', 'shares', false)
on conflict (id) do nothing;

-- Owner may upload/replace/delete their own object at <uid>/<...>.
drop policy if exists shares_obj_owner_write on storage.objects;
create policy shares_obj_owner_write on storage.objects
  for insert to authenticated
  with check (bucket_id = 'shares' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists shares_obj_owner_update on storage.objects;
create policy shares_obj_owner_update on storage.objects
  for update to authenticated
  using (bucket_id = 'shares' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists shares_obj_owner_delete on storage.objects;
create policy shares_obj_owner_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'shares' and (storage.foldername(name))[1] = auth.uid()::text);
-- Public reads are served by the Worker via a signed URL (service role), so no
-- public select policy on the bucket.
