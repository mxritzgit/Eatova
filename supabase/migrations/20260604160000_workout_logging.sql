-- FitPilot — workout_sets (real workout logging, PROD-5)
--
-- Purely additive and idempotent. Stores individual logged working sets
-- (exercise, weight, reps, optional RPE) per user_id.
--
-- RLS strictly user_id = auth.uid(). GRANTs for the authenticated role are
-- EXPLICIT because raw SQL via Management API/psql does not set them
-- (see 20260516180000_grants.sql; otherwise 42501 "permission denied").

-- ---------------------------------------------------------------------------
-- 1) Table
-- ---------------------------------------------------------------------------
create table if not exists public.workout_sets (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  exercise    text not null,
  weight_kg   numeric(6,2) not null default 0 check (weight_kg >= 0),
  reps        integer not null default 0 check (reps >= 0),
  rpe         integer check (rpe is null or (rpe >= 1 and rpe <= 10)),
  logged_at   timestamptz not null default now(),
  local_day   date not null default (now() at time zone 'utc')::date,
  created_at  timestamptz not null default now()
);

-- Fast access to "a user's sets on a local day" and to the recent history per
-- user.
create index if not exists workout_sets_user_local_day_idx
  on public.workout_sets (user_id, local_day desc);

create index if not exists workout_sets_user_exercise_logged_idx
  on public.workout_sets (user_id, exercise, logged_at desc);

-- ---------------------------------------------------------------------------
-- 2) Row Level Security — a user only sees/changes their own rows
-- ---------------------------------------------------------------------------
alter table public.workout_sets enable row level security;

drop policy if exists "workout_sets_select_own" on public.workout_sets;
drop policy if exists "workout_sets_insert_own" on public.workout_sets;
drop policy if exists "workout_sets_update_own" on public.workout_sets;
drop policy if exists "workout_sets_delete_own" on public.workout_sets;

create policy "workout_sets_select_own"
  on public.workout_sets for select to authenticated
  using (user_id = auth.uid());
create policy "workout_sets_insert_own"
  on public.workout_sets for insert to authenticated
  with check (user_id = auth.uid());
create policy "workout_sets_update_own"
  on public.workout_sets for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "workout_sets_delete_own"
  on public.workout_sets for delete to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 3) GRANTs — explicit, since raw SQL does not grant automatically.
--    service_role gets full access (server/backfill).
-- ---------------------------------------------------------------------------
grant select, insert, update, delete on public.workout_sets to authenticated;
grant all on public.workout_sets to service_role;
