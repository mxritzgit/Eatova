-- REC-3 (2026-10-11): a create against a deleted slug is applied, not a conflict.
--
-- Recipe import (user_import_<sha>) and Coach adoption (user_coach_<msgId>)
-- use fixed slugs, and the client sends expected_revision 0 for a slug it does
-- not hold. Against a tombstone head that was `conflictSaved`: a re-import of
-- a deleted recipe landed under user_conflict_<opid> although no other version
-- existed, and every further import made another copy.
--
-- Now a recipeUpsert with coalesce(p_expected_revision,0)=0 whose latest
-- revision is a tombstone recreates the identity under the same slug (a new
-- CAS revision; history keeps the old versions and the tombstone). Unchanged:
-- a stale edit (expected N>0 that no longer matches) still conflicts and
-- cannot resurrect a deleted identity; a create against a live head still
-- conflicts; recipeDelete semantics are unchanged.
--
-- The body is the definition of 20260920100000 with only the conflict test
-- changed. Additive and idempotent; old clients gain the same outcome.

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
  -- A create against a tombstone recreates the absent identity.
  if (current_row.revision is not null and p_expected_revision is distinct from current_row.revision
        and not (p_kind='recipeUpsert' and current_row.deleted and coalesce(p_expected_revision,0)=0))
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
