-- BE-2 (2026-10-11): auth metadata names longer than profiles_display_name_length_check
-- (80 characters) aborted the auth.users insert, so GoTrue answered 500 and the
-- account could never sign in. The bootstrap trigger now clamps the name.
-- Runs inside rls_cross_user.sql; all changes roll back.
\set ON_ERROR_STOP on
begin;
create function pg_temp.require(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Assertion failed: %',label; end if; end;
$$;

-- GoTrue inserts as its own admin role; the trigger runs as the function owner.
insert into auth.users(id,email,raw_user_meta_data) values
 ('75000000-0000-4000-8000-000000000001','long@example.invalid',
   jsonb_build_object('full_name',repeat('Maximilian ',12))),
 ('75000000-0000-4000-8000-000000000002','emoji@example.invalid',
   jsonb_build_object('name',repeat(U&'\+01F600',75)||repeat(U&'\+01F468\200D\+01F469\200D\+01F467',10))),
 ('75000000-0000-4000-8000-000000000003','blank@example.invalid',
   jsonb_build_object('display_name','   ','full_name','Ignored Full Name')),
 ('75000000-0000-4000-8000-000000000004','none@example.invalid','{}'),
 ('75000000-0000-4000-8000-000000000005','exact@example.invalid',
   jsonb_build_object('display_name','  '||repeat('a',80)||'  '));

select pg_temp.require((select display_name=left(repeat('Maximilian ',12),80) and char_length(display_name)=80
  from public.profiles where id='75000000-0000-4000-8000-000000000001'),'long full_name clamped to 80');
select pg_temp.require((select char_length(display_name)=80 and display_name=left(repeat(U&'\+01F600',75)||
    repeat(U&'\+01F468\200D\+01F469\200D\+01F467',10),80)
  from public.profiles where id='75000000-0000-4000-8000-000000000002'),'emoji name clamped to 80 characters');
-- An explicit display_name still wins over full_name; blank collapses to ''.
select pg_temp.require((select display_name='' from public.profiles where id='75000000-0000-4000-8000-000000000003'),
  'blank display_name stays empty');
select pg_temp.require((select display_name='' from public.profiles where id='75000000-0000-4000-8000-000000000004'),
  'no metadata name gives empty name');
select pg_temp.require((select display_name=repeat('a',80) from public.profiles where id='75000000-0000-4000-8000-000000000005'),
  'surrounding spaces do not count toward the limit');

-- The email-change trigger runs the same body: long metadata must not block it,
-- and a blank name keeps the stored one.
update auth.users set raw_user_meta_data=jsonb_build_object('full_name',repeat('Z',200))
  where id='75000000-0000-4000-8000-000000000004';
update auth.users set email='none-new@example.invalid' where id='75000000-0000-4000-8000-000000000004';
select pg_temp.require((select email='none-new@example.invalid' and display_name=repeat('Z',80)
  from public.profiles where id='75000000-0000-4000-8000-000000000004'),'email change with long metadata syncs');
update auth.users set raw_user_meta_data=jsonb_build_object('display_name',' ')
  where id='75000000-0000-4000-8000-000000000001';
update auth.users set email='long-new@example.invalid' where id='75000000-0000-4000-8000-000000000001';
select pg_temp.require((select email='long-new@example.invalid' and display_name=left(repeat('Maximilian ',12),80)
  from public.profiles where id='75000000-0000-4000-8000-000000000001'),'blank metadata keeps the stored name');
rollback;
select 'Profile signup names: all assertions passed' as result;
