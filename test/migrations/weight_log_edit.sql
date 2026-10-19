-- Correctable weigh-ins (20261019110000): weightUpsert edits or restores the
-- caller's own row without counting, weightDelete removes it behind a
-- permanent tombstone, receipts stay exact, and neither kind reaches another
-- account's row. Runs inside rls_cross_user.sql (needs its rlstest
-- functions); all changes roll back.
\set ON_ERROR_STOP on
begin;
create function pg_temp.require(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Assertion failed: %',label; end if; end;
$$;
grant execute on function pg_temp.require(boolean,text) to authenticated;
insert into auth.users(id,email) values
 ('77000000-0000-4000-8000-000000000001','weights-a@example.invalid'),
 ('77000000-0000-4000-8000-000000000002','weights-b@example.invalid');

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"77000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
do $$
#variable_conflict use_variable
declare id uuid:='77000000-0000-4000-8000-0000000000a1'; restored uuid:='77000000-0000-4000-8000-0000000000a2';
  op uuid; edit_op uuid; edit_receipt jsonb; receipt jsonb; again jsonb; body jsonb; base jsonb;
  label text; bad jsonb;
begin
  perform public.apply_sync_operation(gen_random_uuid(),'weightInsert',id::text,
    jsonb_build_object('row',jsonb_build_object('id',id,'recorded_at','2026-10-18T07:00:00Z','weight_kg',95)));
  perform pg_temp.require((select weight_logs=1 from public.lifetime_stats where user_id=auth.uid()),'insert counts once');

  -- An edit moves value and time, counts nothing and keeps an exact receipt.
  edit_op:=gen_random_uuid();
  body:=jsonb_build_object('row',jsonb_build_object('id',id,'recorded_at','2026-10-17T06:30:00Z','weight_kg',85.4));
  edit_receipt:=public.apply_sync_operation(edit_op,'weightUpsert',id::text,body);
  perform pg_temp.require((select weight_kg=85.4 and recorded_at='2026-10-17T06:30:00Z'::timestamptz
    from public.weight_log w where w.id=id),'edit moves value and time');
  perform pg_temp.require(edit_receipt#>>'{current_state,entity_deleted}'='false','edit receipt names the live row');
  perform pg_temp.require(public.apply_sync_operation(edit_op,'weightUpsert',id::text,body)=edit_receipt,'edit retry receipt is exact');
  perform public.apply_sync_operation(gen_random_uuid(),'weightUpsert',id::text,jsonb_set(body,'{row,weight_kg}','85.6'));
  perform public.apply_sync_operation(edit_op,'weightUpsert',id::text,body);
  perform pg_temp.require((select weight_kg=85.6 from public.weight_log w where w.id=id),'old edit retry cannot rewind a newer edit');
  begin
    perform public.apply_sync_operation(edit_op,'weightUpsert',id::text,jsonb_set(body,'{row,weight_kg}','70'));
    raise exception 'reused operation id accepted';
  exception when others then
    if sqlstate<>'22023' then raise; end if;
  end;
  perform pg_temp.require((select weight_kg=85.6 from public.weight_log w where w.id=id),'a reused operation id changes nothing');

  -- The undo of a delete restores under a new id, again without counting.
  perform public.apply_sync_operation(gen_random_uuid(),'weightUpsert',restored::text,
    jsonb_build_object('row',jsonb_build_object('id',restored,'recorded_at','2026-10-16T06:30:00Z','weight_kg',86)));
  perform pg_temp.require(exists(select 1 from public.weight_log w where w.id=restored and w.user_id=auth.uid()),'new id is inserted');
  perform pg_temp.require((select weight_logs=1 from public.lifetime_stats where user_id=auth.uid()),'edits and restores count nothing');

  -- A delete is terminal for its identity.
  op:=gen_random_uuid();
  receipt:=public.apply_sync_operation(op,'weightDelete',id::text,'{}');
  perform pg_temp.require(not exists(select 1 from public.weight_log w where w.id=id),'delete removes the row');
  perform pg_temp.require((receipt#>>'{result,entity_deleted}')::boolean and receipt#>>'{current_state,entity_deleted}'='true',
    'delete receipt names the deletion');
  perform pg_temp.require(public.apply_sync_operation(op,'weightDelete',id::text,'{}')=receipt,'delete retry receipt is exact');
  perform pg_temp.require((select weight_logs=1 from public.lifetime_stats where user_id=auth.uid()),'a delete does not uncount');
  again:=public.apply_sync_operation(gen_random_uuid(),'weightUpsert',id::text,body);
  perform pg_temp.require((again#>>'{result,entity_deleted}')::boolean,'tombstone rejects a stale edit');
  perform pg_temp.require(not exists(select 1 from public.weight_log w where w.id=id),'stale edit cannot resurrect the row');
  again:=public.apply_sync_operation(gen_random_uuid(),'weightUpsert',upper(id::text),
    jsonb_set(body,'{row,id}',to_jsonb(upper(id::text))));
  perform pg_temp.require((again#>>'{result,entity_deleted}')::boolean,'tombstone holds for another spelling of the id');
  again:=public.apply_sync_operation(edit_op,'weightUpsert',id::text,body);
  perform pg_temp.require(again-'current_state'=edit_receipt-'current_state','old edit receipt stays immutable');
  perform pg_temp.require(again#>>'{current_state,entity_deleted}'='true','old edit receipt projects the current deletion');

  -- Everything off the contract is rejected and leaves the rows alone.
  base:=jsonb_set(body,'{row,id}',to_jsonb(restored));
  for label, bad in select * from (values
    ('id mismatch', body),
    ('row missing', '{}'::jsonb),
    ('row not an object', '{"row":[]}'::jsonb),
    ('time missing', base #- '{row,recorded_at}'),
    ('weight missing', base #- '{row,weight_kg}'),
    ('weight out of range', jsonb_set(base,'{row,weight_kg}','500')),
    ('weight not a number', jsonb_set(base,'{row,weight_kg}','"schwer"'))
  ) as cases(case_label, payload)
  loop
    begin
      perform public.apply_sync_operation(gen_random_uuid(),'weightUpsert',restored::text,bad);
      raise exception 'accepted: %', label;
    exception when others then
      if sqlstate<>'22023' then raise; end if;
    end;
  end loop;
  begin
    perform public.apply_sync_operation(gen_random_uuid(),'weightDelete','not-a-uuid','{}');
    raise exception 'accepted: delete of a malformed id';
  exception when others then
    if sqlstate<>'22023' then raise; end if;
  end;
  perform pg_temp.require((select weight_kg=86 from public.weight_log w where w.id=restored),'rejected ops leave the row unchanged');
end $$;

-- B can neither edit nor delete A's weigh-in, and learns nothing but the
-- rejection; no receipt or tombstone of B's survives.
select set_config('request.jwt.claims','{"sub":"77000000-0000-4000-8000-000000000002","role":"authenticated"}',true);
do $$
declare foreign_id uuid:='77000000-0000-4000-8000-0000000000a2';
begin
  begin
    perform public.apply_sync_operation('77000000-0000-4000-8000-0000000000b1','weightUpsert',foreign_id::text,
      jsonb_build_object('row',jsonb_build_object('id',foreign_id,'recorded_at','2026-10-16T06:30:00Z','weight_kg',40)));
    raise exception 'foreign edit accepted';
  exception when others then
    if sqlstate<>'42501' then raise; end if;
  end;
  begin
    perform public.apply_sync_operation('77000000-0000-4000-8000-0000000000b2','weightDelete',foreign_id::text,'{}');
    raise exception 'foreign delete accepted';
  exception when others then
    if sqlstate<>'42501' then raise; end if;
  end;
  perform pg_temp.require(public.load_sync_operation_receipt('77000000-0000-4000-8000-0000000000b1') is null and
    public.load_sync_operation_receipt('77000000-0000-4000-8000-0000000000b2') is null,'rejected ops keep no receipt');
end $$;
-- Direct writes stay behind RLS as before.
select rlstest.erwarte_zeilen(
  'update public.weight_log set weight_kg = 40 where id = ''77000000-0000-4000-8000-0000000000a2''',
  0, 'UPDATE fremder Wiegung');
select rlstest.erwarte_zeilen(
  'delete from public.weight_log where id = ''77000000-0000-4000-8000-0000000000a2''',
  0, 'DELETE fremder Wiegung');
select rlstest.erwarte_ablehnung(
  'insert into public.sync_entity_deletions(user_id,family,entity_id) values (''77000000-0000-4000-8000-000000000002'',''weight'',''x'')',
  'INSERT in sync_entity_deletions');

set local role anon;
select rlstest.erwarte_ablehnung(
  $q$select public.apply_sync_operation(gen_random_uuid(),'weightDelete','77000000-0000-4000-8000-0000000000a2','{}')$q$,
  'anonymous weight delete');

reset role;
select pg_temp.require((select weight_kg=86 from public.weight_log
  where id='77000000-0000-4000-8000-0000000000a2' and user_id='77000000-0000-4000-8000-000000000001'),
  'A is untouched by everything B sent');
select pg_temp.require(not exists(select 1 from public.sync_entity_deletions
  where user_id='77000000-0000-4000-8000-000000000002'),'B left no tombstone');
select pg_temp.require((select count(*)=1 from public.sync_entity_deletions
  where user_id='77000000-0000-4000-8000-000000000001' and family='weight'),'one canonical tombstone for A');
rollback;
select 'Weigh-in edits: all assertions passed' as result;
