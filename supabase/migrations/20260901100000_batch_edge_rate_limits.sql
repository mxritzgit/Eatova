-- Performance audit 2026-09-01, finding P6-02 — the whole rate-limit gate
-- chain of an Edge Function in ONE round trip.
--
-- WHAT IT COSTS TODAY. Every Edge Function opens its request with a chain of
-- `consume_edge_rate_limit()` calls, and each one is its own PostgREST round
-- trip: coach-chat two (ip, user), search-key two (ip, user), analyze-meal
-- four (ip, user, user-day, global). The work behind a call is a single upsert
-- on a primary-key row — microseconds — so what the caller waits for is almost
-- entirely network: up to four sequential round trips before the request body
-- has even been read. `consume_edge_rate_limits()` takes the same gates as one
-- JSON array and walks them inside the database.
--
-- The old function STAYS. `_shared/auth_fail_gate.ts` gates a single scope and
-- has nothing to batch, and the single-gate form is the rollback path: a
-- caller that goes wrong on the batch is a few lines away from the sequential
-- chain it had before. Nothing here drops, alters or re-grants it.
--
-- SEMANTICS, and this is the part that must not drift: the batch STOPS AT THE
-- FIRST DENIAL. As soon as a gate comes back `allowed = false`, no later gate
-- is touched — no row, no increment. That mirrors the `return` that sits
-- between today's sequential calls, and it is the whole reason the result is
-- an array rather than a fixed-length object: it carries ONE element per gate
-- actually consumed, so it is shorter than the input exactly when an earlier
-- gate denied. A missing trailing element means "never consumed", NOT
-- "allowed" — a caller that reads `result[i].allowed` on a short array reads
-- `null`, and must treat that as "not reached".
--
-- VALIDATION runs over the WHOLE array before a single row is touched. Not
-- cosmetic: with lazy per-gate validation a malformed gate 4 would be visible
-- only on the requests where gates 1-3 all passed, i.e. a schema error that
-- appears and disappears with traffic. Checking upfront makes the raise
-- deterministic. The per-gate rules are byte-for-byte those of
-- `consume_edge_rate_limit`, and so are the messages — the gate index rides in
-- DETAIL so `SQLERRM` (and the PostgREST `message` field) stays identical to
-- the single-gate function.
--
-- TRANSACTION NOTE. The four calls are four transactions today; the batch is
-- one. Earlier increments therefore still COMMIT when a later gate denies,
-- because a denial RETURNS normally instead of raising — a denied request must
-- burn its earlier buckets, exactly as it does today. The only thing that
-- rolls the batch back is a validation RAISE, and with the limits coming from
-- compile-time constants in the Edge Functions that is unreachable in
-- practice; if it ever does fire, rolling back beats a partial burn on a
-- request that never ran.
--
-- TRAPS worth writing down:
--   * LOCKS. Each upsert holds a row lock until COMMIT, so the batch holds up
--     to eight of them for the length of the function instead of releasing
--     each one at its own commit. Harmless because nothing inside the function
--     waits on anything external (no network, no scan — eight PK upserts), and
--     deadlock-free because every caller sends its gates in a FIXED order and
--     two concurrent batches therefore take the same rows in the same order.
--     A caller that starts ordering its gates dynamically loses that.
--   * `now()` IS THE TRANSACTION TIME, so every gate of a batch floors its
--     window against the same instant. Today's four calls each get their own,
--     milliseconds apart, and can land on either side of a window boundary.
--     One instant for the batch is the more coherent of the two, not a
--     regression.
--   * `jsonb_typeof(x -> 'k') is distinct from 'string'` and not `<>`: a
--     MISSING key makes `->` return SQL NULL, `jsonb_typeof(NULL)` is NULL,
--     and `NULL <> 'string'` is NULL, which `if` reads as FALSE. Written with
--     `<>` the guard would wave every gate without a `scope` straight through.
--   * `numeric::integer` ROUNDS. A limit of `30.6` would silently become 31,
--     so the integrality check comes before the cast.
--   * PostgREST passes the argument BY NAME: the callers post
--     `{"p_gates": [ … ]}` to `/rest/v1/rpc/consume_edge_rate_limits`.
--
-- Idempotent throughout (`create or replace`, plain grants), so the file
-- replays from an empty database and re-applies on the live one.

create or replace function public.consume_edge_rate_limits(p_gates jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_now timestamptz := now();
  v_gate_count integer;
  v_index integer;
  v_gate jsonb;
  v_number numeric;
  -- The validated batch, so pass 2 does not re-parse the json.
  v_scopes text[] := array[]::text[];
  v_subjects text[] := array[]::text[];
  v_limits integer[] := array[]::integer[];
  v_windows integer[] := array[]::integer[];
  v_scope text;
  v_subject text;
  v_limit integer;
  v_window_seconds integer;
  v_window_start timestamptz;
  v_subject_hash text;
  v_count integer;
  v_reset_at timestamptz;
  v_allowed boolean;
  v_result jsonb := '[]'::jsonb;
begin
  -- -------------------------------------------------------------------------
  -- 1) Validate the whole batch before touching a single row.
  -- -------------------------------------------------------------------------
  if p_gates is null or jsonb_typeof(p_gates) is distinct from 'array' then
    raise exception 'invalid rate limit batch';
  end if;

  v_gate_count := jsonb_array_length(p_gates);
  -- Eight is the longest chain any caller has (analyze-meal runs four in two
  -- batches); the cap is what keeps a single call from becoming a write loop.
  if v_gate_count < 1 or v_gate_count > 8 then
    raise exception 'invalid rate limit batch size';
  end if;

  for v_index in 0 .. v_gate_count - 1 loop
    v_gate := p_gates -> v_index;
    if jsonb_typeof(v_gate) is distinct from 'object' then
      raise exception 'invalid rate limit gate'
        using detail = format('gate %s', v_index);
    end if;

    if jsonb_typeof(v_gate -> 'scope') is distinct from 'string' then
      raise exception 'invalid rate limit scope'
        using detail = format('gate %s', v_index);
    end if;
    v_scope := v_gate ->> 'scope';
    if length(trim(v_scope)) = 0 or length(v_scope) > 80 then
      raise exception 'invalid rate limit scope'
        using detail = format('gate %s', v_index);
    end if;

    if jsonb_typeof(v_gate -> 'subject') is distinct from 'string' then
      raise exception 'invalid rate limit subject'
        using detail = format('gate %s', v_index);
    end if;
    v_subject := v_gate ->> 'subject';
    if length(trim(v_subject)) = 0 or length(v_subject) > 512 then
      raise exception 'invalid rate limit subject'
        using detail = format('gate %s', v_index);
    end if;

    if jsonb_typeof(v_gate -> 'limit') is distinct from 'number' then
      raise exception 'invalid rate limit limit'
        using detail = format('gate %s', v_index);
    end if;
    v_number := (v_gate ->> 'limit')::numeric;
    if v_number <> trunc(v_number) or v_number < 1 or v_number > 10000 then
      raise exception 'invalid rate limit limit'
        using detail = format('gate %s', v_index);
    end if;
    v_limit := v_number::integer;

    if jsonb_typeof(v_gate -> 'window_seconds') is distinct from 'number' then
      raise exception 'invalid rate limit window'
        using detail = format('gate %s', v_index);
    end if;
    v_number := (v_gate ->> 'window_seconds')::numeric;
    if v_number <> trunc(v_number) or v_number < 1 or v_number > 86400 then
      raise exception 'invalid rate limit window'
        using detail = format('gate %s', v_index);
    end if;
    v_window_seconds := v_number::integer;

    v_scopes := v_scopes || v_scope;
    v_subjects := v_subjects || v_subject;
    v_limits := v_limits || v_limit;
    v_windows := v_windows || v_window_seconds;
  end loop;

  -- -------------------------------------------------------------------------
  -- 2) Consume, in array order, stopping at the first denial.
  --
  -- Everything inside this loop is `consume_edge_rate_limit` verbatim: same
  -- window floor, same sha256 over the RAW subject (the hashing stays in the
  -- database, the caller never sends a hash), same upsert, same result object.
  -- -------------------------------------------------------------------------
  for v_index in 1 .. v_gate_count loop
    v_scope := v_scopes[v_index];
    v_subject := v_subjects[v_index];
    v_limit := v_limits[v_index];
    v_window_seconds := v_windows[v_index];

    v_window_start := to_timestamp(
      floor(extract(epoch from v_now) / v_window_seconds) * v_window_seconds
    );
    v_reset_at := v_window_start + make_interval(secs => v_window_seconds);
    v_subject_hash := encode(digest(v_subject::text, 'sha256'::text), 'hex');

    insert into public.edge_rate_limits (
      scope, subject_hash, window_start, window_seconds, request_count, updated_at
    ) values (
      v_scope, v_subject_hash, v_window_start, v_window_seconds, 1, v_now
    )
    on conflict (scope, subject_hash, window_start, window_seconds)
    do update set
      request_count = public.edge_rate_limits.request_count + 1,
      updated_at = excluded.updated_at
    returning request_count into v_count;

    v_allowed := v_count <= v_limit;

    v_result := v_result || jsonb_build_array(
      jsonb_build_object(
        'allowed', v_allowed,
        'limit', v_limit,
        'remaining', greatest(v_limit - v_count, 0),
        'resetAt', v_reset_at,
        'windowSeconds', v_window_seconds
      )
    );

    -- P6-02, the property the whole migration exists for: a denial ends the
    -- batch. Later gates get no row and no increment, so a request rejected at
    -- the IP gate never spends the user's daily bucket — which is what the
    -- early `return` between the sequential calls does today.
    exit when not v_allowed;
  end loop;

  return v_result;
end;
$$;

comment on function public.consume_edge_rate_limits(jsonb) is
  'Batch form of consume_edge_rate_limit: takes 1-8 gates as a jsonb array '
  '({scope, subject, limit, window_seconds}), consumes them in order and STOPS '
  'AT THE FIRST DENIAL. Returns a jsonb array with one element per gate '
  'actually consumed — shorter than the input exactly when an earlier gate '
  'denied, so a missing element means "never consumed", not "allowed". '
  'Performance audit 2026-09-01, P6-02.';

revoke all on function public.consume_edge_rate_limits(jsonb)
  from public, anon, authenticated;
grant execute on function public.consume_edge_rate_limits(jsonb)
  to service_role;
