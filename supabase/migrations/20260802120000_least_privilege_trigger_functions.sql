-- Least-privilege cleanup (audit 2026-08-02), additive and idempotent.
-- 1) Drops the residual PUBLIC EXECUTE on the two trigger functions; EXECUTE is
--    only checked at CREATE TRIGGER time, so existing triggers keep firing.
-- 2) Pins search_path on set_updated_at() (Supabase linter); behaviour-neutral,
--    the body only calls now().

revoke execute on function public.handle_new_user_stats() from public, anon, authenticated;
revoke execute on function public.set_updated_at()        from public, anon, authenticated;
grant execute on function public.handle_new_user_stats() to service_role;
grant execute on function public.set_updated_at()        to service_role;

alter function public.set_updated_at() set search_path = public;
