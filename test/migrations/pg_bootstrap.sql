-- Supabase stand-in for a plain PostgreSQL, so that supabase/migrations/ can be
-- applied unchanged in CI (see the `rls-postgres` job in
-- .github/workflows/security.yml).
--
-- The migrations rest on four things a bare Postgres does not have: the roles
-- `anon` / `authenticated` / `service_role`, the schema `auth` with the columns
-- of `auth.users` the triggers read, and the functions `auth.uid()` /
-- `auth.jwt()`. Everything here is a MINIMUM — deliberately not a Supabase
-- replica: what the migrations themselves state must be what protects the rows,
-- so this file must add nothing that could do the protecting instead.
--
-- NOT set: `force row level security`. `authenticated` is not the owner of any
-- table here either, so RLS applies to it exactly as it does live. `postgres`
-- stays superuser and bypasses RLS — every assertion therefore runs under
-- `set role`, never as postgres.

-- ---------------------------------------------------------------------------
-- 1) The three PostgREST roles
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    -- Live, service_role carries rolbypassrls; keeping that here is what makes
    -- the seed data below insertable in the first place.
    create role service_role nologin noinherit bypassrls;
  end if;
end $$;

-- Membership so the test session can SET ROLE into each of them.
grant anon, authenticated, service_role to current_user;

-- ---------------------------------------------------------------------------
-- 2) schema auth — only what the migrations touch
-- ---------------------------------------------------------------------------
create schema if not exists auth;

-- Columns per the trigger bodies of handle_new_user_profile() and the backfill
-- in 20260516160000: id, email, raw_user_meta_data.
create table if not exists auth.users (
  id                 uuid primary key default gen_random_uuid(),
  email              text,
  raw_user_meta_data jsonb not null default '{}'::jsonb
);

-- GoTrue puts the verified JWT claims into this GUC; PostgREST sets it per
-- request. `true` as the second argument keeps a missing setting from raising.
create or replace function auth.jwt()
returns jsonb
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), ''),
    '{}'
  )::jsonb;
$$;

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid;
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt()
  to anon, authenticated, service_role;
-- delete_account() deletes from auth.users as the function OWNER, so no grant
-- for authenticated here — that is the point of `security definer`.
grant select, insert, update, delete on auth.users to service_role;
