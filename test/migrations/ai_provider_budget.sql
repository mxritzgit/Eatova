-- Synthetic disposable PostgreSQL only, after all migrations and RLS suite.
-- No provider requests; all changes roll back.
\set ON_ERROR_STOP on
begin;
insert into auth.users (id) values
  ('91111111-1111-4111-8111-111111111111'), ('92222222-2222-4222-8222-222222222222');
-- 9111 has Premium (manual grant: pictures, outside the Free pool), 9222 is Free.
insert into public.store_subscriptions(user_id,platform,store_key,product_id,status,expires_at)
  values ('91111111-1111-4111-8111-111111111111','manual','manual:budget-test','eatova_premium','active','2099-01-01');
truncate public.ai_provider_daily_usage, public.ai_provider_user_usage;
update public.ai_provider_limits set daily_call_limit=3, daily_image_limit=1, daily_user_limit=2;

set role anon;
select rlstest.erwarte_ablehnung('select public.reserve_ai_provider_call(''91111111-1111-4111-8111-111111111111'', ''coach_answer'')', 'anon cannot reserve');
select rlstest.erwarte_ablehnung('select * from public.ai_provider_limits', 'anon cannot inspect limits');
select rlstest.erwarte_ablehnung('select * from public.ai_provider_daily_usage', 'anon cannot inspect totals');
select rlstest.erwarte_ablehnung('select * from public.ai_provider_user_usage', 'anon cannot inspect account counters');
select rlstest.erwarte_ablehnung('select public.release_edge_rate_limit(''x'', ''y'', ''2026-01-01'', 86400)', 'anon cannot release a limiter slot');
reset role;
set role authenticated;
select rlstest.erwarte_ablehnung('select public.reserve_ai_provider_call(''91111111-1111-4111-8111-111111111111'', ''coach_answer'')', 'user cannot reserve');
select rlstest.erwarte_ablehnung('update public.ai_provider_limits set enabled=true', 'user cannot enable AI');
select rlstest.erwarte_ablehnung('delete from public.ai_provider_daily_usage', 'user cannot reset global calls');
select rlstest.erwarte_ablehnung('update public.ai_provider_user_usage set calls=0', 'user cannot reset account calls');
select rlstest.erwarte_ablehnung('select public.release_edge_rate_limit(''x'', ''y'', ''2026-01-01'', 86400)', 'user cannot release a limiter slot');
reset role;
set role service_role;
select rlstest.erwarte_ablehnung('update public.ai_provider_limits set enabled=true', 'request service cannot alter policy');
select rlstest.erwarte_ablehnung('delete from public.ai_provider_daily_usage', 'request service has no refund path');
-- A budget denial names the first ceiling it reached; allowed stays as before.
do $$
begin
  if public.reserve_ai_provider_call('91111111-1111-4111-8111-111111111111','coach_classifier') <> '{"allowed":true,"reason":"allowed"}' then raise exception 'first call denied'; end if;
  if public.reserve_ai_provider_call('91111111-1111-4111-8111-111111111111','coach_image')->>'allowed' <> 'true' then raise exception 'image denied'; end if;
  if public.reserve_ai_provider_call('91111111-1111-4111-8111-111111111111','coach_answer') <> '{"allowed":false,"reason":"budget_exhausted","scope":"account"}' then raise exception 'account cap bypassed'; end if;
  if public.reserve_ai_provider_call('92222222-2222-4222-8222-222222222222','coach_image') <> '{"allowed":false,"reason":"budget_exhausted","scope":"images"}' then raise exception 'cross-account image cap bypassed'; end if;
  if public.reserve_ai_provider_call('92222222-2222-4222-8222-222222222222','analyze_meal')->>'allowed' <> 'true' then raise exception 'analysis denied'; end if;
  if public.reserve_ai_provider_call('92222222-2222-4222-8222-222222222222','coach_answer') <> '{"allowed":false,"reason":"budget_exhausted","scope":"all"}' then raise exception 'cross-account global cap bypassed'; end if;
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
-- The Free pool: Free accounts share daily_free_call_limit, Premium keeps the
-- rest of the global ceiling and never counts in free_calls, and a Free
-- account gets no picture whatever the pool holds.
truncate public.ai_provider_daily_usage, public.ai_provider_user_usage;
update public.ai_provider_limits set images_enabled=true, daily_call_limit=100, daily_image_limit=10,
  daily_user_limit=100, daily_free_call_limit=1;
set role service_role;
do $$ begin
  if public.reserve_ai_provider_call('92222222-2222-4222-8222-222222222222','analyze_meal')->>'allowed' <> 'true' then raise exception 'Free call inside the pool denied'; end if;
  if public.reserve_ai_provider_call('92222222-2222-4222-8222-222222222222','coach_answer') <> '{"allowed":false,"reason":"budget_exhausted","scope":"free"}' then raise exception 'Free pool bypassed'; end if;
  if public.reserve_ai_provider_call('91111111-1111-4111-8111-111111111111','coach_answer')->>'allowed' <> 'true' then raise exception 'Premium stopped by the Free pool'; end if;
  if public.reserve_ai_provider_call('92222222-2222-4222-8222-222222222222','coach_image') <> '{"allowed":false,"reason":"budget_exhausted","scope":"plan"}' then raise exception 'Free account got a picture'; end if;
  if (select array[calls, free_calls] from public.ai_provider_daily_usage) <> array[2, 1] then raise exception 'Premium counted in the Free pool'; end if;
end $$;
reset role;
-- Pool 0 is the Free kill switch; Premium, pictures included, keeps working.
update public.ai_provider_limits set daily_free_call_limit=0;
set role service_role;
do $$ begin
  if public.reserve_ai_provider_call('92222222-2222-4222-8222-222222222222','analyze_meal')->>'scope' is distinct from 'free' then raise exception 'Free kill switch bypassed'; end if;
  if public.reserve_ai_provider_call('91111111-1111-4111-8111-111111111111','coach_image')->>'allowed' <> 'true' then raise exception 'Free kill switch stopped Premium'; end if;
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
-- Denied requests are still the first request after a UTC-day rollover.
-- They must clean old account metadata without spending a call.
truncate public.ai_provider_daily_usage, public.ai_provider_user_usage;
update public.ai_provider_limits set enabled=false;
insert into public.ai_provider_daily_usage values
  (((clock_timestamp() at time zone 'UTC')::date)-31, 2, 0),
  (((clock_timestamp() at time zone 'UTC')::date)-30, 5, 2),
  (((clock_timestamp() at time zone 'UTC')::date)-1, 7, 1);
insert into public.ai_provider_user_usage values
  ('91111111-1111-4111-8111-111111111111',((clock_timestamp() at time zone 'UTC')::date)-31,2),
  ('91111111-1111-4111-8111-111111111111',((clock_timestamp() at time zone 'UTC')::date)-30,5),
  ('91111111-1111-4111-8111-111111111111',((clock_timestamp() at time zone 'UTC')::date)-1,7);
set role service_role;
do $$ declare result jsonb; begin
  begin
    perform public.reserve_ai_provider_call('91111111-1111-4111-8111-111111111111','invalid_operation');
    raise exception 'invalid operation was accepted';
  exception when sqlstate '22023' then null; end;
  begin
    perform public.reserve_ai_provider_call('93333333-3333-4333-8333-333333333333','coach_answer');
    raise exception 'unknown account was accepted';
  exception when sqlstate '22023' then null; end;
  if not exists(select 1 from public.ai_provider_user_usage
      where usage_date=((clock_timestamp() at time zone 'UTC')::date)-31 and calls=2)
    or not exists(select 1 from public.ai_provider_daily_usage
      where usage_date=((clock_timestamp() at time zone 'UTC')::date)-31 and calls=2 and image_calls=0)
    then raise exception 'invalid request pruned usage'; end if;
  result := public.reserve_ai_provider_call('91111111-1111-4111-8111-111111111111','coach_answer');
  if result->>'reason' is distinct from 'disabled' or result->>'allowed' is distinct from 'false'
    then raise exception 'disabled budget request was allowed'; end if;
  if (select count(*) from public.ai_provider_user_usage) <> 2
    or (select count(*) from public.ai_provider_daily_usage) <> 2
    or (select sum(calls) from public.ai_provider_user_usage) <> 12
    or (select sum(calls) from public.ai_provider_daily_usage) <> 12
    or (select sum(image_calls) from public.ai_provider_daily_usage) <> 3
    or not exists(select 1 from public.ai_provider_user_usage
      where usage_date=((clock_timestamp() at time zone 'UTC')::date)-30 and calls=5)
    or not exists(select 1 from public.ai_provider_daily_usage
      where usage_date=((clock_timestamp() at time zone 'UTC')::date)-30 and calls=5 and image_calls=2)
    then raise exception 'disabled cleanup lost recent counts or retained stale usage'; end if;
end $$;
reset role;
insert into public.ai_provider_daily_usage values (((clock_timestamp() at time zone 'UTC')::date)-31, 2, 0);
insert into public.ai_provider_user_usage values
  ('91111111-1111-4111-8111-111111111111',((clock_timestamp() at time zone 'UTC')::date)-31,2);
update public.ai_provider_limits set enabled=true,daily_call_limit=0;
set role service_role;
do $$ declare result jsonb; begin
  result := public.reserve_ai_provider_call('91111111-1111-4111-8111-111111111111','coach_answer');
  if result->>'reason' is distinct from 'budget_exhausted' or result->>'allowed' is distinct from 'false'
    then raise exception 'zero cap request was allowed'; end if;
  if (select count(*) from public.ai_provider_user_usage) <> 2
    or (select count(*) from public.ai_provider_daily_usage) <> 2
    or (select sum(calls) from public.ai_provider_user_usage) <> 12
    or (select sum(calls) from public.ai_provider_daily_usage) <> 12
    or (select sum(image_calls) from public.ai_provider_daily_usage) <> 3
    or not exists(select 1 from public.ai_provider_user_usage
      where usage_date=((clock_timestamp() at time zone 'UTC')::date)-30 and calls=5)
    or not exists(select 1 from public.ai_provider_daily_usage
      where usage_date=((clock_timestamp() at time zone 'UTC')::date)-30 and calls=5 and image_calls=2)
    then raise exception 'zero-cap cleanup lost recent counts or retained stale usage'; end if;
end $$;
-- release_edge_rate_limit gives back one counted request of exactly that
-- bucket (same subject hash as the limiter) and never goes below zero.
do $$
declare
  w timestamptz := to_timestamp(floor(extract(epoch from now()) / 86400) * 86400);
  s text := '92222222-2222-4222-8222-222222222222';
begin
  perform public.consume_edge_rate_limit('budgettest:user-day', s, 2, 86400);
  perform public.consume_edge_rate_limit('budgettest:user-day', s, 2, 86400);
  if public.release_edge_rate_limit('budgettest:user-day', '91111111-1111-4111-8111-111111111111', w, 86400)
    then raise exception 'released a slot of another subject'; end if;
  if not public.release_edge_rate_limit('budgettest:user-day', s, w, 86400)
    then raise exception 'release did not give the slot back'; end if;
  if public.consume_edge_rate_limit('budgettest:user-day', s, 2, 86400)->>'allowed' <> 'true'
    then raise exception 'released slot cannot be used again'; end if;
  -- One statement each: a statement sees the rows as they were when it began.
  perform public.release_edge_rate_limit('budgettest:user-day', s, w, 86400);
  perform public.release_edge_rate_limit('budgettest:user-day', s, w, 86400);
  if public.release_edge_rate_limit('budgettest:user-day', s, w, 86400)
    then raise exception 'release went below zero'; end if;
  if (select request_count from public.edge_rate_limits where scope = 'budgettest:user-day') <> 0
    then raise exception 'bucket not empty after the releases'; end if;
end $$;
reset role;
-- Only a window the limiter can have produced: aligned and already started.
select rlstest.erwarte_sqlstate($q$select public.release_edge_rate_limit('budgettest:user-day','92222222-2222-4222-8222-222222222222',
  to_timestamp(floor(extract(epoch from now()) / 86400) * 86400) + interval '1 second', 86400)$q$, 'P0001', 'unaligned window');
select rlstest.erwarte_sqlstate($q$select public.release_edge_rate_limit('budgettest:user-day','92222222-2222-4222-8222-222222222222',
  to_timestamp(floor(extract(epoch from now()) / 86400) * 86400) + interval '1 day', 86400)$q$, 'P0001', 'future window');
delete from public.ai_provider_limits;
select rlstest.erwarte_sqlstate('select public.reserve_ai_provider_call(''91111111-1111-4111-8111-111111111111'', ''coach_answer'')', '55000', 'missing configuration fails closed');
rollback;
\echo 'Provider budget role, global/Free-pool/account/image caps, scopes, kill switches, refund, slot release and UTC retention checks passed.'
