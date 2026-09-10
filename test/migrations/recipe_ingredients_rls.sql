-- Included by the root RLS suite after its user and assertion fixtures exist.
begin;
set local role service_role;
do $$
declare
  valid jsonb := '[{"name":"Oats","grams":400,"source":"manual","per_100g":
    {"calories_kcal":350,"protein_g":12.345,"carbs_g":null,"fat_g":0}}]'::jsonb;
  invalid jsonb;
begin
  if public.recipe_ingredients_valid(valid, 4) is distinct from true then
    raise exception 'INGREDIENT: valid partial snapshot rejected';
  end if;
  foreach invalid in array array[
    null::jsonb, '{}'::jsonb, '[null]'::jsonb,
    jsonb_set(valid, '{0,grams}', '0'),
    jsonb_set(valid, '{0,grams}', '10001'),
    jsonb_set(valid, '{0,grams}', '"100"'),
    jsonb_set(valid, '{0,name}', '""'),
    jsonb_set(valid, '{0,name}', to_jsonb(repeat('a', 161))),
    jsonb_set(valid, '{0,name}', to_jsonb(E'bad\nname'::text)),
    jsonb_set(valid, '{0,source}', '"ai"'),
    jsonb_set(valid, '{0,product_code}', '"123"'),
    jsonb_set(valid, '{0,per_100g,calories_kcal}', '-1'),
    jsonb_set(valid, '{0,per_100g,calories_kcal}', '901'),
    jsonb_set(valid, '{0,per_100g,protein_g}', '101'),
    jsonb_set(valid, '{0,per_100g,protein_g}', '"12"'),
    jsonb_set(valid, '{0,per_100g,unknown}', '1'),
    jsonb_set(valid, '{0,unknown}', '1'),
    (select jsonb_agg(valid->0) from generate_series(1, 101))
  ] loop
    if public.recipe_ingredients_valid(invalid, 4) is distinct from false then
      raise exception 'INGREDIENT: malformed snapshot accepted';
    end if;
    perform rlstest.erwarte_sqlstate(format(
      'insert into public.user_recipes(user_id,slug,title,structured_ingredients,batch_servings) values (%L,%L,%L,%L::jsonb,4)',
      '11111111-1111-1111-1111-111111111111','ingredient-invalid','Invalid',invalid),
      case when invalid is null then '23502' else '23514' end,
      'invalid ingredient write');
  end loop;
  if public.recipe_ingredients_valid(valid, 0) is distinct from false
      or public.recipe_ingredients_valid(valid, 101) is distinct from false
      or public.recipe_ingredients_valid(valid, 'NaN'::numeric) is distinct from false
      or public.recipe_ingredients_valid(
        (select jsonb_agg(valid->0) from generate_series(1, 100)), 1)
          is distinct from false then
    raise exception 'INGREDIENT: invalid portions or aggregate overflow accepted';
  end if;
  insert into public.user_recipes(user_id,slug,title,structured_ingredients,batch_servings)
    values ('11111111-1111-1111-1111-111111111111','ingredient-owner-a','Batch A',valid,4),
      ('22222222-2222-2222-2222-222222222222','ingredient-owner-b','Batch B',valid,4);
end $$;

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
select rlstest.erwarte_zeilen(
  $q$select * from public.user_recipes where slug='ingredient-owner-b'$q$, 0, 'foreign ingredient read');
select rlstest.erwarte_zeilen(
  $q$update public.user_recipes set batch_servings=2 where slug='ingredient-owner-b'$q$, 0, 'foreign ingredient update');
select rlstest.erwarte_zeilen(
  $q$delete from public.user_recipes where slug='ingredient-owner-b'$q$, 0, 'foreign ingredient delete');
select rlstest.erwarte_zeilen(
  $q$update public.user_recipes set batch_servings=2 where slug='ingredient-owner-a'$q$, 1, 'own recipe recalculation');
select rlstest.erwarte_ablehnung(
  $q$insert into public.user_recipes(user_id,slug,title) values
    ('22222222-2222-2222-2222-222222222222','ingredient-forged','Forged')$q$, 'foreign recipe insert');
set local role anon;
select rlstest.erwarte_ablehnung('select * from public.user_recipes', 'anonymous ingredient read');
select rlstest.erwarte_ablehnung('select public.recipe_ingredients_valid(null,1)', 'anonymous ingredient validator');
rollback;
