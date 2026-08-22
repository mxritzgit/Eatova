-- Atomic lifetime-stats and streak RPCs (audit 2026-06-04). Additive and
-- idempotent.
--
-- Client-side read-modify-write lost increments on parallel devices, so these
-- increment server-side (col = col + p_x) and read last_workout_date from the
-- DB, letting the streak survive restarts and device switches.
--
-- Both are security definer and user-scoped via auth.uid(), hence safe to
-- grant to authenticated, and upsert the row so an increment never hits 0.

-- ---------------------------------------------------------------------------
-- 1) increment_lifetime_stats — atomic bump of the cumulative counters. Each
--    parameter defaults to 0; the row is scoped to auth.uid().
-- ---------------------------------------------------------------------------
create or replace function public.increment_lifetime_stats(
  p_water       integer default 0,
  p_steps       integer default 0,
  p_meals       integer default 0,
  p_weight_logs integer default 0,
  p_workouts    integer default 0
)
returns public.lifetime_stats
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.lifetime_stats;
begin
  if v_uid is null then
    raise exception 'EX_USER_REQUIRED' using errcode = '22023';
  end if;

  -- Ensure the row exists (new user before the bootstrap trigger).
  insert into public.lifetime_stats as ls (
    user_id,
    water_total_ml,
    steps_recorded,
    meals_logged,
    weight_logs,
    workouts_completed
  ) values (
    v_uid,
    greatest(p_water, 0),
    greatest(p_steps, 0),
    greatest(p_meals, 0),
    greatest(p_weight_logs, 0),
    greatest(p_workouts, 0)
  )
  on conflict (user_id) do update set
    water_total_ml     = ls.water_total_ml     + greatest(p_water, 0),
    steps_recorded     = ls.steps_recorded     + greatest(p_steps, 0),
    meals_logged       = ls.meals_logged       + greatest(p_meals, 0),
    weight_logs        = ls.weight_logs        + greatest(p_weight_logs, 0),
    workouts_completed = ls.workouts_completed + greatest(p_workouts, 0)
  returning ls.* into v_row;

  return v_row;
end;
$$;

revoke execute on function public.increment_lifetime_stats(integer, integer, integer, integer, integer)
  from public, anon;
grant execute on function public.increment_lifetime_stats(integer, integer, integer, integer, integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 2) record_workout_day — persistent streak update for ONE day:
--      * p_day == last_workout_date      -> idempotent, nothing changes
--      * p_day == last_workout_date + 1  -> current_streak + 1
--      * otherwise (gap / NULL / future) -> current_streak = 1
-- ---------------------------------------------------------------------------
create or replace function public.record_workout_day(p_day date)
returns public.lifetime_stats
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_row  public.lifetime_stats;
  v_last date;
  v_new_streak integer;
begin
  if v_uid is null then
    raise exception 'EX_USER_REQUIRED' using errcode = '22023';
  end if;
  if p_day is null then
    raise exception 'EX_DAY_REQUIRED' using errcode = '22023';
  end if;

  -- On a fresh insert last_workout_date is NULL, so the first day starts the
  -- streak at 1 (else branch below).
  insert into public.lifetime_stats (user_id)
  values (v_uid)
  on conflict (user_id) do nothing;

  select last_workout_date into v_last
  from public.lifetime_stats
  where user_id = v_uid
  for update;

  -- Idempotence: same day already counted -> return the row unchanged.
  if v_last is not null and v_last = p_day then
    select * into v_row from public.lifetime_stats where user_id = v_uid;
    return v_row;
  end if;

  if v_last is not null and p_day = v_last + 1 then
    v_new_streak := null;  -- signal: existing streak + 1 (resolved below)
  else
    v_new_streak := 1;     -- gap, first day, NULL, or a future/back date
  end if;

  update public.lifetime_stats as ls set
    current_streak = case
      when v_new_streak is null then ls.current_streak + 1
      else 1
    end,
    longest_streak = greatest(
      ls.longest_streak,
      case when v_new_streak is null then ls.current_streak + 1 else 1 end
    ),
    last_workout_date  = p_day,
    workouts_completed = ls.workouts_completed + 1
  where ls.user_id = v_uid
  returning ls.* into v_row;

  return v_row;
end;
$$;

revoke execute on function public.record_workout_day(date) from public, anon;
grant execute on function public.record_workout_day(date) to authenticated;
