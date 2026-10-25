-- One account per mailbox (2026-10-25). GoTrue matches addresses exactly, so
-- moritz.gietl@gmail.com and moritzgietl@gmail.com (one Gmail mailbox) could
-- each hold an account. The Before User Created hook below rejects such an
-- alias with GoTrue's own duplicate sentence (the app shows its neutral hint);
-- the BEFORE triggers are the guarantee for races, admin-created users, email
-- changes and confirming a second alias. Existing rows are not touched.
-- The hook is enabled separately in the Auth config (docs/OPERATIONS.md).

-- lower(btrim()), split at the last @, one trailing dot off the domain,
-- googlemail.com -> gmail.com, dots out of a gmail local part, +tag cut for
-- every domain. An empty result keeps the unstripped local part.
create or replace function public.email_canonical_key(address text)
returns text
language sql
immutable
strict
parallel safe
set search_path = ''
as $$
  select case
    when p.e = '' then null
    when p.loc is null or p.loc = '' or p.dom is null or p.dom = '' then p.e
    else coalesce(nullif(
           case when p.dom = 'gmail.com'
                then replace(split_part(p.loc, '+', 1), '.', '')
                else split_part(p.loc, '+', 1) end, ''), p.loc)
         || '@' || p.dom
  end
  from (
    select a.e,
           substring(a.e from '^(.*)@[^@]*$') as loc,
           case regexp_replace(substring(a.e from '@([^@]*)$'), '\.$', '')
             when 'googlemail.com' then 'gmail.com'
             else regexp_replace(substring(a.e from '@([^@]*)$'), '\.$', '')
           end as dom
    from (select lower(btrim(address)) as e) a
  ) p;
$$;

-- Another account holds the key: confirmed, or (signup only) created within
-- the last hour. Unconfirmed squats therefore block for at most an hour.
create or replace function public.email_alias_holder_exists(
  p_key text, p_self uuid, p_count_fresh boolean)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
    from auth.users u
    where u.id is distinct from p_self
      and public.email_canonical_key(u.email) = p_key
      and (u.email_confirmed_at is not null
           or (p_count_fresh and u.created_at > now() - interval '1 hour'))
  );
$$;

create or replace function public.auth_before_user_created(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  email_key text;
  taken boolean := false;
begin
  -- Fails OPEN on internal errors: GoTrue would otherwise refuse every signup.
  -- The insert trigger still blocks aliases. Log the SQLSTATE only.
  begin
    email_key := public.email_canonical_key(event #>> '{user,email}');
    if email_key is not null then
      taken := public.email_alias_holder_exists(
        email_key, null,
        coalesce(event #>> '{user,app_metadata,provider}', 'email') = 'email');
    end if;
  exception when others then
    raise warning 'auth_before_user_created: alias check skipped (%)', sqlstate;
    return '{}'::jsonb;
  end;
  if taken then
    -- GoTrue's own duplicate sentence; auth_screen.dart maps it to the
    -- neutral sign-in hint in every shipped build.
    return jsonb_build_object('error', jsonb_build_object(
      'http_code', 422, 'message', 'User already registered'));
  end if;
  -- Further signup checks (docs/PREMIUM.md 7.7 point 2) go here.
  return '{}'::jsonb;
end;
$$;

create or replace function public.guard_auth_user_email_alias()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  address text;
  count_fresh boolean := false;
  email_key text;
  taken boolean := false;
begin
  begin
    if tg_op = 'INSERT' then
      address := new.email;
      count_fresh := new.email_confirmed_at is null
        and coalesce(new.raw_app_meta_data ->> 'provider', 'email') = 'email';
    elsif new.email_change is distinct from old.email_change
          and coalesce(new.email_change, '') <> '' then
      address := new.email_change;
      count_fresh := true;
    elsif new.email is distinct from old.email
          or (old.email_confirmed_at is null and new.email_confirmed_at is not null) then
      address := new.email;
    end if;
    email_key := public.email_canonical_key(address);
    if email_key is not null then
      -- Serialises same-key rows until commit: two concurrent alias signups
      -- cannot both pass.
      perform pg_advisory_xact_lock(hashtextextended('email_key:' || email_key, 0));
      taken := public.email_alias_holder_exists(email_key, new.id, count_fresh);
    end if;
  exception when others then
    raise warning 'guard_auth_user_email_alias: alias check skipped (%)', sqlstate;
    return new;
  end;
  if taken then
    -- No address in the text: GoTrue's legacy error path can expose it.
    raise exception 'email alias of an existing account';
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_email_alias_insert on auth.users;
create trigger on_auth_user_email_alias_insert
  before insert on auth.users
  for each row
  when (new.email is not null)
  execute function public.guard_auth_user_email_alias();

drop trigger if exists on_auth_user_email_alias_update on auth.users;
create trigger on_auth_user_email_alias_update
  before update of email, email_change, email_confirmed_at on auth.users
  for each row
  when (new.email is distinct from old.email
        or new.email_change is distinct from old.email_change
        or (old.email_confirmed_at is null and new.email_confirmed_at is not null))
  execute function public.guard_auth_user_email_alias();

revoke execute on function public.email_canonical_key(text) from public, anon, authenticated;
grant execute on function public.email_canonical_key(text) to service_role;
revoke execute on function public.email_alias_holder_exists(text, uuid, boolean) from public, anon, authenticated;
grant execute on function public.email_alias_holder_exists(text, uuid, boolean) to service_role;
revoke execute on function public.guard_auth_user_email_alias() from public, anon, authenticated;
grant execute on function public.guard_auth_user_email_alias() to service_role;
revoke execute on function public.auth_before_user_created(jsonb) from public, anon, authenticated;
grant execute on function public.auth_before_user_created(jsonb) to supabase_auth_admin, service_role;
-- GoTrue resolves "public"."auth_before_user_created" as supabase_auth_admin.
grant usage on schema public to supabase_auth_admin;
