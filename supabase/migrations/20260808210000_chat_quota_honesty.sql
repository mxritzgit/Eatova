-- Chat quota honesty. Two changes:
--
-- 1) get_chat_quota_today: the uid-null branch used to answer with the FULL
--    quota — a sentinel the client would take as a server statement. No
--    context is not a number, so it raises. Only reachable for service_role
--    calls without a user JWT.
--
-- 2) refund_chat_quota: claim_chat_quota reserves the daily slot BEFORE the
--    expensive answer call, so a later edge-function failure burned the slot.
--    The refund returns exactly one slot and clamps at 0, so a refund without
--    a prior claim cannot create a free slot.

create or replace function public.get_chat_quota_today(
  p_daily_limit integer default 5
) returns table (used integer, remaining integer, daily_limit integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'utc')::date;
  v_used  integer;
  v_uid   uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'EX_USER_REQUIRED' using errcode = '22023';
  end if;

  select used_count into v_used
    from public.chat_quota_usage
    where user_id = v_uid and day = v_today;

  v_used      := coalesce(v_used, 0);
  used        := v_used;
  remaining   := greatest(p_daily_limit - v_used, 0);
  daily_limit := p_daily_limit;
  return next;
end;
$$;

-- create or replace keeps the existing grants (authenticated + service_role;
-- anon revoked since 20260609120000) — nothing to re-grant here.

create or replace function public.refund_chat_quota(
  p_user_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'utc')::date;
begin
  if p_user_id is null then
    raise exception 'EX_USER_REQUIRED' using errcode = '22023';
  end if;

  update public.chat_quota_usage
     set used_count = greatest(used_count - 1, 0),
         updated_at = now()
   where user_id = p_user_id and day = v_today;
end;
$$;

-- Like claim_chat_quota: only the edge function (service_role) may refund — a
-- client able to reset its own quota would have no limit.
revoke all on function public.refund_chat_quota(uuid) from public;
revoke all on function public.refund_chat_quota(uuid) from authenticated;
revoke all on function public.refund_chat_quota(uuid) from anon;
grant execute on function public.refund_chat_quota(uuid) to service_role;
