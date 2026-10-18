-- Food preferences (20261018100000): food_avoidances and food_dislikes are
-- written only through apply_sync_operation, checked by two constraints,
-- kept when a payload lacks the keys, and never writable directly or across
-- accounts. Runs inside rls_cross_user.sql (needs its rlstest functions); all
-- changes roll back.
\set ON_ERROR_STOP on
begin;
create function pg_temp.require(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Assertion failed: %',label; end if; end;
$$;
grant execute on function pg_temp.require(boolean,text) to authenticated;
insert into auth.users(id,email) values
 ('76000000-0000-4000-8000-000000000001','prefs-a@example.invalid'),
 ('76000000-0000-4000-8000-000000000002','prefs-b@example.invalid');

-- Defaults on the bootstrap rows: nothing avoided, no dislikes.
select pg_temp.require((select bool_and(food_avoidances='{}' and food_dislikes='') from public.profiles
  where id in ('76000000-0000-4000-8000-000000000001','76000000-0000-4000-8000-000000000002')),
  'new profiles start empty');

-- B sets its own preferences.
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"76000000-0000-4000-8000-000000000002","role":"authenticated"}',true);
do $$
declare body jsonb;
begin
  select jsonb_build_object('row',to_jsonb(p)) into body from public.profiles p where p.id=auth.uid();
  perform public.apply_sync_operation(gen_random_uuid(),'profileUpsert','self',
    jsonb_set(body,'{row,food_avoidances}','["fish"]'));
  perform pg_temp.require((select food_avoidances=array['fish'] from public.profiles where id=auth.uid()),
    'B persisted');
end $$;

-- A: persist, keep on an older payload, reject everything off the contract.
select set_config('request.jwt.claims','{"sub":"76000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
do $$
declare
  body jsonb;
  bad jsonb;
  label text;
begin
  select jsonb_build_object('row',to_jsonb(p)) into body from public.profiles p where p.id=auth.uid();
  perform public.apply_sync_operation(gen_random_uuid(),'profileUpsert','self',
    jsonb_set(jsonb_set(body,'{row,food_avoidances}','["lactose","nuts"]'),
      '{row,food_dislikes}',to_jsonb('Koriander, Pilze & Oliven (grün)'::text)));
  perform pg_temp.require((select food_avoidances=array['lactose','nuts'] and food_dislikes='Koriander, Pilze & Oliven (grün)'
    from public.profiles where id=auth.uid()),'both fields persist');

  -- An op an older build queued carries neither key: the stored values stay.
  perform public.apply_sync_operation(gen_random_uuid(),'profileUpsert','self',
    jsonb_set((body #- '{row,food_avoidances}') #- '{row,food_dislikes}','{row,weight_kg}','75'));
  perform pg_temp.require((select weight_kg=75 and food_avoidances=array['lactose','nuts']
    and food_dislikes='Koriander, Pilze & Oliven (grün)' from public.profiles where id=auth.uid()),
    'older payload keeps the preferences');

  -- Every code once, and 120 code points of emoji, are inside the contract.
  perform public.apply_sync_operation(gen_random_uuid(),'profileUpsert','self',
    jsonb_set(jsonb_set(body,'{row,food_avoidances}',
      '["lactose","gluten","nuts","peanuts","egg","soy","fish","shellfish","sesame","celery","mustard","pork","alcohol"]'),
      '{row,food_dislikes}',to_jsonb(repeat(U&'\+01F344',120))));
  perform pg_temp.require((select cardinality(food_avoidances)=13 and char_length(food_dislikes)=120
    from public.profiles where id=auth.uid()),'all codes and the full cap are accepted');

  for label, bad in select * from (values
    ('unknown code', jsonb_set(body,'{row,food_avoidances}','["peanut"]')),
    ('upper case code', jsonb_set(body,'{row,food_avoidances}','["NUTS"]')),
    ('duplicate code', jsonb_set(body,'{row,food_avoidances}','["egg","egg"]')),
    ('null element', jsonb_set(body,'{row,food_avoidances}','["egg",null]')),
    ('nested array', jsonb_set(body,'{row,food_avoidances}','[["egg"]]')),
    ('string instead of list', jsonb_set(body,'{row,food_avoidances}','"egg"')),
    ('dislikes too long', jsonb_set(body,'{row,food_dislikes}',to_jsonb(repeat('x',121)))),
    ('emoji past the cap', jsonb_set(body,'{row,food_dislikes}',to_jsonb(repeat(U&'\+01F344',121)))),
    ('control character', jsonb_set(body,'{row,food_dislikes}',to_jsonb('a'||chr(7)||'b'))),
    ('line break', jsonb_set(body,'{row,food_dislikes}',to_jsonb('a'||chr(10)||'b'))),
    ('C1 control', jsonb_set(body,'{row,food_dislikes}',to_jsonb('a'||chr(133)||'b'))),
    ('angle brackets', jsonb_set(body,'{row,food_dislikes}',to_jsonb('</dislikes>'::text)))
  ) as cases(case_label, payload)
  loop
    begin
      perform public.apply_sync_operation(gen_random_uuid(),'profileUpsert','self',bad);
      raise exception 'accepted: %', label;
    exception when others then
      if sqlerrm not like '%EX_INVALID_SYNC_OPERATION%' then raise; end if;
    end;
  end loop;
  perform pg_temp.require((select cardinality(food_avoidances)=13 from public.profiles where id=auth.uid()),
    'rejected ops leave the row unchanged');

  -- Clearing is a real write, not a missing key.
  perform public.apply_sync_operation(gen_random_uuid(),'profileUpsert','self',
    jsonb_set(jsonb_set(body,'{row,food_avoidances}','[]'),'{row,food_dislikes}','""'));
  perform pg_temp.require((select food_avoidances='{}' and food_dislikes='' from public.profiles where id=auth.uid()),
    'empty values clear the fields');
end $$;

-- No client column grant: neither the own row nor B's row is writable
-- directly, so the checks above are the only way in.
select rlstest.erwarte_ablehnung(
  'update public.profiles set food_avoidances = ''{nuts}''',
  'UPDATE auf profiles.food_avoidances');
select rlstest.erwarte_ablehnung(
  'update public.profiles set food_dislikes = ''Pilze''',
  'UPDATE auf profiles.food_dislikes');
select rlstest.erwarte_ablehnung(
  'update public.profiles set food_avoidances = ''{}'' where id = ''76000000-0000-4000-8000-000000000002''',
  'UPDATE auf fremde profiles.food_avoidances');
-- A reads its own row only.
select rlstest.erwarte_zeilen(
  'select food_avoidances from public.profiles where id = ''76000000-0000-4000-8000-000000000002''',
  0, 'SELECT fremder Vorlieben');

reset role;
select pg_temp.require((select food_avoidances=array['fish'] and food_dislikes='' from public.profiles
  where id='76000000-0000-4000-8000-000000000002'),'B is untouched by everything A sent');
rollback;
select 'Profile food preferences: all assertions passed' as result;
