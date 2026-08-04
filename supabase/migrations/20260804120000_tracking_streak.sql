-- FitPilot — Logging-Streak (2026-08-04).
--
-- KONTEXT/BUG: Seit dem Training-Tab-Aus (Commit a267e15, 2026-08-03) hatte
-- record_workout_day keinen Aufrufer mehr — die Streak blieb fuer immer auf
-- "0 Tage", egal wie fleissig geloggt wurde. Die Streak bedeutet ab jetzt:
-- aufeinanderfolgende Kalendertage mit >= 1 geloggter Mahlzeit
-- (logged_meals.local_day). Die Spalten behalten ihre historischen Namen
-- (current_streak / longest_streak / last_workout_date) — last_workout_date
-- ist jetzt "letzter getrackter Tag".
--
-- Inhalt:
--   1) record_tracking_day(p_day) — Nachfolger von record_workout_day:
--      OHNE workouts_completed-Increment, und Tage <= last_workout_date sind
--      ein No-op (der Food-Kalender erlaubt Nachtraege fuer vergangene Tage;
--      die duerfen die laufende Streak weder resetten noch fortschreiben).
--   2) Backfill: Streak-Felder aus den vorhandenen logged_meals.local_day-
--      Tagen rekonstruieren (gaps-and-islands), damit bestehende Nutzer ihre
--      echte Streak sofort sehen statt wieder bei 1 zu starten.
--   3) drop record_workout_day — seit a267e15 ohne Aufrufer.
--
-- Grant-/search_path-Stil gespiegelt von 20260604120000_lifetime_increment_rpcs.sql.
-- Client-Wiring: lib/src/services/lifetime_stats_sync.dart (recordTrackingDay)
-- + home_store.addResultToDailyTotal (nur bei targetIsToday).

-- ---------------------------------------------------------------------------
-- 1) record_tracking_day — persistente Logging-Streak-Fortschreibung.
--      * p_day <= last_workout_date       -> No-op (idempotent / Nachtrag);
--        Reparatur: war der Tag gezaehlt aber current_streak 0 (Alt-Daten),
--        wird auf 1 angehoben.
--      * p_day == last_workout_date + 1   -> current_streak + 1
--      * sonst (Luecke / NULL / Zukunft)  -> current_streak = 1
--    longest_streak = greatest(longest_streak, current_streak danach),
--    last_workout_date = p_day. workouts_completed bleibt UNBERUEHRT.
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

  -- Zeile sicherstellen, falls der User noch keine lifetime_stats hat.
  insert into public.lifetime_stats (user_id)
  values (v_uid)
  on conflict (user_id) do nothing;

  select last_workout_date into v_last
  from public.lifetime_stats
  where user_id = v_uid
  for update;

  -- Selber Tag (idempotent) oder Rueckdatierung (Nachtrag) -> Streak
  -- unangetastet; nur den inkonsistenten 0-Zustand reparieren.
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
-- 2) Backfill aus logged_meals.local_day (gaps-and-islands): pro User die
--    Kette aufeinanderfolgender Log-Tage bis zum letzten Log als
--    current_streak, die laengste Kette als longest_streak (nie absteigend),
--    letzter Log-Tag als last_workout_date.
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
  -- Aufeinanderfolgende Tage teilen denselben Anker (local_day - Rangfolge).
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
-- 3) record_workout_day entsorgen — seit a267e15 (Training-Tab-Aus) ohne
--    Aufrufer; record_tracking_day ist der Nachfolger.
-- ---------------------------------------------------------------------------
drop function if exists public.record_workout_day(date);
