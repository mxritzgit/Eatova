-- REAL cross-user access against a real PostgreSQL, run by the `rls-postgres`
-- job in .github/workflows/security.yml after pg_bootstrap.sql and all of
-- supabase/migrations/ have been applied.
--
-- test/migrations/rls_invariants_test.dart reads the migrations as TEXT: fast,
-- runs in the required check, catches a weakened policy. What it cannot do is
-- prove PostgreSQL agrees with that reading. This file does the opposite: it
-- makes two users, gives each of them rows, and then tries — as `authenticated`
-- with the other user's JWT and as `anon` — to read, change and delete them.
--
-- Every assertion goes through rlstest.*: SECURITY INVOKER, so the statement
-- runs with the privileges and the RLS context of the role that is set at that
-- moment. A failed expectation raises and psql (-v ON_ERROR_STOP=1) ends the
-- job red.

\set ON_ERROR_STOP on

create schema if not exists rlstest;
grant usage on schema rlstest to anon, authenticated, service_role;

-- Runs [p_sql] and insists on exactly [p_zeilen] affected rows.
create or replace function rlstest.erwarte_zeilen(
  p_sql text, p_zeilen integer, p_was text
) returns void
language plpgsql
as $$
declare
  n integer;
begin
  execute p_sql;
  get diagnostics n = row_count;
  if n <> p_zeilen then
    raise exception 'RLS-VERLETZUNG: % -> % Zeile(n), erwartet %', p_was, n, p_zeilen;
  end if;
end $$;

-- Runs [p_sql] and insists on a rejection. Only 42501 counts: both a missing
-- table grant and a violated RLS policy raise it. Anything else — including the
-- raise below — propagates and fails the job.
create or replace function rlstest.erwarte_ablehnung(p_sql text, p_was text)
returns void
language plpgsql
as $$
begin
  execute p_sql;
  raise exception 'RLS-VERLETZUNG: % ging DURCH, erwartet war eine Ablehnung', p_was;
exception
  when insufficient_privilege then
    return;
end $$;

-- Runs [p_sql] and insists on a rejection with EXACTLY [p_code]. Needed for
-- the row caps (P7-03), which must fail with 22023 and nothing else: only
-- class 22 makes the client outbox drop the item instead of retrying it for a
-- day.
create or replace function rlstest.erwarte_sqlstate(
  p_sql text, p_code text, p_was text
) returns void
language plpgsql
as $$
begin
  execute p_sql;
  raise exception 'ERWARTUNG VERFEHLT: % ging DURCH, erwartet war %', p_was, p_code;
exception
  when others then
    if sqlstate = p_code then
      return;
    end if;
    raise exception 'ERWARTUNG VERFEHLT: % scheiterte mit %, erwartet war %',
      p_was, sqlstate, p_code;
end $$;

grant execute on function
  rlstest.erwarte_zeilen(text, integer, text),
  rlstest.erwarte_ablehnung(text, text),
  rlstest.erwarte_sqlstate(text, text, text)
  to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Seed. As service_role (bypassrls), i.e. the way the Edge Functions write.
-- The auth.users insert fires the two bootstrap triggers, so profiles and
-- lifetime_stats appear on their own — a first proof that they still work.
-- ---------------------------------------------------------------------------
\set a '''11111111-1111-1111-1111-111111111111'''
\set b '''22222222-2222-2222-2222-222222222222'''

insert into auth.users (id, email, raw_user_meta_data) values
  (:a::uuid, 'a@example.test', '{"display_name":"A"}'::jsonb),
  (:b::uuid, 'b@example.test', '{"display_name":"B"}'::jsonb);

do $$
declare
  a uuid := '11111111-1111-1111-1111-111111111111';
  b uuid := '22222222-2222-2222-2222-222222222222';
  u uuid;
begin
  if (select count(*) from public.profiles) <> 2 then
    raise exception 'Bootstrap-Trigger hat keine profiles-Zeilen angelegt';
  end if;
  if (select count(*) from public.lifetime_stats) <> 2 then
    raise exception 'Bootstrap-Trigger hat keine lifetime_stats-Zeilen angelegt';
  end if;

  foreach u in array array[a, b] loop
    insert into public.logged_meals
      (user_id, meal_name, calories_kcal, estimated_g, payload, local_day)
      values (u, 'Testmahlzeit', 500, 300, '{}'::jsonb, current_date);
    insert into public.favorite_meals
      (user_id, favorite_key, meal_name, calories_kcal, estimated_g, payload)
      values (u, 'name:test', 'Testfavorit', 500, 300, '{}'::jsonb);
    insert into public.weight_log (user_id, weight_kg) values (u, 80);
    insert into public.user_recipes
      (user_id, slug, title, calories_kcal, estimated_g)
      values (u, 'test-' || u, 'Testrezept', 500, 300);
    insert into public.chat_sessions (user_id, title) values (u, 'Test');
    insert into public.chat_messages (user_id, role, content)
      values (u, 'user', 'hallo');
    insert into public.chat_quota_usage (user_id, day, used_count)
      values (u, current_date, 1);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 1) Logged in as A: own rows visible, B's rows do not exist
-- ---------------------------------------------------------------------------
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

do $$
declare
  b text := '22222222-2222-2222-2222-222222222222';
  t text;
begin
  foreach t in array array[
    'logged_meals', 'favorite_meals', 'weight_log', 'user_recipes',
    'chat_sessions', 'chat_messages', 'chat_quota_usage'
  ] loop
    -- Exactly one own row …
    perform rlstest.erwarte_zeilen(
      format('select * from public.%I', t), 1,
      format('SELECT auf %s als A', t));
    -- … and B's row is not reachable, not even by its user_id.
    perform rlstest.erwarte_zeilen(
      format('select * from public.%I where user_id = %L', t, b), 0,
      format('SELECT auf fremde Zeile in %s', t));
  end loop;

  -- profiles has `id` as owner column.
  perform rlstest.erwarte_zeilen(
    'select * from public.profiles', 1, 'SELECT auf profiles als A');
  perform rlstest.erwarte_zeilen(
    format('select * from public.profiles where id = %L', b), 0,
    'SELECT auf fremdes Profil');
  perform rlstest.erwarte_zeilen(
    'select * from public.lifetime_stats', 1,
    'SELECT auf lifetime_stats als A');
end $$;
commit;

-- ---------------------------------------------------------------------------
-- 2) Logged in as A: no write reaches B
-- ---------------------------------------------------------------------------
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

do $$
declare
  b text := '22222222-2222-2222-2222-222222222222';
  t text;
  muster text;
begin
  -- Client-writable tables: UPDATE/DELETE on a foreign row hit zero rows,
  -- because USING already hides them.
  foreach t in array array[
    'logged_meals', 'favorite_meals', 'weight_log', 'user_recipes',
    'chat_sessions'
  ] loop
    perform rlstest.erwarte_zeilen(
      format('update public.%I set user_id = user_id where user_id = %L', t, b),
      0, format('UPDATE auf fremde Zeile in %s', t));
    perform rlstest.erwarte_zeilen(
      format('delete from public.%I where user_id = %L', t, b), 0,
      format('DELETE auf fremde Zeile in %s', t));
  end loop;

  -- And WITH CHECK stops writing a NEW row onto B — for EVERY table the
  -- client may insert into.
  --
  -- T12: this used to name three tables by hand, so weakening
  -- `favorite_meals_insert_own` or `chat_sessions_insert_own` to
  -- `with check (auth.uid() is not null)` left this job GREEN. The list now
  -- matches the five client-writable tables of the loop above.
  for t, muster in
    select * from (values
      ('logged_meals', $sql$insert into public.logged_meals
         (user_id, meal_name, calories_kcal, estimated_g, payload)
         values (%L, 'Untergeschoben', 100, 100, '{}'::jsonb)$sql$),
      ('favorite_meals', $sql$insert into public.favorite_meals
         (user_id, favorite_key, meal_name, calories_kcal, estimated_g,
          payload)
         values (%L, 'name:untergeschoben', 'X', 100, 100, '{}'::jsonb)$sql$),
      ('weight_log', $sql$insert into public.weight_log (user_id, weight_kg)
         values (%L, 80)$sql$),
      ('user_recipes', $sql$insert into public.user_recipes
         (user_id, slug, title, calories_kcal, estimated_g)
         values (%L, 'untergeschoben', 'X', 100, 100)$sql$),
      ('chat_sessions', $sql$insert into public.chat_sessions (user_id, title)
         values (%L, 'Untergeschoben')$sql$)
    ) as v(tabelle, anweisung)
  loop
    perform rlstest.erwarte_ablehnung(
      format(muster, b),
      format('INSERT in %s auf fremde user_id', t));
  end loop;

  -- Moving an OWN row over to B must fail on WITH CHECK, not silently
  -- succeed. `favorite_meals` stays out of the loop: A and B hold the same
  -- favorite_key, so the move would trip the unique index (23505) before RLS
  -- ever gets asked, and a green run would then prove nothing.
  foreach t in array array[
    'logged_meals', 'weight_log', 'user_recipes', 'chat_sessions'
  ] loop
    perform rlstest.erwarte_ablehnung(
      format('update public.%I set user_id = %L', t, b),
      format('UPDATE, das die eigene Zeile in %s B unterschiebt', t));
  end loop;
  perform rlstest.erwarte_ablehnung(
    format('update public.profiles set id = %L', b),
    'UPDATE, das das eigene Profil B unterschiebt');
end $$;
commit;

-- ---------------------------------------------------------------------------
-- 3) Server truth stays server truth
-- ---------------------------------------------------------------------------
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

do $$
declare
  a text := '11111111-1111-1111-1111-111111111111';
begin
  -- chat_messages / chat_quota_usage / lifetime_stats: readable, never
  -- writable — a writable history is a forgeable coach context, a writable
  -- quota is a resettable rate limit, writable stats are free counters.
  perform rlstest.erwarte_ablehnung(
    format($sql$insert into public.chat_messages (user_id, role, content)
      values (%L, 'assistant', 'gefaelscht')$sql$, a),
    'INSERT in chat_messages als Client');
  perform rlstest.erwarte_ablehnung(
    'update public.chat_messages set content = ''manipuliert''',
    'UPDATE auf chat_messages als Client');
  perform rlstest.erwarte_ablehnung(
    'delete from public.chat_messages',
    'DELETE auf chat_messages als Client');
  perform rlstest.erwarte_ablehnung(
    'update public.chat_quota_usage set used_count = 0',
    'Ratenlimit zuruecksetzen');
  perform rlstest.erwarte_ablehnung(
    'update public.lifetime_stats set meals_logged = 999999',
    'Lebenszeit-Zaehler direkt setzen');
  perform rlstest.erwarte_ablehnung(
    'delete from public.lifetime_stats',
    'DELETE auf lifetime_stats als Client');

  -- Tables without any client grant: not even readable.
  perform rlstest.erwarte_ablehnung(
    'select * from public.edge_rate_limits', 'SELECT auf edge_rate_limits');
  perform rlstest.erwarte_ablehnung(
    'select * from public.lifetime_stats_requests',
    'SELECT auf lifetime_stats_requests');

  -- Mass assignment on profiles: the app never writes these columns, so the
  -- column grants must not allow it (20260819100000).
  perform rlstest.erwarte_ablehnung(
    'update public.profiles set email = ''fremd@example.test''',
    'UPDATE auf profiles.email');
  perform rlstest.erwarte_ablehnung(
    'update public.profiles set display_name = ''X''',
    'UPDATE auf profiles.display_name');

  -- P7-05: the client never deletes its profile — that runs through
  -- rpc(delete_account) and the auth.users cascade. The unused right could
  -- only destroy the server-only column daily_kcal_goal_before_live_reset.
  perform rlstest.erwarte_ablehnung(
    'delete from public.profiles', 'DELETE auf profiles als Client');

  -- TRUNCATE ignores RLS completely and must be out of reach.
  perform rlstest.erwarte_ablehnung(
    'truncate public.logged_meals', 'TRUNCATE auf logged_meals');
end $$;
commit;

-- ---------------------------------------------------------------------------
-- 4) Not logged in (anon): nothing at all
-- ---------------------------------------------------------------------------
begin;
set local role anon;
set local request.jwt.claims = '';

do $$
declare
  t text;
begin
  foreach t in array array[
    'profiles', 'logged_meals', 'favorite_meals', 'weight_log', 'user_recipes',
    'chat_sessions', 'chat_messages', 'chat_quota_usage', 'lifetime_stats',
    'edge_rate_limits', 'lifetime_stats_requests'
  ] loop
    perform rlstest.erwarte_ablehnung(
      format('select * from public.%I', t),
      format('SELECT auf %s als anon', t));
    perform rlstest.erwarte_ablehnung(
      format('delete from public.%I', t),
      format('DELETE auf %s als anon', t));
  end loop;
end $$;
commit;

-- ---------------------------------------------------------------------------
-- 5) The RPCs a client may call are bound to auth.uid()
-- ---------------------------------------------------------------------------
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

do $$
declare
  b uuid := '22222222-2222-2222-2222-222222222222';
  vorher integer;
  nachher integer;
begin
  -- ensure_default_chat_session takes a user id; pointing it at B must fail
  -- (finding of 20260609120000).
  begin
    perform public.ensure_default_chat_session(b);
    raise exception 'RLS-VERLETZUNG: ensure_default_chat_session(fremde uid) ging durch';
  exception
    when sqlstate '42501' then null;
  end;

  -- increment_lifetime_stats books onto the CALLER, never onto anyone else.
  select meals_logged into vorher from public.lifetime_stats where user_id = b;
  perform public.increment_lifetime_stats(0, 0, 7, 0, 0);
  select meals_logged into nachher from public.lifetime_stats where user_id = b;
  if vorher is distinct from nachher then
    raise exception 'RLS-VERLETZUNG: increment_lifetime_stats hat B veraendert';
  end if;
  if (select meals_logged from public.lifetime_stats
       where user_id = '11111111-1111-1111-1111-111111111111') <> 7 then
    raise exception 'increment_lifetime_stats hat den Aufrufer nicht gebucht';
  end if;

  -- Client-callable RPCs the migrations revoked must stay out of reach.
  perform rlstest.erwarte_ablehnung(
    'select public.claim_chat_quota(''11111111-1111-1111-1111-111111111111''::uuid)',
    'claim_chat_quota als Client');
  perform rlstest.erwarte_ablehnung(
    'select public.consume_edge_rate_limit(''x'', ''y'', 1, 60)',
    'consume_edge_rate_limit als Client');
end $$;
commit;

-- ---------------------------------------------------------------------------
-- 6a) P7-03, T12: the caps are actually WIRED to the real tables.
--
-- Section 6 below proves the trigger FUNCTION by hanging a probe trigger of
-- its own on public.logged_meals. Nothing proved that the five REAL triggers
-- exist — so deleting all five `create trigger` statements from
-- 20260829120000 left this job, rls_invariants_test.dart and the generated
-- SCHEMA_STATE.md green, while one account could fill every table without
-- limit. The replay in migration_schema.dart cannot close this: it waves
-- `create trigger` through as harmless, and a trigger only exists in the live
-- catalogue anyway.
-- ---------------------------------------------------------------------------
do $t$
declare
  fall record;
  tg  record;
begin
  for fall in
    select * from (values
      ('logged_meals',   'logged_meals_row_cap'),
      ('weight_log',     'weight_log_row_cap'),
      ('favorite_meals', 'favorite_meals_row_cap'),
      ('user_recipes',   'user_recipes_row_cap'),
      ('chat_sessions',  'chat_sessions_row_cap')
    ) as v(tabelle, name)
  loop
    select t.tgtype, pg_get_triggerdef(t.oid) as def into tg
      from pg_trigger t
      join pg_class c on c.oid = t.tgrelid
      join pg_namespace n on n.oid = c.relnamespace
      join pg_proc p on p.oid = t.tgfoid
     where n.nspname = 'public'
       and c.relname = fall.tabelle
       and t.tgname = fall.name
       and p.proname = 'enforce_user_row_cap'
       and not t.tgisinternal;
    -- `found` rather than `tg is null`: SELECT INTO nulls the record when it
    -- misses, but `found` says so without depending on how a record compares
    -- to NULL.
    if not found then
      raise exception 'ZEILEN-DECKEL FEHLT: public.% traegt keinen Trigger % '
        'auf enforce_user_row_cap — die Obergrenze ist Dekoration',
        fall.tabelle, fall.name;
    end if;
    -- TRIGGER_TYPE_ROW = 1, _BEFORE = 2, _INSERT = 4. A statement-level or
    -- AFTER trigger would be wired and useless at the same time.
    if (tg.tgtype & 7) <> 7 then
      raise exception 'ZEILEN-DECKEL FALSCH VERDRAHTET: % feuert nicht als '
        'BEFORE INSERT FOR EACH ROW (tgtype=%)', fall.name, tg.tgtype;
    end if;
    -- The cap itself: the second quoted argument. A zero or missing limit
    -- would leave the trigger attached and toothless.
    if coalesce(
         (substring(tg.def from
            'enforce_user_row_cap\(''[a-z_]+'', ''([0-9]+)'''))::integer, 0)
       < 1000 then
      raise exception 'ZEILEN-DECKEL UNPLAUSIBEL: % -> %', fall.name, tg.def;
    end if;
  end loop;
  raise notice 'T12 ok: alle fuenf Zeilen-Obergrenzen sind verdrahtet';
end;
$t$;

-- ---------------------------------------------------------------------------
-- 6) P7-03: the per-user row cap really bites — and only where it should
--
-- The live caps are five figures, so they cannot be reached in a test. The
-- trigger FUNCTION is the thing to prove, so a second trigger with a cap of 2
-- is hung on the real public.logged_meals (real indexes, real RLS, real
-- upsert path) and removed again afterwards. Both triggers fire; the tighter
-- one decides.
-- ---------------------------------------------------------------------------
create trigger logged_meals_row_cap_probe
  before insert on public.logged_meals
  for each row
  execute function public.enforce_user_row_cap('user_id', '2', 'id');

begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

do $$
declare
  a text := '11111111-1111-1111-1111-111111111111';
  v_id uuid;
begin
  -- A holds one seeded row, so the second one still fits.
  perform rlstest.erwarte_zeilen(
    format($sql$insert into public.logged_meals
      (user_id, meal_name, calories_kcal, estimated_g, payload, local_day)
      values (%L, 'Zweite', 100, 100, '{}'::jsonb, current_date)$sql$, a),
    1, 'INSERT unterhalb der Obergrenze');

  -- The third exceeds it and must fail with 22023 — the class the client
  -- outbox drops at once instead of retrying for 24 hours.
  perform rlstest.erwarte_sqlstate(
    format($sql$insert into public.logged_meals
      (user_id, meal_name, calories_kcal, estimated_g, payload, local_day)
      values (%L, 'Dritte', 100, 100, '{}'::jsonb, current_date)$sql$, a),
    '22023', 'INSERT ueber der Obergrenze');

  -- An UPSERT onto an EXISTING row replaces it and grows nothing, so it must
  -- pass even at the cap — otherwise a replayed outbox item would start
  -- failing exactly there.
  select id into v_id from public.logged_meals limit 1;
  perform rlstest.erwarte_zeilen(
    format($sql$insert into public.logged_meals
      (id, user_id, meal_name, calories_kcal, estimated_g, payload, local_day)
      values (%L, %L, 'Wiederholt', 100, 100, '{}'::jsonb, current_date)
      on conflict (id) do update set meal_name = excluded.meal_name$sql$,
      v_id, a),
    1, 'UPSERT auf eine bestehende Zeile an der Obergrenze');
end $$;
rollback;

drop trigger logged_meals_row_cap_probe on public.logged_meals;


-- ---------------------------------------------------------------------------
-- A7 - Aufbewahrung von public.chat_quota_usage (Migration 20260901100200).
--
-- Die Zusage, die hier haengt: die HEUTIGE Zeile ist unantastbar. Sie ist die,
-- gegen die claim_chat_quota() zaehlt, und ein Loeschen mitten am Tag waere ein
-- kostenloser Reset der fuenf Tagesslots. Das Fenster wird deshalb dreifach
-- gesichert (Rechnung, Argumentpruefung, redundantes day < heute im DELETE) und
-- unten aus allen drei Richtungen angegriffen.
--
-- Nicht hier: die Isolationsprobe (ein werfendes Quota-Prune darf das
-- Rate-Limit-Prune nicht zuruecknehmen). Sie ersetzt die Funktion durch einen
-- Stub und laesst sich im selben psql-Lauf nicht sauber zuruecksetzen; die
-- Zusage haengt am exception-Block der Migration. Manuell verifiziert (A7).
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@example.com')
on conflict (id) do nothing;

delete from public.chat_quota_usage;
do $t$
declare
  a uuid := '11111111-1111-1111-1111-111111111111';
  heute date := (now() at time zone 'utc')::date;
  weg integer;
  rest date[];
begin
  insert into public.chat_quota_usage (user_id, day, used_count) values
    (a, heute, 5), (a, heute - 1, 3), (a, heute - 89, 1), (a, heute - 90, 1),
    (a, heute - 91, 1), (a, heute - 200, 1), (a, heute - 365, 1);
  select public.prune_chat_quota_usage() into weg;
  if weg <> 3 then
    raise exception 'A7-1: erwartet 3 geloeschte Zeilen, bekam %', weg;
  end if;
  select array_agg(day order by day desc) into rest
    from public.chat_quota_usage where user_id = a;
  if rest <> array[heute, heute - 1, heute - 89, heute - 90] then
    raise exception 'A7-1: falscher Rest %', rest;
  end if;
  if not exists (select 1 from public.chat_quota_usage
                  where user_id = a and day = heute and used_count = 5) then
    raise exception 'A7-1: die HEUTIGE Zeile wurde angetastet';
  end if;
  raise notice 'A7-1 ok: Fenster 90 Tage, heute unberuehrt';
end;
$t$;

do $t$
declare
  a uuid := '11111111-1111-1111-1111-111111111111';
  heute date := (now() at time zone 'utc')::date;
  weg integer;
  rest date[];
begin
  select public.prune_chat_quota_usage(1, 1000) into weg;
  if weg <> 2 then
    raise exception 'A7-2: erwartet 2 geloeschte Zeilen, bekam %', weg;
  end if;
  select array_agg(day order by day desc) into rest
    from public.chat_quota_usage where user_id = a;
  if rest <> array[heute, heute - 1] then
    raise exception 'A7-2: falscher Rest %', rest;
  end if;
  raise notice 'A7-2 ok: engstes erlaubtes Fenster laesst heute stehen';
end;
$t$;

do $t$
declare
  fall record;
  gefangen text;
begin
  for fall in
    select * from (values
      ('keep 0', 0, 1000), ('keep -500', -500, 1000), ('keep null', null, 1000),
      ('max 0', 90, 0), ('max null', 90, null), ('max zu gross', 90, 100001)
    ) as v(name, tage, zeilen)
  loop
    gefangen := null;
    begin
      perform public.prune_chat_quota_usage(fall.tage, fall.zeilen);
    exception when sqlstate '22023' then
      gefangen := sqlerrm;
    end;
    if gefangen is null then
      raise exception 'A7-3: % ging durch statt 22023', fall.name;
    end if;
  end loop;
  if not exists (select 1 from public.chat_quota_usage
                  where day = (now() at time zone 'utc')::date) then
    raise exception 'A7-3: heutige Zeile ist weg';
  end if;
  raise notice 'A7-3 ok: alle sechs Fehlargumente werfen 22023';
end;
$t$;

delete from public.chat_quota_usage;
do $t$
declare
  b uuid := '22222222-2222-2222-2222-222222222222';
  heute date := (now() at time zone 'utc')::date;
  weg integer;
  aeltester date;
begin
  insert into public.chat_quota_usage (user_id, day, used_count)
  select b, heute - g, 1 from generate_series(100, 109) as g;
  insert into public.chat_quota_usage (user_id, day, used_count)
  values (b, heute, 2);
  select public.prune_chat_quota_usage(90, 3) into weg;
  if weg <> 3 then
    raise exception 'A7-4: erwartet 3, bekam %', weg;
  end if;
  select min(day) into aeltester from public.chat_quota_usage where user_id = b;
  if aeltester <> heute - 106 then
    raise exception 'A7-4: aeltester Rest %, erwartet %', aeltester, heute - 106;
  end if;
  if (select count(*) from public.chat_quota_usage where user_id = b) <> 8 then
    raise exception 'A7-4: falsche Zeilenzahl';
  end if;
  raise notice 'A7-4 ok: LIMIT greift, aelteste zuerst';
end;
$t$;

delete from public.chat_quota_usage;
delete from public.edge_rate_limits;
do $t$
declare
  b uuid := '22222222-2222-2222-2222-222222222222';
  heute date := (now() at time zone 'utc')::date;
  weg integer;
begin
  insert into public.edge_rate_limits
    (scope, subject_hash, window_start, window_seconds, request_count)
  values ('ip', 'aa', now() - interval '3 days', 60, 1),
         ('user', 'bb', now() - interval '5 days', 60, 1),
         ('ip', 'cc', now(), 60, 1);
  insert into public.chat_quota_usage (user_id, day, used_count) values
    (b, heute, 4), (b, heute - 120, 1), (b, heute - 400, 1);
  select public.prune_edge_rate_limits() into weg;
  if weg <> 2 then
    raise exception 'A7-5: Rueckgabe % statt 2', weg;
  end if;
  if (select count(*) from public.edge_rate_limits) <> 1 then
    raise exception 'A7-5: edge_rate_limits nicht gekuerzt';
  end if;
  if (select count(*) from public.chat_quota_usage where user_id = b) <> 1 then
    raise exception 'A7-5: abgelaufene Quota-Zeilen blieben stehen';
  end if;
  if not exists (select 1 from public.chat_quota_usage
                  where user_id = b and day = heute and used_count = 4) then
    raise exception 'A7-5: heutige Quota-Zeile mitgeloescht';
  end if;
  raise notice 'A7-5 ok: beide Jobs laufen, Rueckgabe bleibt ehrlich';
end;
$t$;

do $t$
declare
  f text := 'public.prune_chat_quota_usage(integer,integer)';
begin
  if has_function_privilege('authenticated', f, 'execute') then
    raise exception 'A7-6: authenticated darf ausfuehren';
  end if;
  if has_function_privilege('anon', f, 'execute') then
    raise exception 'A7-6: anon darf ausfuehren';
  end if;
  if has_function_privilege('public', f, 'execute') then
    raise exception 'A7-6: PUBLIC darf ausfuehren';
  end if;
  if not has_function_privilege('service_role', f, 'execute') then
    raise exception 'A7-6: service_role darf NICHT ausfuehren';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'prune_chat_quota_usage'
       and p.prosecdef and p.proconfig @> array['search_path=public']
  ) then
    raise exception 'A7-6: definer/search_path nicht wie erwartet';
  end if;
  if not exists (select 1 from pg_indexes
                  where schemaname = 'public'
                    and indexname = 'chat_quota_usage_day_idx') then
    raise exception 'A7-6: Index fehlt';
  end if;
  raise notice 'A7-6 ok: Rechte, definer/search_path und Index stehen';
end;
$t$;


select 'RLS-Kreuzzugriffe: alle Erwartungen erfuellt' as ergebnis;
