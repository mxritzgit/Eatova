-- Independent, non-refundable call ceilings. These are not monetary budgets.
create table public.ai_provider_limits (
  singleton boolean primary key default true check (singleton),
  enabled boolean not null default true,
  coach_enabled boolean not null default true,
  analysis_enabled boolean not null default true,
  images_enabled boolean not null default true,
  daily_call_limit integer not null default 1000 check (daily_call_limit between 0 and 100000),
  daily_image_limit integer not null default 50 check (daily_image_limit between 0 and 10000),
  daily_user_limit integer not null default 150 check (daily_user_limit between 0 and 10000)
);

create table public.ai_provider_daily_usage (
  usage_date date primary key,
  calls integer not null default 0 check (calls >= 0),
  image_calls integer not null default 0 check (image_calls >= 0)
);

create table public.ai_provider_user_usage (
  user_id uuid not null references auth.users(id) on delete cascade,
  usage_date date not null,
  calls integer not null default 0 check (calls >= 0),
  primary key (user_id, usage_date)
);
create index ai_provider_user_usage_date_idx on public.ai_provider_user_usage (usage_date);

alter table public.ai_provider_limits enable row level security;
alter table public.ai_provider_daily_usage enable row level security;
alter table public.ai_provider_user_usage enable row level security;
revoke all on public.ai_provider_limits, public.ai_provider_daily_usage,
  public.ai_provider_user_usage from public, anon, authenticated, service_role;
-- Operators use a trusted database administration connection for changes.
grant select on public.ai_provider_limits, public.ai_provider_daily_usage,
  public.ai_provider_user_usage to service_role;
insert into public.ai_provider_limits (singleton) values (true);

create function public.reserve_ai_provider_call(p_user_id uuid, p_operation text)
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
  v_user_calls integer;
  v_new_day boolean;
  v_image boolean := p_operation = 'coach_image';
begin
  if p_user_id is null or p_operation is null or p_operation not in
    ('coach_classifier', 'coach_answer', 'coach_recipe', 'coach_plan', 'coach_image', 'analyze_meal') then
    raise exception 'invalid provider budget request' using errcode = '22023';
  end if;
  -- One lock serializes cross-account claims and operator switch changes.
  select * into v_limits from public.ai_provider_limits where singleton for update;
  if not found then
    raise exception 'provider budget configuration unavailable' using errcode = '55000';
  end if;
  if not v_limits.enabled or
    (p_operation = 'analyze_meal' and not v_limits.analysis_enabled) or
    (p_operation <> 'analyze_meal' and not v_limits.coach_enabled) or
    (v_image and not v_limits.images_enabled) then
    return jsonb_build_object('allowed', false, 'reason', 'disabled');
  end if;
  -- Derive the day AFTER waiting for the lock, including at UTC midnight.
  v_day := (clock_timestamp() at time zone 'UTC')::date;
  select calls, image_calls into v_calls, v_images
    from public.ai_provider_daily_usage where usage_date = v_day;
  v_new_day := not found;
  v_calls := coalesce(v_calls, 0);
  v_images := coalesce(v_images, 0);
  select calls into v_user_calls from public.ai_provider_user_usage
    where user_id = p_user_id and usage_date = v_day;
  v_user_calls := coalesce(v_user_calls, 0);
  if v_calls >= v_limits.daily_call_limit or
    v_user_calls >= v_limits.daily_user_limit or
    (v_image and v_images >= v_limits.daily_image_limit) then
    return jsonb_build_object('allowed', false, 'reason', 'budget_exhausted');
  end if;
  -- The FK verifies that the server supplied an existing authenticated user.
  insert into public.ai_provider_user_usage (user_id, usage_date, calls)
    values (p_user_id, v_day, 1)
    on conflict (user_id, usage_date) do update set calls = ai_provider_user_usage.calls + 1;
  insert into public.ai_provider_daily_usage (usage_date, calls, image_calls)
    values (v_day, 1, case when v_image then 1 else 0 end)
    on conflict (usage_date) do update set
      calls = ai_provider_daily_usage.calls + 1,
      image_calls = ai_provider_daily_usage.image_calls + excluded.image_calls;
  if v_new_day then
    -- At most 30 completed days plus today; no request content is retained.
    delete from public.ai_provider_user_usage where usage_date < v_day - 30;
    delete from public.ai_provider_daily_usage where usage_date < v_day - 30;
  end if;
  return jsonb_build_object('allowed', true, 'reason', 'allowed');
end;
$$;

revoke all on function public.reserve_ai_provider_call(uuid, text) from public, anon, authenticated;
grant execute on function public.reserve_ai_provider_call(uuid, text) to service_role;
comment on function public.reserve_ai_provider_call(uuid, text) is
  'Atomically spends one global and account call before provider execution. No refund API; not a currency budget.';
