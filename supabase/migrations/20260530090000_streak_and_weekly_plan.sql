-- FitPilot — streak durability + persistent weekly plan
--
-- Gives workout streak, lifetime stats and the weekly plan real storage;
-- all three were in-memory only and reset on every app restart.
-- Purely additive and idempotent. Builds on
-- 20260516160000_app_data_schema.sql.
--
-- 42501: applied as raw SQL via the Supabase Management API, which does NOT
-- set table GRANTs for the authenticated role (Postgres checks privileges
-- BEFORE RLS). weekly_plans therefore needs the explicit grants below.

-- ---------------------------------------------------------------------------
-- 1) daily_logs — robust workout signal
--    The client clears completed_block_ids on full completion, so it is no
--    history. workout_completed stays true for the day.
-- ---------------------------------------------------------------------------
alter table public.daily_logs
  add column if not exists workout_completed boolean not null default false;

-- ---------------------------------------------------------------------------
-- 2) lifetime_stats — streak fields (1:1 with Dart LifetimeStats)
-- ---------------------------------------------------------------------------
alter table public.lifetime_stats
  add column if not exists current_streak    integer not null default 0,
  add column if not exists longest_streak    integer not null default 0,
  add column if not exists last_workout_date date;

-- ---------------------------------------------------------------------------
-- 3) weekly_plans — one 7-day plan per user (index 0=Mon .. 6=Sun)
-- ---------------------------------------------------------------------------
create table if not exists public.weekly_plans (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  days        text[] not null default '{}',
  updated_at  timestamptz not null default now()
);

drop trigger if exists weekly_plans_set_updated_at on public.weekly_plans;
create trigger weekly_plans_set_updated_at
  before update on public.weekly_plans
  for each row execute function public.set_updated_at();

alter table public.weekly_plans enable row level security;

drop policy if exists "weekly_plans_select_own"  on public.weekly_plans;
drop policy if exists "weekly_plans_insert_own"  on public.weekly_plans;
drop policy if exists "weekly_plans_update_own"  on public.weekly_plans;
drop policy if exists "weekly_plans_delete_own"  on public.weekly_plans;

create policy "weekly_plans_select_own"
  on public.weekly_plans for select to authenticated
  using (user_id = auth.uid());
create policy "weekly_plans_insert_own"
  on public.weekly_plans for insert to authenticated
  with check (user_id = auth.uid());
create policy "weekly_plans_update_own"
  on public.weekly_plans for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "weekly_plans_delete_own"
  on public.weekly_plans for delete to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 4) GRANTs — not automatic on raw-SQL apply. Without them the logged-in
--    user hits 42501 on weekly_plans despite the RLS policy.
--    daily_logs/lifetime_stats already had theirs; repeated idempotently.
-- ---------------------------------------------------------------------------
grant select, insert, update, delete on public.weekly_plans to authenticated;
grant all                            on public.weekly_plans to service_role;
grant select, insert, update, delete on public.daily_logs     to authenticated;
grant select, insert, update, delete on public.lifetime_stats to authenticated;

-- Default privileges for the public schema are set in
-- 20260516180000_grants.sql; the explicit grants above are the safety net
-- for the raw Management API path.
