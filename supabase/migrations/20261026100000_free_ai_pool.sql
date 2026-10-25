-- Free AI pool: Free accounts share their own daily provider pool, the global
-- ceilings drop to pre-launch values, and the Edge Function limiter can hand
-- back a slot that never reached the provider (docs/PREMIUM.md section 7,
-- 2026-10-25).
--
--   ai_provider_limits.daily_free_call_limit
--                                calls all non-Premium accounts together may
--                                reserve per UTC day (150). 0 is the Free
--                                kill switch: Premium keeps running.
--   ai_provider_daily_usage.free_calls
--                                today's reservations of those accounts,
--                                a part of calls.
--   reserve_ai_provider_call     20261025100000 with the pool: the plan is
--                                resolved once per request, a picture needs a
--                                plan that includes it, and a budget denial
--                                names its scope (all, images, plan, free,
--                                account).
--   release_edge_rate_limit      takes one request back from one limiter
--                                bucket; the AI functions call it when the
--                                first provider reservation is denied, so a
--                                capacity denial costs an honest user no
--                                daily slot.
--
-- Why: the per-account Free numbers do not bound a farm of free accounts,
-- and the one shared ceiling let Free use up Premium's calls. Free and the
-- whole day are now bounded on their own; pictures stay Premium only.
--
-- Backward compatible, so it goes live before the new handlers: deployed
-- handlers read only allowed and reason, `scope` is an extra key on a
-- budget_exhausted denial, the new columns have defaults, and nothing calls
-- the new RPC yet. The lower Free tier limits apply at once, since every
-- handler reads plan_tiers per request. Idempotent.

alter table public.ai_provider_limits
  add column if not exists daily_free_call_limit integer not null default 150
    check (daily_free_call_limit between 0 and 100000);

alter table public.ai_provider_daily_usage
  add column if not exists free_calls integer not null default 0
    check (free_calls >= 0);

comment on column public.ai_provider_limits.daily_free_call_limit is
  'Calls all non-Premium accounts together may reserve per UTC day, inside '
  'daily_call_limit. 0 stops Free AI only.';
comment on column public.ai_provider_daily_usage.free_calls is
  'Reservations of non-Premium accounts on that day, counted in calls as well.';

create or replace function public.reserve_ai_provider_call(p_user_id uuid, p_operation text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limits public.ai_provider_limits%rowtype;
  v_day date;
  v_calls integer;
  v_images integer;
  v_free_calls integer;
  v_user_calls integer;
  v_new_day boolean;
  v_reason text;
  v_scope text;
  v_plan jsonb;
  v_free boolean;
  v_image boolean := p_operation = 'coach_image';
begin
  if p_user_id is null or p_operation is null or p_operation not in
    ('coach_classifier', 'coach_answer', 'coach_recipe', 'coach_plan', 'coach_image', 'analyze_meal') then
    raise exception 'invalid provider budget request' using errcode = '22023';
  end if;
  if not exists(select 1 from auth.users where id = p_user_id) then
    raise exception 'invalid provider budget request' using errcode = '22023';
  end if;
  -- The same lock serializes cleanup, budget checks and reservations.
  select * into v_limits from public.ai_provider_limits where singleton for update;
  if not found then
    raise exception 'provider budget configuration unavailable' using errcode = '55000';
  end if;
  -- Derive the day after waiting for the lock, including at UTC midnight.
  v_day := (clock_timestamp() at time zone 'UTC')::date;
  select calls, image_calls, free_calls into v_calls, v_images, v_free_calls
    from public.ai_provider_daily_usage where usage_date = v_day;
  v_new_day := not found;
  if not v_limits.enabled or
    (p_operation = 'analyze_meal' and not v_limits.analysis_enabled) or
    (p_operation <> 'analyze_meal' and not v_limits.coach_enabled) or
    (v_image and not v_limits.images_enabled) then
    v_reason := 'disabled';
  else
    v_plan := public.resolve_plan(p_user_id);
    v_free := (v_plan ->> 'tier') is distinct from 'premium';
    v_calls := coalesce(v_calls, 0);
    v_images := coalesce(v_images, 0);
    v_free_calls := coalesce(v_free_calls, 0);
    select calls into v_user_calls from public.ai_provider_user_usage
      where user_id = p_user_id and usage_date = v_day;
    v_user_calls := coalesce(v_user_calls, 0);
    -- The first ceiling reached names the scope the client shows.
    if v_calls >= v_limits.daily_call_limit then
      v_scope := 'all';
    elsif v_image and v_images >= v_limits.daily_image_limit then
      v_scope := 'images';
    elsif v_image and (v_plan ->> 'recipe_picture')::boolean is not true then
      v_scope := 'plan';
    elsif v_free and v_free_calls >= v_limits.daily_free_call_limit then
      v_scope := 'free';
    elsif v_user_calls >= least(v_limits.daily_user_limit,
        (v_plan ->> 'provider_calls_daily')::integer) then
      v_scope := 'account';
    end if;
    if v_scope is not null then
      v_reason := 'budget_exhausted';
    else
      -- Preserve the original FK-before-cleanup lock order for allowed calls.
      insert into public.ai_provider_user_usage (user_id, usage_date, calls)
        values (p_user_id, v_day, 1)
        on conflict (user_id, usage_date) do update set calls = ai_provider_user_usage.calls + 1;
      insert into public.ai_provider_daily_usage (usage_date, calls, image_calls, free_calls)
        values (v_day, 1, case when v_image then 1 else 0 end, case when v_free then 1 else 0 end)
        on conflict (usage_date) do update set
          calls = ai_provider_daily_usage.calls + 1,
          image_calls = ai_provider_daily_usage.image_calls + excluded.image_calls,
          free_calls = ai_provider_daily_usage.free_calls + excluded.free_calls;
    end if;
  end if;
  if v_new_day then
    -- Cleanup is request-driven; it also runs when the request is denied.
    delete from public.ai_provider_user_usage where usage_date < v_day - 30;
    delete from public.ai_provider_daily_usage where usage_date < v_day - 30;
  end if;
  if v_scope is not null then
    return jsonb_build_object('allowed', false, 'reason', v_reason, 'scope', v_scope);
  end if;
  return jsonb_build_object('allowed', v_reason is null, 'reason', coalesce(v_reason, 'allowed'));
end;
$$;

comment on function public.reserve_ai_provider_call(uuid, text) is
  'Atomically spends one global, account and (non-Premium) Free-pool call before '
  'provider execution. No refund API; not a currency budget.';

revoke all on function public.reserve_ai_provider_call(uuid, text) from public, anon, authenticated;
grant execute on function public.reserve_ai_provider_call(uuid, text) to service_role;

-- Takes back one request that consume_edge_rate_limit(s) counted in this
-- bucket. Same validation and subject hashing as the limiter; the window
-- must be one the limiter can have produced (aligned, already started).
-- Never below zero; false when no bucket changed.
create or replace function public.release_edge_rate_limit(
  p_scope text,
  p_subject text,
  p_window_start timestamptz,
  p_window_seconds integer
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_subject_hash text;
begin
  if p_scope is null or length(trim(p_scope)) = 0 or length(p_scope) > 80 then
    raise exception 'invalid rate limit scope';
  end if;
  if p_subject is null or length(trim(p_subject)) = 0 or length(p_subject) > 512 then
    raise exception 'invalid rate limit subject';
  end if;
  if p_window_seconds is null or p_window_seconds < 1 or p_window_seconds > 86400 then
    raise exception 'invalid rate limit window';
  end if;
  if p_window_start is null or p_window_start > now() or p_window_start <> to_timestamp(
      floor(extract(epoch from p_window_start) / p_window_seconds) * p_window_seconds) then
    raise exception 'invalid rate limit window start';
  end if;

  v_subject_hash := encode(digest(p_subject::text, 'sha256'::text), 'hex');

  update public.edge_rate_limits
    set request_count = request_count - 1,
        updated_at = now()
    where scope = p_scope
      and subject_hash = v_subject_hash
      and window_start = p_window_start
      and window_seconds = p_window_seconds
      and request_count > 0;
  return found;
end;
$$;

comment on function public.release_edge_rate_limit(text, text, timestamptz, integer) is
  'Gives back one counted request of a limiter bucket, never below zero. Only '
  'for a request that never reached the provider (docs/PREMIUM.md 7).';

revoke all on function public.release_edge_rate_limit(text, text, timestamptz, integer)
  from public, anon, authenticated;
grant execute on function public.release_edge_rate_limit(text, text, timestamptz, integer)
  to service_role;

-- Fewer Free features per account. Without pictures a Coach question costs
-- up to 2 calls and an import 2: 2 x 2 + 3 + 1 x 2 = 9, plus one refunded
-- Coach retry.
update public.plan_tiers set
  coach_daily = 2,
  meal_analysis_daily = 3,
  recipe_import_daily = 1,
  provider_calls_daily = 11,
  updated_at = now()
where tier = 'free';

-- Pre-launch ceilings, only ever lowered here: 400 calls and 20 pictures per
-- UTC day for everyone, Premium keeps at least 250 calls above the Free
-- pool. Sized again from ops data before launch (docs/PREMIUM.md 7).
update public.ai_provider_limits set
  daily_call_limit = least(daily_call_limit, 400),
  daily_image_limit = least(daily_image_limit, 20)
where singleton;
