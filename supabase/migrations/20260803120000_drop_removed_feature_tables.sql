-- Drops the tables of the removed Heute / Training / Trends tabs (2026-08-03);
-- no code references them any more.
--
-- DESTRUCTIVE and irreversible: all user data in these five tables is lost.
-- The definitions stay readable in the old migrations. Deliberately kept:
-- weight_log, lifetime_stats, profiles, meal/recipe/chat tables and the
-- lifetime_stats RPCs, as anchors for the rework.
--
-- CASCADE removes the attached policies, indexes and triggers; IF EXISTS makes
-- a second run a no-op.

begin;

drop table if exists public.daily_logs       cascade; -- water/steps/mood/habits/blocks (Heute)
drop table if exists public.caffeine_entries cascade; -- caffeine tracking (Heute)
drop table if exists public.sleep_entries    cascade; -- sleep log (Heute)
drop table if exists public.weekly_plans     cascade; -- 7-day training plan (Training)
drop table if exists public.workout_sets     cascade; -- set logging PROD-5 (Training)

commit;
