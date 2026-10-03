-- Weekly energy check (docs/WEIGHT-TREND.md, stage 2). The app estimates the
-- user's actual daily expenditure from logged intake and the weight trend and,
-- after an explicit confirmation, shifts maintenance by a persisted offset.
--
--   energy_adjustment_kcal  offset on BMR x PAL, kcal/day; the client caps it
--                           at +-500, the check here at +-1000 as a backstop.
--   energy_checked_on       local day of the last answered check (accepted or
--                           dismissed); the next check waits 7 days.
--
-- Written only through apply_sync_operation (SECURITY DEFINER), so no column
-- grants for authenticated: no client path writes profiles directly anymore,
-- and the select stays table-wide. The function below is the definition of
-- 20260920101000 with the profileUpsert branch extended; a payload without
-- the new keys (an older build) keeps the stored values. Idempotent.

alter table public.profiles
  add column if not exists energy_adjustment_kcal smallint not null default 0,
  add column if not exists energy_checked_on date;

alter table public.profiles
  drop constraint if exists profiles_energy_adjustment_range_check;
alter table public.profiles
  add constraint profiles_energy_adjustment_range_check
  check (energy_adjustment_kcal between -1000 and 1000);

comment on column public.profiles.energy_adjustment_kcal is
  'Weekly-check offset on BMR x PAL in kcal/day, set only after the user '
  'confirms a proposal (docs/WEIGHT-TREND.md).';
comment on column public.profiles.energy_checked_on is
  'Local day of the last answered weekly energy check; null = never.';

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
    -- energy_* (20261003100000): a payload without the key (an older build)
    -- keeps the stored value; jsonb_populate_record would read it as null.
    insert into public.profiles as current_row(id,weight_kg,height_cm,age_years,sex,activity_level,target_weight_kg,daily_steps_goal,
      daily_kcal_goal,daily_water_goal_ml,daily_sleep_goal_minutes,protein_goal_g,carbs_goal_g,fat_goal_g,weight_goal,
      diet_preference,onboarding_completed,manual_energy,energy_adjustment_kcal,energy_checked_on)
    values(u,profile.weight_kg,profile.height_cm,profile.age_years,profile.sex,profile.activity_level,profile.target_weight_kg,
      profile.daily_steps_goal,profile.daily_kcal_goal,profile.daily_water_goal_ml,profile.daily_sleep_goal_minutes,
      profile.protein_goal_g,profile.carbs_goal_g,profile.fat_goal_g,profile.weight_goal,profile.diet_preference,
      profile.onboarding_completed,profile.manual_energy,coalesce(profile.energy_adjustment_kcal,0),profile.energy_checked_on)
    on conflict(id) do update set weight_kg=excluded.weight_kg,height_cm=excluded.height_cm,age_years=excluded.age_years,
      sex=excluded.sex,activity_level=excluded.activity_level,target_weight_kg=excluded.target_weight_kg,
      daily_steps_goal=excluded.daily_steps_goal,daily_kcal_goal=excluded.daily_kcal_goal,daily_water_goal_ml=excluded.daily_water_goal_ml,
      daily_sleep_goal_minutes=excluded.daily_sleep_goal_minutes,protein_goal_g=excluded.protein_goal_g,
      carbs_goal_g=excluded.carbs_goal_g,fat_goal_g=excluded.fat_goal_g,weight_goal=excluded.weight_goal,
      diet_preference=excluded.diet_preference,onboarding_completed=excluded.onboarding_completed,manual_energy=excluded.manual_energy,
      energy_adjustment_kcal=case when (p_payload->'row') ? 'energy_adjustment_kcal'
        then excluded.energy_adjustment_kcal else current_row.energy_adjustment_kcal end,
      energy_checked_on=case when (p_payload->'row') ? 'energy_checked_on'
        then excluded.energy_checked_on else current_row.energy_checked_on end;
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
