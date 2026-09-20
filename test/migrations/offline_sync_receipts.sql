-- Runs after the existing rlstest fixture functions in rls_cross_user.sql.
begin;
insert into auth.users(id,email) values
 ('73000000-0000-4000-8000-000000000001','effects-a@example.invalid'),
 ('73000000-0000-4000-8000-000000000002','effects-b@example.invalid');
create function pg_temp.require(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Assertion failed: %',label; end if; end;
$$;
grant execute on function pg_temp.require(boolean,text) to authenticated;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"73000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
do $$
#variable_conflict use_variable
declare id uuid:=gen_random_uuid(); op uuid:=gen_random_uuid(); receipt jsonb; again jsonb;
  body jsonb; row_data jsonb; first_count int; plan_id uuid; plan jsonb; old_op uuid; old_body jsonb;
  favorite jsonb; training_id text:='sync-plan'; history_id uuid:=gen_random_uuid(); check_id text:=current_date::text||':'||repeat('a',64);
begin
  -- Insert, count, streak and receipt commit together. Replaying cannot count
  -- twice or undo a later edit; the receipt remains byte-for-byte identical.
  row_data:=rlstest.plan_meal(id);
  body:=jsonb_build_object('row',row_data,'track_day',true);
  receipt:=public.apply_sync_operation(op,'mealInsert',id::text,body);
  perform pg_temp.require((receipt#>>'{result,lifetime_stats,meals_logged}')::int=1,'meal and lifetime counter committed');
  perform public.apply_sync_operation(gen_random_uuid(),'mealUpsert',id::text,
    jsonb_build_object('row',row_data||'{"meal_name":"Newer device edit"}'));
  again:=public.apply_sync_operation(op,'mealInsert',id::text,body);
  perform pg_temp.require(again=receipt,'meal retry receipt is exact');
  perform pg_temp.require((select meal_name='Newer device edit' from public.logged_meals m where m.id=id),'late insert cannot overwrite edit');
  perform pg_temp.require((select meals_logged=1 from public.lifetime_stats where user_id=auth.uid()),'meal counted exactly once');
  perform public.apply_sync_operation(gen_random_uuid(),'mealDelete',id::text,'{}');
  again:=public.apply_sync_operation(op,'mealInsert',id::text,body);
  perform pg_temp.require(again-'current_state'=receipt-'current_state','diary effect receipt remains immutable after delete');
  perform pg_temp.require(again#>>'{current_state,entity_deleted}'='true','old diary receipt projects current deletion');
  again:=public.apply_sync_operation(gen_random_uuid(),'mealUpsert',id::text,jsonb_build_object('row',row_data));
  perform pg_temp.require((again#>>'{result,entity_deleted}')::boolean,'diary tombstone rejects late edit');

  id:=gen_random_uuid(); op:=gen_random_uuid();
  body:=jsonb_build_object('row',rlstest.plan_meal(id)||jsonb_build_object('meal_name',repeat('x',161)),'track_day',true);
  begin
    perform public.apply_sync_operation(op,'mealInsert',id::text,body);
    raise exception 'Invalid meal accepted';
  exception when sqlstate '22023' then null; end;
  perform pg_temp.require(not exists(select 1 from public.logged_meals m where m.id=id),'invalid effect rolled back');
  body:=jsonb_build_object('row',rlstest.plan_meal(id),'track_day',false);
  perform public.apply_sync_operation(op,'mealInsert',id::text,body);
  perform pg_temp.require((select meals_logged=2 from public.lifetime_stats where user_id=auth.uid()),'failed request consumed neither UUID nor counter');

  id:=gen_random_uuid(); op:=gen_random_uuid();
  body:=jsonb_build_object('row',jsonb_build_object('id',id,'recorded_at',now(),'weight_kg',71));
  receipt:=public.apply_sync_operation(op,'weightInsert',id::text,body);
  perform pg_temp.require(public.apply_sync_operation(op,'weightInsert',id::text,body)=receipt,'weight receipt exact');
  perform pg_temp.require((select weight_logs=1 from public.lifetime_stats where user_id=auth.uid()),'weight counted once');

  favorite:=jsonb_build_object('favorite_key','name:fixture','meal_name','First','calories_kcal',100,'estimated_g',100,
    'payload','{}'::jsonb,'added_at',now(),'pinned',false);
  op:=gen_random_uuid(); body:=jsonb_build_object('row',favorite);
  receipt:=public.apply_sync_operation(op,'favoriteUpsert','name:fixture',body);
  perform public.apply_sync_operation(gen_random_uuid(),'favoriteUpsert','name:fixture',jsonb_build_object('row',favorite||'{"meal_name":"Second","pinned":true}'));
  perform public.apply_sync_operation(op,'favoriteUpsert','name:fixture',body);
  perform pg_temp.require((select pinned and meal_name='Second' from public.favorite_meals where favorite_key='name:fixture'),'favorite retry cannot rewind register');
  old_op:=gen_random_uuid();
  receipt:=public.apply_sync_operation(old_op,'favoriteDelete','name:fixture','{}');
  perform public.apply_sync_operation(gen_random_uuid(),'favoriteUpsert','name:fixture',body);
  perform public.apply_sync_operation(old_op,'favoriteDelete','name:fixture','{}');
  perform pg_temp.require(exists(select 1 from public.favorite_meals where favorite_key='name:fixture'),'old delete cannot delete later re-add');

  select jsonb_build_object('row',to_jsonb(p)||'{"weight_kg":72}') into body from public.profiles p where p.id=auth.uid();
  op:=gen_random_uuid();
  perform public.apply_sync_operation(op,'profileUpsert','self',body);
  perform public.apply_sync_operation(gen_random_uuid(),'profileUpsert','self',jsonb_set(body,'{row,weight_kg}','73'));
  perform public.apply_sync_operation(op,'profileUpsert','self',body);
  perform pg_temp.require((select weight_kg=73 from public.profiles where profiles.id=auth.uid()),'profile retry cannot rewind register');

  body:=jsonb_build_object('row',jsonb_build_object('id',training_id,'plan',rlstest.training_plan(),'exercise_ids','[["squat","plank"]]'::jsonb));
  op:=gen_random_uuid();
  perform public.apply_sync_operation(op,'trainingPlanUpsert',training_id,body);
  perform public.apply_sync_operation(gen_random_uuid(),'trainingPlanUpsert',training_id,jsonb_set(body,'{row,plan,title}','"Second"'));
  perform public.apply_sync_operation(op,'trainingPlanUpsert',training_id,body);
  perform pg_temp.require((select p.plan->>'title'='Second' from public.training_plans p where p.id=training_id),'training plan retry cannot rewind edit');
  perform public.apply_sync_operation(gen_random_uuid(),'trainingPlanDelete',training_id,'{}');
  again:=public.apply_sync_operation(op,'trainingPlanUpsert',training_id,body);
  perform pg_temp.require(again#>>'{current_state,entity_deleted}'='true','old plan receipt projects current deletion');
  again:=public.apply_sync_operation(gen_random_uuid(),'trainingPlanUpsert',training_id,body);
  perform pg_temp.require((again#>>'{result,entity_deleted}')::boolean,'training plan delete remains terminal');

  body:=jsonb_build_object('row',jsonb_build_object('id',history_id,'finished_at','2026-09-10T12:02:00Z','session',rlstest.training_history(history_id)));
  op:=gen_random_uuid();
  receipt:=public.apply_sync_operation(op,'trainingHistoryInsert',history_id::text,body);
  perform pg_temp.require(public.apply_sync_operation(op,'trainingHistoryInsert',history_id::text,body)=receipt,'history exact receipt');
  perform public.apply_sync_operation(gen_random_uuid(),'trainingHistoryDelete',history_id::text,'{}');
  again:=public.apply_sync_operation(op,'trainingHistoryInsert',history_id::text,body);
  perform pg_temp.require(again-'current_state'=receipt-'current_state','history effect receipt remains immutable after delete');
  perform pg_temp.require(again#>>'{current_state,entity_deleted}'='true','old completion receipt projects current deletion');
  again:=public.apply_sync_operation(gen_random_uuid(),'trainingHistoryInsert',history_id::text,body);
  perform pg_temp.require((again#>>'{result,entity_deleted}')::boolean,'immutable history deletion retained');

  op:=gen_random_uuid();
  receipt:=public.apply_sync_operation(op,'shoppingCheck',check_id,'{"checked":true}');
  perform public.apply_sync_operation(gen_random_uuid(),'shoppingCheck',check_id,'{"checked":false}');
  perform public.apply_sync_operation(op,'shoppingCheck',check_id,'{"checked":true}');
  perform pg_temp.require((select not checked from public.shopping_checks where shopping_checks.id=check_id),'shopping retry cannot rewind register');

  plan_id:=gen_random_uuid(); plan:=rlstest.meal_plan(plan_id);
  perform public.apply_sync_operation(gen_random_uuid(),'mealPlanUpsert',plan_id::text,jsonb_build_object('plan',plan));
  perform public.apply_sync_operation(gen_random_uuid(),'mealPlanUpsert',plan_id::text,jsonb_build_object('plan',plan||'{"removed":true}'));
  again:=public.apply_sync_operation(gen_random_uuid(),'mealPlanUpsert',plan_id::text,jsonb_build_object('plan',plan));
  perform pg_temp.require((again#>>'{result,entity_deleted}')::boolean,'meal plan removal remains terminal');
  perform public.save_planned_meal(plan);
  perform pg_temp.require((select p.plan->>'removed'='true' from public.planned_meals p where p.id=plan_id),'legacy save cannot undo removal');
  again:=public.apply_sync_operation(gen_random_uuid(),'mealPlanConvert',plan_id::text,
    jsonb_build_object('plan',plan||jsonb_build_object('eaten_at',now()),'meal',rlstest.plan_meal(plan_id),'track_day',true));
  perform pg_temp.require((again#>>'{result,entity_deleted}')::boolean,'removed plan cannot be consumed');
  plan_id:=gen_random_uuid(); plan:=rlstest.meal_plan(plan_id);
  op:=gen_random_uuid(); body:=jsonb_build_object('plan',plan||jsonb_build_object('eaten_at',now()),'meal',rlstest.plan_meal(plan_id),'track_day',true);
  receipt:=public.apply_sync_operation(op,'mealPlanConvert',plan_id::text,body);
  perform pg_temp.require(public.apply_sync_operation(op,'mealPlanConvert',plan_id::text,body)=receipt,'conversion receipt exact');
  again:=public.apply_sync_operation(gen_random_uuid(),'mealPlanUpsert',plan_id::text,jsonb_build_object('plan',plan));
  perform pg_temp.require(again#>>'{result,planned_meal,eaten_at}' is not null,'stale save returns consumed canonical state');
  perform public.apply_sync_operation(gen_random_uuid(),'mealDelete',plan_id::text,'{}');
  again:=public.apply_sync_operation(op,'mealPlanConvert',plan_id::text,body);
  perform pg_temp.require(again-'current_state'=receipt-'current_state','conversion effect stays immutable after diary deletion');
  perform pg_temp.require(again#>>'{current_state,meal_deleted}'='true' and
    again#>>'{current_state,planned_meal,eaten_at}' is not null,'conversion retry preserves consumed plan without reviving deleted diary');

  -- Another device can delete the shared diary identity before the FIRST
  -- conversion request arrives. Receipts alone do not guard that ordering.
  select meals_logged into first_count from public.lifetime_stats where user_id=auth.uid();
  plan_id:=gen_random_uuid(); plan:=rlstest.meal_plan(plan_id);
  perform public.apply_sync_operation(gen_random_uuid(),'mealPlanUpsert',plan_id::text,jsonb_build_object('plan',plan));
  perform public.apply_sync_operation(gen_random_uuid(),'mealDelete',plan_id::text,'{}');
  op:=gen_random_uuid(); body:=jsonb_build_object('plan',plan||jsonb_build_object('eaten_at',now()),'meal',rlstest.plan_meal(plan_id),'track_day',true);
  receipt:=public.apply_sync_operation(op,'mealPlanConvert',plan_id::text,body);
  perform pg_temp.require(not exists(select 1 from public.logged_meals m where m.id=plan_id),'first conversion cannot revive a deleted diary identity');
  perform pg_temp.require(receipt#>>'{result,meal_plan_conversion,created}'='false' and
    receipt#>>'{current_state,meal_deleted}'='true' and
    receipt#>>'{current_state,planned_meal,eaten_at}' is not null,'deleted conversion retains consumed plan without diary effect');
  perform pg_temp.require(public.apply_sync_operation(op,'mealPlanConvert',plan_id::text,body)=receipt,'cancelled diary conversion receipt is stable');
  plan_id:=gen_random_uuid(); plan:=rlstest.meal_plan(plan_id);
  perform public.apply_sync_operation(gen_random_uuid(),'mealDelete',plan_id::text,'{}');
  perform public.eat_planned_meal(plan||jsonb_build_object('eaten_at',now()),rlstest.plan_meal(plan_id),true);
  perform pg_temp.require(not exists(select 1 from public.logged_meals m where m.id=plan_id),'legacy first conversion respects the same diary tombstone');
  perform pg_temp.require((select meals_logged=first_count from public.lifetime_stats where user_id=auth.uid()),'deleted conversion spends no meal counter');

  op:=gen_random_uuid(); id:=gen_random_uuid();
  receipt:=public.apply_sync_operation(op,'statsIncrement',id::text,'{"meals":1,"weight_logs":0}');
  perform pg_temp.require(public.apply_sync_operation(op,'statsIncrement',id::text,'{"meals":1,"weight_logs":0}')=receipt,'stats receipt exact');
  op:=gen_random_uuid();
  receipt:=public.apply_sync_operation(op,'trackingDay',current_date::text,'{}');
  perform pg_temp.require(public.apply_sync_operation(op,'trackingDay',current_date::text,'{}')=receipt,'tracking receipt exact');
  perform pg_temp.require((select meals_logged=4 and weight_logs=1 from public.lifetime_stats where user_id=auth.uid()),'all counters match accepted atomic effects');
end $$;

-- Receipt lookup is owner-scoped and cannot mutate an acknowledged effect.
do $$
declare op uuid:='73000000-0000-4000-8000-000000000077'; receipt jsonb; readback jsonb;
  before_stats jsonb;
begin
  receipt:=public.apply_sync_operation(op,'favoriteDelete','name:read-receipt','{}');
  select to_jsonb(s) into before_stats from public.lifetime_stats s where user_id=auth.uid();
  readback:=public.load_sync_operation_receipt(op);
  perform pg_temp.require(readback=receipt,'owner can read exact effect and current state');
  perform pg_temp.require(public.load_sync_operation_receipt(gen_random_uuid()) is null,'unknown receipt is unresolved');
  perform set_config('request.jwt.claims','{"sub":"73000000-0000-4000-8000-000000000002","role":"authenticated"}',true);
  perform pg_temp.require(public.load_sync_operation_receipt(op) is null,'foreign operation UUID reveals no receipt');
  perform set_config('request.jwt.claims','{"sub":"73000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
  perform pg_temp.require((select to_jsonb(s)=before_stats from public.lifetime_stats s where user_id=auth.uid()),'reading does not recount');
end $$;

-- Byte budget rejection must roll back an otherwise valid effect.
reset role;
update public.recipe_sync_heads set receipt_bytes=33554432 where user_id='73000000-0000-4000-8000-000000000001';
set local role authenticated;
do $$ begin
  begin
    perform public.apply_sync_operation('73000000-0000-4000-8000-000000000099','favoriteDelete','name:fixture','{}');
    raise exception 'Receipt capacity was bypassed' using errcode='XX000';
  exception when sqlstate 'PT507' then null; end;
  perform pg_temp.require(exists(select 1 from public.favorite_meals where favorite_key='name:fixture'),'capacity failure rolls back effect');
end $$;
reset role;
select pg_temp.require(not exists(select 1 from public.sync_operation_receipts where operation_id='73000000-0000-4000-8000-000000000099'),'capacity failure rolls back receipt');
set local role anon;
select rlstest.erwarte_ablehnung($q$select public.apply_sync_operation('73000000-0000-4000-8000-000000000099','favoriteDelete','name:fixture','{}')$q$,'anonymous mutation');
select rlstest.erwarte_ablehnung($q$select public.load_sync_operation_receipt('73000000-0000-4000-8000-000000000077')$q$,'anonymous receipt read');
reset role;
rollback;
select 'Offline operation receipts: all assertions passed' as result;
