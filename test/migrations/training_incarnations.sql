-- Real owner, legacy and delayed-first-request boundaries, inside a rollback.
begin;
insert into auth.users(id,email) values
 ('74000000-0000-4000-8000-000000000001','training-a@example.invalid'),
 ('74000000-0000-4000-8000-000000000002','training-b@example.invalid');
create function pg_temp.require(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Assertion failed: %',label; end if; end;
$$;
grant execute on function pg_temp.require(boolean,text) to authenticated;
select pg_temp.require(to_regprocedure('public.apply_sync_operation(uuid,text,text,jsonb)') is null,
  'there is no ambiguous unversioned RPC overload');
select pg_temp.require((select pronargdefaults=1 from pg_proc where oid=
  'public.apply_sync_operation(uuid,text,text,jsonb,integer)'::regprocedure),
  'the feature-fenced RPC preserves four-argument legacy calls');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"74000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
do $$
declare body jsonb; next_body jsonb; receipt jsonb; again jsonb; conflict jsonb;
  op uuid:=gen_random_uuid(); deletion uuid:=gen_random_uuid(); conflict_op uuid:=gen_random_uuid(); invalid jsonb;
  history_id uuid:=gen_random_uuid(); snapshot jsonb; head jsonb;
begin
  perform pg_temp.require(public.load_training_plan_head('proposal') is null,'unknown source is authoritative null');
  body:=jsonb_build_object('row',jsonb_build_object('id','coach_proposal','plan',rlstest.training_plan(),
    'exercise_ids','[["squat","plank"]]'::jsonb));
  -- An existing generation-zero frozen body has the same fingerprint under v2.
  receipt:=public.apply_sync_operation(op,'trainingPlanUpsert','coach_proposal',body);
  again:=public.apply_sync_operation(op,'trainingPlanUpsert','coach_proposal',body,2);
  perform pg_temp.require(receipt=again,'feature fence does not rewrite legacy operation fingerprint');
  perform pg_temp.require(receipt#>>'{current_state,training_head,incarnation}'='0','initial head is projected in the same transaction');
  perform public.apply_sync_operation(gen_random_uuid(),'trainingPlanUpsert','coach_proposal',body,2);
  perform pg_temp.require((select count(*)=1 from public.training_plans where id='coach_proposal'),'two devices deduplicate a proposal');
  perform public.apply_sync_operation(deletion,'trainingPlanDelete','coach_proposal','{}',2);
  next_body:=jsonb_set(body,'{row,incarnation}','1')||'{"adoption":true}';
  receipt:=public.apply_sync_operation(gen_random_uuid(),'trainingPlanUpsert','coach_proposal',next_body,2);
  perform pg_temp.require(receipt#>>'{result,training_mutation,outcome}'='applied' and
    receipt#>>'{current_state,training_plan,incarnation}'='1','explicit re-adoption creates the next incarnation');
  -- A previously NEVER submitted old write/delete is as harmless as a retry.
  again:=public.apply_sync_operation(gen_random_uuid(),'trainingPlanUpsert','coach_proposal',body,2);
  perform pg_temp.require(again#>>'{result,training_mutation,outcome}'='deleted','old first edit cannot address next generation');
  perform public.apply_sync_operation(gen_random_uuid(),'trainingPlanDelete','coach_proposal','{}',2);
  again:=public.apply_sync_operation(deletion,'trainingPlanDelete','coach_proposal','{}',2);
  perform pg_temp.require(again#>>'{current_state,entity_deleted}'='true' and
    again#>>'{current_state,training_head,incarnation}'='1' and
    again#>>'{current_state,training_plan,incarnation}'='1','old delete receipt carries current head separately');
  perform pg_temp.require((select incarnation=1 from public.training_plans where id='coach_proposal'),'old deletes preserve re-adoption');
  again:=public.apply_sync_operation(op,'trainingPlanUpsert','coach_proposal',body,2);
  perform pg_temp.require(again#>>'{result,training_mutation,incarnation}'='0' and
    again#>>'{current_state,entity_deleted}'='true','receipt keeps its original generation');

  conflict:=public.apply_sync_operation(conflict_op,'trainingPlanUpsert','coach_proposal',body||'{"adoption":true}',2);
  perform pg_temp.require(conflict#>>'{result,training_mutation,outcome}'='headConflict','unknown offline adoption becomes a retained conflict');
  next_body:=jsonb_set(next_body,'{row,plan,title}','"Reviewed draft"');
  receipt:=public.apply_sync_operation(gen_random_uuid(),'trainingPlanUpsert','coach_proposal',next_body,2);
  perform pg_temp.require(receipt#>>'{current_state,training_plan,plan,title}'='Reviewed draft','explicit reviewed active adoption is LWW on its pinned generation');
  again:=public.apply_sync_operation(conflict_op,'trainingPlanUpsert','coach_proposal',body||'{"adoption":true}',2);
  perform pg_temp.require(again-'current_state'=conflict-'current_state','conflict receipt is immutable after explicit resolution');
  begin
    perform public.apply_sync_operation(conflict_op,'trainingPlanUpsert','coach_proposal',next_body,2);
    raise exception 'Changed operation UUID accepted';
  exception when sqlstate '22023' then null; end;
  perform pg_temp.require(public.load_sync_operation_receipt(conflict_op)=again,'receipt read returns the current generation without replay');

  -- An old direct client cannot identify a new incarnation, so it fails closed.
  perform set_config('eatova.sync_operation',op::text,true);
  begin delete from public.training_plans where id='coach_proposal';
    raise exception 'Legacy delete crossed generation';
  exception when sqlstate '22023' then null; end;
  begin update public.training_plans set plan=jsonb_set(plan,'{title}','"Legacy stale edit"') where id='coach_proposal';
    raise exception 'Legacy update crossed generation';
  exception when sqlstate '22023' then null; end;
  begin
    insert into public.training_plans(user_id,id,plan,exercise_ids)
    values(auth.uid(),'coach_proposal',rlstest.training_plan(),'[["squat","plank"]]')
    on conflict(user_id,id) do update set plan=excluded.plan;
    raise exception 'Legacy upsert crossed generation';
  exception when sqlstate '22023' then null; end;
  perform pg_temp.require((select plan->>'title'='Reviewed draft' from public.training_plans where id='coach_proposal'),'forged completed receipt cannot bypass legacy fence');
  begin
    perform public.apply_sync_operation(gen_random_uuid(),'trainingPlanUpsert','coach_proposal',next_body);
    raise exception 'Missing feature fence accepted modern payload';
  exception when sqlstate '22023' then null; end;

  -- Future deletes cannot affect an active head, but can terminally fence a
  -- locally adopted next generation whose first upsert has not arrived yet.
  begin
    perform public.apply_sync_operation(gen_random_uuid(),'trainingPlanDelete','coach_proposal','{"incarnation":2}',2);
    raise exception 'Unreviewed future generation deleted';
  exception when sqlstate '22023' then null; end;
  perform public.apply_sync_operation(gen_random_uuid(),'trainingPlanDelete','coach_proposal','{"incarnation":1}',2);
  perform public.apply_sync_operation(gen_random_uuid(),'trainingPlanDelete','coach_proposal','{"incarnation":2}',2);
  again:=public.apply_sync_operation(gen_random_uuid(),'trainingPlanUpsert','coach_proposal',jsonb_set(next_body,'{row,incarnation}','2'),2);
  perform pg_temp.require(again#>>'{result,training_mutation,outcome}'='headConflict','delete before first adoption prevents resurrection');
  again:=public.apply_sync_operation(gen_random_uuid(),'trainingPlanUpsert','coach_proposal',jsonb_set(next_body,'{row,incarnation}','3'),2);
  perform pg_temp.require(again#>>'{current_state,training_head,incarnation}'='3','a fresh explicit action can adopt after terminal next generation');

  -- Malformed metadata must neither consume a UUID nor publish a source head.
  body:=jsonb_set(body,'{row,id}','"coach_invalid"');
  for invalid in select value from jsonb_array_elements('[null,-1,0.5,2147483648,"1",{}]') loop
    op:=gen_random_uuid();
    begin
      perform public.apply_sync_operation(op,'trainingPlanUpsert','coach_invalid',jsonb_set(body,'{row,incarnation}',invalid),2);
      raise exception 'Invalid incarnation accepted';
    exception when sqlstate '22023' then null; end;
    perform pg_temp.require(public.load_sync_operation_receipt(op) is null,'invalid metadata consumes no receipt');
  end loop;
  begin
    perform public.apply_sync_operation(gen_random_uuid(),'trainingPlanUpsert','coach_invalid',jsonb_set(body,'{row,source_id}','"another"'),2);
    raise exception 'Mismatched source accepted';
  exception when sqlstate '22023' then null; end;
  perform pg_temp.require(public.load_training_plan_head('invalid') is null,'malformed writes publish no head');
  op:=gen_random_uuid();
  begin
    perform public.apply_sync_operation(op,'trainingPlanUpsert','coach_invalid',jsonb_set(body,'{row,plan}','{}'),2);
    raise exception 'Invalid plan accepted after head creation';
  exception when check_violation or sqlstate '22023' then null; end;
  perform pg_temp.require(public.load_training_plan_head('invalid') is null and public.load_sync_operation_receipt(op) is null,
    'plan validation rolls back head and receipt atomically');
  -- Valid legacy direct writes still function at generation zero.
  insert into public.training_plans(user_id,id,plan,exercise_ids)
  values(auth.uid(),'coach_legacy',rlstest.training_plan(),'[["squat","plank"]]');
  update public.training_plans set plan=jsonb_set(plan,'{title}','"Legacy valid"') where id='coach_legacy';
  perform pg_temp.require(public.load_training_plan_head('legacy')#>>'{plan,plan,title}'='Legacy valid','legacy generation zero remains writable');
  delete from public.training_plans where id='coach_legacy';
  perform pg_temp.require(public.load_training_plan_head('legacy')->>'deleted'='true','legacy delete retains source head');
  insert into public.training_plans(user_id,id,plan,exercise_ids)
  values(auth.uid(),'legacy_manual',rlstest.training_plan(),'[["squat","plank"]]');
  delete from public.training_plans where id='legacy_manual';

  -- An immutable history snapshot is independent of current source existence.
  snapshot:=rlstest.training_history(history_id);
  snapshot:=jsonb_set(snapshot,'{snapshot,plan,id}','"coach_proposal"');
  snapshot:=jsonb_set(snapshot,'{snapshot,plan,source_id}','"proposal"');
  snapshot:=jsonb_set(snapshot,'{snapshot,plan,incarnation}','1');
  perform pg_temp.require(public.is_valid_training_history(snapshot,history_id,'2026-09-10T12:02:00Z'),'history accepts old incarnation metadata');
  perform public.apply_sync_operation(gen_random_uuid(),'trainingHistoryInsert',history_id::text,
    jsonb_build_object('row',jsonb_build_object('id',history_id,'finished_at','2026-09-10T12:02:00Z','session',snapshot)));
  perform pg_temp.require(not public.is_valid_training_history(jsonb_set(snapshot,'{snapshot,plan,incarnation}','null'),history_id,'2026-09-10T12:02:00Z'),'history rejects null incarnation');
  head:=public.load_training_plan_head('proposal');
  perform pg_temp.require(head->>'incarnation'='3' and head->>'deleted'='false','training history never mutates source head');
end;
$$;
reset role;
select pg_temp.require(not exists(select 1 from public.sync_entity_deletions
  where user_id='74000000-0000-4000-8000-000000000001' and entity_id='legacy_manual'),
  'legacy manual create-delete loops do not allocate unbounded tombstones');
update public.recipe_sync_heads set training_head_count=100000
  where user_id='74000000-0000-4000-8000-000000000001';
set local role authenticated;
do $$ declare op uuid:=gen_random_uuid(); begin
  begin
    perform public.apply_sync_operation(op,'trainingPlanDelete','coach_over_capacity','{}',2);
    raise exception 'Source head capacity exceeded';
  exception when sqlstate 'PT507' then null; end;
  perform pg_temp.require(public.load_sync_operation_receipt(op) is null and
    public.load_training_plan_head('over_capacity') is null,'head capacity failure retains an unacknowledged intent');
end;$$;
select rlstest.erwarte_ablehnung('select * from public.training_plan_heads','client cannot enumerate private source heads');
select rlstest.erwarte_ablehnung('select public.training_plan_head_json(auth.uid(),''coach_proposal'')','client cannot call private owner-parameter projection');
select rlstest.erwarte_ablehnung('select public.create_training_plan_head(auth.uid(),''x'',''coach_x'',0,false)','client cannot forge source heads');
select set_config('request.jwt.claims','{"sub":"74000000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select pg_temp.require(public.load_training_plan_head('proposal') is null,'other user cannot read source head');
select pg_temp.require((select count(*)=0 from public.training_plans where id='coach_proposal'),'other user cannot read training row');
set local role anon;
select rlstest.erwarte_ablehnung('select public.load_training_plan_head(''proposal'')','anonymous source read denied');
reset role;
-- Account deletion removes both durable metadata and current generations.
delete from auth.users where id='74000000-0000-4000-8000-000000000001';
select pg_temp.require(not exists(select 1 from public.training_plan_heads where user_id='74000000-0000-4000-8000-000000000001'),'account deletion cascades source heads');
select pg_temp.require(not exists(select 1 from public.sync_operation_receipts where user_id='74000000-0000-4000-8000-000000000001'),'account deletion cascades receipts');
rollback;
select 'Training incarnations: all assertions passed';
