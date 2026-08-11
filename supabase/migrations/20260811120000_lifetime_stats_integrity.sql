-- Eatova — Integritaet der Lifetime-Statistiken (Security-Review 2026-08-11,
-- Finding 7, CWE-840: "Clients can overwrite server-derived lifetime
-- statistics").
--
-- BEFUND: authenticated hatte direkte INSERT/UPDATE/DELETE-Rechte auf
-- public.lifetime_stats (Blanket-Grant aus 20260517220000_security_hardening.sql
-- Z. 19 + expliziter Re-Grant aus 20260530090000_streak_and_weekly_plan.sql
-- Z. 78) samt Own-Row-Write-Policies aus 20260516160000_app_data_schema.sql.
-- Die App behandelt Zaehler und Streak aber seit dem Audit 2026-06-04 als
-- SERVER-Wahrheit: alle Schreibpfade laufen ausschliesslich ueber die
-- security-definer-RPCs increment_lifetime_stats + record_tracking_day;
-- lib/src/services/lifetime_stats_sync.dart macht auf der Tabelle selbst nur
-- noch ein SELECT (load) — es gibt KEINEN direkten Client-Schreibpfad mehr.
-- Ein manipulierter Client konnte die RPCs trotzdem umgehen und sich per
-- direktem UPDATE beliebige eigene Zaehler-/Streak-Werte setzen. Zusaetzlich
-- akzeptierte record_tracking_day JEDES Datum: auch Tage ohne irgendeinen
-- geloggten Eintrag, und beliebig weit in der Zukunft — ein Zukunfts-Datum in
-- last_workout_date haette obendrein jede echte Fortschreibung bis zu diesem
-- Tag zum No-op gemacht (p_day <= v_last-Zweig).
--
-- Inhalt (rein haertend + idempotent):
--   1) Write-Grants fuer authenticated auf der Tabelle entziehen
--      (SELECT bleibt: LifetimeStatsSync.load + Datenexport lesen direkt).
--   2) Die drei Own-Row-Write-Policies droppen (Select-Policy bleibt).
--   3) KEINE neuen RPCs noetig: die bestehenden zwei decken alle realen
--      Schreibpfade der App ab (verifiziert per Grep ueber lib/ — einziger
--      from('lifetime_stats')-Zugriff ist das SELECT in load()).
--   4) record_tracking_day haerten: Quell-Beweis via EXISTS auf
--      logged_meals.local_day + Zukunfts-Schranke.
--
-- Grant-/search_path-Stil gespiegelt von 20260604120000_lifetime_increment_rpcs.sql
-- + 20260804120000_tracking_streak.sql. BEWUSST KEIN force row level security
-- (siehe 20260809120000_pin_function_execute_defaults.sql: bei der
-- Supabase-Rollenlage ein wirkungsloser No-Op, der Lesern Schutz vorgaukelt).

-- ---------------------------------------------------------------------------
-- 1) Direkte Client-Writes entziehen. Die Zeile entsteht weiterhin per
--    Bootstrap-Trigger (handle_new_user_stats, security definer) bzw. per
--    Upsert IN den RPCs — beides laeuft als Funktions-Owner und braucht
--    keine authenticated-Grants. service_role bleibt unberuehrt (grant all
--    aus 20260517220000). anon hat seit ebendort ohnehin nichts; der Revoke
--    hier ist Guertel + Hosentraeger.
-- ---------------------------------------------------------------------------
revoke insert, update, delete on public.lifetime_stats from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2) Write-Policies droppen. Zweite Verteidigungslinie zum Grant-Entzug:
--    sollte ein kuenftiger Blanket-Grant ("grant ... on all tables ...") die
--    Tabellenrechte versehentlich wiederbeleben, blockt RLS ohne Policy
--    weiterhin jeden Client-Write. Die Select-Policy bleibt bestehen
--    (lifetime_stats_select_own, user_id = auth.uid()).
-- ---------------------------------------------------------------------------
drop policy if exists "lifetime_stats_insert_own" on public.lifetime_stats;
drop policy if exists "lifetime_stats_update_own" on public.lifetime_stats;
drop policy if exists "lifetime_stats_delete_own" on public.lifetime_stats;

-- ---------------------------------------------------------------------------
-- 3) record_tracking_day — gehaertete Fassung (ersetzt 20260804120000).
--    Streak-Logik unveraendert; neu sind ausschliesslich die zwei Guards:
--
--    a) Zukunfts-Schranke: p_day ist ein CLIENT-lokaler Tages-Schluessel
--       (20260604150000_local_day_keys.sql) und darf dem UTC-Kalendertag um
--       hoechstens EINEN Tag vorauslaufen (UTC+14 ist die oestlichste Zone).
--    b) Quell-Beweis: ein Tag zaehlt nur, wenn fuer diesen User an diesem
--       lokalen Tag tatsaechlich eine Mahlzeit geloggt ist. logged_meals ist
--       die definierende Quelle der Logging-Streak (siehe Backfill in
--       20260804120000); local_day wird seit 20260604150000 von jedem
--       Insert/Update mitgeschrieben und war dort fuer Altzeilen
--       backgefuellt — fuer frisch verbuchte Tage ist der eq-Match
--       zuverlaessig.
--
--    Reihenfolge-Sicherheit der Client-Pfade: Frisch-Log und Outbox-Replay
--    rufen den RPC erst NACH zugestellter Mahlzeit auf (onDelivered bzw.
--    nach dem await des Inserts in _performOp). Einzige nebenlaeufige Stelle
--    ist die Tag-Verschiebung AUF heute (_applyLoggedMealDetails): verliert
--    der RPC dort das Rennen gegen das Meal-Update, greift der bestehende
--    catchError-Pfad (_queueTrackingDay) und der Replay gewinnt, sobald das
--    Update angekommen ist. Deshalb tragen BEIDE neuen Fehler bewusst KEINE
--    errcode-Klausel (Default P0001): die Client-Outbox klassifiziert P0001
--    als retrybar-mit-Budget (sync_error_messages.dart), waehrend '22023'
--    (Klasse 22, wie EX_USER_REQUIRED/EX_DAY_REQUIRED) als
--    payload-determiniert SOFORT verworfen wuerde — genau falsch fuer einen
--    Grenzfall, der sich beim naechsten Replay von selbst heilt.
--
--    DOKUMENTIERTE GRENZE: local_day ist ein CLIENT-deklarierter lokaler
--    Tag — der Server kann die Geraete-Zeitzone nicht verifizieren, und ein
--    boeswilliger Client mit INSERT auf logged_meals kann sich Quell-Zeilen
--    fabrizieren. Der EXISTS-Beweis erzwingt also Konsistenz ("kein
--    Streak-Tag ohne geloggten Eintrag" — das Finding), keinen
--    vollstaendigen Anti-Cheat; mehr gibt die Local-Day-Semantik
--    serverseitig nicht her.
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

  -- Guard a): kein Vorausbuchen. Nebeneffekt-Fix: eine kaputte Geraete-Uhr
  -- (Datum weit in der Zukunft) konnte bisher last_workout_date so setzen,
  -- dass alle echten Folgetage im p_day <= v_last-Zweig versanden.
  if p_day > (now() at time zone 'utc')::date + 1 then
    raise exception 'EX_DAY_IN_FUTURE';
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
  -- unangetastet; nur den inkonsistenten 0-Zustand reparieren. Dieser Zweig
  -- laeuft bewusst VOR dem Quell-Beweis: er schreibt nichts fort (die
  -- Reparatur betrifft nur einen Tag, dessen Zaehlung last_workout_date
  -- selbst belegt) — ein Fehler wuerde hier nur nutzlose Outbox-Retries
  -- fuer einen No-op erzeugen.
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

  -- Guard b): Quell-Beweis (Finding 7) — der Tag muss einen geloggten
  -- Eintrag haben, bevor er die Streak fortschreiben darf. Index
  -- logged_meals_user_local_day_idx (20260604150000) traegt den Lookup.
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
