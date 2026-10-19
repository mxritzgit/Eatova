-- AI consent log and answer reports (20261019100000): own rows only,
-- append-only, owner and timestamp from defaults (column grants), closed
-- codes, the per-day bound and the account deletion cascade. Runs inside
-- rls_cross_user.sql (needs its rlstest functions); all changes roll back.
\set ON_ERROR_STOP on
begin;
create function pg_temp.require(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Assertion failed: %',label; end if; end;
$$;
grant execute on function pg_temp.require(boolean,text) to authenticated;
insert into auth.users(id,email) values
 ('77000000-0000-4000-8000-000000000001','ai-a@example.invalid'),
 ('77000000-0000-4000-8000-000000000002','ai-b@example.invalid');

-- B logs a grant and a report.
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"77000000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select rlstest.erwarte_zeilen($q$insert into public.ai_consents(version,granted,health_data) values (1,true,true)$q$,1,'B grants');
select rlstest.erwarte_zeilen($q$insert into public.ai_reports(message_id,session_id,target,reason)
  values ('b-answer','77000000-0000-4000-8000-0000000000bb','answer','harmful')$q$,1,'B reports');

-- A: own rows only, the owner comes from the session.
select set_config('request.jwt.claims','{"sub":"77000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select rlstest.erwarte_zeilen($q$insert into public.ai_consents(version,granted,health_data) values (1,true,true)$q$,1,'A grants');
select rlstest.erwarte_zeilen($q$insert into public.ai_consents(version,granted,health_data) values (1,false,false)$q$,1,'A withdraws');
select rlstest.erwarte_zeilen($q$insert into public.ai_reports(message_id,target,reason) values ('local-r-1','recipe_image','other')$q$,1,'A reports a picture');
select rlstest.erwarte_zeilen('select * from public.ai_consents',2,'A reads only its own consents');
select rlstest.erwarte_zeilen('select * from public.ai_reports',1,'A reads only its own report');
select rlstest.erwarte_zeilen($q$select * from public.ai_consents where user_id='77000000-0000-4000-8000-000000000002'$q$,0,'foreign consents');
select rlstest.erwarte_zeilen($q$select * from public.ai_reports where user_id='77000000-0000-4000-8000-000000000002'$q$,0,'foreign reports');
select pg_temp.require((select bool_and(user_id=auth.uid() and created_at is not null) from public.ai_consents),
  'owner and timestamp from defaults');

-- Column grants: no chosen owner, no backdating; append-only.
select rlstest.erwarte_ablehnung($q$insert into public.ai_consents(user_id,version,granted,health_data)
  values ('77000000-0000-4000-8000-000000000001',1,true,true)$q$,'consent with a chosen owner');
select rlstest.erwarte_ablehnung($q$insert into public.ai_consents(user_id,version,granted,health_data)
  values ('77000000-0000-4000-8000-000000000002',1,false,false)$q$,'consent for B');
select rlstest.erwarte_ablehnung($q$insert into public.ai_consents(version,granted,health_data,created_at)
  values (1,true,true,'2020-01-01')$q$,'backdated consent');
select rlstest.erwarte_ablehnung('update public.ai_consents set granted=true','consent update');
select rlstest.erwarte_ablehnung('delete from public.ai_consents','consent delete');
select rlstest.erwarte_ablehnung($q$insert into public.ai_reports(user_id,message_id,reason)
  values ('77000000-0000-4000-8000-000000000002','x','other')$q$,'report for B');
select rlstest.erwarte_ablehnung($q$insert into public.ai_reports(message_id,reason,created_at)
  values ('x','other','2020-01-01')$q$,'backdated report');
select rlstest.erwarte_ablehnung($q$update public.ai_reports set reason='other'$q$,'report update');
select rlstest.erwarte_ablehnung('delete from public.ai_reports','report delete');

-- Checks: health data only with a grant, versions, closed codes, ids only.
select rlstest.erwarte_sqlstate($q$insert into public.ai_consents(version,granted,health_data) values (1,false,true)$q$,'23514','health data without a grant');
select rlstest.erwarte_sqlstate($q$insert into public.ai_consents(version,granted,health_data) values (0,true,true)$q$,'23514','version 0');
select rlstest.erwarte_sqlstate($q$insert into public.ai_consents(version,granted,health_data) values (1,null,false)$q$,'23502','missing decision');
select rlstest.erwarte_sqlstate($q$insert into public.ai_reports(message_id,reason) values ('x','spam')$q$,'23514','unknown reason');
select rlstest.erwarte_sqlstate($q$insert into public.ai_reports(message_id,target,reason) values ('x','video','other')$q$,'23514','unknown target');
select rlstest.erwarte_sqlstate($q$insert into public.ai_reports(message_id,reason) values ('Das ist die Antwort','other')$q$,'23514','content as message id');
select rlstest.erwarte_sqlstate(format('insert into public.ai_reports(message_id,reason) values (%L,%L)',repeat('a',65),'other'),'23514','message id too long');
select rlstest.erwarte_sqlstate($q$insert into public.ai_reports(message_id,session_id,reason) values ('x','not-a-uuid','other')$q$,'22P02','session id not a uuid');

-- The daily bound: A has 2 consents today, 18 more fit, the 21st fails with
-- 22023; reports: 1 today, 29 more fit, the 31st fails.
do $$
begin
  for i in 1..18 loop
    insert into public.ai_consents(version,granted,health_data) values (1,true,true);
  end loop;
  for i in 1..29 loop
    insert into public.ai_reports(message_id,reason) values ('m' || i,'incorrect');
  end loop;
end $$;
select rlstest.erwarte_sqlstate($q$insert into public.ai_consents(version,granted,health_data) values (1,false,false)$q$,'22023','21st consent today');
select rlstest.erwarte_sqlstate($q$insert into public.ai_reports(message_id,reason) values ('m31','other')$q$,'22023','31st report today');

-- Yesterday's rows do not count against today.
reset role;
update public.ai_consents set created_at = created_at - interval '1 day'
  where user_id='77000000-0000-4000-8000-000000000001';
set local role authenticated;
select rlstest.erwarte_zeilen($q$insert into public.ai_consents(version,granted,health_data) values (1,false,false)$q$,1,'a new day');

-- B's bound is its own.
select set_config('request.jwt.claims','{"sub":"77000000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select rlstest.erwarte_zeilen($q$insert into public.ai_reports(message_id,reason) values ('b-2','other')$q$,1,'B unaffected by A');

-- anon reaches neither table.
set local role anon;
select rlstest.erwarte_ablehnung('select * from public.ai_consents','anon reads consents');
select rlstest.erwarte_ablehnung('select * from public.ai_reports','anon reads reports');
select rlstest.erwarte_ablehnung($q$insert into public.ai_consents(version,granted,health_data) values (1,true,true)$q$,'anon consents');
select rlstest.erwarte_ablehnung($q$insert into public.ai_reports(message_id,reason) values ('x','other')$q$,'anon reports');

-- An unattributable row is refused by the bound, not let through.
reset role;
select set_config('request.jwt.claims','',true);
set local role service_role;
select rlstest.erwarte_sqlstate($q$insert into public.ai_reports(message_id,reason) values ('x','other')$q$,'22023','report without owner');

-- Account deletion removes both logs.
reset role;
delete from auth.users where id='77000000-0000-4000-8000-000000000002';
select pg_temp.require(
  not exists(select 1 from public.ai_consents where user_id='77000000-0000-4000-8000-000000000002')
  and not exists(select 1 from public.ai_reports where user_id='77000000-0000-4000-8000-000000000002'),
  'deleted account leaves no consent or report');
select pg_temp.require(
  exists(select 1 from public.ai_consents where user_id='77000000-0000-4000-8000-000000000001'),
  'the other account keeps its log');
rollback;
