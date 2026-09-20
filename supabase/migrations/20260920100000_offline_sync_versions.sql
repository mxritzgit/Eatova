-- Additive rollout: deploy before clients use apply_sync_operation. Legacy
-- writes remain callable and every recipe revision stays recoverable.
create table public.recipe_sync_heads (
  user_id uuid primary key references auth.users(id) on delete cascade,
  revision bigint not null default 0 check (revision >= 0),
  history_bytes bigint not null default 0 check (history_bytes >= 0),
  history_budget bigint not null default 67108864 check (history_budget >= 67108864),
  receipt_bytes bigint not null default 0 check (receipt_bytes >= 0),
  receipt_count integer not null default 0 check (receipt_count >= 0)
);
create table public.recipe_revisions (
  user_id uuid not null references auth.users(id) on delete cascade,
  revision bigint not null check (revision > 0),
  slug text not null check (char_length(slug) between 1 and 200),
  deleted boolean not null,
  recipe jsonb not null check (jsonb_typeof(recipe) = 'object'),
  source text not null check (source in ('seed', 'legacy', 'cas')),
  recorded_at timestamptz not null default clock_timestamp(),
  primary key (user_id, revision)
);
create index recipe_revisions_snapshot_idx
  on public.recipe_revisions(user_id, slug, revision desc);

create table public.sync_operation_receipts (
  user_id uuid not null references auth.users(id) on delete cascade,
  operation_id uuid not null,
  fingerprint bytea not null,
  response jsonb,
  created_at timestamptz not null default clock_timestamp(),
  primary key (user_id, operation_id)
);
create table public.sync_entity_deletions (
  user_id uuid not null references auth.users(id) on delete cascade,
  family text not null check (family in ('meal', 'training_plan')),
  entity_id text not null,
  primary key (user_id, family, entity_id)
);

alter table public.recipe_sync_heads enable row level security;
alter table public.recipe_revisions enable row level security;
alter table public.sync_operation_receipts enable row level security;
alter table public.sync_entity_deletions enable row level security;
revoke all on public.recipe_sync_heads from public, anon, authenticated;
revoke all on public.recipe_revisions from public, anon, authenticated;
revoke all on public.sync_operation_receipts from public, anon, authenticated;
revoke all on public.sync_entity_deletions from public, anon, authenticated;
grant all on public.recipe_sync_heads to service_role;
grant all on public.recipe_revisions to service_role;
grant all on public.sync_operation_receipts to service_role;
grant all on public.sync_entity_deletions to service_role;

alter table public.user_recipes
  add column server_revision bigint not null default 0,
  add column conflict_of text;
alter table public.user_recipes add constraint user_recipes_revision_check
  check (server_revision >= 0 and (conflict_of is null or char_length(conflict_of) between 1 and 200));

-- Seed while migration DDL owns the table lock, before exposing the triggers.
with numbered as (
  select id, row_number() over (partition by user_id order by created_at,id) as revision
  from public.user_recipes
)
update public.user_recipes r set server_revision = n.revision from numbered n where r.id=n.id;
insert into public.recipe_sync_heads(user_id,revision)
  select user_id,max(server_revision) from public.user_recipes group by user_id;
insert into public.recipe_revisions(user_id,revision,slug,deleted,recipe,source)
  select user_id,server_revision,slug,false,to_jsonb(r),'seed' from public.user_recipes r;
update public.recipe_sync_heads h set history_bytes=(select coalesce(sum(octet_length(recipe::text)),0)
  from public.recipe_revisions where user_id=h.user_id);
-- Existing valid collections receive the same additional history allowance as
-- an empty account. Migration never strands a previously writable large library.
update public.recipe_sync_heads set history_budget=greatest(67108864,history_bytes+67108864);

create or replace function public.recipe_revision_before()
returns trigger language plpgsql security definer set search_path = pg_catalog as $$
declare u uuid; v bigint; row_data jsonb; origin text := 'legacy'; op text;
  latest_deleted boolean; latest_revision bigint; original_slug text; redirects integer:=0;
begin
  u := case when tg_op='DELETE' then old.user_id else new.user_id end;
  -- Cascading account erasure must erase the journal too, never recreate it.
  if tg_op='DELETE' and not exists(select 1 from auth.users where id=u) then return old; end if;
  if auth.uid() is not null and auth.uid()<>u then
    raise exception 'EX_OWNER_REQUIRED' using errcode='42501';
  end if;
  if tg_op='UPDATE' and (new.user_id is distinct from old.user_id or
      new.id is distinct from old.id or new.slug is distinct from old.slug) then
    raise exception 'EX_RECIPE_IDENTITY_IMMUTABLE' using errcode='22023';
  end if;
  insert into public.recipe_sync_heads(user_id) values(u) on conflict do nothing;
  update public.recipe_sync_heads set revision=revision+1 where user_id=u returning revision into v;
  -- Permanent history has an explicit storage budget; never prune user versions.
  if v>100000 then raise exception 'EX_RECIPE_HISTORY_CAPACITY' using errcode='PT507'; end if;
  op := current_setting('eatova.sync_operation',true);
  if op is not null and exists(select 1 from public.sync_operation_receipts
      where user_id=u and operation_id::text=op and response is null) then origin:='cas'; end if;
  if tg_op='INSERT' and origin='legacy' then
    original_slug:=new.slug;
    loop
      select deleted,revision into latest_deleted,latest_revision from public.recipe_revisions
        where user_id=u and slug=new.slug order by revision desc limit 1;
      exit when latest_deleted is distinct from true;
      -- Old clients cannot assert an intentional restore. Preserve their write
      -- as a deterministic copy without reviving the deleted identity.
      redirects:=redirects+1;
      if redirects>32 then raise exception 'EX_RECIPE_RESTORE_REQUIRED' using errcode='22023'; end if;
      new.conflict_of:=original_slug;
      new.slug:='user_legacy_'||encode(sha256(convert_to((to_jsonb(new)-
        array['id','created_at','updated_at','server_revision'])::text||':'||latest_revision::text,'UTF8')),'hex');
    end loop;
  end if;
  if tg_op='DELETE' then
    row_data := to_jsonb(old) || jsonb_build_object('server_revision',v);
    update public.recipe_sync_heads set history_bytes=history_bytes+octet_length(row_data::text)
      where user_id=u and history_bytes+octet_length(row_data::text)<=history_budget;
    if not found then raise exception 'EX_RECIPE_HISTORY_CAPACITY' using errcode='PT507'; end if;
    insert into public.recipe_revisions(user_id,revision,slug,deleted,recipe,source)
      values(u,v,old.slug,true,row_data,origin);
    return old;
  end if;
  new.server_revision := v;
  if tg_op='UPDATE' then new.created_at := old.created_at; end if;
  return new;
end;
$$;
create or replace function public.recipe_revision_after()
returns trigger language plpgsql security definer set search_path = pg_catalog as $$
declare origin text := 'legacy'; op text := current_setting('eatova.sync_operation',true);
begin
  if op is not null and exists(select 1 from public.sync_operation_receipts
      where user_id=new.user_id and operation_id::text=op and response is null) then origin:='cas'; end if;
  update public.recipe_sync_heads set history_bytes=history_bytes+octet_length(to_jsonb(new)::text)
    where user_id=new.user_id and history_bytes+octet_length(to_jsonb(new)::text)<=history_budget;
  if not found then raise exception 'EX_RECIPE_HISTORY_CAPACITY' using errcode='PT507'; end if;
  insert into public.recipe_revisions(user_id,revision,slug,deleted,recipe,source)
    values(new.user_id,new.server_revision,new.slug,false,to_jsonb(new),origin);
  return new;
end;
$$;
create trigger user_recipes_revision_before before insert or update or delete on public.user_recipes
  for each row execute function public.recipe_revision_before();
create trigger user_recipes_revision_after after insert or update on public.user_recipes
  for each row execute function public.recipe_revision_after();
revoke all on function public.recipe_revision_before() from public, anon, authenticated;
revoke all on function public.recipe_revision_after() from public, anon, authenticated;
grant execute on function public.recipe_revision_before() to service_role;
grant execute on function public.recipe_revision_after() to service_role;

create or replace function public.load_recipe_page(
  p_watermark bigint default null, p_after_slug text default null, p_limit integer default 200
) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare u uuid := auth.uid(); head bigint; mark bigint; items jsonb; more boolean; cursor text;
begin
  if u is null then raise exception 'EX_USER_REQUIRED' using errcode='42501'; end if;
  if p_limit is null or p_limit not between 1 and 200 or
      (p_after_slug is not null and char_length(p_after_slug)>200) then
    raise exception 'EX_INVALID_PAGE' using errcode='22023'; end if;
  select coalesce((select revision from public.recipe_sync_heads where user_id=u),0) into head;
  mark := coalesce(p_watermark,head);
  if mark<0 or mark>head then raise exception 'EX_INVALID_WATERMARK' using errcode='22023'; end if;
  with latest as (
    select distinct on (slug) slug,deleted,recipe from public.recipe_revisions
    where user_id=u and revision<=mark and (p_after_slug is null or slug>p_after_slug)
    order by slug,revision desc
  ), page as (
    select slug,recipe from latest where not deleted order by slug limit p_limit+1
  ), numbered as (select *,row_number() over(order by slug) n from page)
  select coalesce(jsonb_agg(recipe order by slug) filter(where n<=p_limit),'[]'::jsonb),
    count(*)>p_limit,max(slug) filter(where n<=p_limit) into items,more,cursor from numbered;
  return jsonb_build_object('watermark',mark,'rows',items,
    'next_after',case when more then cursor else null end,'complete',not more);
end;
$$;
create or replace function public.load_recipe_history(
  p_slug text default null, p_before_revision bigint default null, p_limit integer default 30
) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare u uuid := auth.uid(); items jsonb; more boolean; cursor bigint; current_row public.recipe_revisions%rowtype;
begin
  if u is null then raise exception 'EX_USER_REQUIRED' using errcode='42501'; end if;
  if p_limit is null or p_limit not between 1 and 50 or
      (p_slug is not null and char_length(p_slug) not between 1 and 200) or
      (p_before_revision is not null and p_before_revision<=0) then
    raise exception 'EX_INVALID_PAGE' using errcode='22023'; end if;
  if p_slug is not null then select * into current_row from public.recipe_revisions
    where user_id=u and slug=p_slug order by revision desc limit 1; end if;
  with page as (
    select * from public.recipe_revisions where user_id=u and (p_slug is null or slug=p_slug)
      and (p_before_revision is null or revision<p_before_revision)
    order by revision desc limit p_limit+1
  ), numbered as (select *,row_number() over(order by revision desc) n from page)
  select coalesce(jsonb_agg(jsonb_build_object('revision',revision,'deleted',deleted,
      'recorded_at',recorded_at,'source',source,'recipe',recipe) order by revision desc)
      filter(where n<=p_limit),'[]'::jsonb),
    count(*)>p_limit,min(revision) filter(where n<=p_limit) into items,more,cursor from numbered;
  return jsonb_build_object('current_revision',case when p_slug is null then null else coalesce(current_row.revision,0) end,
    'current_deleted',case when p_slug is null then null else coalesce(current_row.deleted,true) end,
    'versions',items,'next_before',case when more then cursor else null end);
end;
$$;
revoke all on function public.load_recipe_page(bigint,text,integer) from public, anon, authenticated;
revoke all on function public.load_recipe_history(text,bigint,integer) from public, anon, authenticated;
grant execute on function public.load_recipe_page(bigint,text,integer) to authenticated, service_role;
grant execute on function public.load_recipe_history(text,bigint,integer) to authenticated, service_role;

-- Orphan cleanup needs every historical local marker, not every recipe body.
create or replace function public.load_recipe_photo_refs(
  p_watermark bigint default null,p_after_ref text default null,p_limit integer default 200
) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare u uuid:=auth.uid(); head bigint; mark bigint; refs jsonb; more boolean; cursor text;
begin
  if u is null then raise exception 'EX_USER_REQUIRED' using errcode='42501'; end if;
  if p_limit is null or p_limit not between 1 and 200 or
      (p_after_ref is not null and char_length(p_after_ref)>2048) then
    raise exception 'EX_INVALID_PAGE' using errcode='22023'; end if;
  select coalesce((select revision from public.recipe_sync_heads where user_id=u),0) into head;
  mark:=coalesce(p_watermark,head);
  if mark<0 or mark>head then raise exception 'EX_INVALID_WATERMARK' using errcode='22023'; end if;
  with candidates as (
    select distinct recipe->>'image_asset' ref from public.recipe_revisions
    where user_id=u and revision<=mark and left(recipe->>'image_asset',6)='local:'
      and (p_after_ref is null or recipe->>'image_asset'>p_after_ref)
    order by ref limit p_limit+1
  ), numbered as(select ref,row_number() over(order by ref) n from candidates)
  select coalesce(jsonb_agg(ref order by ref) filter(where n<=p_limit),'[]'::jsonb),
    count(*)>p_limit,max(ref) filter(where n<=p_limit) into refs,more,cursor from numbered;
  return jsonb_build_object('watermark',mark,'refs',refs,
    'next_after',case when more then cursor else null end,'complete',not more);
end;
$$;
revoke all on function public.load_recipe_photo_refs(bigint,text,integer) from public, anon, authenticated;
grant execute on function public.load_recipe_photo_refs(bigint,text,integer) to authenticated, service_role;

-- Internal CAS implementation; only apply_sync_operation exposes writes.
create or replace function public.apply_recipe_mutation(
  p_operation_id uuid,p_kind text,p_slug text,p_expected_revision bigint,p_recipe jsonb
) returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare u uuid:=auth.uid(); current_row public.recipe_revisions%rowtype; saved public.user_recipes%rowtype;
  candidate public.user_recipes%rowtype; target text:=p_slug; outcome text:='applied'; current_data jsonb;
begin
  if u is null then raise exception 'EX_USER_REQUIRED' using errcode='42501'; end if;
  if p_slug is null or char_length(p_slug) not between 1 and 200 or p_expected_revision<0
      or p_kind not in ('recipeUpsert','recipeDelete') then
    raise exception 'EX_INVALID_RECIPE_MUTATION' using errcode='22023'; end if;
  insert into public.recipe_sync_heads(user_id) values(u) on conflict do nothing;
  perform 1 from public.recipe_sync_heads where user_id=u for update;
  select * into current_row from public.recipe_revisions where user_id=u and slug=p_slug order by revision desc limit 1;
  current_data:=case when current_row.deleted=false then current_row.recipe else null end;
  if (current_row.revision is not null and p_expected_revision is distinct from current_row.revision)
      or (current_row.revision is null and coalesce(p_expected_revision,0)<>0) then
    if p_kind='recipeDelete' then outcome:='deleteConflict';
    else outcome:='conflictSaved'; target:='user_conflict_'||p_operation_id::text; end if;
  end if;
  if p_kind='recipeUpsert' then
    if jsonb_typeof(p_recipe) is distinct from 'object' or p_recipe->>'slug' is distinct from p_slug
      or octet_length(p_recipe::text)>180000 or not (p_recipe ?& array['title','description','portion',
        'ingredients','preparation','image_asset','calories_kcal','protein_g','carbs_g','fat_g','estimated_g','categories']) then
      raise exception 'EX_INVALID_RECIPE' using errcode='22023'; end if;
    candidate:=jsonb_populate_record(null::public.user_recipes,p_recipe);
    if outcome='conflictSaved' and exists(select 1 from public.recipe_revisions where user_id=u and slug=target) then
      raise exception 'EX_CONFLICT_IDENTITY_TAKEN' using errcode='22023'; end if;
    insert into public.user_recipes(user_id,slug,title,description,portion,ingredients,preparation,image_asset,
      calories_kcal,protein_g,carbs_g,fat_g,estimated_g,categories,structured_ingredients,batch_servings,conflict_of)
    values(u,target,candidate.title,candidate.description,candidate.portion,candidate.ingredients,candidate.preparation,
      candidate.image_asset,candidate.calories_kcal,candidate.protein_g,candidate.carbs_g,candidate.fat_g,
      candidate.estimated_g,candidate.categories,coalesce(candidate.structured_ingredients,'[]'),coalesce(candidate.batch_servings,1),
      case when outcome='conflictSaved' then p_slug else current_row.recipe->>'conflict_of' end)
    on conflict(user_id,slug) do update set title=excluded.title,description=excluded.description,portion=excluded.portion,
      ingredients=excluded.ingredients,preparation=excluded.preparation,image_asset=excluded.image_asset,
      calories_kcal=excluded.calories_kcal,protein_g=excluded.protein_g,carbs_g=excluded.carbs_g,fat_g=excluded.fat_g,
      estimated_g=excluded.estimated_g,categories=excluded.categories,structured_ingredients=excluded.structured_ingredients,
      batch_servings=excluded.batch_servings
    returning * into saved;
    if outcome='applied' then current_data:=to_jsonb(saved); current_row.revision:=saved.server_revision; current_row.deleted:=false; end if;
  elsif outcome='applied' then
    if current_row.deleted=false then
      delete from public.user_recipes where user_id=u and slug=p_slug;
      select * into current_row from public.recipe_revisions where user_id=u and slug=p_slug order by revision desc limit 1;
    elsif current_row.revision is null then
      -- A create-before-delete race still needs a permanent tombstone.
      update public.recipe_sync_heads set revision=revision+1 where user_id=u returning revision into current_row.revision;
      if current_row.revision>100000 then raise exception 'EX_RECIPE_HISTORY_CAPACITY' using errcode='PT507'; end if;
      update public.recipe_sync_heads set history_bytes=history_bytes+octet_length(jsonb_build_object('slug',p_slug,'server_revision',current_row.revision)::text)
        where user_id=u and history_bytes+octet_length(jsonb_build_object('slug',p_slug,'server_revision',current_row.revision)::text)<=history_budget;
      if not found then raise exception 'EX_RECIPE_HISTORY_CAPACITY' using errcode='PT507'; end if;
      insert into public.recipe_revisions(user_id,revision,slug,deleted,recipe,source)
        values(u,current_row.revision,p_slug,true,jsonb_build_object('slug',p_slug,'server_revision',current_row.revision),'cas');
    end if;
    current_row.deleted:=true; current_data:=null;
  end if;
  return jsonb_build_object('outcome',outcome,'saved_recipe',case when saved.id is not null then to_jsonb(saved) else null end,
    'current_recipe',current_data,'current_revision',coalesce(current_row.revision,0),'current_deleted',coalesce(current_row.deleted,true));
end;
$$;
revoke all on function public.apply_recipe_mutation(uuid,text,text,bigint,jsonb) from public, anon, authenticated;
grant execute on function public.apply_recipe_mutation(uuid,text,text,bigint,jsonb) to service_role;
