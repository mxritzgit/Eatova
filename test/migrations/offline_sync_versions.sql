\set ON_ERROR_STOP on
begin;
insert into auth.users(id,email) values
 ('71000000-0000-4000-8000-000000000001','sync-a@example.invalid'),
 ('71000000-0000-4000-8000-000000000002','sync-b@example.invalid');

create function pg_temp.recipe(slug text,title text) returns jsonb language sql as $$
 select jsonb_build_object('slug',slug,'title',title,'description','','portion','','ingredients','',
   'preparation','','image_asset','','calories_kcal',100,'protein_g',10,'carbs_g',10,'fat_g',2,
   'estimated_g',100,'categories','[]'::jsonb,'structured_ingredients','[]'::jsonb,'batch_servings',1);
$$;
create function pg_temp.require(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Assertion failed: %',label; end if; end;
$$;
grant execute on function pg_temp.recipe(text,text),pg_temp.require(boolean,text) to authenticated;

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"71000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
do $$
declare first_receipt jsonb; second_receipt jsonb; conflict jsonb; erased jsonb; restored jsonb;
  v1 bigint; v2 bigint; deleted_revision bigint; body jsonb; old_snapshot jsonb; history jsonb; legacy_copy text;
begin
  body:=jsonb_build_object('expected_revision',0,'recipe',pg_temp.recipe('user_shared','First'));
  first_receipt:=public.apply_sync_operation('72000000-0000-4000-8000-000000000001','recipeUpsert','user_shared',body);
  v1:=(first_receipt#>>'{result,recipe_mutation,current_revision}')::bigint;
  perform pg_temp.require(v1>0,'create has server revision');
  second_receipt:=public.apply_sync_operation('72000000-0000-4000-8000-000000000002','recipeUpsert','user_shared',
    jsonb_build_object('expected_revision',v1,'recipe',pg_temp.recipe('user_shared','Second device')));
  v2:=(second_receipt#>>'{result,recipe_mutation,current_revision}')::bigint;
  perform pg_temp.require(v2>v1,'monotone revision');
  perform pg_temp.require(public.apply_sync_operation('72000000-0000-4000-8000-000000000001','recipeUpsert','user_shared',body)-'current_state'=first_receipt-'current_state',
    'lost response retry returns exact receipt');
  perform pg_temp.require((select title='Second device' from public.user_recipes where slug='user_shared'),'old retry cannot overwrite newer device');
  begin
    perform public.apply_sync_operation('72000000-0000-4000-8000-000000000001','recipeUpsert','user_shared',
      jsonb_build_object('expected_revision',v1,'recipe',pg_temp.recipe('user_shared','Changed request')));
    raise exception 'Changed operation UUID was accepted';
  exception when sqlstate '22023' then null; end;
  conflict:=public.apply_sync_operation('72000000-0000-4000-8000-000000000003','recipeUpsert','user_shared',
    jsonb_build_object('expected_revision',v1,'recipe',pg_temp.recipe('user_shared','Offline draft')));
  perform pg_temp.require(conflict#>>'{result,recipe_mutation,outcome}'='conflictSaved','stale update keeps a copy');
  perform pg_temp.require(conflict#>>'{result,recipe_mutation,saved_recipe,slug}'='user_conflict_72000000-0000-4000-8000-000000000003','copy identity is deterministic');
  perform pg_temp.require((select count(*)=2 from public.user_recipes),'both drafts survive');
  perform pg_temp.require((select title='Second device' from public.user_recipes where slug='user_shared'),'conflict never changes original');
  erased:=public.apply_sync_operation('72000000-0000-4000-8000-000000000004','recipeDelete','user_shared',jsonb_build_object('expected_revision',v2));
  deleted_revision:=(erased#>>'{result,recipe_mutation,current_revision}')::bigint;
  perform pg_temp.require(deleted_revision>v2 and (erased#>>'{result,recipe_mutation,current_deleted}')::boolean,'delete advances tombstone');
  history:=public.apply_sync_operation('72000000-0000-4000-8000-000000000001','recipeUpsert','user_shared',body);
  perform pg_temp.require(history-'current_state'=first_receipt-'current_state','deleted recipe keeps immutable effect receipt');
  perform pg_temp.require(history#>>'{current_state,recipe,deleted}'='true' and
    (history#>>'{current_state,saved_recipe,revision}')::bigint=deleted_revision,'old recipe receipt projects current tombstone');
  history:=public.load_sync_operation_receipt('72000000-0000-4000-8000-000000000001');
  perform pg_temp.require(history-'current_state'=first_receipt-'current_state','read preserves original immutable effect');
  perform pg_temp.require(history#>>'{current_state,saved_recipe,deleted}'='true','read resolves background acknowledgement to current tombstone');
  history:=public.load_sync_operation_receipt('72000000-0000-4000-8000-000000000003');
  perform pg_temp.require(history#>>'{current_state,saved_recipe,recipe,title}'='Offline draft','read resolves exact conflict copy');
  perform pg_temp.require(not exists(select 1 from public.user_recipes where slug='user_shared'),'reading never replays a deleted recipe');
  conflict:=public.apply_sync_operation('72000000-0000-4000-8000-000000000005','recipeUpsert','user_shared',
    jsonb_build_object('expected_revision',v2,'recipe',pg_temp.recipe('user_shared','Late draft')));
  perform pg_temp.require(conflict#>>'{result,recipe_mutation,outcome}'='conflictSaved','edit after delete is preserved as copy');
  perform pg_temp.require(not exists(select 1 from public.user_recipes where slug='user_shared'),'stale edit cannot resurrect identity');
  restored:=public.apply_sync_operation('72000000-0000-4000-8000-000000000006','recipeUpsert','user_shared',
    jsonb_build_object('expected_revision',deleted_revision,'recipe',pg_temp.recipe('user_shared','Restored explicitly')));
  perform pg_temp.require(restored#>>'{result,recipe_mutation,outcome}'='applied','explicit restore CAS succeeds');
  conflict:=public.apply_sync_operation('72000000-0000-4000-8000-000000000007','recipeDelete','user_shared',jsonb_build_object('expected_revision',v2));
  perform pg_temp.require(conflict#>>'{result,recipe_mutation,outcome}'='deleteConflict','stale delete preserves newer content');
  update public.user_recipes set title='Legacy edit' where slug='user_shared';
  delete from public.user_recipes where slug='user_shared';
  insert into public.user_recipes(user_id,slug,title) values(auth.uid(),'user_shared','Legacy delayed write')
    on conflict(user_id,slug) do update set title=excluded.title;
  perform pg_temp.require(not exists(select 1 from public.user_recipes where slug='user_shared'),'legacy cannot undo tombstone');
  perform pg_temp.require(exists(select 1 from public.user_recipes where conflict_of='user_shared' and title='Legacy delayed write'),'legacy content retained as copy');
  select slug into legacy_copy from public.user_recipes where conflict_of='user_shared' and title='Legacy delayed write';
  delete from public.user_recipes where slug=legacy_copy;
  insert into public.user_recipes(user_id,slug,title) values(auth.uid(),'user_shared','Legacy delayed write')
    on conflict(user_id,slug) do update set title=excluded.title;
  perform pg_temp.require(not exists(select 1 from public.user_recipes where slug=legacy_copy),'legacy cannot revive deleted conflict copy');
  perform pg_temp.require(exists(select 1 from public.user_recipes where conflict_of='user_shared' and title='Legacy delayed write'),'second legacy intent survives as fresh copy');
  history:=public.load_recipe_history('user_shared');
  perform pg_temp.require((history->>'current_deleted')::boolean,'history names terminal identity');
  perform pg_temp.require(exists(select 1 from jsonb_array_elements(history->'versions') v
    where v->>'source'='legacy' and v#>>'{recipe,title}'='Legacy edit'),'legacy version recoverable');
  perform pg_temp.require(exists(select 1 from jsonb_array_elements(public.load_recipe_history()->'versions') v
    where v#>>'{recipe,title}'='First'),'global history exposes deleted originals');

  -- The first page's watermark is a snapshot, even while unseen rows change.
  old_snapshot:=public.load_recipe_page(null,null,1);
  perform public.apply_sync_operation('72000000-0000-4000-8000-000000000008','recipeUpsert','user_zzz',
    jsonb_build_object('expected_revision',0,'recipe',pg_temp.recipe('user_zzz','Later insertion')));
  perform pg_temp.require(not exists(select 1 from jsonb_array_elements(public.load_recipe_page(
    (old_snapshot->>'watermark')::bigint,null,200)->'rows') r where r->>'slug'='user_zzz'),'snapshot excludes later insertion');
  perform pg_temp.require(jsonb_array_length(public.load_recipe_page(null,null,200)->'rows')=
    jsonb_array_length(public.load_recipe_page((old_snapshot->>'watermark')::bigint,null,200)->'rows')+1,'live snapshot includes new row');
  old_snapshot:=public.load_recipe_page(null,null,1);
  update public.user_recipes set title='Changed after first page' where slug='user_zzz';
  delete from public.user_recipes where slug='user_zzz';
  history:=public.load_recipe_page((old_snapshot->>'watermark')::bigint,old_snapshot->>'next_after',200);
  perform pg_temp.require(exists(select 1 from jsonb_array_elements(history->'rows') r
    where r->>'slug'='user_zzz' and r->>'title'='Later insertion'),'later page retains row deleted or edited after watermark');
  history:=public.load_recipe_history('user_zzz');
  perform public.apply_sync_operation('72000000-0000-4000-8000-000000000009','recipeUpsert','user_zzz',
    jsonb_build_object('expected_revision',(history->>'current_revision')::bigint,'recipe',pg_temp.recipe('user_zzz','For photos')));
  update public.user_recipes set image_asset='local:old-photo.jpg' where slug='user_zzz';
  update public.user_recipes set image_asset='local:new-photo.jpg' where slug='user_zzz';
  delete from public.user_recipes where slug='user_zzz';
  old_snapshot:=public.load_recipe_photo_refs(null,null,1);
  perform pg_temp.require(old_snapshot->>'complete'='false','historical photo refs paginate');
  history:=public.load_recipe_photo_refs((old_snapshot->>'watermark')::bigint,old_snapshot->>'next_after',1);
  perform pg_temp.require(history->>'complete'='true','photo reference cursor terminates');
  perform pg_temp.require((old_snapshot->'refs')||(history->'refs')='["local:new-photo.jpg","local:old-photo.jpg"]'::jsonb,
    'deleted and replaced photos remain protected');
end;
$$;

-- A different owner may reuse UUIDs but can read neither history nor receipts.
select set_config('request.jwt.claims','{"sub":"71000000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select pg_temp.require(jsonb_array_length(public.load_recipe_page()->'rows')=0,'cross-user snapshot isolated');
select pg_temp.require(jsonb_array_length(public.load_recipe_history()->'versions')=0,'cross-user history isolated');
select pg_temp.require(jsonb_array_length(public.load_recipe_photo_refs()->'refs')=0,'cross-user photo references isolated');
select public.apply_sync_operation('72000000-0000-4000-8000-000000000001','recipeUpsert','user_shared',
  jsonb_build_object('expected_revision',0,'recipe',pg_temp.recipe('user_shared','Owner B')));
do $$ begin
  begin
    perform public.apply_recipe_mutation('72000000-0000-4000-8000-000000000010','recipeDelete','user_shared',0,null);
    raise exception 'Private mutation bypass accessible';
  exception when insufficient_privilege then null; end;
  begin
    perform * from public.sync_operation_receipts;
    raise exception 'Private operation receipts accessible';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
delete from auth.users where id='71000000-0000-4000-8000-000000000001';
select pg_temp.require(not exists(select 1 from public.recipe_revisions where user_id='71000000-0000-4000-8000-000000000001'),'account deletion erases history');
select pg_temp.require(not exists(select 1 from public.sync_operation_receipts where user_id='71000000-0000-4000-8000-000000000001'),'account deletion erases receipts');
rollback;
select 'Offline recipe versions: all assertions passed' as result;
