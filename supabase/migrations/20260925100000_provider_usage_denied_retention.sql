-- A disabled switch or zero limit can deny every request on a new UTC day.
-- Such requests still trigger the request-driven cleanup of old usage dates.
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
  v_user_calls integer;
  v_new_day boolean;
  v_reason text;
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
  select calls, image_calls into v_calls, v_images
    from public.ai_provider_daily_usage where usage_date = v_day;
  v_new_day := not found;
  if not v_limits.enabled or
    (p_operation = 'analyze_meal' and not v_limits.analysis_enabled) or
    (p_operation <> 'analyze_meal' and not v_limits.coach_enabled) or
    (v_image and not v_limits.images_enabled) then
    v_reason := 'disabled';
  else
    v_calls := coalesce(v_calls, 0);
    v_images := coalesce(v_images, 0);
    select calls into v_user_calls from public.ai_provider_user_usage
      where user_id = p_user_id and usage_date = v_day;
    v_user_calls := coalesce(v_user_calls, 0);
    if v_calls >= v_limits.daily_call_limit or
      v_user_calls >= v_limits.daily_user_limit or
      (v_image and v_images >= v_limits.daily_image_limit) then
      v_reason := 'budget_exhausted';
    else
      -- Preserve the original FK-before-cleanup lock order for allowed calls.
      insert into public.ai_provider_user_usage (user_id, usage_date, calls)
        values (p_user_id, v_day, 1)
        on conflict (user_id, usage_date) do update set calls = ai_provider_user_usage.calls + 1;
      insert into public.ai_provider_daily_usage (usage_date, calls, image_calls)
        values (v_day, 1, case when v_image then 1 else 0 end)
        on conflict (usage_date) do update set
          calls = ai_provider_daily_usage.calls + 1,
          image_calls = ai_provider_daily_usage.image_calls + excluded.image_calls;
    end if;
  end if;
  if v_new_day then
    -- Cleanup is request-driven; it also runs when the request is denied.
    delete from public.ai_provider_user_usage where usage_date < v_day - 30;
    delete from public.ai_provider_daily_usage where usage_date < v_day - 30;
  end if;
  return jsonb_build_object('allowed', v_reason is null, 'reason', coalesce(v_reason, 'allowed'));
end;
$$;

revoke all on function public.reserve_ai_provider_call(uuid, text) from public, anon, authenticated;
grant execute on function public.reserve_ai_provider_call(uuid, text) to service_role;
