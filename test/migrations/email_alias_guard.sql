-- One account per mailbox (20261027100000): the canonical key, the Before User
-- Created hook called as GoTrue's role, the BEFORE triggers on auth.users and
-- the EXECUTE grants. The insert race is email_alias_concurrency.py. Runs
-- inside rls_cross_user.sql; all changes roll back.
\set ON_ERROR_STOP on
begin;
create function pg_temp.require(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Assertion failed: %',label; end if; end;
$$;
grant execute on function pg_temp.require(boolean,text) to supabase_auth_admin;
-- SQLSTATE of [q], or 'ok'; the failed statement rolls back on its own.
create function pg_temp.sqlstate_of(q text) returns text language plpgsql as $$
begin execute q; return 'ok'; exception when others then return sqlstate; end;
$$;

do $$
declare r record;
begin
  for r in select * from (values
    (' Moritz.Gietl@GMAIL.com ', 'moritzgietl@gmail.com'),
    ('moritzgietl@googlemail.com', 'moritzgietl@gmail.com'),
    ('moritz.gietl+x@gmail.com', 'moritzgietl@gmail.com'),
    ('a.b@outlook.com', 'a.b@outlook.com'),
    ('a.b+t@outlook.com', 'a.b@outlook.com'),
    ('+x@gmail.com', '+x@gmail.com'),
    ('x@gmail.com.', 'x@gmail.com'),
    ('no-at', 'no-at'),
    ('  ', null)) v(address, expected) loop
    if public.email_canonical_key(r.address) is distinct from r.expected then
      raise exception 'Assertion failed: key of "%" is %, expected %',
        r.address, public.email_canonical_key(r.address), r.expected;
    end if;
  end loop;
end $$;

-- H confirmed, F pending for minutes, S pending for two hours, O unrelated.
insert into auth.users(id,email,email_confirmed_at,created_at,raw_app_meta_data) values
 ('78000000-0000-4000-8000-000000000001','alias.holder@gmail.com',now()-interval '2 days',
   now()-interval '2 days','{"provider":"email"}'),
 ('78000000-0000-4000-8000-000000000002','fresh.pending@gmail.com',null,now(),'{"provider":"email"}'),
 ('78000000-0000-4000-8000-000000000003','stale.pending@gmail.com',null,now()-interval '2 hours',
   '{"provider":"email"}'),
 ('78000000-0000-4000-8000-000000000004','other.person@example.invalid',now(),now(),'{"provider":"email"}');

-- GoTrue calls the hook as supabase_auth_admin: this proves its EXECUTE and
-- its USAGE on schema public.
set local role supabase_auth_admin;
select pg_temp.require(
  public.auth_before_user_created('{"user":{"email":"aliasholder+new@googlemail.com","app_metadata":{"provider":"email"}}}')
    = '{"error":{"http_code":422,"message":"User already registered"}}'::jsonb
  and public.auth_before_user_created('{"user":{"email":"aliasholder@gmail.com","app_metadata":{"provider":"google"}}}')
    = '{"error":{"http_code":422,"message":"User already registered"}}'::jsonb,
  'a confirmed holder rejects an alias with GoTrue''s duplicate answer');
select pg_temp.require(
  public.auth_before_user_created('{"user":{"email":"freshpending@gmail.com","app_metadata":{"provider":"email"}}}')
    = '{"error":{"http_code":422,"message":"User already registered"}}'::jsonb,
  'a fresh unconfirmed holder rejects an email signup');
select pg_temp.require(
  public.auth_before_user_created('{"user":{"email":"freshpending@gmail.com","app_metadata":{"provider":"google"}}}')
    = '{}'::jsonb,
  'a fresh unconfirmed holder does not block Google');
select pg_temp.require(
  public.auth_before_user_created('{"user":{"email":"stalepending@gmail.com","app_metadata":{"provider":"email"}}}')
    = '{}'::jsonb,
  'an unconfirmed holder older than an hour does not block');
select pg_temp.require(
  public.auth_before_user_created('{"user":{"phone":"4915100000000","app_metadata":{"provider":"phone"}}}')
    = '{}'::jsonb
  and public.auth_before_user_created('{"user":{"email":"someone.new@gmail.com","app_metadata":{"provider":"email"}}}')
    = '{}'::jsonb,
  'no email and an unrelated address are allowed');
reset role;

select pg_temp.require(pg_temp.sqlstate_of(
  $q$insert into auth.users(id,email) values ('78000000-0000-4000-8000-000000000005','aliasholder+2@gmail.com')$q$)
  = 'P0001','an alias insert raises');
-- Google inserts unconfirmed and confirms in the same transaction; a pending
-- squat blocks neither step.
insert into auth.users(id,email,raw_app_meta_data) values
 ('78000000-0000-4000-8000-000000000006','freshpending@gmail.com','{"provider":"google"}');
update auth.users set email_confirmed_at=now() where id='78000000-0000-4000-8000-000000000006';
select pg_temp.require(pg_temp.sqlstate_of(
  $q$update auth.users set email_change='aliasholder+o@gmail.com' where id='78000000-0000-4000-8000-000000000004'$q$)
  = 'P0001','an email change to another account''s alias raises');
update auth.users set email_change='alias.holder+own@gmail.com' where id='78000000-0000-4000-8000-000000000001';
select pg_temp.require((select email_change='alias.holder+own@gmail.com' from auth.users
  where id='78000000-0000-4000-8000-000000000001'),'an email change to an alias of the own address passes');
-- Batch farming: the stale pending alias cannot be confirmed next to a
-- confirmed one.
insert into auth.users(id,email,email_confirmed_at) values
 ('78000000-0000-4000-8000-000000000007','stalepending+b@gmail.com',now());
select pg_temp.require(pg_temp.sqlstate_of(
  $q$update auth.users set email_confirmed_at=now() where id='78000000-0000-4000-8000-000000000003'$q$)
  = 'P0001','confirming a second alias raises');

-- A pair that predates the guard keeps working.
set local session_replication_role = replica;
insert into auth.users(id,email,email_confirmed_at) values
 ('78000000-0000-4000-8000-000000000008','dup.pair@gmail.com',now()),
 ('78000000-0000-4000-8000-000000000009','duppair@gmail.com',now());
set local session_replication_role = origin;
select rlstest.erwarte_zeilen(
  $q$update auth.users set email=email, raw_user_meta_data='{"display_name":"Pair"}'
     where id in ('78000000-0000-4000-8000-000000000008','78000000-0000-4000-8000-000000000009')$q$,
  2,'an existing duplicate pair accepts an unrelated update');

select pg_temp.require(not exists(
  select 1 from (values ('anon'),('authenticated')) r(role)
  cross join (values ('public.email_canonical_key(text)'),
    ('public.email_alias_holder_exists(text,uuid,boolean)'),
    ('public.guard_auth_user_email_alias()'),
    ('public.auth_before_user_created(jsonb)')) f(fn)
  where has_function_privilege(r.role,f.fn,'execute')),'clients execute none of the four functions');
select pg_temp.require(has_function_privilege('supabase_auth_admin','public.auth_before_user_created(jsonb)','execute'),
  'GoTrue can execute the hook');
rollback;
select 'Email alias guard: all assertions passed' as result;
