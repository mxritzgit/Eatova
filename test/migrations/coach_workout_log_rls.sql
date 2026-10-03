-- Included by rls_cross_user.sql after training_plans_rls.sql. Coach /log
-- proposals on chat_messages (20261004090000): the database validator runs the
-- SAME cases as the edge function and the app, and only the server writes the
-- column. All writes roll back.

-- The shared fixture, read relative to the repository root like the
-- rls-postgres job runs psql. A session setting reaches every role below.
\set workout_log_cases `cat supabase/functions/coach-chat/fixtures/workout_log_cases.json`
select set_config('rlstest.workout_log_cases', :'workout_log_cases', false) is not null as fixture_loaded;

create or replace function rlstest.workout_log()
returns jsonb language sql immutable as $$
  select '{"schema_version":1,"title":"Leg day","performed_on":"2026-10-03","duration_minutes":null,
    "other_days_omitted":false,"note":"","exercises":[{"name":"Squat","kind":"reps",
    "duration_seconds":null,"sets":[{"reps":5,"weight_kg":102.06}]}]}'::jsonb;
$$;
grant execute on function rlstest.workout_log() to authenticated, service_role;

begin;
set local role service_role;
do $$
declare
  cases json;
  item json;
  candidate jsonb;
  valid_cases integer := 0;
  invalid_cases integer := 0;
  unrepresentable integer := 0;
begin
  -- PostgreSQL rejects a lone UTF-16 surrogate escape anywhere in JSON input,
  -- so the column can never receive one. Those cases are marked before
  -- parsing; the edge function and the app reject them explicitly.
  cases := regexp_replace(current_setting('rlstest.workout_log_cases'),
    '\\u[dD][89abAB][0-9a-fA-F]{2}(?!\\u[dD][c-fC-F])|(?<!\\u[dD][89abAB][0-9a-fA-F]{2})\\u[dD][c-fC-F][0-9a-fA-F]{2}',
    '<lone surrogate>', 'g')::json;

  for item in select value from json_array_elements(cases -> 'valid') loop
    candidate := item::jsonb;
    if public.is_valid_coach_workout_log(candidate) is distinct from true then
      raise exception 'WORKOUT LOG: valid fixture rejected: %', candidate;
    end if;
    insert into public.chat_messages(user_id, role, content, workout_log)
      values ('11111111-1111-1111-1111-111111111111', 'assistant', 'Log', candidate);
    valid_cases := valid_cases + 1;
  end loop;

  for item in select value from json_array_elements(cases -> 'invalid') loop
    if (item -> 'value')::text like '%<lone surrogate>%' then
      unrepresentable := unrepresentable + 1;
      invalid_cases := invalid_cases + 1;
      continue;
    end if;
    candidate := (item -> 'value')::jsonb;
    if public.is_valid_coach_workout_log(candidate) is distinct from false then
      raise exception 'WORKOUT LOG: invalid fixture accepted (%)', item ->> 'reason';
    end if;
    -- The CHECK defends persisted rows independently of the edge function.
    perform rlstest.erwarte_sqlstate(format(
      $q$insert into public.chat_messages(user_id, role, content, workout_log)
        values ('11111111-1111-1111-1111-111111111111', 'assistant', 'Log', %L::jsonb)$q$, candidate),
      '23514', format('persist invalid workout log (%s)', item ->> 'reason'));
    invalid_cases := invalid_cases + 1;
  end loop;
  if valid_cases < 12 or invalid_cases < 20 then
    raise exception 'WORKOUT LOG: fixture not loaded (% valid, % invalid)', valid_cases, invalid_cases;
  end if;
  -- The marker must hit exactly the surrogate cases, never a valid pair.
  if unrepresentable <> (select count(*) from json_array_elements(cases -> 'invalid') e
                         where e ->> 'reason' like '%surrogate%') or unrepresentable = 0 then
    raise exception 'WORKOUT LOG: % cases marked as lone surrogates', unrepresentable;
  end if;

  -- SQL NULL means "no proposal"; a validator call on it is a plain false.
  if public.is_valid_coach_workout_log(null) is distinct from false then
    raise exception 'WORKOUT LOG: NULL is not a log';
  end if;
  -- Numeric parity with the TS validator: mathematical integers and two
  -- decimals pass, a third decimal or an out-of-range magnitude does not.
  if not public.is_valid_coach_workout_log(jsonb_set(rlstest.workout_log(), '{exercises,0,sets,0,reps}', '5.0'))
     or not public.is_valid_coach_workout_log(jsonb_set(rlstest.workout_log(), '{exercises,0,sets,0,weight_kg}', '102.50'))
     or public.is_valid_coach_workout_log(jsonb_set(rlstest.workout_log(), '{exercises,0,sets,0,weight_kg}', '102.055'))
     or public.is_valid_coach_workout_log(jsonb_set(rlstest.workout_log(), '{exercises,0,sets,0,reps}', '1e1000')) then
    raise exception 'WORKOUT LOG: numeric rules differ from the edge function';
  end if;
end $$;

-- One proposal kind per row, only on a non-refusal assistant row.
select rlstest.erwarte_sqlstate(
  $q$insert into public.chat_messages(user_id, role, content, workout_log)
    values ('11111111-1111-1111-1111-111111111111', 'user', 'Log', rlstest.workout_log())$q$,
  '23514', 'user-message workout log');
select rlstest.erwarte_sqlstate(
  $q$insert into public.chat_messages(user_id, role, content, refusal, workout_log)
    values ('11111111-1111-1111-1111-111111111111', 'assistant', 'Log', true, rlstest.workout_log())$q$,
  '23514', 'refusal with workout log');
select rlstest.erwarte_sqlstate(
  $q$insert into public.chat_messages(user_id, role, content, recipe, workout_log)
    values ('11111111-1111-1111-1111-111111111111', 'assistant', 'Log', '{}', rlstest.workout_log())$q$,
  '23514', 'recipe and workout log');
select rlstest.erwarte_sqlstate(
  $q$insert into public.chat_messages(user_id, role, content, training_plan, workout_log)
    values ('11111111-1111-1111-1111-111111111111', 'assistant', 'Log', rlstest.training_plan(), rlstest.workout_log())$q$,
  '23514', 'training plan and workout log');
-- Older backend writers do not know the column; rollout preserves them.
insert into public.chat_messages(user_id, role, content)
  values ('11111111-1111-1111-1111-111111111111', 'assistant', 'Plain answer');
insert into public.chat_messages(user_id, role, content, workout_log)
  values ('11111111-1111-1111-1111-111111111111', 'assistant', 'Log', rlstest.workout_log());

-- The proposal is the owner's to read, never the client's to write.
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
select rlstest.erwarte_zeilen(
  $q$select * from public.chat_messages where workout_log = rlstest.workout_log()$q$,
  1, 'own workout log proposal');
select rlstest.erwarte_ablehnung(
  $q$insert into public.chat_messages(user_id, role, content, workout_log)
    values ('11111111-1111-1111-1111-111111111111', 'assistant', 'Forged', rlstest.workout_log())$q$,
  'client workout log forgery');
select rlstest.erwarte_ablehnung(
  $q$update public.chat_messages set workout_log = rlstest.workout_log()$q$,
  'client workout log rewrite');
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
select rlstest.erwarte_zeilen(
  'select * from public.chat_messages where workout_log is not null', 0, 'foreign workout log');

set local role anon;
select rlstest.erwarte_ablehnung(
  'select * from public.chat_messages where workout_log is not null', 'anonymous workout log read');
select rlstest.erwarte_ablehnung(
  'select public.is_valid_coach_workout_log(null)', 'anonymous validator RPC');
rollback;
