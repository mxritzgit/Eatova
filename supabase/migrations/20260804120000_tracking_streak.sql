-- Logging streak: a streak is now consecutive calendar days with at least one
-- logged meal (logged_meals.local_day). record_workout_day lost its caller
-- when the training tab went away, so the streak was stuck at 0. The columns
-- keep their historical names; last_workout_date now means "last tracked day".
--
-- Contents:
--   1) record_tracking_day(p_day), successor of record_workout_day: no
--      workouts_completed increment, and days <= last_workout_date are a
--      no-op (backdated entries must not reset or advance the streak).
--   2) Backfill the streak fields from existing local_day values
--      (gaps-and-islands) so users keep their real streak.
--   3) Drop record_workout_day.

-- ---------------------------------------------------------------------------
-- 1) record_tracking_day — advances the persistent logging streak.
--      * p_day <= last_workout_date       -> no-op (idempotent/backdated),
--        except repairing legacy rows stuck at current_streak 0.
--      * p_day == last_workout_date + 1   -> current_streak + 1
--      * otherwise (gap / NULL / future)  -> current_streak = 1
--    workouts_completed stays untouched.
-- ---------------------------------------------------------------------------
create or replace function public.record_tracking_day(p_day date)
returns public.lifetime_stats
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_row  public.lifetime_stats;
  v_last date;
begin
  if v_uid is null then
    raise exception 'EX_USER_REQUIRED' using errcode = '22023';
  end if;
  if p_day is null then
    raise exception 'EX_DAY_REQUIRED' using errcode = '22023';
  end if;

  -- Ensure a row exists for users without lifetime_stats yet.
  insert into public.lifetime_stats (user_id)
  values (v_uid)
  on conflict (user_id) do nothing;

  select last_workout_date into v_last
  from public.lifetime_stats
  where user_id = v_uid
  for update;

  -- Same day (idempotent) or backdated -> streak untouched; only repair the
  -- inconsistent 0 state.
  if v_last is not null and p_day <= v_last then
    update public.lifetime_stats set
      current_streak = 1,
      longest_streak = greatest(longest_streak, 1)
    where user_id = v_uid
      and last_workout_date = p_day
      and current_streak < 1;
    select * into v_row from public.lifetime_stats where user_id = v_uid;
    return v_row;
  end if;

  update public.lifetime_stats as ls set
    current_streak = case
      when v_last is not null and p_day = v_last + 1 then ls.current_streak + 1
      else 1
    end,
    longest_streak = greatest(
      ls.longest_streak,
      case
        when v_last is not null and p_day = v_last + 1 then ls.current_streak + 1
        else 1
      end
    ),
    last_workout_date = p_day
  where ls.user_id = v_uid
  returning ls.* into v_row;

  return v_row;
end;
$$;

revoke execute on function public.record_tracking_day(date) from public, anon;
grant execute on function public.record_tracking_day(date) to authenticated;

-- ---------------------------------------------------------------------------
-- 2) Backfill from logged_meals.local_day (gaps-and-islands): per user, the
--    run of consecutive days ending at the last log becomes current_streak,
--    the longest run becomes longest_streak (never decreasing).
-- ---------------------------------------------------------------------------
insert into public.lifetime_stats (user_id)
select distinct user_id from public.logged_meals
on conflict (user_id) do nothing;

with days as (
  select distinct user_id, local_day
  from public.logged_meals
  where local_day is not null
),
grouped as (
  -- Consecutive days share the same anchor (local_day minus its rank).
  select
    user_id,
    local_day,
    local_day
      - (dense_rank() over (partition by user_id order by local_day))::int
      as anchor
  from days
),
islands as (
  select user_id, count(*)::int as len, max(local_day) as island_end
  from grouped
  group by user_id, anchor
),
agg as (
  select user_id, max(len) as longest_len, max(island_end) as last_day
  from islands
  group by user_id
),
cur as (
  select i.user_id, i.len as current_len, a.longest_len, a.last_day
  from islands i
  join agg a on a.user_id = i.user_id and i.island_end = a.last_day
)
update public.lifetime_stats as ls set
  current_streak    = c.current_len,
  longest_streak    = greatest(ls.longest_streak, c.longest_len),
  last_workout_date = c.last_day
from cur c
where ls.user_id = c.user_id;

-- ---------------------------------------------------------------------------
-- 3) Drop record_workout_day: no callers left, record_tracking_day succeeds it.
-- ---------------------------------------------------------------------------
drop function if exists public.record_workout_day(date);
