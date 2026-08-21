-- Supabase Security Advisor cleanup, August 2026 (all WARNING level, no
-- errors). Companion to 20260821_news_active_security_invoker.sql.
--
-- Three lints, each a hardening nicety rather than a live hole:
--
-- 1. "Function Search Path Mutable" on public.touch_updated_at — an
--    updated_at trigger helper with no pinned search_path. Its body only
--    calls now() (pg_catalog, always resolvable), so an empty path is safe
--    and closes the theoretical search-path-hijack vector.
--
-- 2/3. "Public / Signed-In Users Can Execute SECURITY DEFINER Function" on
--    public.handle_new_user and public.rls_auto_enable. Both are invoked
--    ONLY by triggers (on_auth_user_created on auth.users, and the
--    `ensure_rls` DDL event trigger). Trigger invocation ignores EXECUTE
--    grants, so revoking them from the public API roles changes no runtime
--    behaviour and removes the "anyone can call a definer function" flag.
--
-- NOT touched: public.is_admin keeps EXECUTE for authenticated because RLS
-- policies (news_items_admin_all, bug_reports_admin_read) evaluate it as
-- the querying role. It only reads the caller's own JWT and returns a
-- bool, so the residual "Signed-In Users Can Execute" flag on it is
-- by-design and harmless. "Leaked Password Protection Disabled" is an Auth
-- dashboard toggle (Authentication → Policies), not SQL.
--
-- Run in the Supabase SQL editor against the Corder project:
--   https://supabase.com/dashboard/project/cfsajlsctzxgixjwslni/sql

alter function public.touch_updated_at() set search_path = '';

revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
