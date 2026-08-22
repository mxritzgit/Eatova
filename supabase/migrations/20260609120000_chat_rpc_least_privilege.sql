-- Least-privilege hardening of the chat session RPCs (Audit 2026-06-09),
-- additive and idempotent. Fixes:
--
--  MEDIUM: ensure_default_chat_session(uuid) was PUBLIC-executable and took
--    any p_user_id, whose coalesce path bypassed the null guard, so an anon
--    caller could insert a chat_sessions row into a foreign account.
--
--  LOW: 5 further chat RPCs kept residual PUBLIC EXECUTE, because
--    20260517220000_security_hardening.sql revoked only from anon and
--    authenticated.
--
-- Deliberately unchanged: touch_chat_session/claim_chat_quota get NO
-- in-function auth.uid() filter. They run only via service_role, where a
-- filter would break the edge-function path; the grant is their safeguard.

-- ---------------------------------------------------------------------------
-- 1) Revoke PUBLIC/anon EXECUTE; keep authenticated/service_role explicitly
-- ---------------------------------------------------------------------------
revoke execute on function public.ensure_default_chat_session(uuid) from public, anon;
revoke execute on function public.create_chat_session(text)         from public, anon;
revoke execute on function public.delete_chat_session(uuid)         from public, anon;
revoke execute on function public.rename_chat_session(uuid, text)   from public, anon;
revoke execute on function public.list_chat_sessions()              from public, anon;
revoke execute on function public.get_chat_quota_today(integer)     from public, anon;

grant execute on function public.ensure_default_chat_session(uuid) to authenticated, service_role;
grant execute on function public.create_chat_session(text)         to authenticated, service_role;
grant execute on function public.delete_chat_session(uuid)         to authenticated, service_role;
grant execute on function public.rename_chat_session(uuid, text)   to authenticated, service_role;
grant execute on function public.list_chat_sessions()              to authenticated, service_role;
grant execute on function public.get_chat_quota_today(integer)     to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2) In-function guard: a logged-in client must not point p_user_id at a
--    foreign user. service_role has auth.uid() = null and may set it freely.
-- ---------------------------------------------------------------------------
create or replace function public.ensure_default_chat_session(
  p_user_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
  v_id  uuid;
begin
  if p_user_id is not null
     and auth.uid() is not null
     and p_user_id <> auth.uid() then
    raise exception 'EX_FORBIDDEN' using errcode = '42501';
  end if;

  v_uid := coalesce(p_user_id, auth.uid());
  if v_uid is null then
    raise exception 'EX_USER_REQUIRED' using errcode = '22023';
  end if;

  select id into v_id
    from public.chat_sessions
   where user_id = v_uid
   order by last_message_at desc
   limit 1;

  if v_id is null then
    insert into public.chat_sessions (user_id, title)
      values (v_uid, 'Neue Unterhaltung')
      returning id into v_id;
  end if;

  return v_id;
end;
$$;

-- create or replace preserves the ACL, but pin it down anyway (idempotent).
revoke execute on function public.ensure_default_chat_session(uuid) from public, anon;
grant execute on function public.ensure_default_chat_session(uuid) to authenticated, service_role;
