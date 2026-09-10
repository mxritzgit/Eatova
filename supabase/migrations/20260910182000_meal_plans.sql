-- Planning never enters logged_meals until eat_planned_meal commits both rows.
create or replace function public.is_valid_planned_meal(p jsonb)
returns boolean language plpgsql immutable set search_path = public as $$
declare r jsonb; k text; n numeric; d date;
begin
  if jsonb_typeof(p) is distinct from 'object' or octet_length(p::text) > 70000
    or not (p ?& array['id','day','slot','servings','recipe','removed','eaten_at'])
    or (p - array['id','day','slot','servings','recipe','removed','eaten_at']) <> '{}'::jsonb
    or jsonb_typeof(p->'id') <> 'string'
    or (p->>'id') !~ '^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$'
    or jsonb_typeof(p->'day') <> 'string' or (p->>'day') !~ '^\d{4}-\d{2}-\d{2}$'
    or jsonb_typeof(p->'slot') is distinct from 'string'
    or (p->>'slot') not in ('breakfast','lunch','dinner','snack')
    or jsonb_typeof(p->'servings') <> 'number'
    or jsonb_typeof(p->'removed') <> 'boolean'
    or jsonb_typeof(p->'eaten_at') not in ('null','string') then return false; end if;
  d := (p->>'day')::date;
  if d < date '2000-01-01' or d > date '2100-12-31' then return false; end if;
  n := (p->>'servings')::numeric;
  if n < .1 or n > 100 then return false; end if;
  if p->>'eaten_at' is not null then
    perform (p->>'eaten_at')::timestamptz;
    if (p->>'removed')::boolean then return false; end if;
  end if;
  r := p->'recipe';
  if jsonb_typeof(r) is distinct from 'object' or octet_length(r::text) > 65536 then return false; end if;
  foreach k in array array['slug','title','description','portion','ingredients','preparation','image_asset'] loop
    if jsonb_typeof(r->k) is distinct from 'string' then return false; end if;
    if char_length(r->>k) > case k when 'slug' then 300 when 'title' then 300
      when 'description' then 2000 when 'portion' then 500 when 'image_asset' then 1000
      else 10000 end then return false; end if;
  end loop;
  if btrim(r->>'title') = '' or btrim(r->>'slug') = '' then return false; end if;
  foreach k in array array['calories_kcal','protein_g','carbs_g','fat_g','estimated_g'] loop
    if jsonb_typeof(r->k) is distinct from 'number' then return false; end if;
    n := (r->>k)::numeric;
    if n < 0 or n > 1000000 then return false; end if;
  end loop;
  if not public.recipe_ingredients_valid(
    coalesce(r->'structured_ingredients','[]'::jsonb),
    coalesce((r->>'batch_servings')::numeric,1)) then return false; end if;
  return true;
exception when others then return false;
end;
$$;
revoke all on function public.is_valid_planned_meal(jsonb) from public, anon;
grant execute on function public.is_valid_planned_meal(jsonb) to authenticated, service_role;

create table public.planned_meals (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  plan jsonb not null check (public.is_valid_planned_meal(plan)),
  primary key (user_id,id),
  check ((plan->>'id')::uuid = id)
);
alter table public.planned_meals enable row level security;
create policy planned_meals_select_own on public.planned_meals for select to authenticated
  using (user_id = (select auth.uid()));
revoke all on public.planned_meals from public, anon, authenticated;
grant select on public.planned_meals to authenticated;
grant all on public.planned_meals to service_role;
create index planned_meals_user_day_idx on public.planned_meals(user_id,(plan->>'day'));

create table public.shopping_checks (
  user_id uuid not null references auth.users(id) on delete cascade,
  id text not null check (id ~ '^\d{4}-\d{2}-\d{2}:[a-f0-9]{64}$'),
  checked boolean not null,
  primary key (user_id,id)
);
alter table public.shopping_checks enable row level security;
create policy shopping_checks_select_own on public.shopping_checks for select to authenticated
  using (user_id = (select auth.uid()));
revoke all on public.shopping_checks from public, anon, authenticated;
grant select on public.shopping_checks to authenticated;
grant all on public.shopping_checks to service_role;

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
  if old->>'eaten_at' is not null then return; end if;
  if old is null and ((select count(*) from public.planned_meals where user_id=u) >= 10000
    or (select count(*) from public.planned_meals where user_id=u
      and plan->>'eaten_at' is null and plan->>'removed'='false') >= 500) then
    raise exception 'EX_PLAN_LIMIT'; end if;
  insert into public.planned_meals(user_id,id,plan) values(u,(p_plan->>'id')::uuid,p_plan)
  on conflict(user_id,id) do update set plan=excluded.plan;
end;
$$;
revoke all on function public.save_planned_meal(jsonb) from public, anon;
grant execute on function public.save_planned_meal(jsonb) to authenticated;

create or replace function public.save_shopping_check(p_id text,p_checked boolean)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'EX_USER_REQUIRED' using errcode='42501'; end if;
  if p_id is null or p_id !~ '^\d{4}-\d{2}-\d{2}:[a-f0-9]{64}$' or p_checked is null then
    raise exception 'EX_INVALID_CHECK' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(u::text || ':meal-plan',0));
  delete from public.shopping_checks where user_id=u and left(id,10) < ((now() at time zone 'utc')::date - 35)::text;
  if not exists(select 1 from public.shopping_checks where user_id=u and id=p_id)
    and (select count(*) from public.shopping_checks where user_id=u) >= 2000 then
    raise exception 'EX_SHOPPING_LIMIT'; end if;
  insert into public.shopping_checks(user_id,id,checked) values(u,p_id,p_checked)
  on conflict(user_id,id) do update set checked=excluded.checked;
end;
$$;
revoke all on function public.save_shopping_check(text,boolean) from public, anon;
grant execute on function public.save_shopping_check(text,boolean) to authenticated;

create or replace function public.load_meal_plan()
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); result jsonb;
begin
  if u is null then raise exception 'EX_USER_REQUIRED' using errcode='42501'; end if;
  select jsonb_build_object('plans',coalesce((select jsonb_agg(plan) from public.planned_meals
    where user_id=u and plan->>'removed'='false' and (plan->>'day')::date >= (now() at time zone 'utc')::date - 35), '[]'::jsonb),
    'checks',coalesce((select jsonb_agg(jsonb_build_object('id',id,'checked',checked))
      from public.shopping_checks where user_id=u),'[]'::jsonb)) into result;
  return result;
end;
$$;
revoke all on function public.load_meal_plan() from public, anon;
grant execute on function public.load_meal_plan() to authenticated;

create or replace function public.eat_planned_meal(p_plan jsonb,p_meal jsonb,p_track_day boolean)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); old jsonb; meal_id uuid;
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
  perform pg_advisory_xact_lock(hashtextextended(u::text || ':meal-plan',0));
  select plan into old from public.planned_meals where user_id=u and id=meal_id for update;
  if old->>'eaten_at' is not null then return; end if;
  if old is null and (select count(*) from public.planned_meals where user_id=u) >= 10000 then
    raise exception 'EX_PLAN_LIMIT'; end if;
  -- Never overwrite an unrelated or foreign diary UUID. A conflict aborts the
  -- entire transaction; the still-planned meal remains recoverable.
  insert into public.logged_meals(id,user_id,logged_at,local_day,forced_slot,
    meal_name,calories_kcal,estimated_g,protein_g,carbs_g,fat_g,source_label,payload)
  values(meal_id,u,(p_meal->>'logged_at')::timestamptz,(p_meal->>'local_day')::date,
    p_meal->>'forced_slot',p_meal->>'meal_name',(p_meal->>'calories_kcal')::integer,
    (p_meal->>'estimated_g')::integer,(p_meal->>'protein_g')::numeric,
    (p_meal->>'carbs_g')::numeric,(p_meal->>'fat_g')::numeric,
    p_meal->>'source_label',p_meal->'payload');
  insert into public.planned_meals(user_id,id,plan) values(u,meal_id,p_plan)
  on conflict(user_id,id) do update set plan=excluded.plan;
  perform public.increment_lifetime_stats(p_meals=>1,p_request_id=>meal_id);
  if p_track_day then perform public.record_tracking_day((p_meal->>'local_day')::date); end if;
end;
$$;
revoke all on function public.eat_planned_meal(jsonb,jsonb,boolean) from public, anon;
grant execute on function public.eat_planned_meal(jsonb,jsonb,boolean) to authenticated;
