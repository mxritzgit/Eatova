-- Included by rls_cross_user.sql. All writes roll back; only fixture helpers
-- remain. Assertions execute as authenticated/anon/service_role, never relying
-- on the superuser's bypass to prove a client action is permitted.
create or replace function rlstest.training_plan()
returns jsonb language sql immutable as $$
  select '{"schema_version":1,"title":"Training","description":"","goal":"",
    "workouts":[{"title":"A","description":"","exercises":[
      {"name":"Squat","sets":3,"reps":10,"duration_seconds":null,"rest_seconds":60,"notes":""},
      {"name":"Plank","sets":2,"reps":null,"duration_seconds":30,"rest_seconds":0,"notes":""}
    ]}]}'::jsonb;
$$;
grant execute on function rlstest.training_plan() to authenticated, service_role;

-- Semantic validation, including payloads that pass shape checks but violate
-- nested limits. The database must reject invalid service writes too.
begin;
set local role service_role;
do $$
declare
  draft jsonb := rlstest.training_plan();
  invalid jsonb;
  test_case record;
  total_limit jsonb;
  codepoint integer;
begin
  if public.is_valid_training_plan(draft) is distinct from true then
    raise exception 'TRAINING: valid repetitions/timed draft rejected';
  end if;
  foreach invalid in array array[
    null::jsonb, 'null'::jsonb, '[]'::jsonb, '{}'::jsonb,
    draft - 'title', draft || '{"unknown":1}'::jsonb,
    draft || '{"schema_version":"1"}'::jsonb,
    draft || '{"schema_version":2}'::jsonb,
    draft || '{"description":null}'::jsonb,
    draft || '{"workouts":{}}'::jsonb,
    draft || '{"workouts":[]}'::jsonb,
    draft || '{"title":""}'::jsonb,
    draft || jsonb_build_object('title', repeat('a', 121)),
    draft || jsonb_build_object('description', repeat('a', 1001)),
    draft || jsonb_build_object('goal', repeat('a', 201)),
    jsonb_set(draft, '{workouts,0}', (draft #> '{workouts,0}') - 'title'),
    jsonb_set(draft, '{workouts,0,other}', '1'),
    jsonb_set(draft, '{workouts,0,description}', to_jsonb(repeat('a', 501))),
    jsonb_set(draft, '{workouts,0,exercises}', '[]'),
    jsonb_set(draft, '{workouts,0,exercises}', '{}'),
    jsonb_set(draft, '{workouts,0,exercises,0}', 'null'),
    jsonb_set(draft, '{workouts,0,exercises,0}', (draft #> '{workouts,0,exercises,0}') - 'notes'),
    jsonb_set(draft, '{workouts,0,exercises,0,owner}', '"attacker"'),
    jsonb_set(draft, '{workouts,0,exercises,0,name}', '""'),
    jsonb_set(draft, '{workouts,0,exercises,0,notes}', to_jsonb(repeat('a', 501))),
    jsonb_set(draft, '{workouts,0,exercises,0,reps}', 'null'),
    jsonb_set(draft, '{workouts,0,exercises,0,duration_seconds}', '30'),
    draft || jsonb_build_object('workouts',
      (select jsonb_agg(draft #> '{workouts,0}') from generate_series(1,8))),
    jsonb_set(draft, '{workouts,0,exercises}',
      (select jsonb_agg(draft #> '{workouts,0,exercises,0}') from generate_series(1,21)))
  ] loop
    if public.is_valid_training_plan(invalid) is distinct from false then
      raise exception 'TRAINING: invalid structure accepted: %', invalid;
    end if;
    -- NOT NULL and CHECK independently defend persisted rows.
    perform rlstest.erwarte_sqlstate(format(
      'insert into public.training_plans(user_id,id,plan) values (%L,%L,%L::jsonb)',
      '11111111-1111-1111-1111-111111111111', 'invalid', invalid),
      case when invalid is null then '23502' else '23514' end,
      'persist invalid training draft');
  end loop;

  for test_case in select * from (values
    ('sets', '0'), ('sets', '11'), ('sets', '1.5'), ('sets', '"3"'),
    ('sets', 'true'), ('sets', 'null'), ('sets', '{}'), ('sets', '[]'),
    ('reps', '0'), ('reps', '101'), ('reps', '1.5'), ('reps', '"10"'),
    ('rest_seconds', '-1'), ('rest_seconds', '601'), ('rest_seconds', '1.5'),
    ('rest_seconds', 'null'), ('rest_seconds', '1e1000')
  ) as cases(field, value) loop
    invalid := jsonb_set(draft,
      array['workouts','0','exercises','0',test_case.field], test_case.value::jsonb);
    if public.is_valid_training_plan(invalid) is distinct from false then
      raise exception 'TRAINING: invalid numeric % = % accepted', test_case.field, test_case.value;
    end if;
  end loop;
  foreach invalid in array array['4'::jsonb, '3601', '5.5', '"30"', 'true'] loop
    if public.is_valid_training_plan(jsonb_set(draft,
      '{workouts,0,exercises,1,duration_seconds}', invalid)) is distinct from false then
      raise exception 'TRAINING: invalid duration accepted';
    end if;
  end loop;
  if not public.is_valid_training_plan(jsonb_set(draft,
    '{workouts,0,exercises,0,sets}', '1.0')) then
    raise exception 'TRAINING: mathematical integer rejected';
  end if;

  -- PostgreSQL char_length counts codepoints, not UTF-16 code units/UTF-8 bytes.
  if not public.is_valid_training_plan(draft || jsonb_build_object('title', repeat(chr(128170), 120)))
     or public.is_valid_training_plan(draft || jsonb_build_object('title', repeat(chr(128170), 121))) then
    raise exception 'TRAINING: Unicode codepoint title bound differs';
  end if;
  foreach codepoint in array array[9,10,13,32,133,160,5760,8192,8232,8239,8287,12288,65279] loop
    if public.is_valid_training_plan(draft || jsonb_build_object('title', chr(codepoint))) then
      raise exception 'TRAINING: whitespace-only title accepted (%)', codepoint;
    end if;
  end loop;
  for codepoint in 1..31 loop
    invalid := jsonb_set(draft, '{workouts,0,exercises,0,notes}', to_jsonb(chr(codepoint)));
    if public.is_valid_training_plan(invalid) is distinct from (codepoint in (9,10,13)) then
      raise exception 'TRAINING: C0 policy differs (%)', codepoint;
    end if;
  end loop;

  -- Exactly 12000: 33 title/name codepoints + 29*399 + 396 note codepoints.
  select jsonb_build_object('schema_version', 1, 'title', 'x', 'description', '', 'goal', '',
    'workouts', jsonb_agg(jsonb_build_object('title', 'x', 'description', '',
      'exercises', (select jsonb_agg(jsonb_build_object('name', 'x', 'sets', 1,
        'reps', 1, 'duration_seconds', null, 'rest_seconds', 0,
        'notes', repeat(chr(128170), case when w = 2 and e = 15 then 396 else 399 end)))
        from generate_series(1,15) e))))
    into total_limit from generate_series(1,2) w;
  if not public.is_valid_training_plan(total_limit)
     or public.is_valid_training_plan(total_limit || '{"description":"x"}'::jsonb) then
    raise exception 'TRAINING: combined 12000-codepoint boundary differs';
  end if;
  if public.is_valid_training_plan(draft || jsonb_build_object('description', repeat('a', 131073))) then
    raise exception 'TRAINING: oversized payload accepted';
  end if;
end $$;
rollback;

-- A generated draft belongs only to chat history until explicitly adopted.
begin;
set local role service_role;
insert into public.chat_messages(user_id, role, content, training_plan)
values ('11111111-1111-1111-1111-111111111111', 'assistant', 'Plan', rlstest.training_plan());
do $$ begin
  if exists (select 1 from public.training_plans) then
    raise exception 'TRAINING: generating a draft silently adopted it';
  end if;
  perform rlstest.erwarte_sqlstate(
    $q$insert into public.chat_messages(user_id, role, content, training_plan)
      values ('11111111-1111-1111-1111-111111111111', 'user', 'Plan', rlstest.training_plan())$q$,
    '23514', 'user-message draft');
  perform rlstest.erwarte_sqlstate(
    $q$insert into public.chat_messages(user_id, role, content, refusal, training_plan)
      values ('11111111-1111-1111-1111-111111111111', 'assistant', 'Plan', true, rlstest.training_plan())$q$,
    '23514', 'refusal draft');
  perform rlstest.erwarte_sqlstate(
    $q$insert into public.chat_messages(user_id, role, content, recipe, training_plan)
      values ('11111111-1111-1111-1111-111111111111', 'assistant', 'Plan', '{}', rlstest.training_plan())$q$,
    '23514', 'mixed recipe/plan draft');
  perform rlstest.erwarte_sqlstate(
    $q$insert into public.chat_messages(user_id, role, content, training_plan)
      values ('11111111-1111-1111-1111-111111111111', 'assistant', 'Plan', '{}')$q$,
    '23514', 'malformed history draft');
end $$;
-- Older backend writers do not know the column; rollout preserves them.
insert into public.chat_messages(user_id, role, content, recipe)
values ('11111111-1111-1111-1111-111111111111', 'assistant', 'Recipe', '{}');

insert into public.training_plans(user_id,id,plan) values
  ('11111111-1111-1111-1111-111111111111', 'shared_id', rlstest.training_plan()),
  ('22222222-2222-2222-2222-222222222222', 'shared_id', rlstest.training_plan());
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
select rlstest.erwarte_zeilen('select * from public.training_plans', 1, 'own saved plan/export');
select rlstest.erwarte_zeilen(
  'select * from public.chat_messages where training_plan is not null', 1, 'own draft history');
select rlstest.erwarte_zeilen(
  $q$select * from public.training_plans where user_id='22222222-2222-2222-2222-222222222222'$q$,
  0, 'foreign saved plan');
select rlstest.erwarte_zeilen(
  $q$update public.training_plans set plan=rlstest.training_plan()
    where user_id='22222222-2222-2222-2222-222222222222'$q$, 0, 'foreign update');
select rlstest.erwarte_zeilen(
  $q$delete from public.training_plans where user_id='22222222-2222-2222-2222-222222222222'$q$,
  0, 'foreign delete');
select rlstest.erwarte_ablehnung(
  $q$insert into public.training_plans(user_id,id,plan)
    values ('22222222-2222-2222-2222-222222222222','forged',rlstest.training_plan())$q$, 'foreign insert');
select rlstest.erwarte_ablehnung(
  $q$update public.training_plans set user_id='22222222-2222-2222-2222-222222222222'$q$, 'owner reassignment');
select rlstest.erwarte_ablehnung(
  $q$update public.chat_messages set training_plan=rlstest.training_plan()$q$, 'client draft forgery');

select rlstest.erwarte_zeilen(
  $q$insert into public.training_plans(user_id,id,plan)
    values ('11111111-1111-1111-1111-111111111111','coach_message-1',rlstest.training_plan())
    on conflict (user_id,id) do update set plan=excluded.plan$q$, 1, 'explicit adoption');
select rlstest.erwarte_zeilen(
  $q$insert into public.training_plans(user_id,id,plan)
    values ('11111111-1111-1111-1111-111111111111','coach_message-1',rlstest.training_plan())
    on conflict (user_id,id) do update set plan=excluded.plan$q$, 1, 'idempotent adoption retry');
select rlstest.erwarte_zeilen('select * from public.training_plans', 2, 'retry did not duplicate');
select rlstest.erwarte_sqlstate(
  $q$insert into public.training_plans(user_id,id,plan)
    values ('11111111-1111-1111-1111-111111111111','../bad',rlstest.training_plan())$q$,
  '23514', 'unsafe ID');
select rlstest.erwarte_sqlstate(
  $q$insert into public.training_plans(user_id,id,plan)
    values ('11111111-1111-1111-1111-111111111111',repeat('a',101),rlstest.training_plan())$q$,
  '23514', 'oversized ID');

set local role anon;
select rlstest.erwarte_ablehnung('select * from public.training_plans', 'anonymous export');
select rlstest.erwarte_ablehnung('delete from public.training_plans', 'anonymous delete');
select rlstest.erwarte_ablehnung('select public.is_valid_training_plan(null)', 'anonymous validator RPC');

set local role authenticated;
set local request.jwt.claims = '{}';
select rlstest.erwarte_zeilen('select * from public.training_plans', 0, 'missing subject');
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
select rlstest.erwarte_zeilen(
  'select * from public.chat_messages where training_plan is not null', 0, 'foreign proposal history');
rollback;

-- Real 200-row storage guard; existing upserts remain valid when full.
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
do $$ begin
  for i in 1..200 loop
    insert into public.training_plans(user_id,id,plan) values
      ('11111111-1111-1111-1111-111111111111', 'plan_' || i, rlstest.training_plan());
  end loop;
  perform rlstest.erwarte_sqlstate(
    $q$insert into public.training_plans(user_id,id,plan)
      values ('11111111-1111-1111-1111-111111111111','overflow',rlstest.training_plan())$q$,
    '22023', 'actual training row cap');
  perform rlstest.erwarte_zeilen(
    $q$insert into public.training_plans(user_id,id,plan)
      values ('11111111-1111-1111-1111-111111111111','plan_1',rlstest.training_plan())
      on conflict (user_id,id) do update set plan=excluded.plan$q$, 1, 'retry at cap');
  perform rlstest.erwarte_zeilen('select * from public.training_plans', 200, 'bounded library');
  perform rlstest.erwarte_zeilen($q$delete from public.training_plans where id='plan_1'$q$, 1, 'own deletion');
  insert into public.training_plans(user_id,id,plan) values
    ('11111111-1111-1111-1111-111111111111', 'replacement', rlstest.training_plan());
end $$;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
insert into public.training_plans(user_id,id,plan) values
  ('22222222-2222-2222-2222-222222222222', 'other_owner', rlstest.training_plan());

-- Actual authenticated account RPC must remove A's plans and retain B's.
select set_config('request.jwt.claims', jsonb_build_object(
  'sub', '11111111-1111-1111-1111-111111111111',
  'amr', jsonb_build_array(jsonb_build_object('method','otp',
    'timestamp',extract(epoch from now() - interval '1 minute')::bigint)))::text, true);
select public.delete_account();
reset role;
do $$ begin
  if exists (select 1 from public.training_plans where user_id='11111111-1111-1111-1111-111111111111')
     or (select count(*) from public.training_plans where user_id='22222222-2222-2222-2222-222222222222') <> 1 then
    raise exception 'TRAINING: account deletion cascade/ownership failed';
  end if;
end $$;
rollback;
