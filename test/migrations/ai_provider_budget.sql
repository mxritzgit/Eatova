-- Synthetic disposable PostgreSQL only, after all migrations and RLS suite.
-- No provider requests; all changes roll back.
\set ON_ERROR_STOP on
begin;
insert into auth.users (id) values
  ('91111111-1111-4111-8111-111111111111'), ('92222222-2222-4222-8222-222222222222');
truncate public.ai_provider_daily_usage, public.ai_provider_user_usage;
update public.ai_provider_limits set daily_call_limit=3, daily_image_limit=1, daily_user_limit=2;

set role anon;
select rlstest.erwarte_ablehnung('select public.reserve_ai_provider_call(''91111111-1111-4111-8111-111111111111'', ''coach_answer'')', 'anon cannot reserve');
select rlstest.erwarte_ablehnung('select * from public.ai_provider_limits', 'anon cannot inspect limits');
select rlstest.erwarte_ablehnung('select * from public.ai_provider_daily_usage', 'anon cannot inspect totals');
select rlstest.erwarte_ablehnung('select * from public.ai_provider_user_usage', 'anon cannot inspect account counters');
reset role;
set role authenticated;
select rlstest.erwarte_ablehnung('select public.reserve_ai_provider_call(''91111111-1111-4111-8111-111111111111'', ''coach_answer'')', 'user cannot reserve');
select rlstest.erwarte_ablehnung('update public.ai_provider_limits set enabled=true', 'user cannot enable AI');
select rlstest.erwarte_ablehnung('delete from public.ai_provider_daily_usage', 'user cannot reset global calls');
select rlstest.erwarte_ablehnung('update public.ai_provider_user_usage set calls=0', 'user cannot reset account calls');
reset role;
set role service_role;
select rlstest.erwarte_ablehnung('update public.ai_provider_limits set enabled=true', 'request service cannot alter policy');
select rlstest.erwarte_ablehnung('delete from public.ai_provider_daily_usage', 'request service has no refund path');
do $$
begin
  if public.reserve_ai_provider_call('91111111-1111-4111-8111-111111111111','coach_classifier')->>'allowed' <> 'true' then raise exception 'first call denied'; end if;
  if public.reserve_ai_provider_call('91111111-1111-4111-8111-111111111111','coach_image')->>'allowed' <> 'true' then raise exception 'image denied'; end if;
  if public.reserve_ai_provider_call('91111111-1111-4111-8111-111111111111','coach_answer')->>'reason' <> 'budget_exhausted' then raise exception 'account cap bypassed'; end if;
  if public.reserve_ai_provider_call('92222222-2222-4222-8222-222222222222','coach_image')->>'reason' <> 'budget_exhausted' then raise exception 'cross-account image cap bypassed'; end if;
  if public.reserve_ai_provider_call('92222222-2222-4222-8222-222222222222','analyze_meal')->>'allowed' <> 'true' then raise exception 'analysis denied'; end if;
  if public.reserve_ai_provider_call('92222222-2222-4222-8222-222222222222','coach_answer')->>'reason' <> 'budget_exhausted' then raise exception 'cross-account global cap bypassed'; end if;
  if (select calls from public.ai_provider_daily_usage where usage_date=(clock_timestamp() at time zone 'UTC')::date) <> 3 then raise exception 'incorrect total'; end if;
  if (select sum(calls) from public.ai_provider_user_usage) <> 3 then raise exception 'denial consumed account budget'; end if;
end $$;
reset role;
update public.ai_provider_limits set daily_call_limit=100, daily_user_limit=100;
-- User-question refunds must never erase the independent call count.
select public.refund_chat_quota_for_day('91111111-1111-4111-8111-111111111111', (clock_timestamp() at time zone 'UTC')::date);
do $$ begin
  if (select sum(calls) from public.ai_provider_daily_usage) <> 3 then raise exception 'question refund altered call budget'; end if;
end $$;
update public.ai_provider_limits set enabled=false;
set role service_role;
do $$ begin
  if public.reserve_ai_provider_call('92222222-2222-4222-8222-222222222222','analyze_meal')->>'reason' <> 'disabled' then raise exception 'global kill switch bypassed'; end if;
end $$;
reset role;
update public.ai_provider_limits set enabled=true, coach_enabled=false, analysis_enabled=false, images_enabled=false;
set role service_role;
do $$ declare operation text; begin
  foreach operation in array array['coach_classifier','coach_answer','coach_recipe','coach_plan','coach_image','analyze_meal'] loop
    if public.reserve_ai_provider_call('92222222-2222-4222-8222-222222222222',operation)->>'reason' <> 'disabled' then raise exception 'feature switch bypassed: %', operation; end if;
  end loop;
end $$;
reset role;
update public.ai_provider_limits set coach_enabled=true, analysis_enabled=true, images_enabled=false;
set role service_role;
do $$ begin
  if public.reserve_ai_provider_call('92222222-2222-4222-8222-222222222222','coach_image')->>'reason' <> 'disabled' then raise exception 'image kill switch bypassed'; end if;
end $$;
reset role;
update public.ai_provider_limits set daily_call_limit=0;
set role service_role;
do $$ begin
  if public.reserve_ai_provider_call('92222222-2222-4222-8222-222222222222','coach_answer')->>'reason' <> 'budget_exhausted' then raise exception 'zero cap must stop calls'; end if;
end $$;
reset role;
-- Yesterday never consumes today's allowance; old account metadata is pruned.
truncate public.ai_provider_daily_usage, public.ai_provider_user_usage;
update public.ai_provider_limits set daily_call_limit=100, daily_user_limit=100;
insert into public.ai_provider_daily_usage values (current_date-1, 100, 1), (current_date-31, 2, 0);
insert into public.ai_provider_user_usage values ('91111111-1111-4111-8111-111111111111',current_date-31,2);
set role service_role;
do $$ begin
  if public.reserve_ai_provider_call('91111111-1111-4111-8111-111111111111','coach_answer')->>'allowed' <> 'true' then raise exception 'UTC day reset failed'; end if;
  if exists(select 1 from public.ai_provider_user_usage where usage_date < current_date-30) then raise exception 'stale account counters retained'; end if;
end $$;
reset role;
delete from public.ai_provider_limits;
select rlstest.erwarte_sqlstate('select public.reserve_ai_provider_call(''91111111-1111-4111-8111-111111111111'', ''coach_answer'')', '55000', 'missing configuration fails closed');
rollback;
\echo 'Provider budget role, global/account/image caps, kill switches, refund and UTC retention checks passed.'
