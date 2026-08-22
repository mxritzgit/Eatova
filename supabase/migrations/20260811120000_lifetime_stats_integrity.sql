-- Lifetime statistics integrity (Security review 2026-08-11, finding 7,
-- CWE-840: clients can overwrite server-derived lifetime statistics).
--
-- authenticated held direct write grants and own-row policies although every
-- real write goes through the security-definer RPCs, so a tampered client
-- could set arbitrary counters; record_tracking_day also accepted ANY date.
--
-- Hardening only, idempotent: revoke the write grants (SELECT stays), drop the
-- three write policies, add a source proof and a future bound.
-- Deliberately NO force row level security — with Supabase's role setup it is
-- a no-op that only pretends to protect.

-- ---------------------------------------------------------------------------
-- 1) Revoke direct client writes. The row is still created by the bootstrap
--    trigger or by the upsert inside the RPCs, both of which run as function
--    owner. service_role is untouched; the anon revoke is belt and braces.
-- ---------------------------------------------------------------------------
revoke insert, update, delete on public.lifetime_stats from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2) Drop the write policies. Second line of defence: if a future blanket
--    grant revives the table privileges, RLS without a policy still blocks
--    every client write. lifetime_stats_select_own stays.
-- ---------------------------------------------------------------------------
drop policy if exists "lifetime_stats_insert_own" on public.lifetime_stats;
drop policy if exists "lifetime_stats_update_own" on public.lifetime_stats;
drop policy if exists "lifetime_stats_delete_own" on public.lifetime_stats;

-- ---------------------------------------------------------------------------
-- 3) record_tracking_day — hardened. Streak logic unchanged; new are a future
--    bound (p_day is a CLIENT-local key and may lead UTC by at most one day)
--    and a source proof (the day needs a logged meal). Both new errors carry
--    NO errcode clause on purpose: the client outbox treats the default P0001
--    as retryable, while class 22 would be dropped as payload-determined.
--    Limit: local_day is client-declared, so this is consistency, not
--    anti-cheat.
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

  -- Guard a): no booking ahead. A broken device clock could otherwise set
  -- last_workout_date so far ahead that every real later day became a no-op.
  if p_day > (now() at time zone 'utc')::date + 1 then
    raise exception 'EX_DAY_IN_FUTURE';
  end if;

  -- Ensure the row exists if the user has no lifetime_stats yet.
  insert into public.lifetime_stats (user_id)
  values (v_uid)
  on conflict (user_id) do nothing;

  select last_workout_date into v_last
  from public.lifetime_stats
  where user_id = v_uid
  for update;

  -- Same day or backdated entry: streak untouched, only the inconsistent 0
  -- state is repaired. Runs BEFORE the source proof because it advances
  -- nothing, so an error here would only cause useless outbox retries.
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

  -- Guard b): source proof (finding 7) — the day needs a logged entry before
  -- it may advance the streak. logged_meals_user_local_day_idx carries this.
  if not exists (
    select 1
    from public.logged_meals
    where user_id = v_uid
      and local_day = p_day
  ) then
    raise exception 'EX_DAY_NOT_LOGGED';
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
