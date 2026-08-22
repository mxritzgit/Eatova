-- DATA-6: canonical local day key for meals and caffeine.
--
-- Meals were bucketed client-side via isSameDay(.toLocal()), caffeine
-- server-side via a UTC window from naive local midnight, so across a DST
-- switch or zone change the same entry could fall on two different days.
--
-- Fix: an explicit `local_day date` column filled by the client from the
-- entry's LOCAL wall clock. Caffeine sync now filters on `local_day` (eq) and
-- meal bucketing prefers it over isSameDay.
--
-- Additive and idempotent: `add column if not exists`, the column is NULLABLE
-- (the client falls back to the old logic for NULL rows), and RLS/grants are
-- unchanged (new columns inherit the table-level policies and grants).

-- ---------------------------------------------------------------------------
-- 1) Add the columns (additive, idempotent)
-- ---------------------------------------------------------------------------
alter table public.logged_meals
  add column if not exists local_day date;

alter table public.caffeine_entries
  add column if not exists local_day date;

-- ---------------------------------------------------------------------------
-- 2) Backfill existing rows (one-off approximation)
--
-- Historical rows carry no original offset, so the exact local day is not
-- reconstructable. Existing accounts are overwhelmingly German, so derive
-- local_day as (timestamptz AT TIME ZONE 'Europe/Berlin')::date — the same
-- value localDayKey(.toLocal()) yields on a DE device, DST offsets included.
-- Rows recorded in another zone are a deliberate approximation; from now on
-- the client writes the exact local day.
--
-- Only touches rows with local_day IS NULL, so a rerun overwrites nothing.
-- ---------------------------------------------------------------------------
update public.logged_meals
  set local_day = (logged_at at time zone 'Europe/Berlin')::date
  where local_day is null;

update public.caffeine_entries
  set local_day = (consumed_at at time zone 'Europe/Berlin')::date
  where local_day is null;

-- ---------------------------------------------------------------------------
-- 3) Indexes for the new (user_id, local_day) filters. Caffeine filters on
--    them now; meals still load per user_id, but the composite index keeps
--    future local_day filters cheap.
-- ---------------------------------------------------------------------------
create index if not exists caffeine_entries_user_local_day_idx
  on public.caffeine_entries (user_id, local_day);

create index if not exists logged_meals_user_local_day_idx
  on public.logged_meals (user_id, local_day);
