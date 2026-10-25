-- Eatova Premium: tier limits, store subscriptions and the tier-aware
-- provider ceiling (docs/PREMIUM.md section 2, 2026-10-25).
--
--   plan_tiers                   the three limit sets (free, premium, legacy).
--                                Operators change a value here; the Edge
--                                Functions read it per request, no release.
--   plan_settings                the legacy window, one row. Accounts created
--                                before legacy_created_before (the time this
--                                migration ran) keep the legacy limits while
--                                legacy_until is null or in the future. The
--                                operator sets legacy_until once the new AGB
--                                were announced four weeks ahead.
--   store_account_tokens         one random UUID per account, sent to the
--                                stores as applicationUserName (Google
--                                obfuscatedAccountId, Apple appAccountToken).
--                                Not the user id, no personal data.
--   store_subscriptions          one row per store purchase (Google
--                                purchaseToken, Apple originalTransactionId)
--                                or manual grant ('manual:<label>'), bound to
--                                exactly one account: the first verified
--                                binding wins. One exception: Apple keeps the
--                                originalTransactionId for one Apple ID across
--                                resubscribes and crossgrades, so a newer
--                                Apple purchase carrying another account's
--                                appAccountToken moves the row to that
--                                account (last_purchase_at orders them).
--   store_notification_receipts  dedupe of store notifications, kept 90 days.
--
-- Only the server writes. The Edge Functions record a purchase through
-- record_store_subscription after verifying the store proof, mark Google's
-- acknowledgement through mark_store_subscription_acknowledged, and record
-- notifications through record_store_notification; operators grant manual
-- Premium by SQL. The app reads its own view through get_my_plan and its
-- token through get_store_account_token. No client role holds a privilege
-- on any of the five tables, so purchase tokens never leave the server.
--
-- Entitled = status active, grace or canceled (auto-renew off, paid until
-- expires_at), expires_at in the future and not superseded. Expiry is
-- computed, never scheduled. resolve_plan is the one place of the limit
-- rules; plan_snapshot and the per-account ceiling of
-- reserve_ai_provider_call read it.
--
-- The shared Edge Function limiter (consume_edge_rate_limits and the
-- single-gate consume_edge_rate_limit) stops counting at the limit: a denied
-- attempt no longer increments its bucket, so a mid-day upgrade finds the
-- real usage instead of the Free denials. Allowed and denied answers are
-- the same as before.
--
-- Backward compatible, so it goes live before the new handlers: deployed
-- handlers ignore the new tables, every existing account is legacy (provider
-- ceiling 150, as before; 200 with Premium), the limiter answers as before,
-- and the global ceilings are only raised. Accounts created after the
-- migration get the Free provider ceiling (30) at once.
--
-- Row bound: one token per account; subscriptions grow only with real store
-- purchases; receipts are pruned on every new notification.
-- Idempotent.

create table if not exists public.plan_tiers (
  tier text primary key constraint plan_tiers_tier_check
    check (tier in ('free', 'premium', 'legacy')),
  coach_daily integer not null check (coach_daily between 1 and 10000),
  meal_analysis_daily integer not null check (meal_analysis_daily between 1 and 10000),
  recipe_import_daily integer not null check (recipe_import_daily between 1 and 10000),
  provider_calls_daily integer not null check (provider_calls_daily between 0 and 10000),
  recipe_picture boolean not null,
  updated_at timestamptz not null default now()
);

comment on table public.plan_tiers is
  'Daily limits per tier, read by resolve_plan. legacy = the limits before '
  'Premium for accounts inside the plan_settings window. Operator-owned.';

insert into public.plan_tiers
  (tier, coach_daily, meal_analysis_daily, recipe_import_daily,
   provider_calls_daily, recipe_picture)
values
  ('free', 3, 4, 2, 30, false),
  ('premium', 20, 30, 10, 150, true),
  ('legacy', 5, 100, 20, 150, true)
on conflict (tier) do nothing;

create table if not exists public.plan_settings (
  singleton boolean primary key default true check (singleton),
  legacy_created_before timestamptz not null,
  legacy_until timestamptz,
  updated_at timestamptz not null default now()
);

comment on table public.plan_settings is
  'Legacy window, one row: accounts created before legacy_created_before keep '
  'the legacy limits while legacy_until is null or in the future.';
comment on column public.plan_settings.legacy_until is
  'Null: legacy accounts keep the legacy limits. Set only after the AGB change '
  'was announced at least four weeks ahead.';

insert into public.plan_settings (singleton, legacy_created_before)
values (true, now())
on conflict (singleton) do nothing;

create table if not exists public.store_account_tokens (
  user_id uuid primary key references auth.users(id) on delete cascade,
  token uuid not null unique default gen_random_uuid(),
  created_at timestamptz not null default now()
);

comment on table public.store_account_tokens is
  'Random per-account token sent to the stores as applicationUserName; maps '
  'store notifications back to the account. Not the user id.';

create table if not exists public.store_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  platform text not null constraint store_subscriptions_platform_check
    check (platform in ('google', 'apple', 'manual')),
  store_key text not null check (char_length(store_key) between 1 and 4096),
  product_id text not null check (char_length(product_id) between 1 and 200),
  base_plan_id text check (base_plan_id is null or char_length(base_plan_id) between 1 and 200),
  status text not null constraint store_subscriptions_status_check
    check (status in ('active', 'grace', 'canceled', 'on_hold', 'paused',
                      'pending', 'expired', 'revoked')),
  expires_at timestamptz not null,
  auto_renewing boolean,
  environment text not null default 'production'
    constraint store_subscriptions_environment_check
    check (environment in ('production', 'sandbox', 'test')),
  ownership text,
  acknowledged boolean not null default false,
  superseded_by text,
  last_transaction_id text,
  last_event_at timestamptz,
  last_purchase_at timestamptz,
  last_verified_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint store_subscriptions_store_key_unique unique (platform, store_key)
);

create index if not exists store_subscriptions_user_expires_idx
  on public.store_subscriptions (user_id, expires_at desc);

comment on table public.store_subscriptions is
  'Verified store purchases and manual grants, one account each. Written only '
  'by record_store_subscription (server) or an operator. store_key is '
  'credential-like and never leaves the server.';
comment on column public.store_subscriptions.store_key is
  'Google purchaseToken, Apple originalTransactionId, or manual:<label>.';
comment on column public.store_subscriptions.superseded_by is
  'store_key of the purchase that replaced this one (Google '
  'linkedPurchaseToken); a superseded row never entitles.';
comment on column public.store_subscriptions.last_purchase_at is
  'Newest store purchase time seen (Apple purchaseDate); an Apple purchase of '
  'another account moves the row only when it is newer.';

create table if not exists public.store_notification_receipts (
  source text not null check (source in ('apple', 'google')),
  notification_id text not null check (char_length(notification_id) between 1 and 200),
  received_at timestamptz not null default now(),
  primary key (source, notification_id)
);

create index if not exists store_notification_receipts_received_idx
  on public.store_notification_receipts (received_at);

comment on table public.store_notification_receipts is
  'Store notification ids already processed (Apple notificationUUID, Pub/Sub '
  'messageId). Pruned after 90 days by record_store_notification.';

alter table public.plan_tiers enable row level security;
alter table public.plan_settings enable row level security;
alter table public.store_account_tokens enable row level security;
alter table public.store_subscriptions enable row level security;
alter table public.store_notification_receipts enable row level security;

-- No policies: clients go through get_my_plan and get_store_account_token.
-- The Edge Functions read the configuration, the caller's token and the
-- stored purchases they re-check; every write runs through the definer
-- functions below or an operator connection. The receipts get select as
-- well: an owner-only ACL equals the default, pg_dump omits it, and the
-- restored table would differ (test/operations/backup_restore.py).
revoke all on public.plan_tiers, public.plan_settings, public.store_account_tokens,
  public.store_subscriptions, public.store_notification_receipts
  from public, anon, authenticated, service_role;
grant select on public.plan_tiers, public.plan_settings, public.store_account_tokens,
  public.store_subscriptions, public.store_notification_receipts
  to service_role;

create or replace function public.plan_tier_for(p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case when exists (
    select 1 from public.store_subscriptions s
    where s.user_id = p_user_id
      and s.status in ('active', 'grace', 'canceled')
      and s.expires_at > now()
      and s.superseded_by is null
  ) then 'premium' else 'free' end;
$$;

comment on function public.plan_tier_for(uuid) is
  'premium while the account has an entitled store_subscriptions row, else free.';

revoke all on function public.plan_tier_for(uuid) from public, anon, authenticated;
grant execute on function public.plan_tier_for(uuid) to service_role;

-- The limit rules. Top-level limits are the account's current ones; premium
-- is what Premium would give this account (for a legacy account the higher
-- value of premium and legacy per feature). A missing tier row fails closed
-- (55000); the Edge Functions then apply the Free fallback.
create or replace function public.resolve_plan(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_free public.plan_tiers%rowtype;
  v_premium public.plan_tiers%rowtype;
  v_old public.plan_tiers%rowtype;
  v_current public.plan_tiers%rowtype;
  v_tier text;
  v_legacy boolean;
begin
  if p_user_id is null then
    raise exception 'invalid plan request' using errcode = '22023';
  end if;
  select * into v_free from public.plan_tiers t where t.tier = 'free';
  select * into v_premium from public.plan_tiers t where t.tier = 'premium';
  select * into v_old from public.plan_tiers t where t.tier = 'legacy';
  if v_free.tier is null or v_premium.tier is null or v_old.tier is null then
    raise exception 'plan configuration unavailable' using errcode = '55000';
  end if;

  v_tier := public.plan_tier_for(p_user_id);
  -- Without a settings row nobody is legacy: the fallback is fewer limits.
  v_legacy := exists (
    select 1 from auth.users u, public.plan_settings s
    where u.id = p_user_id
      and s.singleton
      and u.created_at < s.legacy_created_before
      and (s.legacy_until is null or now() < s.legacy_until)
  );

  if v_legacy then
    v_premium.coach_daily := greatest(v_premium.coach_daily, v_old.coach_daily);
    v_premium.meal_analysis_daily :=
      greatest(v_premium.meal_analysis_daily, v_old.meal_analysis_daily);
    v_premium.recipe_import_daily :=
      greatest(v_premium.recipe_import_daily, v_old.recipe_import_daily);
    -- The merged features need more calls than either row: a Coach question
    -- costs up to 3 (classifier, recipe, picture), an analysis 1 and an
    -- import 2 (20 x 3 + 100 + 20 x 2 = 200 with the seeds). Capped at the
    -- plan_tiers bound, which _shared/plan.ts also enforces.
    v_premium.provider_calls_daily := least(10000, greatest(
      v_premium.provider_calls_daily, v_old.provider_calls_daily,
      v_premium.coach_daily * 3 + v_premium.meal_analysis_daily
        + v_premium.recipe_import_daily * 2));
    v_premium.recipe_picture := v_premium.recipe_picture or v_old.recipe_picture;
  end if;

  if v_tier = 'premium' then
    v_current := v_premium;
  elsif v_legacy then
    v_current := v_old;
  else
    v_current := v_free;
  end if;

  return jsonb_build_object(
    'tier', v_tier,
    'legacy', v_legacy,
    'coach_daily', v_current.coach_daily,
    'meal_analysis_daily', v_current.meal_analysis_daily,
    'recipe_import_daily', v_current.recipe_import_daily,
    'provider_calls_daily', v_current.provider_calls_daily,
    'recipe_picture', v_current.recipe_picture,
    'premium', jsonb_build_object(
      'coach_daily', v_premium.coach_daily,
      'meal_analysis_daily', v_premium.meal_analysis_daily,
      'recipe_import_daily', v_premium.recipe_import_daily,
      'recipe_picture', v_premium.recipe_picture
    )
  );
end;
$$;

comment on function public.resolve_plan(uuid) is
  'Tier, legacy flag, current limits and the effective Premium limits of one '
  'account. One call per AI request (_shared/plan.ts).';

revoke all on function public.resolve_plan(uuid) from public, anon, authenticated;
grant execute on function public.resolve_plan(uuid) to service_role;

-- The account view for Profile and paywall. Never carries store_key,
-- tokens or transaction ids. Usage reads the same buckets the Edge Functions
-- count (chat_quota_usage; edge_rate_limits with the sha256 subject of
-- consume_edge_rate_limits); pg_catalog.sha256 gives the same hex digest as
-- pgcrypto's digest() and works wherever pgcrypto is installed.
create or replace function public.plan_snapshot(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := now();
  v_day date := (now() at time zone 'utc')::date;
  v_window timestamptz := to_timestamp(floor(extract(epoch from now()) / 86400) * 86400);
  v_subject text;
  v_plan jsonb;
  v_free public.plan_tiers%rowtype;
  v_base public.plan_tiers%rowtype;
  v_sub public.store_subscriptions%rowtype;
  v_legacy jsonb;
  v_until timestamptz;
  v_coach integer;
  v_meal integer;
  v_import integer;
begin
  if p_user_id is null then
    raise exception 'invalid plan request' using errcode = '22023';
  end if;
  v_plan := public.resolve_plan(p_user_id);
  select * into v_free from public.plan_tiers t where t.tier = 'free';

  -- The entitled row that runs longest; else the latest change, so the app
  -- can show "payment failed" or "expired on".
  select * into v_sub from public.store_subscriptions s
    where s.user_id = p_user_id
      and s.status in ('active', 'grace', 'canceled')
      and s.expires_at > v_now
      and s.superseded_by is null
    order by s.expires_at desc
    limit 1;
  if v_sub.id is null then
    select * into v_sub from public.store_subscriptions s
      where s.user_id = p_user_id
      order by s.updated_at desc, (s.superseded_by is null) desc, s.created_at desc
      limit 1;
  end if;

  if (v_plan ->> 'legacy')::boolean then
    select s.legacy_until into v_until from public.plan_settings s where s.singleton;
    select * into v_base from public.plan_tiers t where t.tier = 'premium';
    -- `premium` is the regular Premium tier: what a legacy subscriber keeps
    -- after `until` (limits.premium merges it with the old limits).
    v_legacy := jsonb_build_object(
      'until', case when v_until is null then null
        else to_char(v_until at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') end,
      'premium', jsonb_build_object(
        'coach_daily', v_base.coach_daily,
        'meal_analysis_daily', v_base.meal_analysis_daily,
        'recipe_import_daily', v_base.recipe_import_daily));
  end if;

  v_subject := encode(sha256(convert_to(p_user_id::text, 'UTF8')), 'hex');
  select q.used_count into v_coach from public.chat_quota_usage q
    where q.user_id = p_user_id and q.day = v_day;
  select r.request_count into v_meal from public.edge_rate_limits r
    where r.scope = 'analyze-meal:user-day' and r.subject_hash = v_subject
      and r.window_start = v_window and r.window_seconds = 86400;
  select r.request_count into v_import from public.edge_rate_limits r
    where r.scope = 'recipe-import:user-day' and r.subject_hash = v_subject
      and r.window_start = v_window and r.window_seconds = 86400;

  return jsonb_build_object(
    'tier', v_plan -> 'tier',
    'subscription', case when v_sub.id is null then null else jsonb_build_object(
      'platform', v_sub.platform,
      'product_id', v_sub.product_id,
      'base_plan_id', v_sub.base_plan_id,
      'status', v_sub.status,
      'expires_at', to_char(v_sub.expires_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'auto_renewing', v_sub.auto_renewing,
      'environment', v_sub.environment
    ) end,
    'limits', jsonb_build_object(
      'current', jsonb_build_object(
        'coach_daily', v_plan -> 'coach_daily',
        'meal_analysis_daily', v_plan -> 'meal_analysis_daily',
        'recipe_import_daily', v_plan -> 'recipe_import_daily',
        'recipe_picture', v_plan -> 'recipe_picture'
      ),
      'free', jsonb_build_object(
        'coach_daily', v_free.coach_daily,
        'meal_analysis_daily', v_free.meal_analysis_daily,
        'recipe_import_daily', v_free.recipe_import_daily,
        'recipe_picture', v_free.recipe_picture
      ),
      'premium', v_plan -> 'premium'
    ),
    'legacy', v_legacy,
    -- A bucket stops at its limit, but a lower limit (downgrade, operator)
    -- can leave it above the current one, so each value is capped.
    'usage', jsonb_build_object(
      'day', to_char(v_day, 'YYYY-MM-DD'),
      'coach', least(coalesce(v_coach, 0), (v_plan ->> 'coach_daily')::integer),
      'meal_analysis', least(coalesce(v_meal, 0), (v_plan ->> 'meal_analysis_daily')::integer),
      'recipe_import', least(coalesce(v_import, 0), (v_plan ->> 'recipe_import_daily')::integer)
    ),
    'reset_at', to_char((v_day + 1)::timestamp, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
end;
$$;

comment on function public.plan_snapshot(uuid) is
  'Tier, subscription (without store keys), limits, legacy window and today''s '
  'usage of one account (docs/PREMIUM.md 2.4).';

revoke all on function public.plan_snapshot(uuid) from public, anon, authenticated;
grant execute on function public.plan_snapshot(uuid) to service_role;

create or replace function public.get_my_plan()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  return public.plan_snapshot(v_user);
end;
$$;

comment on function public.get_my_plan() is
  'plan_snapshot of the caller (auth.uid()).';

revoke all on function public.get_my_plan() from public, anon, authenticated;
grant execute on function public.get_my_plan() to authenticated, service_role;

create or replace function public.get_store_account_token()
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_token uuid;
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  insert into public.store_account_tokens (user_id) values (v_user)
    on conflict (user_id) do nothing;
  select t.token into v_token from public.store_account_tokens t
    where t.user_id = v_user;
  return v_token;
end;
$$;

comment on function public.get_store_account_token() is
  'The caller''s store account token, created on first call.';

revoke all on function public.get_store_account_token() from public, anon, authenticated;
grant execute on function public.get_store_account_token() to authenticated, service_role;

create or replace function public.store_account_owner(p_token uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select t.user_id from public.store_account_tokens t where t.token = p_token;
$$;

comment on function public.store_account_owner(uuid) is
  'Account of a store account token, or null (store notifications).';

revoke all on function public.store_account_owner(uuid) from public, anon, authenticated;
grant execute on function public.store_account_owner(uuid) to service_role;

create or replace function public.store_subscription_owner(p_platform text, p_store_key text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select s.user_id from public.store_subscriptions s
  where s.platform = p_platform and s.store_key = p_store_key;
$$;

comment on function public.store_subscription_owner(text, text) is
  'Account a stored purchase is bound to, or null.';

revoke all on function public.store_subscription_owner(text, text)
  from public, anon, authenticated;
grant execute on function public.store_subscription_owner(text, text) to service_role;

-- Upsert of one verified purchase. The first binding wins: a row of another
-- account changes nothing (owned_by_other). The one exception is p_rebind,
-- which the server passes only for an Apple transaction that carries the
-- new owner's own appAccountToken: Apple keeps one originalTransactionId per
-- Apple ID, so a resubscribe or crossgrade from a second Eatova account
-- arrives under the first account's key. Such a purchase moves the row when
-- it is newer than the last one stored (p_purchase_at); an older one stays
-- owned_by_other, so the accounts cannot take it back and forth. Google keys
-- every purchase separately and never rebinds. An event older than the
-- stored one changes nothing (stale; store notifications arrive out of
-- order). Optional descriptive fields passed as null keep the stored value,
-- so a verification without renewal info does not erase what a notification
-- stored. Manual rows are SQL-only.
create or replace function public.record_store_subscription(
  p_user_id uuid,
  p_platform text,
  p_store_key text,
  p_product_id text,
  p_base_plan_id text,
  p_status text,
  p_expires_at timestamptz,
  p_auto_renewing boolean,
  p_environment text,
  p_ownership text,
  p_acknowledged boolean,
  p_linked_store_key text,
  p_last_transaction_id text,
  p_event_at timestamptz,
  p_rebind boolean default false,
  p_purchase_at timestamptz default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_row public.store_subscriptions%rowtype;
  v_inserted boolean := false;
begin
  if p_user_id is null
    or p_platform is null or p_platform not in ('google', 'apple')
    or p_store_key is null or char_length(p_store_key) not between 1 and 4096
    or p_product_id is null or char_length(p_product_id) not between 1 and 200
    or (p_base_plan_id is not null and char_length(p_base_plan_id) not between 1 and 200)
    or p_status is null or p_status not in
      ('active', 'grace', 'canceled', 'on_hold', 'paused', 'pending', 'expired', 'revoked')
    or p_expires_at is null
    or p_environment is null or p_environment not in ('production', 'sandbox', 'test')
    or (p_ownership is not null and char_length(p_ownership) not between 1 and 64)
    or (p_linked_store_key is not null and char_length(p_linked_store_key) not between 1 and 4096)
    or (p_last_transaction_id is not null and char_length(p_last_transaction_id) not between 1 and 200)
  then
    raise exception 'invalid store subscription' using errcode = '22023';
  end if;
  if not exists (select 1 from auth.users u where u.id = p_user_id) then
    raise exception 'invalid store subscription' using errcode = '22023';
  end if;

  select * into v_row from public.store_subscriptions s
    where s.platform = p_platform and s.store_key = p_store_key
    for update;
  if v_row.id is null then
    insert into public.store_subscriptions (
      user_id, platform, store_key, product_id, base_plan_id, status, expires_at,
      auto_renewing, environment, ownership, acknowledged, last_transaction_id,
      last_event_at, last_purchase_at
    ) values (
      p_user_id, p_platform, p_store_key, p_product_id, p_base_plan_id, p_status,
      p_expires_at, p_auto_renewing, p_environment, p_ownership,
      coalesce(p_acknowledged, false), p_last_transaction_id, p_event_at,
      p_purchase_at
    )
    on conflict (platform, store_key) do nothing;
    v_inserted := found;
    if not v_inserted then
      -- A concurrent first binding won; continue against its row.
      select * into v_row from public.store_subscriptions s
        where s.platform = p_platform and s.store_key = p_store_key
        for update;
    end if;
  end if;

  if not v_inserted then
    if v_row.user_id <> p_user_id and not (
      p_platform = 'apple' and coalesce(p_rebind, false) and p_purchase_at is not null
      and p_purchase_at > coalesce(v_row.last_purchase_at, '-infinity'::timestamptz)
    ) then
      return jsonb_build_object('outcome', 'owned_by_other',
        'tier', public.plan_tier_for(p_user_id));
    end if;
    if p_event_at < v_row.last_event_at then
      return jsonb_build_object('outcome', 'stale',
        'tier', public.plan_tier_for(p_user_id));
    end if;
    update public.store_subscriptions s set
      -- Unchanged unless the rebind above allowed a newer Apple purchase.
      user_id = p_user_id,
      product_id = p_product_id,
      base_plan_id = coalesce(p_base_plan_id, s.base_plan_id),
      status = p_status,
      expires_at = p_expires_at,
      auto_renewing = coalesce(p_auto_renewing, s.auto_renewing),
      environment = p_environment,
      ownership = coalesce(p_ownership, s.ownership),
      acknowledged = coalesce(p_acknowledged, s.acknowledged),
      last_transaction_id = coalesce(p_last_transaction_id, s.last_transaction_id),
      last_event_at = greatest(p_event_at, s.last_event_at),
      last_purchase_at = greatest(p_purchase_at, s.last_purchase_at),
      last_verified_at = now(),
      updated_at = now()
    where s.id = v_row.id;
  end if;

  -- Google linkedPurchaseToken: the replaced purchase of the same account
  -- stops entitling. Another account's row is never touched.
  if p_linked_store_key is not null and p_linked_store_key <> p_store_key then
    update public.store_subscriptions s set
      superseded_by = p_store_key,
      updated_at = now()
    where s.platform = p_platform
      and s.store_key = p_linked_store_key
      and s.user_id = p_user_id;
  end if;

  return jsonb_build_object('outcome', 'stored', 'tier', public.plan_tier_for(p_user_id));
end;
$$;

comment on function public.record_store_subscription(uuid, text, text, text, text, text,
  timestamptz, boolean, text, text, boolean, text, text, timestamptz, boolean, timestamptz) is
  'Records a verified Google or Apple purchase for one account: '
  '{outcome: stored|stale|owned_by_other, tier}. p_rebind moves an Apple row '
  'to a newer purchase''s account. 22023 on invalid input.';

revoke all on function public.record_store_subscription(uuid, text, text, text, text, text,
  timestamptz, boolean, text, text, boolean, text, text, timestamptz, boolean, timestamptz)
  from public, anon, authenticated;
grant execute on function public.record_store_subscription(uuid, text, text, text, text,
  text, timestamptz, boolean, text, text, boolean, text, text, timestamptz, boolean, timestamptz)
  to service_role;

-- Google's acknowledgement succeeded after the row was stored with Google's
-- earlier answer (PENDING). Sets only the flag of that one row, so a newer
-- state a notification wrote in between stays.
create or replace function public.mark_store_subscription_acknowledged(
  p_platform text,
  p_store_key text
)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_marked integer;
begin
  if p_platform is null or p_platform not in ('google', 'apple')
    or p_store_key is null or char_length(p_store_key) not between 1 and 4096
  then
    raise exception 'invalid store subscription' using errcode = '22023';
  end if;
  update public.store_subscriptions s set
    acknowledged = true,
    updated_at = now()
  where s.platform = p_platform and s.store_key = p_store_key and not s.acknowledged;
  get diagnostics v_marked = row_count;
  return v_marked = 1;
end;
$$;

comment on function public.mark_store_subscription_acknowledged(text, text) is
  'Sets acknowledged on one stored purchase after the store acknowledged it; '
  'true when the flag changed.';

revoke all on function public.mark_store_subscription_acknowledged(text, text)
  from public, anon, authenticated;
grant execute on function public.mark_store_subscription_acknowledged(text, text)
  to service_role;

create or replace function public.record_store_notification(
  p_source text,
  p_notification_id text
)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_new integer;
begin
  if p_source is null or p_source not in ('apple', 'google')
    or p_notification_id is null
    or char_length(p_notification_id) not between 1 and 200
  then
    raise exception 'invalid store notification' using errcode = '22023';
  end if;
  insert into public.store_notification_receipts (source, notification_id)
    values (p_source, p_notification_id)
    on conflict (source, notification_id) do nothing;
  get diagnostics v_new = row_count;
  delete from public.store_notification_receipts r
    where r.received_at < now() - interval '90 days';
  return v_new = 1;
end;
$$;

comment on function public.record_store_notification(text, text) is
  'True the first time a store notification id is seen, false for a '
  'duplicate. Prunes receipts older than 90 days.';

revoke all on function public.record_store_notification(text, text)
  from public, anon, authenticated;
grant execute on function public.record_store_notification(text, text) to service_role;

-- 20260925100000 with one change: the per-account ceiling is the lower of the
-- operator value and the account's plan (resolve_plan).
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
      v_user_calls >= least(v_limits.daily_user_limit,
        (public.resolve_plan(p_user_id) ->> 'provider_calls_daily')::integer) or
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

-- The shared limiter, 20260901100000 (batch) and 20260518000100 (single
-- gate, still used by _shared/auth_fail_gate.ts) with one change each: a
-- bucket at or above its limit is not incremented (the upsert's where), so
-- a denied attempt costs nothing. No row back means denied; remaining is 0.
-- Every verdict is the one the old functions gave: within a fixed window a
-- counter at the limit denied either way, and one above it (a lowered
-- limit) still denies. What changes is the stored count: the Free denials
-- before a mid-day upgrade no longer use up the Premium allowance.
create or replace function public.consume_edge_rate_limits(p_gates jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_now timestamptz := now();
  v_gate_count integer;
  v_index integer;
  v_gate jsonb;
  v_number numeric;
  -- The validated batch, so pass 2 does not re-parse the json.
  v_scopes text[] := array[]::text[];
  v_subjects text[] := array[]::text[];
  v_limits integer[] := array[]::integer[];
  v_windows integer[] := array[]::integer[];
  v_scope text;
  v_subject text;
  v_limit integer;
  v_window_seconds integer;
  v_window_start timestamptz;
  v_subject_hash text;
  v_count integer;
  v_reset_at timestamptz;
  v_allowed boolean;
  v_result jsonb := '[]'::jsonb;
begin
  -- -------------------------------------------------------------------------
  -- 1) Validate the whole batch before touching a single row.
  -- -------------------------------------------------------------------------
  if p_gates is null or jsonb_typeof(p_gates) is distinct from 'array' then
    raise exception 'invalid rate limit batch';
  end if;

  v_gate_count := jsonb_array_length(p_gates);
  -- Eight is the longest chain any caller has (analyze-meal runs four in two
  -- batches); the cap is what keeps a single call from becoming a write loop.
  if v_gate_count < 1 or v_gate_count > 8 then
    raise exception 'invalid rate limit batch size';
  end if;

  for v_index in 0 .. v_gate_count - 1 loop
    v_gate := p_gates -> v_index;
    if jsonb_typeof(v_gate) is distinct from 'object' then
      raise exception 'invalid rate limit gate'
        using detail = format('gate %s', v_index);
    end if;

    if jsonb_typeof(v_gate -> 'scope') is distinct from 'string' then
      raise exception 'invalid rate limit scope'
        using detail = format('gate %s', v_index);
    end if;
    v_scope := v_gate ->> 'scope';
    if length(trim(v_scope)) = 0 or length(v_scope) > 80 then
      raise exception 'invalid rate limit scope'
        using detail = format('gate %s', v_index);
    end if;

    if jsonb_typeof(v_gate -> 'subject') is distinct from 'string' then
      raise exception 'invalid rate limit subject'
        using detail = format('gate %s', v_index);
    end if;
    v_subject := v_gate ->> 'subject';
    if length(trim(v_subject)) = 0 or length(v_subject) > 512 then
      raise exception 'invalid rate limit subject'
        using detail = format('gate %s', v_index);
    end if;

    if jsonb_typeof(v_gate -> 'limit') is distinct from 'number' then
      raise exception 'invalid rate limit limit'
        using detail = format('gate %s', v_index);
    end if;
    v_number := (v_gate ->> 'limit')::numeric;
    if v_number <> trunc(v_number) or v_number < 1 or v_number > 10000 then
      raise exception 'invalid rate limit limit'
        using detail = format('gate %s', v_index);
    end if;
    v_limit := v_number::integer;

    if jsonb_typeof(v_gate -> 'window_seconds') is distinct from 'number' then
      raise exception 'invalid rate limit window'
        using detail = format('gate %s', v_index);
    end if;
    v_number := (v_gate ->> 'window_seconds')::numeric;
    if v_number <> trunc(v_number) or v_number < 1 or v_number > 86400 then
      raise exception 'invalid rate limit window'
        using detail = format('gate %s', v_index);
    end if;
    v_window_seconds := v_number::integer;

    v_scopes := v_scopes || v_scope;
    v_subjects := v_subjects || v_subject;
    v_limits := v_limits || v_limit;
    v_windows := v_windows || v_window_seconds;
  end loop;

  -- -------------------------------------------------------------------------
  -- 2) Consume, in array order, stopping at the first denial.
  --
  -- Everything inside this loop is `consume_edge_rate_limit` verbatim: same
  -- window floor, same sha256 over the RAW subject (the hashing stays in the
  -- database, the caller never sends a hash), same upsert, same result object.
  -- -------------------------------------------------------------------------
  for v_index in 1 .. v_gate_count loop
    v_scope := v_scopes[v_index];
    v_subject := v_subjects[v_index];
    v_limit := v_limits[v_index];
    v_window_seconds := v_windows[v_index];

    v_window_start := to_timestamp(
      floor(extract(epoch from v_now) / v_window_seconds) * v_window_seconds
    );
    v_reset_at := v_window_start + make_interval(secs => v_window_seconds);
    v_subject_hash := encode(digest(v_subject::text, 'sha256'::text), 'hex');

    insert into public.edge_rate_limits (
      scope, subject_hash, window_start, window_seconds, request_count, updated_at
    ) values (
      v_scope, v_subject_hash, v_window_start, v_window_seconds, 1, v_now
    )
    on conflict (scope, subject_hash, window_start, window_seconds)
    do update set
      request_count = public.edge_rate_limits.request_count + 1,
      updated_at = excluded.updated_at
    where public.edge_rate_limits.request_count < v_limit
    returning request_count into v_count;

    v_allowed := coalesce(v_count <= v_limit, false);

    v_result := v_result || jsonb_build_array(
      jsonb_build_object(
        'allowed', v_allowed,
        'limit', v_limit,
        'remaining', greatest(v_limit - coalesce(v_count, v_limit), 0),
        'resetAt', v_reset_at,
        'windowSeconds', v_window_seconds
      )
    );

    -- P6-02, the property the whole migration exists for: a denial ends the
    -- batch. Later gates get no row and no increment, so a request rejected at
    -- the IP gate never spends the user's daily bucket — which is what the
    -- early `return` between the sequential calls does today.
    exit when not v_allowed;
  end loop;

  return v_result;
end;
$$;

revoke all on function public.consume_edge_rate_limits(jsonb)
  from public, anon, authenticated;
grant execute on function public.consume_edge_rate_limits(jsonb)
  to service_role;

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
  where public.edge_rate_limits.request_count < p_limit
  returning request_count into v_count;

  return jsonb_build_object(
    'allowed', coalesce(v_count <= p_limit, false),
    'limit', p_limit,
    'remaining', greatest(p_limit - coalesce(v_count, p_limit), 0),
    'resetAt', v_reset_at,
    'windowSeconds', p_window_seconds
  );
end;
$$;

revoke all on function public.consume_edge_rate_limit(text, text, integer, integer)
  from public, anon, authenticated;
grant execute on function public.consume_edge_rate_limit(text, text, integer, integer)
  to service_role;

-- Premium needs 150 calls per account, a legacy account with Premium 200
-- (resolve_plan); recipe pictures and all calls get room for the launch.
-- Only ever raised, never lowered.
update public.ai_provider_limits set
  daily_user_limit = greatest(daily_user_limit, 200),
  daily_image_limit = greatest(daily_image_limit, 200),
  daily_call_limit = greatest(daily_call_limit, 3000);
