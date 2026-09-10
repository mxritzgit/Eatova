-- Additive recipe calculation snapshots. Existing owner RLS and grants remain.
-- Ingredient masses are raw weights, not a measured cooked recipe yield.
alter table public.user_recipes
  add column if not exists structured_ingredients jsonb not null default '[]'::jsonb,
  add column if not exists batch_servings numeric not null default 1;

create or replace function public.recipe_ingredients_valid(value jsonb, servings numeric)
returns boolean
language plpgsql immutable
set search_path = ''
as $$
declare
  item jsonb;
  nutrient jsonb;
  field text;
  calories numeric := 0;
  protein numeric := 0;
  carbs numeric := 0;
  fat numeric := 0;
  factor numeric;
begin
  if servings is null or servings not between 0.1 and 100 then return false; end if;
  if value is null or jsonb_typeof(value) <> 'array'
      or octet_length(value::text) > 100000 then return false; end if;
  if jsonb_array_length(value) > 100 then return false; end if;
  for item in select jsonb_array_elements(value) loop
    if jsonb_typeof(item) <> 'object' then return false; end if;
    if exists (select 1 from jsonb_object_keys(item) k
        where k not in ('name', 'grams', 'per_100g', 'source', 'product_code'))
        then return false; end if;
    if jsonb_typeof(item->'name') is distinct from 'string'
        or char_length(btrim(item->>'name')) not between 1 and 160
        or (item->>'name') ~ '[[:cntrl:]]'
        or jsonb_typeof(item->'grams') is distinct from 'number'
        or jsonb_typeof(item->'source') is distinct from 'string'
        or (item->>'source') not in ('manual', 'openFoodFacts')
        or jsonb_typeof(item->'per_100g') is distinct from 'object'
        then return false; end if;
    if (item->>'grams')::numeric not between 0.001 and 10000
        then return false; end if;
    if item ? 'product_code' and item->'product_code' <> 'null'::jsonb then
      if jsonb_typeof(item->'product_code') <> 'string'
          or (item->>'product_code') !~ '^[A-Za-z0-9_-]{1,64}$'
          or item->>'source' = 'manual' then return false; end if;
    end if;
    nutrient := item->'per_100g';
    if exists (select 1 from jsonb_object_keys(nutrient) k
        where k not in ('calories_kcal', 'protein_g', 'carbs_g', 'fat_g'))
        then return false; end if;
    foreach field in array array['calories_kcal', 'protein_g', 'carbs_g', 'fat_g'] loop
      if nutrient ? field and nutrient->field <> 'null'::jsonb then
        if jsonb_typeof(nutrient->field) <> 'number' then return false; end if;
        if (nutrient->>field)::numeric < 0
            or (nutrient->>field)::numeric >
                case when field = 'calories_kcal' then 900 else 100 end
            then return false; end if;
      end if;
    end loop;
    factor := (item->>'grams')::numeric / 100 / servings;
    calories := calories + coalesce((nutrient->>'calories_kcal')::numeric, 0) * factor;
    protein := protein + coalesce((nutrient->>'protein_g')::numeric, 0) * factor;
    carbs := carbs + coalesce((nutrient->>'carbs_g')::numeric, 0) * factor;
    fat := fat + coalesce((nutrient->>'fat_g')::numeric, 0) * factor;
  end loop;
  return calories <= 10000 and protein <= 1000 and carbs <= 1000 and fat <= 1000;
end;
$$;

revoke all on function public.recipe_ingredients_valid(jsonb, numeric) from public, anon;
grant execute on function public.recipe_ingredients_valid(jsonb, numeric) to authenticated, service_role;

alter table public.user_recipes
  add constraint user_recipes_ingredients_check
  check (public.recipe_ingredients_valid(structured_ingredients, batch_servings)
    and batch_servings between 0.1 and 100);
