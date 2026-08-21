-- Supabase advisor: "Security Definer View" (CRITICAL) on public.news_active.
--
-- A view created without `security_invoker` runs with the rights of its
-- OWNER (postgres), so row level security on the underlying table is
-- evaluated as the owner instead of as the caller. Nothing leaked here:
-- the view already filters to `is_draft = false AND now() between
-- starts_at and ends_at`, which is exactly what the
-- `news_items_authenticated_read` policy lets anon/authenticated read
-- anyway, and every real caller goes through the Worker's service-role
-- key. The risk is future drift: adding a column or relaxing the WHERE
-- would silently bypass RLS. Flip it to invoker rights so the caller's
-- own policies always apply.
--
-- Requires Postgres 15+; the Corder project runs 17.6.
--
-- Run in the Supabase SQL editor against the Corder project:
--   https://supabase.com/dashboard/project/cfsajlsctzxgixjwslni/sql

alter view public.news_active set (security_invoker = on);
