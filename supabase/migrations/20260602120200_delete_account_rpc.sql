-- GDPR Art. 17 / Apple 5.1.1(v): self-service account deletion.
-- delete_account() removes the caller's auth.users row; app tables cascade
-- from auth.users(id). security definer so `authenticated` (table grants only)
-- may delete it; search_path pinned. Only auth.uid()'s own account.

create or replace function public.delete_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from auth.users where id = auth.uid();
end;
$$;

revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
