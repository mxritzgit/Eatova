-- Eatova Premium (20261025100000): the five tables stay server-only, the two
-- client RPCs see only the caller, record_store_subscription binds, orders,
-- supersedes and rebinds Apple, the tier and legacy rules, today's usage
-- (denied attempts do not count), the tier-aware provider ceiling and the
-- deletion cascade. Runs inside rls_cross_user.sql
-- (needs its rlstest functions); everything rolls back, including the
-- provider usage that ai_provider_budget_concurrency.py expects empty.
\set ON_ERROR_STOP on
begin;
create function pg_temp.require(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Assertion failed: %',label; end if; end;
$$;
grant execute on function pg_temp.require(boolean,text) to authenticated, service_role;

-- A buys on Google, B stays Free, C carries the tier-rule fixtures, L is a
-- legacy account, M a legacy account with a manual grant, E owns a foreign
-- purchase and is deleted at the end.
insert into auth.users(id,email,created_at) values
 ('a7000000-0000-4000-8000-000000000001','premium-a@example.invalid',now()),
 ('a7000000-0000-4000-8000-000000000002','premium-b@example.invalid',now()),
 ('a7000000-0000-4000-8000-000000000003','premium-c@example.invalid',now()),
 ('a7000000-0000-4000-8000-000000000004','premium-l@example.invalid',
   (select legacy_created_before - interval '1 day' from public.plan_settings)),
 ('a7000000-0000-4000-8000-000000000005','premium-m@example.invalid',
   (select legacy_created_before - interval '1 day' from public.plan_settings)),
 ('a7000000-0000-4000-8000-000000000006','premium-e@example.invalid',now());
insert into public.store_subscriptions(user_id,platform,store_key,product_id,status,expires_at)
  values ('a7000000-0000-4000-8000-000000000005','manual','manual:support-1','eatova_premium','active','2099-01-01');

select pg_temp.require(
  (select jsonb_object_agg(tier, jsonb_build_array(coach_daily, meal_analysis_daily,
     recipe_import_daily, provider_calls_daily, recipe_picture)) from public.plan_tiers)
  = '{"free":[3,4,2,30,false],"premium":[20,30,10,150,true],"legacy":[5,100,20,150,true]}'::jsonb,
  'the decided tiers are seeded');
select pg_temp.require(
  (select daily_user_limit >= 200 and daily_image_limit >= 200 and daily_call_limit >= 3000
     from public.ai_provider_limits),
  'the provider ceilings were raised');

-- Clients reach none of the five tables: no self-grant, no limit change.
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
do $$
declare t text;
begin
  foreach t in array array['plan_tiers','plan_settings','store_account_tokens',
    'store_subscriptions','store_notification_receipts'] loop
    perform rlstest.erwarte_ablehnung(format('select * from public.%I',t),'client reads '||t);
    perform rlstest.erwarte_ablehnung(format('delete from public.%I',t),'client deletes '||t);
  end loop;
end $$;
select rlstest.erwarte_ablehnung($q$insert into public.store_subscriptions(user_id,platform,store_key,product_id,status,expires_at)
  values ('a7000000-0000-4000-8000-000000000001','manual','manual:self','eatova_premium','active','2099-01-01')$q$,'client grants itself Premium');
select rlstest.erwarte_ablehnung($q$update public.store_subscriptions set expires_at='2099-01-01'$q$,'client extends a purchase');
select rlstest.erwarte_ablehnung($q$update public.plan_tiers set coach_daily=10000$q$,'client raises a limit');
select rlstest.erwarte_ablehnung($q$update public.plan_settings set legacy_until=null$q$,'client reopens the legacy window');
select rlstest.erwarte_ablehnung($q$insert into public.store_account_tokens(user_id) values ('a7000000-0000-4000-8000-000000000001')$q$,'client picks a token');
select rlstest.erwarte_ablehnung($q$insert into public.store_notification_receipts(source,notification_id) values ('apple','n-x')$q$,'client marks a notification');
-- The server functions are not callable by clients.
select rlstest.erwarte_ablehnung($q$select public.plan_tier_for('a7000000-0000-4000-8000-000000000001')$q$,'client resolves a tier');
select rlstest.erwarte_ablehnung($q$select public.resolve_plan('a7000000-0000-4000-8000-000000000001')$q$,'client resolves limits');
select rlstest.erwarte_ablehnung($q$select public.plan_snapshot('a7000000-0000-4000-8000-000000000002')$q$,'client reads a foreign snapshot');
select rlstest.erwarte_ablehnung($q$select public.store_account_owner(gen_random_uuid())$q$,'client maps a token');
select rlstest.erwarte_ablehnung($q$select public.store_subscription_owner('google','tok-a1')$q$,'client finds a purchase owner');
select rlstest.erwarte_ablehnung($q$select public.record_store_subscription('a7000000-0000-4000-8000-000000000001','google','tok-self',
  'eatova_premium','yearly','active','2099-01-01',true,'production',null,true,null,null,null)$q$,'client records a purchase');
select rlstest.erwarte_ablehnung($q$select public.record_store_notification('apple','n-x')$q$,'client records a notification');
select rlstest.erwarte_ablehnung($q$select public.mark_store_subscription_acknowledged('google','tok-a1')$q$,'client marks an acknowledgement');

-- The account token: created once, stable, per account.
select set_config('premiumtest.token_a', public.get_store_account_token()::text, true);
select pg_temp.require(public.get_store_account_token()::text = current_setting('premiumtest.token_a'),'A keeps its token');
select set_config('request.jwt.claims','{"sub":"a7000000-0000-4000-8000-000000000006","role":"authenticated"}',true);
select set_config('premiumtest.token_e', public.get_store_account_token()::text, true);
select pg_temp.require(current_setting('premiumtest.token_e') <> current_setting('premiumtest.token_a'),'E has its own token');
select set_config('request.jwt.claims','{"role":"authenticated"}',true);
select rlstest.erwarte_ablehnung('select public.get_my_plan()','plan without a user');
select rlstest.erwarte_ablehnung('select public.get_store_account_token()','token without a user');
set local role anon;
select rlstest.erwarte_ablehnung('select public.get_my_plan()','anon plan');
select rlstest.erwarte_ablehnung('select public.get_store_account_token()','anon token');
select rlstest.erwarte_ablehnung('select * from public.store_subscriptions','anon reads purchases');

-- record_store_subscription: binding, ordering, superseding, validation.
reset role;
set local role service_role;
select pg_temp.require(public.store_account_owner(current_setting('premiumtest.token_a')::uuid)
  = 'a7000000-0000-4000-8000-000000000001','token maps back to A');
select pg_temp.require(public.store_account_owner(gen_random_uuid()) is null,'unknown token has no owner');
select pg_temp.require(public.record_store_subscription('a7000000-0000-4000-8000-000000000001','google','tok-a1',
  'eatova_premium','monthly','active',now()+interval '30 days',true,'production',null,false,null,'GPA.1',now()-interval '1 hour')
  = '{"outcome":"stored","tier":"premium"}','A stores its purchase');
select pg_temp.require(public.record_store_subscription('a7000000-0000-4000-8000-000000000002','google','tok-a1',
  'eatova_premium','yearly','active',now()+interval '400 days',true,'production',null,true,null,null,now())
  = '{"outcome":"owned_by_other","tier":"free"}','B cannot take over A''s purchase');
select pg_temp.require(public.record_store_subscription('a7000000-0000-4000-8000-000000000001','google','tok-a1',
  'eatova_premium','monthly','expired',now()-interval '1 day',false,'production',null,true,null,null,now()-interval '2 hours')
  = '{"outcome":"stale","tier":"premium"}','an older event is stale');
select pg_temp.require((select user_id='a7000000-0000-4000-8000-000000000001' and base_plan_id='monthly'
  and status='active' and not acknowledged from public.store_subscriptions where store_key='tok-a1'),
  'neither the takeover nor the stale event changed the row');
-- One statement each: a statement sees the rows as they were when it began.
select pg_temp.require(public.mark_store_subscription_acknowledged('google','tok-a1'),'the acknowledgement is marked');
select pg_temp.require(not public.mark_store_subscription_acknowledged('google','tok-a1')
  and not public.mark_store_subscription_acknowledged('apple','tok-a1')
  and (select acknowledged and status='active' from public.store_subscriptions where store_key='tok-a1'),
  'an acknowledgement marks only that row, once, and nothing else');
select pg_temp.require(public.record_store_subscription('a7000000-0000-4000-8000-000000000001','google','tok-a1',
  'eatova_premium','monthly','canceled',now()+interval '30 days',false,'production',null,true,null,null,now())
  = '{"outcome":"stored","tier":"premium"}','canceled before expiry stays Premium');
select pg_temp.require(public.record_store_subscription('a7000000-0000-4000-8000-000000000001','google','tok-a1',
  'eatova_premium',null,'canceled',now()+interval '30 days',null,'production',null,null,null,null,null)
  ->> 'outcome' = 'stored','a verification without renewal info');
select pg_temp.require((select auto_renewing is false and acknowledged and base_plan_id='monthly'
  and last_transaction_id='GPA.1' from public.store_subscriptions where store_key='tok-a1'),
  'unknown fields keep the stored values');
select pg_temp.require(public.record_store_subscription('a7000000-0000-4000-8000-000000000001','google','tok-a2',
  'eatova_premium','yearly','active','2099-01-02 03:04:05.678+00',true,'production',null,true,'tok-a1',null,now())
  ->> 'outcome' = 'stored','A upgrades to yearly');
select pg_temp.require((select superseded_by='tok-a2' from public.store_subscriptions where store_key='tok-a1'),
  'the linked monthly purchase is superseded');
select pg_temp.require(public.record_store_subscription('a7000000-0000-4000-8000-000000000006','google','tok-e1',
  'eatova_premium','monthly','active',now()+interval '30 days',true,'production',null,true,null,null,now())
  ->> 'tier' = 'premium','E stores its purchase');
select pg_temp.require(public.record_store_subscription('a7000000-0000-4000-8000-000000000001','google','tok-a3',
  'eatova_premium','monthly','active',now()+interval '10 days',true,'production',null,true,'tok-e1',null,now())
  ->> 'outcome' = 'stored','A links a foreign purchase');
select pg_temp.require((select superseded_by is null from public.store_subscriptions where store_key='tok-e1')
  and public.plan_tier_for('a7000000-0000-4000-8000-000000000006')='premium',
  'a foreign purchase is never superseded');
select pg_temp.require(public.store_subscription_owner('google','tok-a1')='a7000000-0000-4000-8000-000000000001'
  and public.store_subscription_owner('apple','tok-a1') is null
  and public.store_subscription_owner('google','tok-unknown') is null,'purchase owners');
select rlstest.erwarte_sqlstate($q$select public.record_store_subscription('a7000000-0000-4000-8000-000000000001','manual','manual:x',
  'eatova_premium',null,'active','2099-01-01',null,'production',null,null,null,null,null)$q$,'22023','manual rows are SQL-only');
select rlstest.erwarte_sqlstate($q$select public.record_store_subscription('a7000000-0000-4000-8000-000000000001','google','tok-x',
  'eatova_premium',null,'lifetime','2099-01-01',null,'production',null,null,null,null,null)$q$,'22023','unknown status');
select rlstest.erwarte_sqlstate($q$select public.record_store_subscription('a7000000-0000-4000-8000-000000000001','google','',
  'eatova_premium',null,'active','2099-01-01',null,'production',null,null,null,null,null)$q$,'22023','empty store key');
select rlstest.erwarte_sqlstate($q$select public.record_store_subscription('a7000000-0000-4000-8000-000000000001','google','tok-x',
  'eatova_premium',null,'active',null,null,'production',null,null,null,null,null)$q$,'22023','no expiry');
select rlstest.erwarte_sqlstate($q$select public.record_store_subscription('a7000000-0000-4000-8000-000000000001','apple','tok-x',
  'eatova_premium',null,'active','2099-01-01',null,'staging',null,null,null,null,null)$q$,'22023','unknown environment');
select rlstest.erwarte_sqlstate($q$select public.record_store_subscription('a7000000-0000-4000-8000-0000000000ff','apple','tok-x',
  'eatova_premium',null,'active','2099-01-01',null,'production',null,null,null,null,null)$q$,'22023','unknown account');

-- The tier rule, one stored row of C at a time.
reset role;
do $$
declare c record;
begin
  for c in select * from (values
    ('active', interval '1 day', null, 'premium'),
    ('grace', interval '1 day', null, 'premium'),
    ('canceled', interval '1 day', null, 'premium'),
    ('canceled', interval '-1 second', null, 'free'),
    ('active', interval '-1 second', null, 'free'),
    ('expired', interval '1 day', null, 'free'),
    ('on_hold', interval '1 day', null, 'free'),
    ('paused', interval '1 day', null, 'free'),
    ('pending', interval '1 day', null, 'free'),
    ('revoked', interval '1 day', null, 'free'),
    ('active', interval '1 day', 'tok-newer', 'free')
  ) as v(status, offset_by, superseded, tier) loop
    insert into public.store_subscriptions(user_id,platform,store_key,product_id,status,expires_at,superseded_by)
      values ('a7000000-0000-4000-8000-000000000003','google','tok-c',
        'eatova_premium',c.status,now()+c.offset_by,c.superseded);
    if public.plan_tier_for('a7000000-0000-4000-8000-000000000003') <> c.tier then
      raise exception 'Assertion failed: % expiring in % superseded % should be %',
        c.status, c.offset_by, c.superseded, c.tier;
    end if;
    delete from public.store_subscriptions where store_key='tok-c';
  end loop;
end $$;

-- resolve_plan: Free, Premium, legacy, legacy with Premium, and the window.
set local role service_role;
select pg_temp.require(public.resolve_plan('a7000000-0000-4000-8000-000000000002') =
  '{"tier":"free","legacy":false,"coach_daily":3,"meal_analysis_daily":4,"recipe_import_daily":2,
    "provider_calls_daily":30,"recipe_picture":false,
    "premium":{"coach_daily":20,"meal_analysis_daily":30,"recipe_import_daily":10,"recipe_picture":true}}','Free');
select pg_temp.require(public.resolve_plan('a7000000-0000-4000-8000-000000000001') =
  '{"tier":"premium","legacy":false,"coach_daily":20,"meal_analysis_daily":30,"recipe_import_daily":10,
    "provider_calls_daily":150,"recipe_picture":true,
    "premium":{"coach_daily":20,"meal_analysis_daily":30,"recipe_import_daily":10,"recipe_picture":true}}','Premium');
select pg_temp.require(public.resolve_plan('a7000000-0000-4000-8000-000000000004') =
  '{"tier":"free","legacy":true,"coach_daily":5,"meal_analysis_daily":100,"recipe_import_daily":20,
    "provider_calls_daily":150,"recipe_picture":true,
    "premium":{"coach_daily":20,"meal_analysis_daily":100,"recipe_import_daily":20,"recipe_picture":true}}','legacy keeps today''s limits');
select pg_temp.require(public.resolve_plan('a7000000-0000-4000-8000-000000000005') =
  '{"tier":"premium","legacy":true,"coach_daily":20,"meal_analysis_daily":100,"recipe_import_daily":20,
    "provider_calls_daily":200,"recipe_picture":true,
    "premium":{"coach_daily":20,"meal_analysis_daily":100,"recipe_import_daily":20,"recipe_picture":true}}','legacy with Premium takes the maximum');
reset role;
update public.plan_settings set legacy_until = now() + interval '1 day';
set local role service_role;
select pg_temp.require((public.resolve_plan('a7000000-0000-4000-8000-000000000004') ->> 'meal_analysis_daily')::int = 100,
  'legacy until a future date');
reset role;
update public.plan_settings set legacy_until = now() - interval '1 second';
set local role service_role;
select pg_temp.require(public.resolve_plan('a7000000-0000-4000-8000-000000000004') = public.resolve_plan('a7000000-0000-4000-8000-000000000002'),
  'after legacy_until the legacy account is Free');
select pg_temp.require(public.resolve_plan('a7000000-0000-4000-8000-000000000005') = public.resolve_plan('a7000000-0000-4000-8000-000000000001'),
  'after legacy_until the legacy Premium account is plain Premium');
reset role;
update public.plan_settings set legacy_until = date_trunc('second', now()) + interval '30 days';

-- Usage: B's own buckets, capped at the current limit; never A's.
insert into public.chat_quota_usage(user_id,day,used_count) values
  ('a7000000-0000-4000-8000-000000000002',(now() at time zone 'utc')::date,2),
  ('a7000000-0000-4000-8000-000000000001',(now() at time zone 'utc')::date,7);
set local role service_role;
-- The buckets come from the limiter itself, so the subject hash must match.
do $$
begin
  for i in 1..6 loop
    perform public.consume_edge_rate_limits(jsonb_build_array(jsonb_build_object('scope','analyze-meal:user-day',
      'subject','a7000000-0000-4000-8000-000000000002','limit',4,'window_seconds',86400)));
  end loop;
  perform public.consume_edge_rate_limits(jsonb_build_array(jsonb_build_object('scope','recipe-import:user-day',
    'subject','a7000000-0000-4000-8000-000000000002','limit',2,'window_seconds',86400)));
  for i in 1..3 loop
    perform public.consume_edge_rate_limits(jsonb_build_array(jsonb_build_object('scope','recipe-import:user-day',
      'subject','a7000000-0000-4000-8000-000000000001','limit',10,'window_seconds',86400)));
  end loop;
  -- Denied attempts are not counted: after 4 analyses and 2 denials on Free,
  -- a mid-day upgrade to 30 leaves 25. The single gate behaves the same.
  if not public.consume_edge_rate_limits(jsonb_build_array(jsonb_build_object('scope','analyze-meal:user-day',
       'subject','a7000000-0000-4000-8000-000000000002','limit',30,'window_seconds',86400))) -> 0
     @> '{"allowed":true,"remaining":25}' then
    raise exception 'Assertion failed: a denied batch attempt was counted';
  end if;
  for i in 1..3 loop
    perform public.consume_edge_rate_limit('premiumtest:single','a7000000-0000-4000-8000-000000000002',2,86400);
  end loop;
  if public.consume_edge_rate_limit('premiumtest:single','a7000000-0000-4000-8000-000000000002',10,86400)
       ->> 'remaining' is distinct from '7' then
    raise exception 'Assertion failed: a denied single-gate attempt was counted';
  end if;
end $$;

-- get_my_plan: the caller's snapshot and nothing else.
reset role;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a7000000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select pg_temp.require(public.get_my_plan() = jsonb_build_object(
  'tier','free','subscription',null,'legacy',null,
  'limits','{"current":{"coach_daily":3,"meal_analysis_daily":4,"recipe_import_daily":2,"recipe_picture":false},
             "free":{"coach_daily":3,"meal_analysis_daily":4,"recipe_import_daily":2,"recipe_picture":false},
             "premium":{"coach_daily":20,"meal_analysis_daily":30,"recipe_import_daily":10,"recipe_picture":true}}'::jsonb,
  'usage',jsonb_build_object('day',to_char((now() at time zone 'utc')::date,'YYYY-MM-DD'),
    'coach',2,'meal_analysis',4,'recipe_import',1),
  'reset_at',to_char(((now() at time zone 'utc')::date + 1)::timestamp,'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
  'B sees its own Free snapshot, usage capped');
select set_config('request.jwt.claims','{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select pg_temp.require(public.get_my_plan() -> 'subscription' =
  '{"platform":"google","product_id":"eatova_premium","base_plan_id":"yearly","status":"active",
    "expires_at":"2099-01-02T03:04:05Z","auto_renewing":true,"environment":"production"}'::jsonb
  and public.get_my_plan() -> 'usage' ->> 'coach' = '7'
  and public.get_my_plan() -> 'usage' ->> 'recipe_import' = '3'
  and public.get_my_plan() -> 'limits' -> 'current' ->> 'coach_daily' = '20',
  'A sees its longest entitled purchase and its own usage');
select pg_temp.require(position('tok-' in public.get_my_plan()::text) = 0
  and position('GPA.' in public.get_my_plan()::text) = 0,'no store key or transaction id leaves the server');
select set_config('request.jwt.claims','{"sub":"a7000000-0000-4000-8000-000000000004","role":"authenticated"}',true);
select pg_temp.require(public.get_my_plan() -> 'legacy' = jsonb_build_object('until',
    to_char((date_trunc('second', now()) + interval '30 days') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'premium', '{"coach_daily":20,"meal_analysis_daily":30,"recipe_import_daily":10}'::jsonb)
  and public.get_my_plan() ->> 'tier' = 'free','L sees its legacy window and the regular Premium after it');
select set_config('request.jwt.claims','{"sub":"a7000000-0000-4000-8000-000000000005","role":"authenticated"}',true);
select pg_temp.require(public.get_my_plan() -> 'subscription' ->> 'platform' = 'manual','M sees its manual grant');
reset role;
insert into public.store_subscriptions(user_id,platform,store_key,product_id,status,expires_at,updated_at) values
  ('a7000000-0000-4000-8000-000000000003','google','tok-c-old','eatova_premium','expired',now()-interval '40 days',now()-interval '39 days'),
  ('a7000000-0000-4000-8000-000000000003','google','tok-c-hold','eatova_premium','on_hold',now()-interval '1 day',now());
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"a7000000-0000-4000-8000-000000000003","role":"authenticated"}',true);
select pg_temp.require(public.get_my_plan() -> 'subscription' ->> 'status' = 'on_hold'
  and public.get_my_plan() ->> 'tier' = 'free','without an entitled row the latest change is shown');

-- reserve_ai_provider_call: the account ceiling follows the plan.
reset role;
update public.ai_provider_limits set enabled=true, coach_enabled=true, analysis_enabled=true,
  images_enabled=true, daily_call_limit=100000, daily_user_limit=150;
insert into public.ai_provider_user_usage(user_id,usage_date,calls) values
  ('a7000000-0000-4000-8000-000000000002',(clock_timestamp() at time zone 'UTC')::date,29),
  ('a7000000-0000-4000-8000-000000000001',(clock_timestamp() at time zone 'UTC')::date,149),
  ('a7000000-0000-4000-8000-000000000004',(clock_timestamp() at time zone 'UTC')::date,149),
  ('a7000000-0000-4000-8000-000000000005',(clock_timestamp() at time zone 'UTC')::date,9);
update public.plan_settings set legacy_until = null;
set local role service_role;
do $$
declare u record;
begin
  for u in select * from (values
    ('a7000000-0000-4000-8000-000000000002'::uuid, 'Free stops at 30'),
    ('a7000000-0000-4000-8000-000000000001'::uuid, 'Premium stops at 150'),
    ('a7000000-0000-4000-8000-000000000004'::uuid, 'legacy stops at 150')
  ) as v(id, label) loop
    if public.reserve_ai_provider_call(u.id,'coach_answer')->>'allowed' <> 'true' then
      raise exception 'Assertion failed: % (last call denied)', u.label;
    end if;
    if public.reserve_ai_provider_call(u.id,'coach_answer')->>'reason' <> 'budget_exhausted' then
      raise exception 'Assertion failed: % (call above the ceiling allowed)', u.label;
    end if;
  end loop;
end $$;
reset role;
update public.ai_provider_limits set daily_user_limit=10;
set local role service_role;
select pg_temp.require(public.reserve_ai_provider_call('a7000000-0000-4000-8000-000000000005','coach_answer')->>'allowed' = 'true',
  'Premium below a lower operator ceiling');
select pg_temp.require(public.reserve_ai_provider_call('a7000000-0000-4000-8000-000000000005','coach_answer')->>'reason' = 'budget_exhausted',
  'a lower operator ceiling wins over Premium');

-- record_store_notification: first time true, duplicates false, 90-day prune.
select pg_temp.require(public.record_store_notification('apple','n-1'),'first notification');
select pg_temp.require(not public.record_store_notification('apple','n-1'),'duplicate notification');
select pg_temp.require(public.record_store_notification('google','n-1'),'ids are per source');
reset role;
insert into public.store_notification_receipts(source,notification_id,received_at)
  values ('apple','n-old',now()-interval '91 days');
set local role service_role;
select pg_temp.require(public.record_store_notification('apple','n-2'),'another notification');
reset role;
select pg_temp.require(not exists(select 1 from public.store_notification_receipts where notification_id='n-old')
  and (select count(*) from public.store_notification_receipts where notification_id in ('n-1','n-2')) = 3,
  'old receipts are pruned, recent ones kept');
set local role service_role;
select rlstest.erwarte_sqlstate($q$select public.record_store_notification('stripe','n-3')$q$,'22023','unknown source');
select rlstest.erwarte_sqlstate($q$select public.record_store_notification('apple','')$q$,'22023','empty notification id');

-- Account deletion removes the account's purchases and token, nothing else.
reset role;
delete from auth.users where id='a7000000-0000-4000-8000-000000000006';
select pg_temp.require(
  not exists(select 1 from public.store_subscriptions where user_id='a7000000-0000-4000-8000-000000000006')
  and not exists(select 1 from public.store_account_tokens where user_id='a7000000-0000-4000-8000-000000000006')
  and (select count(*) from public.store_subscriptions where user_id='a7000000-0000-4000-8000-000000000001') = 3
  and exists(select 1 from public.store_account_tokens where user_id='a7000000-0000-4000-8000-000000000001')
  and (select count(*) from public.store_notification_receipts where notification_id in ('n-1','n-2')) = 3,
  'deletion cascades to the deleted account only');

-- Apple keeps one originalTransactionId per Apple ID: B's newer purchase that
-- carries B's own token moves A's row to B; without the token, or older, it
-- stays A's, and a Google purchase never moves.
set local role service_role;
select pg_temp.require(public.record_store_subscription('a7000000-0000-4000-8000-000000000001','apple','otid-1',
  'eatova_premium_monthly',null,'active',now()+interval '30 days',null,'sandbox','PURCHASED',null,null,'t-1',
  now()-interval '2 days',true,now()-interval '2 days') ->> 'outcome' = 'stored','A buys on Apple');
select pg_temp.require(public.record_store_subscription('a7000000-0000-4000-8000-000000000002','apple','otid-1',
  'eatova_premium_yearly',null,'active',now()+interval '365 days',null,'sandbox','PURCHASED',null,null,'t-2',
  now()-interval '1 hour',false,now()-interval '1 hour') = '{"outcome":"owned_by_other","tier":"free"}',
  'without its own token B cannot take the row');
select pg_temp.require(public.record_store_subscription('a7000000-0000-4000-8000-000000000002','apple','otid-1',
  'eatova_premium_yearly',null,'active',now()+interval '365 days',null,'sandbox','PURCHASED',null,null,'t-2',
  now()-interval '1 hour',true,now()-interval '1 hour') = '{"outcome":"stored","tier":"premium"}',
  'B''s newer purchase with its own token moves the row');
select pg_temp.require(public.record_store_subscription('a7000000-0000-4000-8000-000000000001','apple','otid-1',
  'eatova_premium_monthly',null,'active',now()+interval '30 days',null,'sandbox','PURCHASED',null,null,'t-1',
  now(),true,now()-interval '2 days') ->> 'outcome' = 'owned_by_other','A''s older purchase cannot move it back');
select pg_temp.require(public.record_store_subscription('a7000000-0000-4000-8000-000000000002','google','tok-a2',
  'eatova_premium','yearly','active','2099-01-03',true,'production',null,true,null,null,now(),true,now())
  ->> 'outcome' = 'owned_by_other','a Google purchase never rebinds');
select pg_temp.require((select user_id='a7000000-0000-4000-8000-000000000002' and product_id='eatova_premium_yearly'
  and last_transaction_id='t-2' and last_purchase_at > now()-interval '2 hours'
  from public.store_subscriptions where store_key='otid-1')
  and (select user_id='a7000000-0000-4000-8000-000000000001' from public.store_subscriptions where store_key='tok-a2'),
  'the Apple row belongs to B, the Google row stays A''s');
rollback;
\echo 'Premium tables, tier and legacy rules, store records, usage and provider ceiling checks passed.'
