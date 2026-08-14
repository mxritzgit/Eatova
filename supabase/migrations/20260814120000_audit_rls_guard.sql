-- Eatova — Audit 2026-08-14: RLS-Netz versionieren, Default-Grants entschaerfen,
-- increment_lifetime_stats gegen Selbst-Vergiftung und Doppelzaehlung sichern.
--
-- Vier Befunde, vier Bloecke. Rein haertend + idempotent (die Migration darf
-- gegen die BESTEHENDE Live-DB genauso laufen wie gegen ein frisches
-- `supabase db reset`).
--
--   A) 20260516180000_grants.sql Z. 32 gibt JEDER kuenftigen public-Tabelle
--      automatisch volles CRUD an `authenticated`. Der einzige Gegenschutz war
--      der Event-Trigger `ensure_rls` / `rls_auto_enable()`, den
--      20260809120000_pin_function_execute_defaults.sql als live-verifiziert
--      BEHAUPTET — im Repo existiert er nur in diesem Kommentar. Ein frisches
--      Schema hat ihn also nicht, und eine Folge-Migration, die
--      `enable row level security` vergisst, waere sofort Vollzugriff aller
--      Nutzer auf alle Zeilen. Hier wird er versioniert; zusaetzlich fallen die
--      Default-Privilegien fuer `authenticated`, damit die Luecke auch dann zu
--      ist, wenn der Event-Trigger mangels Superuser-Rechten nicht installiert
--      werden kann.
--   B) 20260604120000_lifetime_increment_rpcs.sql Z. 72 klemmt nur nach unten.
--      Ein direkter RPC-Aufruf mit p_meals = 2147483647 setzt die eigene Zeile
--      an den int4-Rand; jeder naechste legitime Increment wirft dauerhaft
--      22003 — die Zaehler des Users sind permanent kaputt (Fremddaten sind
--      nicht erreichbar, es ist reine Selbst-Vergiftung, aber sie ist
--      irreversibel ohne Support-Eingriff).
--   C) chat_messages / chat_quota_usage sind heute allein dadurch geschuetzt,
--      dass ihnen eine Write-Policy fehlt — die Tabellen-Grants aus
--      20260516180000 tragen fuer `authenticated` weiterhin INSERT/UPDATE/
--      DELETE. Ein kuenftiger Policy-Fehlgriff waere sofort Historien-
--      Faelschung bzw. Quota-Reset. Dieselbe Linie wie
--      20260811120000_lifetime_stats_integrity.sql sie fuer lifetime_stats
--      zieht: Grant weg, nicht nur Policy weg.
--   D) increment_lifetime_stats ist nicht idempotent: die Client-Outbox
--      retryt einen Aufruf, dessen Antwort unterwegs verloren ging, und zaehlt
--      dabei doppelt. Optionale Request-ID + Verbrauchs-Tabelle schliessen das.
--
-- WICHTIG fuer alle neuen Fehlerpfade unten: bewusst OHNE errcode-Klausel
-- (Default P0001). Die Client-Outbox stuft P0001 als retrybar-mit-Budget ein
-- (sync_error_messages.dart), waehrend Klasse 22 (z.B. 22023) als
-- payload-determiniert SOFORT verworfen wird — siehe die ausfuehrliche
-- Begruendung in 20260811120000_lifetime_stats_integrity.sql.

-- ---------------------------------------------------------------------------
-- A1) rls_auto_enable() — schaltet RLS auf jeder neu erzeugten public-Tabelle
--     ein. Damit ist die "neue Tabelle ohne RLS"-Luecke auch in einer frisch
--     aufgesetzten Umgebung zu, nicht nur in der historisch gewachsenen
--     Produktions-DB.
--
--     BEWUSST KEIN `security definer` (Abweichung von der sonstigen Linie):
--     der Erzeuger einer Tabelle ist immer auch ihr Owner und darf RLS auf ihr
--     schalten. Als definer liefe die Funktion dagegen als postgres und wuerde
--     bei einer Tabelle fremden Owners mit 42501 scheitern — und weil ein
--     Fehler im Event-Trigger das ausloesende CREATE TABLE mitreisst, waere
--     das ein Schutz, der DDL blockiert statt sie abzusichern. Invoker ist
--     hier gleichzeitig das schwaechere Recht und der robustere Pfad.
--
--     search_path gepinnt (Supabase-Linter function_search_path_mutable);
--     pg_event_trigger_ddl_commands() liegt in pg_catalog, das ohnehin immer
--     zuerst durchsucht wird. object_identity ist bereits vollstaendig
--     qualifiziert und bei Bedarf gequotet — deshalb %s statt %I.
-- ---------------------------------------------------------------------------
--     ZWEI EIGENSCHAFTEN SIND HIER NICHT KOSMETIK (Live-Abgleich 2026-08-14):
--     In der Produktions-DB existiert bereits eine Fassung dieser Funktion, und
--     weil `postgres` sie besitzt, ersetzt `create or replace` sie tatsaechlich
--     — waehrend der Event-Trigger daneben mangels Superuser-Rechten NICHT neu
--     angelegt werden kann (siehe A2). Der Trigger zeigt danach also auf genau
--     diesen Rumpf. Er muss deshalb mindestens so defensiv sein wie der, den er
--     ersetzt:
--       1. Fehler pro Tabelle abfangen. Ein Fehler im Event-Trigger reisst das
--          ausloesende CREATE TABLE mit — ein Schutz, der DDL blockiert, waere
--          schlimmer als die Luecke, die er schliesst. Nur loggen, weiterlaufen.
--       2. `partitioned table` mitnehmen. Der WHEN-Filter des Triggers laesst
--          CREATE TABLE / CREATE TABLE AS / SELECT INTO durch; eine partitionierte
--          Tabelle meldet sich als eigener object_type und faellt sonst durchs
--          Raster, also genau der Fall, den A3 nicht mehr auffangen kann.
create or replace function public.rls_auto_enable()
returns event_trigger
language plpgsql
set search_path = public
as $$
declare
  obj record;
begin
  for obj in select * from pg_event_trigger_ddl_commands()
  loop
    if obj.object_type in ('table', 'partitioned table')
       and obj.schema_name = 'public'
    then
      begin
        execute format('alter table %s enable row level security', obj.object_identity);
      exception
        when others then
          raise log 'rls_auto_enable: RLS auf % nicht aktivierbar (%)',
            obj.object_identity, sqlerrm;
      end;
    end if;
  end loop;
end;
$$;

-- Least-Privilege-Linie aus 20260802120000_least_privilege_trigger_functions.sql:
-- die Default-Privilegien aus 20260516180000 Z. 41 wuerden der frischen
-- Funktion sonst EXECUTE an authenticated geben. Event-Trigger-Funktionen sind
-- via PostgREST-RPC nicht aufrufbar (Rueckgabetyp event_trigger) und der
-- Trigger feuert unabhaengig von EXECUTE — praktisch harmlos, aber die
-- Konsistenz ist der Punkt.
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
grant execute on function public.rls_auto_enable() to service_role;

-- ---------------------------------------------------------------------------
-- A2) Event-Trigger `ensure_rls` idempotent setzen.
--
--     drop + create statt "nur anlegen wenn fehlt": so traegt der Trigger nach
--     jedem Lauf garantiert die Fassung von oben, auch wenn live eine aeltere
--     Variante haengt.
--
--     Der ganze Block laeuft in einem Sub-Transaktions-Handler, weil
--     CREATE EVENT TRIGGER Superuser verlangt: in der Live-Umgebung ist
--     `postgres` KEIN Superuser, und ein bereits vorhandener `ensure_rls`
--     gehoert dort ggf. `supabase_admin` (dann scheitert schon das DROP mit
--     42501). Beides ist unkritisch — genau diese Umgebung ist die, in der der
--     Trigger laut 20260809120000 schon existiert. Der Handler sorgt dafuer,
--     dass die uebrigen Bloecke der Migration trotzdem durchlaufen; das
--     eigentliche Ziel des Befunds (frische Umgebung, `supabase db reset` als
--     Superuser) ist davon unberuehrt.
-- ---------------------------------------------------------------------------
do $$
begin
  drop event trigger if exists ensure_rls;
  execute $ddl$
    create event trigger ensure_rls on ddl_command_end
      when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      execute function public.rls_auto_enable()
  $ddl$;
exception
  when insufficient_privilege then
    raise notice 'ensure_rls nicht (neu) installiert: keine Superuser-Rechte. In der Live-DB besteht der Trigger bereits (siehe 20260809120000); dort ist das der erwartete Ausgang.';
end $$;

-- ---------------------------------------------------------------------------
-- A3) Die eigentliche Ursache: Default-Privilegien fuer `authenticated` auf
--     TABELLEN entziehen. Der Event-Trigger oben ist nur die zweite Linie —
--     er schaltet RLS an, aber ohne Policy heisst RLS "niemand", und genau
--     darauf soll man sich nicht verlassen muessen. Ohne Default-Grant bekommt
--     eine neue Tabelle gar kein CRUD mehr geschenkt.
--
--     KONSEQUENZ FUER KUENFTIGE MIGRATIONEN: eine neue client-sichtbare
--     Tabelle braucht ab hier ihren expliziten
--     `grant select, insert, update, delete on public.<tabelle> to authenticated;`
--     — so wie 20260530090000_streak_and_weekly_plan.sql Z. 75 ff. es ohnehin
--     schon als "Sicherheitsnetz fuer den raw-Management-API-Pfad" tut. Der
--     bestehende Tabellenbestand ist unberuehrt: ALTER DEFAULT PRIVILEGES
--     wirkt ausschliesslich auf kuenftige Objekte.
--
--     `revoke all`, NICHT nur die vier CRUD-Rechte aus 20260516180000 Z. 32:
--     der ACL-Eintrag, den dieser Revoke anfasst, stammt nicht nur von dort.
--     Ein Supabase-Projekt bringt aus seinem Bootstrap ein
--     `alter default privileges in schema public grant ALL on tables to anon,
--     authenticated, service_role` mit — selber Grantor (postgres), selber
--     Eintrag. Ein Subset-Revoke laesst dort TRUNCATE, REFERENCES und TRIGGER
--     stehen, und TRUNCATE ignoriert RLS vollstaendig: die Luecke waere nur
--     eine Privilegien-Klasse weitergerueckt. Dieselbe Wahl trifft
--     20260517220000_security_hardening.sql Z. 29-30 fuer anon; die
--     Asymmetrie waere unbegruendet.
--
--     Sequenzen bleiben bewusst wie sie sind (usage/select ist kein Datenweg),
--     Funktionen ebenfalls — deren PUBLIC-Anteil hat 20260809120000 bereits
--     gezogen, und ein Entzug fuer authenticated wuerde jeden neuen RPC
--     stillschweigend unaufrufbar machen.
-- ---------------------------------------------------------------------------
alter default privileges in schema public
  revoke all on tables from authenticated;

-- ---------------------------------------------------------------------------
-- A4) Defensiver Strip auf dem BESTAND — zweistufig wie 20260809120000
--     (Abschnitt 1 kuenftig, Abschnitt 2 Bestand). Jede Tabelle, die seit dem
--     Supabase-Bootstrap unter dem oben beschriebenen `grant all`-Default
--     entstanden ist, traegt fuer `authenticated` bis heute TRUNCATE,
--     REFERENCES und TRIGGER — A3 wirkt ausschliesslich auf kuenftige Objekte
--     und raeumt das nicht ab.
--
--     Ueber PostgREST ist keines der drei erreichbar (es setzt nur
--     SELECT/INSERT/UPDATE/DELETE/CALL ab), der Entzug ist also kein
--     Incident-Fix. Er nimmt der Rolle aber die Rechte, mit denen ein
--     kuenftiger dynamischer Pfad an RLS vorbeikaeme — TRUNCATE loescht ohne
--     jede Policy-Pruefung, TRIGGER erlaubt das Anhaengen fremden Codes an
--     eine Tabelle.
--
--     Bewusst nur diese drei: `revoke all` wuerde hier auch das SELECT und
--     die CRUD-Rechte des Bestands mitnehmen und die App sofort stilllegen.
--     service_role bleibt unberuehrt (grant all aus 20260517220000 Z. 25).
-- ---------------------------------------------------------------------------
revoke truncate, references, trigger on all tables in schema public from authenticated;

-- ---------------------------------------------------------------------------
-- C) chat_messages / chat_quota_usage — Write-Grants entziehen.
--    Beide Tabellen sind reine Server-Wahrheit: geschrieben wird
--    ausschliesslich aus der Edge Function coach-chat mit service_role
--    (handler.ts storeMessage / claim_chat_quota + refund_chat_quota), der
--    Client liest nur (coach_chat_service.dart loadHistory, data_export.dart).
--    Ohne diesen Entzug haengt der Schutz allein daran, dass niemand je eine
--    Write-Policy ergaenzt — bei chat_quota_usage waere das ein
--    selbst-zuruecksetzbares Rate-Limit, bei chat_messages eine faelschbare
--    Konversationshistorie (die die naechste Coach-Anfrage als Kontext
--    weiterreicht). anon hat seit 20260517220000 ohnehin nichts; der Revoke
--    ist Guertel + Hosentraeger.
-- ---------------------------------------------------------------------------
revoke insert, update, delete on public.chat_messages    from anon, authenticated;
revoke insert, update, delete on public.chat_quota_usage from anon, authenticated;

-- ---------------------------------------------------------------------------
-- D1) lifetime_stats_requests — verbrauchte Request-IDs.
--     Ausschliesslich Server-Bookkeeping: kein Grant fuer authenticated (die
--     Zeilen sagen nichts, was der User nicht selbst geschickt hat, aber es
--     gibt auch keinen Lesegrund), RLS an und KEINE Policy — die Tabelle wird
--     nur aus der security-definer-RPC unten beruehrt, die als Funktions-Owner
--     laeuft und weder Grant noch Policy braucht.
--     on delete cascade an auth.users, damit delete_account() (DSGVO Art. 17)
--     sie mitnimmt wie jede andere App-Tabelle.
-- ---------------------------------------------------------------------------
create table if not exists public.lifetime_stats_requests (
  user_id    uuid not null references auth.users(id) on delete cascade,
  request_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (user_id, request_id)
);

alter table public.lifetime_stats_requests enable row level security;

revoke all on public.lifetime_stats_requests from anon, authenticated;
grant all  on public.lifetime_stats_requests to service_role;

-- ---------------------------------------------------------------------------
-- B+D2) increment_lifetime_stats — Obergrenzen pro Aufruf + optionale
--       Request-ID gegen Doppelzaehlung.
--
--       DROP statt reinem `create or replace`: eine zusaetzliche Signatur ist
--       in Postgres eine ZWEITE Funktion, nicht ein Ersatz. Blieben beide
--       stehen, koennte PostgREST den heutigen Aufruf (vier benannte
--       Parameter, lifetime_stats_sync.dart) nicht mehr aufloesen und
--       antwortete mit PGRST203 "could not choose the best candidate function"
--       — der Increment-Pfad waere sofort tot. Das DROP nimmt die Grants der
--       alten Fassung mit; sie stehen darum unten neu.
--
--       Die Signatur bleibt abwaertskompatibel: p_request_id hat einen
--       Default, der bestehende Vier-Parameter-Aufruf trifft weiter. Das
--       Client-Wiring der ID kommt aus einem anderen Paket.
--
--       Obergrenzen (Befund B): pro AUFRUF geklemmt, nicht kumulativ. Die
--       Werte sind absichtlich weit ueber allem, was die App je erzeugt — ein
--       Delta entsteht aus einer Nutzeraktion bzw. aus dem Nachtrag einer
--       Offline-Phase (home_store: _pendingMealsDelta/_pendingWeightLogsDelta
--       summieren, waehrend der RPC scheitert). 500 nachgetragene Mahlzeiten
--       sind rund vier Monate Offline-Betrieb; wer daran stoesst, hat ein
--       anderes Problem als eine zu enge Schranke.
-- ---------------------------------------------------------------------------
drop function if exists public.increment_lifetime_stats(integer, integer, integer, integer, integer);

create or replace function public.increment_lifetime_stats(
  p_water       integer default 0,
  p_steps       integer default 0,
  p_meals       integer default 0,
  p_weight_logs integer default 0,
  p_workouts    integer default 0,
  p_request_id  uuid    default null
)
returns public.lifetime_stats
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.lifetime_stats;
  -- greatest/least ignorieren NULL-Argumente, ein fehlender Parameter faellt
  -- also wie bisher auf 0 bzw. auf die Schranke.
  v_water       integer := least(greatest(p_water, 0),        20000);
  v_steps       integer := least(greatest(p_steps, 0),       200000);
  v_meals       integer := least(greatest(p_meals, 0),          500);
  v_weight_logs integer := least(greatest(p_weight_logs, 0),    500);
  v_workouts    integer := least(greatest(p_workouts, 0),       500);
begin
  if v_uid is null then
    raise exception 'EX_USER_REQUIRED' using errcode = '22023';
  end if;

  -- Befund D: derselbe Request zaehlt genau einmal. Die Einfuegung IST der
  -- Test — `on conflict do nothing` + FOUND ist atomar, zwei parallele Retries
  -- koennen sich nicht aneinander vorbeimogeln (anders als ein vorheriges
  -- SELECT). Ohne ID bleibt das Verhalten exakt wie bisher.
  if p_request_id is not null then
    insert into public.lifetime_stats_requests (user_id, request_id)
    values (v_uid, p_request_id)
    on conflict (user_id, request_id) do nothing;

    if not found then
      -- Schon verbucht: nichts addieren, aber die aktuelle Zeile liefern —
      -- der Retry ist damit erfolgreich und verlaesst die Outbox, statt bis
      -- zum Budget-Ende zu laufen.
      insert into public.lifetime_stats (user_id)
      values (v_uid)
      on conflict (user_id) do nothing;
      select * into v_row from public.lifetime_stats where user_id = v_uid;
      return v_row;
    end if;

    -- Aufraeumen im Vorbeigehen: die Tabelle darf nicht unbegrenzt wachsen,
    -- und ein Retry-Fenster von 30 Tagen ueberdauert jede Outbox-Phase
    -- (kOutboxMaxAttempts laeuft in Stunden ab, nicht in Wochen). Laeuft nur
    -- auf den eigenen Zeilen, der PK-Prefix user_id traegt den Lookup.
    delete from public.lifetime_stats_requests
    where user_id = v_uid
      and created_at < now() - interval '30 days';
  end if;

  -- Zeile sicherstellen (Erst-User vor Bootstrap-Trigger), dann atomar
  -- hochzaehlen. on conflict do update mit demselben col = col + p_x, damit
  -- der erste Aufruf eines neuen Users nicht auf 0 Zeilen laeuft.
  insert into public.lifetime_stats as ls (
    user_id,
    water_total_ml,
    steps_recorded,
    meals_logged,
    weight_logs,
    workouts_completed
  ) values (
    v_uid,
    v_water,
    v_steps,
    v_meals,
    v_weight_logs,
    v_workouts
  )
  on conflict (user_id) do update set
    water_total_ml     = ls.water_total_ml     + v_water,
    steps_recorded     = ls.steps_recorded     + v_steps,
    meals_logged       = ls.meals_logged       + v_meals,
    weight_logs        = ls.weight_logs        + v_weight_logs,
    workouts_completed = ls.workouts_completed + v_workouts
  returning ls.* into v_row;

  return v_row;
end;
$$;

revoke execute on function public.increment_lifetime_stats(integer, integer, integer, integer, integer, uuid)
  from public, anon;
grant execute on function public.increment_lifetime_stats(integer, integer, integer, integer, integer, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- B2) Letzte Linie: Obergrenzen auch auf der Tabelle. Die Klemme oben schuetzt
--     den RPC-Pfad; dieser Check schuetzt die Spalte — falls je ein anderer
--     Schreibweg dazukommt (service_role, Dashboard-SQL, kuenftiger RPC).
--     1 Mrd. liegt weit ueber jedem realen Lebenszeit-Wert und mehr als eine
--     Milliarde unter dem int4-Rand: der Zaehler kann die Zone, in der der
--     naechste Increment mit 22003 stirbt, gar nicht mehr erreichen.
--
--     `not valid`: der Check gilt ab sofort fuer jede neue Zeilenversion,
--     prueft den Bestand aber NICHT. Ein bereits vergifteter Zaehler (Befund B
--     war ausnutzbar) wuerde die Migration sonst zum Scheitern bringen — und
--     eine Datenreparatur gehoert nicht in eine haertende Migration.
--     Idempotenz-Muster gespiegelt von 20260517220000_security_hardening.sql
--     Z. 227 (conname-Probe statt `if not exists`, das ALTER TABLE nicht hat).
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'lifetime_stats_upper_bound_check') then
    alter table public.lifetime_stats add constraint lifetime_stats_upper_bound_check
      check (
        workouts_completed <= 1000000000 and
        meals_logged       <= 1000000000 and
        water_total_ml     <= 1000000000 and
        steps_recorded     <= 1000000000 and
        weight_logs        <= 1000000000 and
        current_streak     <= 1000000 and
        longest_streak     <= 1000000
      ) not valid;
  end if;
end $$;
