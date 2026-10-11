-- BE-2 (2026-10-11): clamp the auth metadata name to the profiles limit.
--
-- handle_new_user_profile() copied display_name / full_name / name / user_name
-- unclamped, but profiles_display_name_length_check allows 80 characters. A
-- longer name (e.g. a Google full_name) aborted the auth.users insert, GoTrue
-- answered 500 "Database error saving new user", and the account could never
-- sign in. The same body runs on email changes (on_auth_user_email_updated,
-- 20260818120000), so those failed for such metadata too.
--
-- Now the chosen name is btrim()med and cut to 80 characters (code points, as
-- char_length counts them). The key precedence is unchanged; a blank name
-- becomes '' and, on the upsert path, still keeps the stored name. Same
-- security definer, search_path, triggers and grants. Idempotent.

create or replace function public.handle_new_user_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, display_name)
  values (
    new.id,
    new.email,
    left(btrim(coalesce(
      new.raw_user_meta_data ->> 'display_name',
      new.raw_user_meta_data ->> 'full_name',
      new.raw_user_meta_data ->> 'name',
      new.raw_user_meta_data ->> 'user_name',
      ''
    )), 80)
  )
  on conflict (id) do update set
    email = excluded.email,
    display_name = coalesce(nullif(excluded.display_name, ''), public.profiles.display_name),
    updated_at = now();
  return new;
end;
$$;

revoke execute on function public.handle_new_user_profile() from public, anon, authenticated;
grant execute on function public.handle_new_user_profile() to service_role;
