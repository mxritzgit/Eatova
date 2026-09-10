-- Root includes this file after the common role/assertion fixtures.
create or replace function rlstest.training_history(history_id uuid default 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
returns jsonb language sql immutable as $$
select jsonb_build_object('note','Fixture', 'snapshot', jsonb_build_object(
  'schema_version',2,'status','paused','session_id',history_id::text,
  'started_at','2026-09-10T12:00:00Z','workout_index',0,'exercise_index',0,'set_index',1,
  'phase','review','remaining_milliseconds',0,'draft_reps',null,'draft_weight_kg',null,
  'plan',jsonb_build_object('id','source-plan','exercise_ids','[["squat-identity"]]'::jsonb,
    'plan','{"schema_version":1,"title":"Original plan","description":"","goal":"", "workouts":[{"title":"Original workout","description":"","exercises":[{"name":"Squat","sets":2,"reps":8,"duration_seconds":null,"rest_seconds":0,"notes":""}]}]}'::jsonb),
  'completed_sets','[{"exercise_index":0,"set_index":0}]'::jsonb,
  'skipped_sets','[{"exercise_index":0,"set_index":1}]'::jsonb,
  'actual_sets','[{"exercise_index":0,"set_index":0,"reps":6,"weight_kg":12.5,"completed_at":"2026-09-10T12:01:00Z"}]'::jsonb));
$$;
grant execute on function rlstest.training_history(uuid) to authenticated, service_role;

begin;
set local role service_role;
do $$ declare valid jsonb := rlstest.training_history(); invalid jsonb; begin
  if public.is_valid_training_history(valid,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','2026-09-10T12:02:00Z') is distinct from true then
    raise exception 'TRAINING HISTORY: valid completion rejected';
  end if;
  foreach invalid in array array[
    'null'::jsonb, '{}'::jsonb, valid - 'note', valid || '{"owner":"forged"}',
    jsonb_set(valid,'{snapshot,schema_version}','1'),
    jsonb_set(valid,'{snapshot,session_id}','"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"'),
    jsonb_set(valid,'{snapshot,started_at}','"2026-09-10T12:03:00Z"'),
    jsonb_set(valid,'{snapshot,started_at}','"infinity"'),
    jsonb_set(valid,'{snapshot,phase}','"exercise"'),
    jsonb_set(valid,'{snapshot,phase}','null'),
    jsonb_set(valid,'{snapshot,status}','null'),
    jsonb_set(valid,'{snapshot,session_id}','null'),
    jsonb_set(valid,'{snapshot,plan,id}','null'),
    jsonb_set(valid,'{snapshot,workout_index}','5'),
    jsonb_set(valid,'{snapshot,set_index}','0'),
    jsonb_set(valid,'{snapshot,plan,id}','"../bad"'),
    jsonb_set(valid,'{snapshot,plan,exercise_ids}','null'),
    jsonb_set(valid,'{snapshot,plan,exercise_ids}','[]'),
    jsonb_set(valid,'{snapshot,skipped_sets}','[]'),
    jsonb_set(valid,'{snapshot,skipped_sets}','[{"exercise_index":0,"set_index":0}]'),
    jsonb_set(valid,'{snapshot,actual_sets}','[]'),
    jsonb_set(valid,'{snapshot,actual_sets,0,set_index}','1'),
    jsonb_set(valid,'{snapshot,actual_sets,0,reps}','null'),
    jsonb_set(valid,'{snapshot,actual_sets,0,reps}','-1'),
    jsonb_set(valid,'{snapshot,actual_sets,0,reps}','1.5'),
    jsonb_set(valid,'{snapshot,actual_sets,0,weight_kg}','-1'),
    jsonb_set(valid,'{snapshot,actual_sets,0,weight_kg}','2001'),
    jsonb_set(valid,'{snapshot,actual_sets,0,weight_kg}','"NaN"'),
    jsonb_set(valid,'{snapshot,actual_sets,0,completed_at}','"2026-09-10T11:59:00Z"'),
    jsonb_set(valid,'{snapshot,actual_sets,0,completed_at}','"2026-09-10T12:03:00Z"')
  ] loop
    if public.is_valid_training_history(invalid,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','2026-09-10T12:02:00Z') is distinct from false then
      raise exception 'TRAINING HISTORY: invalid completion accepted';
    end if;
    perform rlstest.erwarte_sqlstate(format(
      'insert into public.training_history(user_id,id,finished_at,session) values (%L,%L,%L,%L::jsonb)',
      '11111111-1111-1111-1111-111111111111','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','2026-09-10T12:02:00Z',invalid),
      '23514','invalid persisted history');
  end loop;
end $$;

insert into public.training_history(user_id,id,finished_at,session) values
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','2026-09-10T12:02:00Z',rlstest.training_history()),
  ('22222222-2222-2222-2222-222222222222','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','2026-09-10T12:02:00Z',rlstest.training_history());
insert into public.training_plans(user_id,id,plan,exercise_ids) values
  ('11111111-1111-1111-1111-111111111111','source-plan',rlstest.training_history() #> '{snapshot,plan,plan}','[["squat-identity"]]');
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
select rlstest.erwarte_zeilen('select * from public.training_history',1,'own history/export');
select rlstest.erwarte_zeilen($q$select * from public.training_history where user_id='22222222-2222-2222-2222-222222222222'$q$,0,'foreign history/export');
select rlstest.erwarte_zeilen($q$delete from public.training_history where user_id='22222222-2222-2222-2222-222222222222'$q$,0,'foreign history delete');
select rlstest.erwarte_ablehnung($q$insert into public.training_history(user_id,id,finished_at,session) values
  ('22222222-2222-2222-2222-222222222222','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','2026-09-10T12:02:00Z',rlstest.training_history('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'))$q$,'forged history owner');
select rlstest.erwarte_ablehnung($q$update public.training_history set session=jsonb_set(session,'{note}','"changed"')$q$,'immutable completion');
select rlstest.erwarte_ablehnung($q$update public.training_history set user_id='22222222-2222-2222-2222-222222222222'$q$,'history owner reassignment');
select rlstest.erwarte_zeilen($q$insert into public.training_history(user_id,id,finished_at,session) values
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','2026-09-10T12:02:00Z',rlstest.training_history()) on conflict(user_id,id) do nothing$q$,0,'same completion retry');
select rlstest.erwarte_zeilen('select * from public.training_history',1,'retry did not duplicate history');
update public.training_plans set plan=jsonb_set(plan,'{title}','"Edited plan"') where id='source-plan';
delete from public.training_plans where id='source-plan';
select rlstest.erwarte_zeilen($q$select * from public.training_history where session #>> '{snapshot,plan,plan,title}'='Original plan'$q$,1,'history survives source edit/delete');

set local role service_role;
delete from public.profiles where id='11111111-1111-1111-1111-111111111111';
select rlstest.erwarte_zeilen($q$select * from public.training_history where user_id='11111111-1111-1111-1111-111111111111'$q$,1,'profile deletion is not account deletion');
set local role anon;
select rlstest.erwarte_ablehnung('select * from public.training_history','anonymous history');
select rlstest.erwarte_ablehnung('delete from public.training_history','anonymous history deletion');
set local role authenticated;
set local request.jwt.claims = '{}';
select rlstest.erwarte_zeilen('select * from public.training_history',0,'missing subject history');
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
select rlstest.erwarte_zeilen('select * from public.training_history',1,'B retains own history');
select set_config('request.jwt.claims',jsonb_build_object('sub','11111111-1111-1111-1111-111111111111',
  'amr',jsonb_build_array(jsonb_build_object('method','otp','timestamp',extract(epoch from now()-interval '1 minute')::bigint)))::text,true);
select public.delete_account();
reset role;
do $$ begin
  if exists(select 1 from public.training_history where user_id='11111111-1111-1111-1111-111111111111')
     or (select count(*) from public.training_history where user_id='22222222-2222-2222-2222-222222222222') <> 1 then
    raise exception 'TRAINING HISTORY: account cascade/ownership failed';
  end if;
end $$;
rollback;
reset role;
