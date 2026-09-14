-- Synthetic privacy regression, included after the shared RLS fixtures.
-- Proves the restricted caller's export visibility and account deletion,
-- then checks actual contents as the observer. Everything rolls back.
\set ON_ERROR_STOP on
begin;

insert into auth.users(id, email, raw_user_meta_data) values
 ('33333333-3333-4333-8333-333333333333', 'privacy-a@example.test', '{}'),
 ('44444444-4444-4444-8444-444444444444', 'privacy-b@example.test', '{}');

set local role service_role;
do $$
declare u uuid;
begin
  foreach u in array array[
    '33333333-3333-4333-8333-333333333333'::uuid,
    '44444444-4444-4444-8444-444444444444'::uuid
  ] loop
    insert into public.logged_meals
      (user_id,meal_name,calories_kcal,estimated_g,payload,local_day)
      values(u,'Synthetic meal',100,100,'{}',current_date);
    insert into public.favorite_meals
      (user_id,favorite_key,meal_name,calories_kcal,estimated_g,payload)
      values(u,'synthetic-favorite','Synthetic meal',100,100,'{}');
    insert into public.weight_log(user_id,weight_kg) values(u,70);
    insert into public.user_recipes(user_id,slug,title,calories_kcal,estimated_g)
      values(u,'synthetic-recipe','Synthetic recipe',100,100);
    insert into public.chat_sessions(user_id,title) values(u,'Synthetic chat');
    insert into public.chat_messages(user_id,session_id,role,content)
      select u,id,'user','Synthetic question' from public.chat_sessions where user_id=u;
    insert into public.chat_quota_usage(user_id,day,used_count) values(u,current_date,1);
    insert into public.lifetime_stats_requests(user_id,request_id)
      values(u,'55555555-5555-4555-8555-555555555555');
    insert into public.training_plans(user_id,id,plan)
      values(u,'synthetic-plan',rlstest.training_plan());
  end loop;
end $$;

-- Only a trusted reservation can increment these counters. Both identities
-- are synthetic; no provider call is made by the SQL function.
select public.reserve_ai_provider_call('33333333-3333-4333-8333-333333333333','coach_answer');
select public.reserve_ai_provider_call('44444444-4444-4444-8444-444444444444','coach_answer');

set local role authenticated;
do $$
declare u text;
begin
  foreach u in array array[
    '33333333-3333-4333-8333-333333333333',
    '44444444-4444-4444-8444-444444444444'
  ] loop
    perform set_config('request.jwt.claims', jsonb_build_object('sub',u)::text,true);
    perform public.record_training_history(
      '66666666-6666-4666-8666-666666666666','2026-09-10T12:02:00Z',
      rlstest.training_history('66666666-6666-4666-8666-666666666666'));
    perform public.delete_training_history('77777777-7777-4777-8777-777777777777');
    perform public.save_planned_meal(rlstest.meal_plan('88888888-8888-4888-8888-888888888888'));
    perform public.save_shopping_check('2026-09-07:'||repeat('a',64),true);
  end loop;
end $$;

reset role;
create temporary table privacy_expected_b(table_name text, owner_key text, rows jsonb);
do $$
declare t text; k text; payload jsonb;
begin
  foreach t in array array[
    'profiles','logged_meals','favorite_meals','weight_log','user_recipes',
    'lifetime_stats','lifetime_stats_requests','training_plans','training_history',
    'training_history_deletions','planned_meals','shopping_checks',
    'chat_sessions','chat_messages','chat_quota_usage','ai_provider_user_usage'
  ] loop
    k := case when t='profiles' then 'id' else 'user_id' end;
    execute format('select jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text) from public.%I r where %I=%L',
      t,k,'44444444-4444-4444-8444-444444444444') into payload;
    if jsonb_array_length(payload) is distinct from 1 then
      raise exception 'Privacy fixture missing B data in %',t;
    end if;
    insert into privacy_expected_b values(t,k,payload);
  end loop;
end $$;

set local role anon;
select rlstest.erwarte_ablehnung('select public.delete_account()','unauthenticated account deletion');
select rlstest.erwarte_ablehnung('select * from public.ai_provider_user_usage','anonymous AI usage export');

set local role authenticated;
set local request.jwt.claims='{"sub":"33333333-3333-4333-8333-333333333333"}';
do $$
declare t text; k text;
begin
  foreach t in array array[
    'profiles','logged_meals','favorite_meals','weight_log','user_recipes',
    'lifetime_stats','training_plans','training_history','training_history_deletions',
    'planned_meals','shopping_checks','chat_sessions','chat_messages','chat_quota_usage',
    'ai_provider_user_usage'
  ] loop
    k := case when t='profiles' then 'id' else 'user_id' end;
    perform rlstest.erwarte_zeilen(format('select * from public.%I',t),1,'own export data: '||t);
    perform rlstest.erwarte_zeilen(format('select * from public.%I where %I=%L',
      t,k,'44444444-4444-4444-8444-444444444444'),0,'foreign export data: '||t);
  end loop;
  perform rlstest.erwarte_ablehnung('select * from public.lifetime_stats_requests','private operational markers');
  perform rlstest.erwarte_ablehnung('select * from public.ai_provider_daily_usage','private global AI usage');
  perform rlstest.erwarte_ablehnung('select * from public.ai_provider_limits','private global AI limits');
  perform rlstest.erwarte_ablehnung($q$insert into public.ai_provider_user_usage(user_id,usage_date,calls)
    values('33333333-3333-4333-8333-333333333333',current_date,0)$q$,'forged AI usage');
  perform rlstest.erwarte_ablehnung('update public.ai_provider_user_usage set calls=0','AI budget reset');
  perform rlstest.erwarte_ablehnung('delete from public.ai_provider_user_usage','AI budget removal');
  perform rlstest.erwarte_sqlstate('select public.delete_account()','28000','deletion requires fresh proof');
end $$;

select set_config('request.jwt.claims',jsonb_build_object(
  'sub','33333333-3333-4333-8333-333333333333',
  'amr',jsonb_build_array(jsonb_build_object('method','otp',
    'timestamp',extract(epoch from now()-interval '1 minute')::bigint)))::text,true);
select public.delete_account();
reset role;
do $$
declare r record; n bigint; after_b jsonb;
begin
  if exists(select 1 from auth.users where id='33333333-3333-4333-8333-333333333333')
    or not exists(select 1 from auth.users where id='44444444-4444-4444-8444-444444444444') then
    raise exception 'Privacy deletion did not isolate auth account A from B';
  end if;
  for r in select * from privacy_expected_b loop
    execute format('select count(*) from public.%I where %I=%L',r.table_name,r.owner_key,
      '33333333-3333-4333-8333-333333333333') into n;
    if n<>0 then raise exception 'Privacy deletion left A data in %',r.table_name; end if;
    execute format('select jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text) from public.%I t where %I=%L',
      r.table_name,r.owner_key,'44444444-4444-4444-8444-444444444444') into after_b;
    if after_b is distinct from r.rows then
      raise exception 'Privacy deletion changed B contents in %',r.table_name;
    end if;
  end loop;
end $$;
rollback;
select 'Privacy: A removed from 16 tables, B contents preserved; 15 export tables isolated' as result;
