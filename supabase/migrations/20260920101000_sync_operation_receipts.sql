-- Every durable operation has one committed effect and one immutable receipt.
-- Authenticated legacy endpoints remain available during staged rollout.
-- A receipt describes the original effect; current state prevents old retries
-- from restoring a row deleted or edited by another device in the meantime.
create or replace function public.sync_operation_current_state(p_receipt jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare u uuid:=auth.uid(); kind text:=p_receipt->>'kind'; identity text:=p_receipt->>'entity_id';
  state jsonb:='{}'; event public.recipe_revisions%rowtype; saved_slug text; plan jsonb;
begin
  if u is null then raise exception 'EX_USER_REQUIRED' using errcode='42501'; end if;
  if kind in ('recipeUpsert','recipeDelete') then
    select * into event from public.recipe_revisions where user_id=u and slug=identity order by revision desc limit 1;
    state:=jsonb_build_object('recipe',jsonb_build_object('slug',identity,'revision',coalesce(event.revision,0),
      'deleted',coalesce(event.deleted,true),'recipe',case when event.deleted=false then event.recipe else null end));
    saved_slug:=p_receipt#>>'{result,recipe_mutation,saved_recipe,slug}';
    if saved_slug is not null then
      select * into event from public.recipe_revisions where user_id=u and slug=saved_slug order by revision desc limit 1;
      state:=state||jsonb_build_object('saved_recipe',jsonb_build_object('slug',saved_slug,'revision',coalesce(event.revision,0),
        'deleted',coalesce(event.deleted,true),'recipe',case when event.deleted=false then event.recipe else null end));
    end if;
  elsif kind in ('mealInsert','mealUpsert','mealDelete') then
    state:=jsonb_build_object('entity_deleted',not exists(select 1 from public.logged_meals where user_id=u and id=identity::uuid));
  elsif kind in ('trainingPlanUpsert','trainingPlanDelete') then
    state:=jsonb_build_object(
      'entity_deleted',not exists(select 1 from public.training_plans where user_id=u and id=identity
        and incarnation=coalesce((p_receipt#>>'{result,training_mutation,incarnation}')::bigint,0)),
      'training_head',public.training_plan_head_json(u,identity),
      'training_plan',(select jsonb_build_object('id',p.id,'source_id',p.source_id,'incarnation',p.incarnation,
        'plan',p.plan,'exercise_ids',p.exercise_ids) from public.training_plans p where p.user_id=u and p.id=identity));
  elsif kind in ('trainingHistoryInsert','trainingHistoryDelete') then
    state:=jsonb_build_object('entity_deleted',not exists(select 1 from public.training_history where user_id=u and id=identity::uuid));
  elsif kind in ('mealPlanUpsert','mealPlanConvert') then
    select p.plan into plan from public.planned_meals p where user_id=u and id=identity::uuid;
    state:=jsonb_build_object('planned_meal',plan,'entity_deleted',coalesce((plan->>'removed')::boolean,true));
    if kind='mealPlanConvert' then
      state:=state||jsonb_build_object('meal_deleted',not exists(select 1 from public.logged_meals where user_id=u and id=identity::uuid));
    end if;
  end if;
  if p_receipt#>'{result,lifetime_stats}' is not null or p_receipt#>'{result,meal_plan_conversion,stats}' is not null then
    state:=state||jsonb_build_object('lifetime_stats',coalesce((select to_jsonb(s) from public.lifetime_stats s where user_id=u),'{}'::jsonb));
  end if;
  return state;
end;
$$;
revoke all on function public.sync_operation_current_state(jsonb) from public, anon, authenticated;
grant execute on function public.sync_operation_current_state(jsonb) to service_role;

-- Resolve a foreground view after another engine acknowledged its operation.
-- Reading a receipt never replays a mutation or changes its immutable result.
create or replace function public.load_sync_operation_receipt(p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare u uuid:=auth.uid(); receipt jsonb;
begin
  if u is null then raise exception 'EX_USER_REQUIRED' using errcode='42501'; end if;
  if p_operation_id is null then raise exception 'EX_OPERATION_REQUIRED' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('sync:'||u::text,0));
  select response into receipt from public.sync_operation_receipts
    where user_id=u and operation_id=p_operation_id;
  if receipt is null then return null; end if;
  return receipt||jsonb_build_object('current_state',public.sync_operation_current_state(receipt));
end;
$$;
revoke all on function public.load_sync_operation_receipt(uuid) from public, anon, authenticated;
grant execute on function public.load_sync_operation_receipt(uuid) to authenticated, service_role;

create or replace function public.apply_sync_operation(
  p_operation_id uuid,p_kind text,p_entity_id text,p_payload jsonb,p_training_protocol integer default 1
) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare
  u uuid:=auth.uid(); fingerprint bytea; prior public.sync_operation_receipts%rowtype;
  result jsonb:='{}'; v_response jsonb; row_data jsonb; old_plan jsonb; stats jsonb;
  meal public.logged_meals%rowtype; favorite public.favorite_meals%rowtype;
  profile public.profiles%rowtype; weight public.weight_log%rowtype;
  identity uuid; stats_id uuid;
  raw_id bytea; mask bytea:=decode('6561746f76612d73746174732d726964','hex'); i integer;
begin
  if u is null then raise exception 'EX_USER_REQUIRED' using errcode='42501'; end if;
  if p_operation_id is null or p_entity_id is null or char_length(p_entity_id) not between 1 and 500
    or p_kind is null or p_kind not in ('recipeUpsert','recipeDelete','mealInsert','mealUpsert','mealDelete',
      'weightInsert','favoriteUpsert','favoriteDelete','profileUpsert','trainingPlanUpsert','trainingPlanDelete',
      'trainingHistoryInsert','trainingHistoryDelete','mealPlanUpsert','mealPlanConvert','shoppingCheck',
      'trackingDay','statsIncrement') or jsonb_typeof(p_payload) is distinct from 'object'
    or octet_length(p_payload::text)>250000 then
    raise exception 'EX_INVALID_SYNC_OPERATION' using errcode='22023'; end if;
  if p_training_protocol is null or p_training_protocol not in (1,2) or
    (p_training_protocol=2 and p_kind not in ('trainingPlanUpsert','trainingPlanDelete')) then
    raise exception 'EX_INVALID_TRAINING_PROTOCOL' using errcode='22023'; end if;
  if p_training_protocol=1 and p_kind in ('trainingPlanUpsert','trainingPlanDelete') and
    (p_payload ? 'adoption' or p_payload ? 'incarnation' or (p_payload->'row') ? 'incarnation') then
    raise exception 'EX_TRAINING_PROTOCOL_REQUIRED' using errcode='22023'; end if;
  fingerprint:=sha256(convert_to(jsonb_build_object('kind',p_kind,'entity_id',p_entity_id,'payload',p_payload)::text,'UTF8'));
  perform pg_advisory_xact_lock(hashtextextended('sync:'||u::text,0));
  select * into prior from public.sync_operation_receipts where user_id=u and operation_id=p_operation_id;
  if found then
    if prior.fingerprint<>fingerprint then raise exception 'EX_OPERATION_ID_REUSED' using errcode='22023'; end if;
    if prior.response is null then raise exception 'EX_INCOMPLETE_SYNC_RECEIPT'; end if;
    return prior.response||jsonb_build_object('current_state',public.sync_operation_current_state(prior.response));
  end if;
  insert into public.recipe_sync_heads(user_id) values(u) on conflict do nothing;
  update public.recipe_sync_heads set receipt_count=receipt_count+1
    where user_id=u and receipt_count<100000;
  if not found then raise exception 'EX_SYNC_RECEIPT_CAPACITY' using errcode='PT507'; end if;
  insert into public.sync_operation_receipts(user_id,operation_id,fingerprint) values(u,p_operation_id,fingerprint);
  perform set_config('eatova.sync_operation',p_operation_id::text,true);

  if p_kind in ('recipeUpsert','recipeDelete') then
    result:=jsonb_build_object('recipe_mutation',public.apply_recipe_mutation(p_operation_id,p_kind,p_entity_id,
      (p_payload->>'expected_revision')::bigint,p_payload->'recipe'));
  elsif p_kind in ('mealInsert','mealUpsert') then
    row_data:=p_payload->'row';
    if jsonb_typeof(row_data) is distinct from 'object' or row_data->>'id' is distinct from p_entity_id then
      raise exception 'EX_INVALID_MEAL' using errcode='22023'; end if;
    meal:=jsonb_populate_record(null::public.logged_meals,row_data);
    if exists(select 1 from public.logged_meals where id=meal.id and user_id<>u) then
      raise exception 'EX_OWNER_REQUIRED' using errcode='42501'; end if;
    if exists(select 1 from public.sync_entity_deletions where user_id=u and family='meal' and entity_id=p_entity_id) then
      result:=jsonb_build_object('entity_deleted',true);
    else
      if p_kind='mealUpsert' or not exists(select 1 from public.logged_meals where id=meal.id and user_id=u) then
        insert into public.logged_meals(id,user_id,logged_at,local_day,forced_slot,meal_name,calories_kcal,estimated_g,
          protein_g,carbs_g,fat_g,barcode,brand,source_label,payload)
        values(meal.id,u,meal.logged_at,meal.local_day,meal.forced_slot,meal.meal_name,meal.calories_kcal,meal.estimated_g,
          meal.protein_g,meal.carbs_g,meal.fat_g,meal.barcode,meal.brand,meal.source_label,meal.payload)
        on conflict(id) do update set logged_at=excluded.logged_at,local_day=excluded.local_day,forced_slot=excluded.forced_slot,
          meal_name=excluded.meal_name,calories_kcal=excluded.calories_kcal,estimated_g=excluded.estimated_g,
          protein_g=excluded.protein_g,carbs_g=excluded.carbs_g,fat_g=excluded.fat_g,barcode=excluded.barcode,
          brand=excluded.brand,source_label=excluded.source_label,payload=excluded.payload
        where public.logged_meals.user_id=u;
      end if;
      -- Two owners may race the same global UUID after the initial read.
      if not exists(select 1 from public.logged_meals where id=meal.id and user_id=u) then
        raise exception 'EX_OWNER_REQUIRED' using errcode='42501'; end if;
      if p_kind='mealInsert' then
        raw_id:=decode(replace(p_entity_id,'-',''),'hex');
        for i in 0..15 loop raw_id:=set_byte(raw_id,i,get_byte(raw_id,i)#get_byte(mask,i)); end loop;
        stats_id:=encode(raw_id,'hex')::uuid;
        select to_jsonb(s) into stats from public.increment_lifetime_stats(p_meals=>1,p_request_id=>stats_id) s;
        if coalesce((p_payload->>'track_day')::boolean,false) then
          select to_jsonb(s) into stats from public.record_tracking_day(meal.local_day) s;
        end if;
        result:=jsonb_build_object('lifetime_stats',stats);
      end if;
    end if;
  elsif p_kind='mealDelete' then
    identity:=p_entity_id::uuid;
    delete from public.logged_meals where user_id=u and id=identity;
    insert into public.sync_entity_deletions(user_id,family,entity_id) values(u,'meal',p_entity_id) on conflict do nothing;
    result:=jsonb_build_object('entity_deleted',true);
  elsif p_kind='weightInsert' then
    row_data:=p_payload->'row';
    if row_data->>'id' is distinct from p_entity_id then raise exception 'EX_INVALID_WEIGHT' using errcode='22023'; end if;
    weight:=jsonb_populate_record(null::public.weight_log,row_data);
    if exists(select 1 from public.weight_log where id=weight.id and user_id<>u) then
      raise exception 'EX_OWNER_REQUIRED' using errcode='42501'; end if;
    insert into public.weight_log(id,user_id,recorded_at,weight_kg) values(weight.id,u,weight.recorded_at,weight.weight_kg)
      on conflict(id) do nothing;
    if not exists(select 1 from public.weight_log where id=weight.id and user_id=u) then
      raise exception 'EX_OWNER_REQUIRED' using errcode='42501'; end if;
    raw_id:=decode(replace(p_entity_id,'-',''),'hex');
    for i in 0..15 loop raw_id:=set_byte(raw_id,i,get_byte(raw_id,i)#get_byte(mask,i)); end loop;
    stats_id:=encode(raw_id,'hex')::uuid;
    select to_jsonb(s) into stats from public.increment_lifetime_stats(p_weight_logs=>1,p_request_id=>stats_id) s;
    result:=jsonb_build_object('lifetime_stats',stats);
  elsif p_kind='favoriteUpsert' then
    row_data:=p_payload->'row';
    if row_data->>'favorite_key' is distinct from p_entity_id then raise exception 'EX_INVALID_FAVORITE' using errcode='22023'; end if;
    favorite:=jsonb_populate_record(null::public.favorite_meals,row_data);
    insert into public.favorite_meals(user_id,favorite_key,meal_name,calories_kcal,estimated_g,barcode,brand,source_label,payload,added_at,pinned)
    values(u,favorite.favorite_key,favorite.meal_name,favorite.calories_kcal,favorite.estimated_g,favorite.barcode,
      favorite.brand,favorite.source_label,favorite.payload,favorite.added_at,favorite.pinned)
    on conflict(user_id,favorite_key) do update set meal_name=excluded.meal_name,calories_kcal=excluded.calories_kcal,
      estimated_g=excluded.estimated_g,barcode=excluded.barcode,brand=excluded.brand,source_label=excluded.source_label,
      payload=excluded.payload,added_at=excluded.added_at,pinned=excluded.pinned;
  elsif p_kind='favoriteDelete' then
    delete from public.favorite_meals where user_id=u and favorite_key=p_entity_id;
  elsif p_kind='profileUpsert' then
    if p_entity_id<>'self' then raise exception 'EX_INVALID_PROFILE_ID' using errcode='22023'; end if;
    profile:=jsonb_populate_record(null::public.profiles,p_payload->'row');
    insert into public.profiles(id,weight_kg,height_cm,age_years,sex,activity_level,target_weight_kg,daily_steps_goal,
      daily_kcal_goal,daily_water_goal_ml,daily_sleep_goal_minutes,protein_goal_g,carbs_goal_g,fat_goal_g,weight_goal,
      diet_preference,onboarding_completed,manual_energy)
    values(u,profile.weight_kg,profile.height_cm,profile.age_years,profile.sex,profile.activity_level,profile.target_weight_kg,
      profile.daily_steps_goal,profile.daily_kcal_goal,profile.daily_water_goal_ml,profile.daily_sleep_goal_minutes,
      profile.protein_goal_g,profile.carbs_goal_g,profile.fat_goal_g,profile.weight_goal,profile.diet_preference,
      profile.onboarding_completed,profile.manual_energy)
    on conflict(id) do update set weight_kg=excluded.weight_kg,height_cm=excluded.height_cm,age_years=excluded.age_years,
      sex=excluded.sex,activity_level=excluded.activity_level,target_weight_kg=excluded.target_weight_kg,
      daily_steps_goal=excluded.daily_steps_goal,daily_kcal_goal=excluded.daily_kcal_goal,daily_water_goal_ml=excluded.daily_water_goal_ml,
      daily_sleep_goal_minutes=excluded.daily_sleep_goal_minutes,protein_goal_g=excluded.protein_goal_g,
      carbs_goal_g=excluded.carbs_goal_g,fat_goal_g=excluded.fat_goal_g,weight_goal=excluded.weight_goal,
      diet_preference=excluded.diet_preference,onboarding_completed=excluded.onboarding_completed,manual_energy=excluded.manual_energy;
  elsif p_kind in ('trainingPlanUpsert','trainingPlanDelete') then
    result:=public.apply_training_plan_mutation(p_kind,p_entity_id,p_payload);
  elsif p_kind='trainingHistoryInsert' then
    row_data:=p_payload->'row';
    if row_data->>'id' is distinct from p_entity_id then raise exception 'EX_INVALID_TRAINING_ID' using errcode='22023'; end if;
    result:=jsonb_build_object('entity_deleted',not public.record_training_history(p_entity_id::uuid,
      (row_data->>'finished_at')::timestamptz,row_data->'session'));
  elsif p_kind='trainingHistoryDelete' then
    perform public.delete_training_history(p_entity_id::uuid);
    result:=jsonb_build_object('entity_deleted',true);
  elsif p_kind in ('mealPlanUpsert','mealPlanConvert') then
    row_data:=p_payload->'plan';
    if row_data->>'id' is distinct from p_entity_id then raise exception 'EX_INVALID_PLAN_ID' using errcode='22023'; end if;
    perform pg_advisory_xact_lock(hashtextextended(u::text||':meal-plan',0));
    select plan into old_plan from public.planned_meals where user_id=u and id=p_entity_id::uuid;
    if old_plan->>'removed'='true' then result:=jsonb_build_object('entity_deleted',true,'planned_meal',old_plan);
    elsif p_kind='mealPlanConvert' then
      result:=jsonb_build_object('meal_plan_conversion',public.eat_planned_meal(row_data,p_payload->'meal',
        coalesce((p_payload->>'track_day')::boolean,false)));
    else
      perform public.save_planned_meal(row_data);
      select jsonb_build_object('planned_meal',plan) into result from public.planned_meals where user_id=u and id=p_entity_id::uuid;
    end if;
  elsif p_kind='shoppingCheck' then
    perform public.save_shopping_check(p_entity_id,(p_payload->>'checked')::boolean);
  elsif p_kind='trackingDay' then
    select to_jsonb(s) into stats from public.record_tracking_day(p_entity_id::date) s;
    result:=jsonb_build_object('lifetime_stats',stats);
  elsif p_kind='statsIncrement' then
    select to_jsonb(s) into stats from public.increment_lifetime_stats(p_request_id=>p_entity_id::uuid,
      p_meals=>coalesce((p_payload->>'meals')::integer,0),p_weight_logs=>coalesce((p_payload->>'weight_logs')::integer,0)) s;
    result:=jsonb_build_object('lifetime_stats',stats);
  end if;

  v_response:=jsonb_build_object('operation_id',p_operation_id,'kind',p_kind,'entity_id',p_entity_id,'result',result);
  update public.recipe_sync_heads set receipt_bytes=receipt_bytes+octet_length(v_response::text)+64
    where user_id=u and receipt_bytes+octet_length(v_response::text)+64<=33554432;
  if not found then raise exception 'EX_SYNC_RECEIPT_CAPACITY' using errcode='PT507'; end if;
  update public.sync_operation_receipts set response=v_response
    where user_id=u and operation_id=p_operation_id;
  return v_response||jsonb_build_object('current_state',public.sync_operation_current_state(v_response));
exception when data_exception or integrity_constraint_violation then
  -- Constraint DETAIL may contain the entire recipe/health row. Never put it
  -- in a client error or its diagnostic logs.
  raise exception 'EX_INVALID_SYNC_OPERATION' using errcode='22023';
end;
$$;
revoke all on function public.apply_sync_operation(uuid,text,text,jsonb,integer) from public, anon, authenticated;
grant execute on function public.apply_sync_operation(uuid,text,text,jsonb,integer) to authenticated, service_role;

-- Keep removal terminal for clients still calling the old meal-plan RPCs.
create or replace function public.save_planned_meal(p_plan jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); old jsonb;
begin
  if u is null then raise exception 'EX_USER_REQUIRED' using errcode='42501'; end if;
  if not public.is_valid_planned_meal(p_plan) or p_plan->>'eaten_at' is not null then
    raise exception 'EX_INVALID_PLAN' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(u::text || ':meal-plan',0));
  select plan into old from public.planned_meals where user_id=u and id=(p_plan->>'id')::uuid for update;
  -- Conversion receipts are immutable, even if an older offline edit arrives.
  if old->>'eaten_at' is not null or old->>'removed'='true' then return; end if;
  if old is null and ((select count(*) from public.planned_meals where user_id=u) >= 10000
    or (select count(*) from public.planned_meals where user_id=u
      and plan->>'eaten_at' is null and plan->>'removed'='false'
      and (plan->>'day')::date >= (now() at time zone 'utc')::date - 35) >= 500) then
    raise exception 'EX_PLAN_LIMIT'; end if;
  insert into public.planned_meals(user_id,id,plan) values(u,(p_plan->>'id')::uuid,p_plan)
  on conflict(user_id,id) do update set plan=excluded.plan;
end;
$$;
create or replace function public.eat_planned_meal(p_plan jsonb,p_meal jsonb,p_track_day boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); old jsonb; meal_id uuid; created boolean := false;
begin
  if u is null then raise exception 'EX_USER_REQUIRED' using errcode='42501'; end if;
  if not public.is_valid_planned_meal(p_plan) or p_plan->>'eaten_at' is null
    or (p_plan->>'removed')::boolean or jsonb_typeof(p_meal) is distinct from 'object'
    or p_track_day is null or p_meal->>'id' is distinct from p_plan->>'id'
    or p_meal->>'forced_slot' is distinct from p_plan->>'slot'
    or (p_meal->>'local_day')::date > (now() at time zone 'utc')::date + 1 then
    raise exception 'EX_INVALID_CONVERSION' using errcode='22023'; end if;
  if not (p_meal ?& array['id','logged_at','local_day','forced_slot','meal_name',
    'calories_kcal','estimated_g','protein_g','carbs_g','fat_g','source_label','payload'])
    or jsonb_typeof(p_meal->'local_day') is distinct from 'string'
    or p_meal->>'local_day' !~ '^\d{4}-\d{2}-\d{2}$'
    or jsonb_typeof(p_meal->'logged_at') is distinct from 'string'
    or jsonb_typeof(p_meal->'meal_name') is distinct from 'string'
    or jsonb_typeof(p_meal->'calories_kcal') is distinct from 'number'
    or jsonb_typeof(p_meal->'estimated_g') is distinct from 'number'
    or jsonb_typeof(p_meal->'payload') is distinct from 'object'
    or octet_length(p_meal::text) > 70000 then
    raise exception 'EX_INVALID_CONVERSION' using errcode='22023'; end if;
  meal_id := (p_plan->>'id')::uuid;
  -- Match dispatcher lock order, including legacy callers. A delete from
  -- another device must serialize with this first conversion attempt.
  perform pg_advisory_xact_lock(hashtextextended('sync:'||u::text,0));
  perform pg_advisory_xact_lock(hashtextextended(u::text || ':meal-plan',0));
  select plan into old from public.planned_meals where user_id=u and id=meal_id for update;
  if old->>'removed'='true' then raise exception 'EX_PLAN_REMOVED'; end if;
  if old->>'eaten_at' is null then
  if old is null and (select count(*) from public.planned_meals where user_id=u) >= 10000 then
    raise exception 'EX_PLAN_LIMIT'; end if;
  if not exists(select 1 from public.sync_entity_deletions
    where user_id=u and family='meal' and entity_id=meal_id::text) then
  -- Never overwrite an unrelated or foreign diary UUID. A conflict aborts the
  -- entire transaction; the still-planned meal remains recoverable.
  insert into public.logged_meals(id,user_id,logged_at,local_day,forced_slot,
    meal_name,calories_kcal,estimated_g,protein_g,carbs_g,fat_g,source_label,payload)
  values(meal_id,u,(p_meal->>'logged_at')::timestamptz,(p_meal->>'local_day')::date,
    p_meal->>'forced_slot',p_meal->>'meal_name',(p_meal->>'calories_kcal')::integer,
    (p_meal->>'estimated_g')::integer,(p_meal->>'protein_g')::numeric,
    (p_meal->>'carbs_g')::numeric,(p_meal->>'fat_g')::numeric,
    p_meal->>'source_label',p_meal->'payload');
  perform public.increment_lifetime_stats(p_meals=>1,p_request_id=>meal_id);
  if p_track_day then perform public.record_tracking_day((p_meal->>'local_day')::date); end if;
  created := true;
  end if;
  -- Keep the consumed plan even when a concurrent diary deletion won. The
  -- missing diary effect spends neither a counter nor a tracked day.
  insert into public.planned_meals(user_id,id,plan) values(u,meal_id,p_plan)
  on conflict(user_id,id) do update set plan=excluded.plan;
  end if;
  return jsonb_build_object('plan',(select plan from public.planned_meals where user_id=u and id=meal_id),
    'meal',(select to_jsonb(m) from public.logged_meals m where user_id=u and id=meal_id),
    'stats',coalesce((select to_jsonb(s) from public.lifetime_stats s where user_id=u),'{}'::jsonb),'created',created);
end;
$$;
