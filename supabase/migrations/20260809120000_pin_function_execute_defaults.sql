-- Security hardening (audit 2026-08-09): pin the execute privileges of new
-- functions in schema public.
--
-- This is an ASSERTION, not a repair: live verification showed no public
-- function carrying PUBLIC EXECUTE, and default privileges already stood at
-- {postgres, service_role}. Versioning the intent makes a later accidental
-- `grant execute ... to public` visible in the migration history.
--
-- Deliberately NOT `force row level security`: `postgres` and `service_role`
-- carry `rolbypassrls` anyway, and `authenticated`/`anon` are never table
-- owners — FORCE would be a no-op that reads like protection.

-- 1) Future functions get no automatic PUBLIC EXECUTE. service_role stays
--    (edge functions), PUBLIC goes.
alter default privileges in schema public
  revoke execute on functions from public;

-- 2) Defensive strip of existing functions: removes any stray PUBLIC EXECUTE
--    (currently a no-op). Explicit grants to service_role/authenticated stay.
revoke execute on all functions in schema public from public;
