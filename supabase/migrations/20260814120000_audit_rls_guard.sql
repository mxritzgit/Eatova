-- Eatova — audit 2026-08-14: version the RLS net, defuse the default grants,
-- harden increment_lifetime_stats against self-poisoning and double counting.
--
-- Four findings, four blocks. Purely hardening and idempotent: runs against the
-- existing live DB and a fresh `supabase db reset` alike.
--
--   A) The default privileges give every future public table full CRUD to
--      `authenticated`; the only counterweight was an `ensure_rls` event
--      trigger that exists in no migration. Versioned here, and the default
--      privileges drop so the gap is closed even where the trigger cannot be
--      installed for lack of superuser rights.
--   B) increment_lifetime_stats clamped only downwards: a direct RPC call with
--      p_meals = 2147483647 pins the row at the int4 edge and every later
--      increment fails 22003 — self-inflicted, but irreversible without
--      support.
--   C) chat_messages / chat_quota_usage were protected only by the absence of
--      a write policy while the grants still carried INSERT/UPDATE/DELETE. Take
--      the grant, not just the policy.
--   D) increment_lifetime_stats was not idempotent: an outbox retry of a call
--      whose response was lost counted twice. Optional request id + a consumed
--      table close that.
--
-- All new error paths below deliberately carry NO errcode (default P0001): the
-- client outbox treats P0001 as retryable-with-budget, while class 22 is
-- discarded at once as payload-determined.

-- ---------------------------------------------------------------------------
-- A1) rls_auto_enable() — turns RLS on for every newly created public table,
--     closing the "new table without RLS" gap in fresh environments too.
--
--     NO `security definer` on purpose: a table's creator is its owner and may
--     enable RLS on it, while as definer the function would run as postgres and
--     fail 42501 on a foreign-owned table. Since an error in an event trigger
--     tears down the triggering CREATE TABLE, that would block DDL instead of
--     securing it. Invoker is both the weaker right and the robust path.
--
--     search_path pinned (function_search_path_mutable); object_identity is
--     already fully qualified and quoted, hence %s rather than %I.
-- ---------------------------------------------------------------------------
--     Two properties are not cosmetic: live, `create or replace` really does
--     replace this body while the event trigger next to it cannot be recreated
--     without superuser rights (see A2), so the existing trigger ends up
--     pointing here. This body must therefore be at least as defensive:
--       1. Catch errors per table. An error in the event trigger takes the
--          triggering CREATE TABLE with it. Log and continue.
--       2. Include `partitioned table`. A partitioned table reports its own
--          object_type and would otherwise slip through — exactly the case A3
--          can no longer catch.
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

-- Least-privilege line: the default privileges would otherwise grant EXECUTE
-- to authenticated. Event-trigger functions are not callable via PostgREST and
-- the trigger fires regardless of EXECUTE — harmless, but consistency is the
-- point.
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
grant execute on function public.rls_auto_enable() to service_role;

-- ---------------------------------------------------------------------------
-- A2) Set the `ensure_rls` event trigger idempotently.
--
--     drop + create rather than create-if-missing, so the trigger always
--     carries the body above even if an older variant is live.
--
--     Wrapped in a sub-transaction handler because CREATE EVENT TRIGGER needs
--     superuser: live, `postgres` is not one and an existing `ensure_rls` may
--     belong to `supabase_admin`, so even the DROP fails with 42501. Harmless —
--     that is the environment where the trigger already exists; the handler
--     just lets the remaining blocks run.
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
-- A3) The actual cause: revoke the default privileges on TABLES from
--     `authenticated`. The event trigger above is only the second line — it
--     enables RLS, but without a policy RLS means "nobody", and that must not
--     be what the safety rests on.
--
--     CONSEQUENCE FOR FUTURE MIGRATIONS: a new client-visible table now needs
--     its explicit
--     `grant select, insert, update, delete on public.<table> to authenticated;`
--     Existing tables are untouched: ALTER DEFAULT PRIVILEGES affects future
--     objects only.
--
--     `revoke all`, not just the four CRUD rights: the Supabase bootstrap adds
--     its own `grant ALL on tables` default with the same grantor, and a subset
--     revoke would leave TRUNCATE, REFERENCES and TRIGGER standing — TRUNCATE
--     ignores RLS entirely, so the gap would only move one privilege class.
--
--     Sequences and functions stay as they are: usage/select is no data path,
--     and revoking from authenticated would silently make every new RPC
--     uncallable.
-- ---------------------------------------------------------------------------
alter default privileges in schema public
  revoke all on tables from authenticated;

-- ---------------------------------------------------------------------------
-- A4) Defensive strip on EXISTING tables: everything created under the
--     bootstrap `grant all` default still carries TRUNCATE, REFERENCES and
--     TRIGGER for `authenticated`, which A3 does not clear.
--
--     None of the three is reachable through PostgREST, so this is no incident
--     fix. It removes the rights a future dynamic path could use to bypass RLS:
--     TRUNCATE deletes without any policy check, TRIGGER attaches foreign code
--     to a table.
--
--     Only those three: `revoke all` would take SELECT and CRUD with it and
--     stop the app at once. service_role is untouched.
-- ---------------------------------------------------------------------------
revoke truncate, references, trigger on all tables in schema public from authenticated;

-- ---------------------------------------------------------------------------
-- C) chat_messages / chat_quota_usage — revoke write grants.
--    Both tables are server truth: written only from the coach-chat edge
--    function with service_role, read-only for the client. Without this the
--    protection rests on nobody ever adding a write policy — which would mean
--    a self-resettable rate limit and a forgeable conversation history that
--    the next coach request carries as context.
-- ---------------------------------------------------------------------------
revoke insert, update, delete on public.chat_messages    from anon, authenticated;
revoke insert, update, delete on public.chat_quota_usage from anon, authenticated;

-- ---------------------------------------------------------------------------
-- D1) lifetime_stats_requests — consumed request ids.
--     Pure server bookkeeping: no grant for authenticated, RLS on and NO
--     policy — only the security-definer RPC below touches it, running as
--     function owner. `on delete cascade` on auth.users so delete_account()
--     (GDPR Art. 17) takes it along like any other app table.
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
-- B+D2) increment_lifetime_stats — per-call upper bounds plus an optional
--       request id against double counting.
--
--       DROP rather than plain `create or replace`: an extra signature is a
--       SECOND function in Postgres, and with both present PostgREST could no
--       longer resolve the existing four-parameter call (PGRST203). The DROP
--       takes the old grants with it, hence the new ones below.
--
--       The signature stays backwards compatible: p_request_id has a default,
--       so the existing four-parameter call still matches.
--
--       Bounds (finding B) clamp per CALL, not cumulatively, and sit far above
--       anything the app produces — 500 backfilled meals is roughly four
--       months offline.
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
  -- greatest/least ignore NULL arguments, so a missing parameter still falls
  -- back to 0 or to the bound.
  v_water       integer := least(greatest(p_water, 0),        20000);
  v_steps       integer := least(greatest(p_steps, 0),       200000);
  v_meals       integer := least(greatest(p_meals, 0),          500);
  v_weight_logs integer := least(greatest(p_weight_logs, 0),    500);
  v_workouts    integer := least(greatest(p_workouts, 0),       500);
begin
  if v_uid is null then
    raise exception 'EX_USER_REQUIRED' using errcode = '22023';
  end if;

  -- Finding D: the same request counts exactly once. The insert IS the test —
  -- `on conflict do nothing` + FOUND is atomic, so two parallel retries cannot
  -- slip past each other the way a preceding SELECT would allow. Without an id
  -- the behaviour is unchanged.
  if p_request_id is not null then
    insert into public.lifetime_stats_requests (user_id, request_id)
    values (v_uid, p_request_id)
    on conflict (user_id, request_id) do nothing;

    if not found then
      -- Already booked: add nothing, but return the current row so the retry
      -- succeeds and leaves the outbox instead of burning its budget.
      insert into public.lifetime_stats (user_id)
      values (v_uid)
      on conflict (user_id) do nothing;
      select * into v_row from public.lifetime_stats where user_id = v_uid;
      return v_row;
    end if;

    -- Cleanup in passing: the table must not grow unbounded, and a 30-day
    -- retry window outlives any outbox phase. Only own rows; the PK prefix
    -- user_id carries the lookup.
    delete from public.lifetime_stats_requests
    where user_id = v_uid
      and created_at < now() - interval '30 days';
  end if;

  -- Ensure the row exists (new user before the bootstrap trigger), then count
  -- up atomically, so a new user's first call does not hit 0 rows.
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
-- B2) Last line: bounds on the table too. The clamp above protects the RPC
--     path, this check protects the column should another write path appear.
--     1e9 is far above any real lifetime value and more than a billion below
--     the int4 edge, so the counter can never reach the zone where the next
--     increment dies with 22003.
--
--     `not valid`: applies to every new row version but does NOT check the
--     existing rows — an already poisoned counter would otherwise fail the
--     migration, and data repair does not belong in a hardening migration.
--     Idempotency via a conname probe, since ALTER TABLE has no `if not
--     exists`.
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
