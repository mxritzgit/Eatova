-- Fix the Edge Function rate limiter: pgcrypto lives in the extensions schema
-- on hosted Supabase, so digest() failed with a public-only search_path.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create or replace function public.consume_edge_rate_limit(
  p_scope text,
  p_subject text,
  p_limit integer,
  p_window_seconds integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_now timestamptz := now();
  v_window_start timestamptz;
  v_subject_hash text;
  v_count integer;
  v_reset_at timestamptz;
begin
  if p_scope is null or length(trim(p_scope)) = 0 or length(p_scope) > 80 then
    raise exception 'invalid rate limit scope';
  end if;
  if p_subject is null or length(trim(p_subject)) = 0 or length(p_subject) > 512 then
    raise exception 'invalid rate limit subject';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 10000 then
    raise exception 'invalid rate limit limit';
  end if;
  if p_window_seconds is null or p_window_seconds < 1 or p_window_seconds > 86400 then
    raise exception 'invalid rate limit window';
  end if;

  v_window_start := to_timestamp(
    floor(extract(epoch from v_now) / p_window_seconds) * p_window_seconds
  );
  v_reset_at := v_window_start + make_interval(secs => p_window_seconds);
  v_subject_hash := encode(digest(p_subject::text, 'sha256'::text), 'hex');

  insert into public.edge_rate_limits (
    scope, subject_hash, window_start, window_seconds, request_count, updated_at
  ) values (
    p_scope, v_subject_hash, v_window_start, p_window_seconds, 1, v_now
  )
  on conflict (scope, subject_hash, window_start, window_seconds)
  do update set
    request_count = public.edge_rate_limits.request_count + 1,
    updated_at = excluded.updated_at
  returning request_count into v_count;

  return jsonb_build_object(
    'allowed', v_count <= p_limit,
    'limit', p_limit,
    'remaining', greatest(p_limit - v_count, 0),
    'resetAt', v_reset_at,
    'windowSeconds', p_window_seconds
  );
end;
$$;

revoke all on function public.consume_edge_rate_limit(text, text, integer, integer)
  from public, anon, authenticated;
grant execute on function public.consume_edge_rate_limit(text, text, integer, integer)
  to service_role;
