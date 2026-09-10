-- Included after rlstest helpers and users A/B. Every assertion runs with the
-- same role and claims as its client; successful writes roll back afterwards.
create or replace function rlstest.meal_plan(p_id uuid)
returns jsonb language sql stable as $$
  select jsonb_build_object('id',p_id,'day',(current_date+2)::text,'slot','dinner',
    'servings',1.5,'removed',false,'eaten_at',null,'recipe',jsonb_build_object(
      'slug','fixture','title','Oats','description','','portion','1 bowl',
      'ingredients','100 g oats','preparation','','image_asset','',
      'calories_kcal',100,'protein_g',10,'carbs_g',15,'fat_g',2,
      'estimated_g',100,'categories',jsonb_build_array('Eigene'),
      'structured_ingredients','[]'::jsonb,'batch_servings',1));
$$;
create or replace function rlstest.plan_meal(p_id uuid)
returns jsonb language sql stable as $$
  select jsonb_build_object('id',p_id,'local_day',current_date::text,
    'logged_at',now(),'forced_slot','dinner','meal_name','Oats',
    'calories_kcal',150,'estimated_g',150,'protein_g',15,'carbs_g',22.5,
    'fat_g',3,'source_label','recipe','payload','{}'::jsonb);
$$;
grant execute on function rlstest.meal_plan(uuid),rlstest.plan_meal(uuid)
  to authenticated,service_role;

begin;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',true);
select public.save_planned_meal(rlstest.meal_plan('aaaaaaaa-0000-4000-8000-000000000001'));
select public.save_shopping_check('2026-09-07:'||repeat('a',64),true);
do $$
declare draft jsonb := rlstest.meal_plan('aaaaaaaa-0000-4000-8000-000000000001');
  bad jsonb; large_recipe jsonb;
begin
  large_recipe := draft || jsonb_build_object('recipe', draft->'recipe' ||
    jsonb_build_object('description', repeat('a',4000),'portion',repeat('a',1000),
      'ingredients',repeat('a',20000),'preparation',repeat('a',20000),
      'image_asset',repeat('a',2048)));
  if not public.is_valid_planned_meal(large_recipe) then
    raise exception 'MEALPLAN: legal recipe field limits rejected'; end if;
  if (select count(*) from public.planned_meals where id='aaaaaaaa-0000-4000-8000-000000000001') <> 1
    then raise exception 'MEALPLAN: own plan invisible'; end if;
  if exists(select 1 from public.logged_meals where id='aaaaaaaa-0000-4000-8000-000000000001')
    then raise exception 'MEALPLAN: planning logged consumption'; end if;
  foreach bad in array array[draft||'{"servings":0}',draft||'{"servings":101}',
    draft||'{"servings":"1.5"}',draft||'{"slot":null}',draft||'{"day":"2026-02-31"}',
    draft||'{"user_id":"22222222-2222-2222-2222-222222222222"}',
    jsonb_set(draft,'{recipe,calories_kcal}','-1'),
    jsonb_set(draft,'{recipe,batch_servings}','0'),
    jsonb_set(draft,'{recipe,structured_ingredients}','[{"name":"Oats","grams":-5}]')] loop
    if public.is_valid_planned_meal(bad) is distinct from false then
      raise exception 'MEALPLAN: malformed plan accepted'; end if;
    perform rlstest.erwarte_sqlstate(format('select public.save_planned_meal(%L::jsonb)',bad),
      '22023','malformed meal plan');
  end loop;
  perform rlstest.erwarte_ablehnung(
    'update public.planned_meals set user_id=''22222222-2222-2222-2222-222222222222''',
    'direct owner reassignment');
  perform rlstest.erwarte_ablehnung('delete from public.planned_meals','direct plan deletion');
end $$;

-- B sees neither A's plan nor A's checklist, and can write its own data.
select set_config('request.jwt.claims','{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}',true);
select rlstest.erwarte_zeilen('select * from public.planned_meals where user_id=''11111111-1111-1111-1111-111111111111''',0,'foreign plans');
select rlstest.erwarte_zeilen('select * from public.shopping_checks where user_id=''11111111-1111-1111-1111-111111111111''',0,'foreign checks');
select public.save_planned_meal(rlstest.meal_plan('bbbbbbbb-0000-4000-8000-000000000001'));
select public.save_shopping_check('2026-09-07:'||repeat('b',64),true);
do $$ begin
  if jsonb_array_length(public.load_meal_plan()->'plans') <> 1 then
    raise exception 'MEALPLAN: RPC leaked another account'; end if;
end $$;

select set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',true);
do $$
declare draft jsonb := rlstest.meal_plan('aaaaaaaa-0000-4000-8000-000000000001');
  consumed jsonb; meal jsonb; receipt jsonb; before_meals integer;
begin
  consumed := draft || jsonb_build_object('eaten_at',now());
  meal := rlstest.plan_meal('aaaaaaaa-0000-4000-8000-000000000001');
  select meals_logged into before_meals from public.lifetime_stats where user_id=auth.uid();
  -- Invalid diary data must roll back the conversion receipt, too.
  perform rlstest.erwarte_sqlstate(format('select public.eat_planned_meal(%L,%L,true)',
    consumed,meal||'{"calories_kcal":-1}'),'23514','atomic invalid conversion');
  if (select plan->>'eaten_at' from public.planned_meals where user_id=auth.uid()
      and id='aaaaaaaa-0000-4000-8000-000000000001') is not null then
    raise exception 'MEALPLAN: invalid meal prematurely consumed plan'; end if;
  receipt := public.eat_planned_meal(consumed,meal,true);
  if receipt->>'created' <> 'true' or receipt->'plan' <> consumed then
    raise exception 'MEALPLAN: missing canonical creation receipt'; end if;
  receipt := public.eat_planned_meal(consumed,meal,true);
  if receipt->>'created' <> 'false' or receipt->'plan' <> consumed
    or receipt->'meal'->>'local_day' <> current_date::text
    or (receipt->'stats'->>'meals_logged')::integer <> before_meals+1 then
    raise exception 'MEALPLAN: non-canonical retry receipt'; end if;
  perform public.save_planned_meal(draft||'{"servings":2}');
  if (select count(*) from public.logged_meals where id='aaaaaaaa-0000-4000-8000-000000000001')<>1
    then raise exception 'MEALPLAN: duplicate consumed diary row'; end if;
  if (select meals_logged from public.lifetime_stats where user_id=auth.uid())<>before_meals+1
    then raise exception 'MEALPLAN: conversion counted more than once'; end if;
  if (select plan->>'eaten_at' from public.planned_meals where user_id=auth.uid()
      and id='aaaaaaaa-0000-4000-8000-000000000001') is null then
    raise exception 'MEALPLAN: stale edit erased conversion'; end if;
  if (select local_day from public.logged_meals where id='aaaaaaaa-0000-4000-8000-000000000001')<>current_date
    then raise exception 'MEALPLAN: scheduled future date used as consumed date'; end if;
  -- Removing a diary entry does not erase its conversion receipt: retries may
  -- never resurrect a deliberately deleted consumed meal.
  delete from public.logged_meals where id='aaaaaaaa-0000-4000-8000-000000000001';
  receipt := public.eat_planned_meal(consumed,meal,true);
  if receipt->'meal' is distinct from 'null'::jsonb or receipt->>'created' <> 'false' then
    raise exception 'MEALPLAN: deleted meal receipt returned stale diary'; end if;
  if exists(select 1 from public.logged_meals where id='aaaaaaaa-0000-4000-8000-000000000001')
    then raise exception 'MEALPLAN: retry resurrected deleted meal'; end if;
end $$;

-- A cannot convert onto B's diary ID; the UNIQUE error rolls back A's receipt.
select set_config('request.jwt.claims','{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}',true);
select public.eat_planned_meal(rlstest.meal_plan('bbbbbbbb-0000-4000-8000-000000000001')||jsonb_build_object('eaten_at',now()),
  rlstest.plan_meal('bbbbbbbb-0000-4000-8000-000000000001'),true);
select set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',true);
select rlstest.erwarte_sqlstate($q$select public.eat_planned_meal(
  rlstest.meal_plan('bbbbbbbb-0000-4000-8000-000000000001')||jsonb_build_object('eaten_at',now()),
  rlstest.plan_meal('bbbbbbbb-0000-4000-8000-000000000001'),true)$q$,'23505','foreign diary UUID collision');
select rlstest.erwarte_zeilen('select * from public.planned_meals where user_id=auth.uid() and id=''bbbbbbbb-0000-4000-8000-000000000001''',0,'collision left no plan receipt');

-- Hidden historical plans must not exhaust the active-plan allowance.
set local role service_role;
insert into public.planned_meals(user_id,id,plan)
select '11111111-1111-1111-1111-111111111111',
  ('cccccccc-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,
  rlstest.meal_plan(('cccccccc-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid)
    || jsonb_build_object('day',(current_date-36)::text)
from generate_series(1,500) i;
set local role authenticated;
select public.save_planned_meal(rlstest.meal_plan('aaaaaaaa-0000-4000-8000-000000000002'));
select rlstest.erwarte_zeilen('select * from public.planned_meals where id=''aaaaaaaa-0000-4000-8000-000000000002''',1,'historical plans leave active capacity');

set local role anon;
select set_config('request.jwt.claims','{}',true);
select rlstest.erwarte_ablehnung('select * from public.planned_meals','anonymous plans');
select rlstest.erwarte_ablehnung('select * from public.shopping_checks','anonymous checks');
select rlstest.erwarte_ablehnung('select public.load_meal_plan()','anonymous planner RPC');
select rlstest.erwarte_ablehnung('select public.eat_planned_meal(''{}'',''{}'',true)','anonymous conversion');
rollback;
