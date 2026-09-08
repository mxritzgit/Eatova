-- A request can claim before UTC midnight and fail after it. Return the
-- database's claim day so the Edge Function refunds that same row.
-- Deploy this migration before the updated coach-chat handler. Old handlers
-- ignore the extra result field and retain their existing refund RPC until
-- deployment; only the new explicit-day RPC fixes their midnight behavior.

-- PostgreSQL requires a drop to extend a RETURNS TABLE result. The transaction
-- owned by the migration runner keeps replacement and service-only grants
-- atomic. Input arguments stay the same for existing PostgREST callers.
drop function if exists public.claim_chat_quota(uuid, integer);

create or replace function public.claim_chat_quota(
  p_user_id uuid,
  p_daily_limit integer default 5
) returns table (used integer, remaining integer, quota_day date)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'utc')::date;
  v_used integer;
begin
  if p_user_id is null then
    raise exception 'EX_USER_REQUIRED' using errcode = '22023';
  end if;

  insert into public.chat_quota_usage (user_id, day, used_count, updated_at)
    values (p_user_id, v_today, 0, now())
    on conflict (user_id, day) do nothing;

  select used_count into v_used
    from public.chat_quota_usage
   where user_id = p_user_id and day = v_today
   for update;

  if v_used >= p_daily_limit then
    raise exception 'EX_QUOTA_EXCEEDED' using errcode = 'P0001';
  end if;

  update public.chat_quota_usage
     set used_count = used_count + 1,
         updated_at = now()
   where user_id = p_user_id and day = v_today;

  used := v_used + 1;
  remaining := p_daily_limit - used;
  quota_day := v_today;
  return next;
end;
$$;

revoke all on function public.claim_chat_quota(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.claim_chat_quota(uuid, integer)
  to service_role;

create or replace function public.refund_chat_quota_for_day(
  p_user_id uuid,
  p_quota_day date
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user_id is null then
    raise exception 'EX_USER_REQUIRED' using errcode = '22023';
  end if;
  if p_quota_day is null or not isfinite(p_quota_day)
     or p_quota_day > (now() at time zone 'utc')::date then
    raise exception 'EX_QUOTA_DAY_INVALID' using errcode = '22023';
  end if;

  update public.chat_quota_usage
     set used_count = greatest(used_count - 1, 0),
         updated_at = now()
   where user_id = p_user_id and day = p_quota_day;
end;
$$;

revoke all on function public.refund_chat_quota_for_day(uuid, date)
  from public, anon, authenticated;
grant execute on function public.refund_chat_quota_for_day(uuid, date)
  to service_role;

comment on function public.refund_chat_quota_for_day(uuid, date) is
  'Returns one slot to the UTC quota_day returned by claim_chat_quota. '
  'The Edge Function must refund each confirmed claim at most once.';
comment on function public.refund_chat_quota(uuid) is
  'Legacy current-day refund for older coach-chat deployments. New callers '
  'must use refund_chat_quota_for_day with the day returned by their claim.';

notify pgrst, 'reload schema';
