-- Security hardening follow-up (audit 2026-06-03). Additive and idempotent.
--
-- 1) delete_account(): explicit auth.uid() guard (EX_USER_REQUIRED), the only
--    security-definer RPC that lacked one. Defense in depth; behaviour for
--    real authenticated calls is unchanged.
--
-- 2) touch_chat_session(uuid): explicit `revoke ... from authenticated`. The
--    function is service-role-only but relied on the global revoke in
--    20260517220000_security_hardening.sql, so an out-of-order apply would
--    briefly expose it.

create or replace function public.delete_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'EX_USER_REQUIRED' using errcode = '22023';
  end if;
  delete from auth.users where id = auth.uid();
end;
$$;

revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;

revoke execute on function public.touch_chat_session(uuid)
  from public, anon, authenticated;
grant execute on function public.touch_chat_session(uuid) to service_role;
