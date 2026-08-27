-- Manual energy mode (review 2026-08-27, F7-01): the goals page used to
-- RECONSTRUCT "manual" by comparing the stored kcal/macros with the
-- calculator. Every calculator change (PR #47/#48: PAL 1.2 -> 1.3, new
-- floors) therefore flipped every existing profile into manual mode and froze
-- the old target. The flag is now explicit and persisted.
--
-- false = live: the calculator is the truth, stored goals are a cache the
-- client heals on load. true = the user set kcal/macros by hand.
--
-- Column grants on public.profiles are per column since 20260819100000, so the
-- new column must be granted for insert AND update or the upsert fails with
-- 42501. Idempotent: `if not exists` plus grants that are additive.

alter table public.profiles
  add column if not exists manual_energy boolean not null default false;

comment on column public.profiles.manual_energy is
  'true = kcal/macros set by hand; false = calculator is the truth and the '
  'stored goals are healed on load (review 2026-08-27, F7-01).';

grant insert (manual_energy) on public.profiles to authenticated;
grant update (manual_energy) on public.profiles to authenticated;

-- Snapshot (review I-1): every existing profile boots as live (manual_energy
-- false), so the app heals its stored kcal goal to the calculator and writes
-- that back — a goal the user once set by hand would be gone for good. Keep
-- the pre-reset value once so a later in-app prompt can offer it back.
-- Server-only: no grants for authenticated (column grants cover insert and
-- update only; select is table-wide and the client selects explicit columns),
-- and the one-off backfill touches only rows that have no snapshot yet.

alter table public.profiles
  add column if not exists daily_kcal_goal_before_live_reset integer;

comment on column public.profiles.daily_kcal_goal_before_live_reset is
  'daily_kcal_goal as stored before the first live-mode heal of the '
  'manual_energy rollout; server-only snapshot for a later in-app prompt '
  '(review 2026-08-27, I-1).';

update public.profiles
  set daily_kcal_goal_before_live_reset = daily_kcal_goal
  where daily_kcal_goal_before_live_reset is null;
