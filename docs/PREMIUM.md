# Eatova Premium

Design and build contract of 2026-10-25 (branch `feat/premium-tier`, base
main `fdd8d63f`). The owner asked for a complete Premium subscription:
Free and Premium usage limits, a paywall after the onboarding with an
explicit Free choice, a purchase screen, a Profile section with tier, status
and renewal or expiry date, and upgrade hints whenever a Free user reaches a
limit. The owner delegated every decision. All decisions below are open for
review; limits change without an app release (section 2), prices in the
store consoles.

Revised the same day after an abuse review: lower Free limits, a shared
daily AI pool for all Free accounts and lower ceilings before the launch
(migration `20261026100000_free_ai_pool.sql`, [section 7](#7-abuse-protection)).

## 1. Decisions

### 1.1 Tiers, limits, price

Three decision agents (unit economics, market and conversion, the Free
experience) proposed independently; then each saw all three proposals and
cast a final vote. The result is the median per number and the majority per
choice; the first round's final votes were unanimous except the Premium
Coach limit (15, 20, 20), the Free analyses (4, 3, 5) and the Free imports
(2, 2, 3). The first Free numbers were 3 Coach questions, 4 analyses, 2 imports and
a cap of 30. After the abuse review three new decision agents (cost safety,
experience, pragmatic) voted Free Coach (2, 3, 2), analyses (3, 3, 3),
imports (1, 1, 1) and the cap (11, 13, 10); the medians are below. Reasoning
in sections 6 and 7.

| | Free | Premium |
| --- | --- | --- |
| Coach questions per day (chat, photo, `/recipe`, `/plan`, `/log`; `/meal` stays free) | 2 | 20 |
| AI meal analyses per day (photo scan and Describe share one bucket) | 3 | 30 |
| Recipe imports per day | 1 | 10 |
| AI picture with a Coach `/recipe` | no (the full recipe stays) | yes |
| Provider-call safety cap per account per day | 11 | 150 |
| Shared AI pool per day | 150 provider calls for all Free accounts together | not counted in it |
| Price (store price incl. VAT) | free | 7,99 EUR per month, or 49,99 EUR per year (4,17 EUR per month, 48 % less) with a 7-day free trial on the yearly plan only |

- Everything that costs no AI stays free for everyone: diary, barcode,
  search, favorites, own products, recipes, meal plan, shopping list,
  training, trends (all ranges), weekly check, reminders, health import,
  export. No other Premium perks.
- Free stays on the same model as Premium (`claude-sonnet-5-5`); Premium buys
  more uses and the picture, not better answers.
- Global ceilings until the launch: 400 provider calls and 20 recipe
  pictures per UTC day, of which Free may use at most 150 calls. The first
  Premium migration had raised them to 3000 and 200; `20261026100000` lowers
  them again until the pools are sized from real use (section 7). Alert at
  60 %: the ops watch runs `--budget-warning-percent 60`.
- **Existing accounts kept the earlier limits** (Coach 5, analyses 100,
  imports 20, picture included) until the operator set
  `plan_settings.legacy_until`, normally after announcing the new AGB at
  least four weeks ahead (AGB section 11). Accounts created after the
  migration get the new Free limits at once. A legacy account with Premium
  gets the higher value of both per feature and a provider-call cap that
  covers that maximum: 20 x 3 + 100 + 20 x 2 = 200. The window ended live on
  2026-10-25 at 08:30:35 UTC with the owner's consent and without the notice:
  all 7 accounts were the owner's test accounts and the app is not public.
  The mechanism stays in the code.
- A downgrade or expiry locks and deletes nothing; saved recipes and their
  on-device pictures stay. Free limits apply from the next request.
- All limits are per UTC day (reset 00:00 UTC, shown on the phone's clock).

### 1.2 Presentation rules (decision agents)

- **Paywall** once, as the last step of a fresh onboarding, before Today.
  Already onboarded accounts never get it; it never returns on app start.
- Yearly preselected and the only plan with a trial. The large number is the
  billed amount ("49,99 EUR pro Jahr"); the monthly equivalent and the savings
  are secondary and computed from the store's prices at runtime (PAngV).
- A trial is never shown without its price and first charge date: a short
  timeline in the offer ("Heute: Premium freigeschaltet", "Ab {date}:
  {price} pro Jahr, vorher jederzeit kündbar"), and the charge line directly
  above the purchase button in the pinned foot (trial: first charge date and
  price; otherwise the billed price), so it is visible whenever the button is.
- "Weiter mit Free" is full width and as tall as the purchase button; the
  close button is visible at once (in the onboarding it also means Free).
- Restore, Terms and Privacy links on the paywall; "Abo verwalten" in Profile
  and Settings; the account deletion warns that store billing continues.
- **At a limit:** an inline, non-modal message, never a sheet while logging
  food. It names what still works and the reset time first; the "Mehr mit
  Premium" action appears at most once per feature per UTC day (remembered
  per account across app restarts), afterwards only the wait message. With
  two or fewer analyses left, the scan and Describe entry says "Heute noch 2
  KI-Analysen".
- Free Coach recipe cards show a quiet "KI-Bild mit Premium" line where the
  picture would be (no blurred teaser), also after a reload; it opens the
  paywall.
- Tone: calm, factual, du-form; every number comes from the server config;
  no countdowns, no strike-through prices, no "unbegrenzt", no health or
  weight promises.
- Existing (legacy) accounts see a one-time notice once the operator has set
  `legacy_until`, naming the date and the new Free limits, with "Mehr KI gibt
  es mit Premium" and an upgrade action. A legacy account that has Premium
  sees the regular Premium limits from `legacy.premium` instead (no numbers
  without them) and no upgrade action, and its Profile card keeps that date
  and those limits as a lasting note (4.4).

### 1.3 Architecture (orchestrator)

1. **Official `in_app_purchase` plugin with server-side verification, no
   RevenueCat:** no new data processor; Google and Apple stay the only parties
   that handle payment. Only the server grants Premium, after verifying the
   store proof. The client never decides its tier.
2. **The entitlement belongs to the Eatova account,** not to the device or
   store: bought on Android, it counts on iOS for the same account. Each store
   purchase binds to exactly one account. Google: the first verified binding
   wins. Apple keeps one `originalTransactionId` per Apple ID across the
   whole subscription group (renewals, crossgrades, resubscribes), so a newer
   Apple-signed purchase that carries the caller's own `appAccountToken`
   re-binds that transaction to the caller (2.5). A purchase carrying another
   Eatova account's token is answered `422 purchase_invalid` reason
   `account`; the app shows it as "gehört zu einem anderen Eatova-Konto" and
   never completes it. `409` applies to a token-less purchase (bought outside
   the app) already bound to someone else.
3. **Account token:** a random UUID per account (`store_account_tokens`),
   sent as `applicationUserName`, which becomes Google's `obfuscatedAccountId`
   and Apple's `appAccountToken`. It is not the user id and carries no
   personal data.
4. **Products:** Google: one subscription `eatova_premium` with base plans
   `monthly` and `yearly`, the trial as an offer on `yearly`. Apple: one
   subscription group "Eatova Premium" with `eatova_premium_monthly` and
   `eatova_premium_yearly`, the trial as an introductory offer. Family
   Sharing off.
5. **Renewals work without a webhook:** the app restores silently on start
   and re-verifies, and `refresh` re-checks stored Google tokens. **Store
   notifications** (`store-notifications`, a public endpoint with its own
   signature checks) close the refund and cancellation gap once the owner
   configures Pub/Sub and App Store Server Notifications.
6. **Fail-safe to Free:** when the plan lookup fails, the AI functions apply
   the Free limits (never more), log it and keep working. Those limits are
   never presented as the account's limit: a request they would deny answers
   `503 {"error":"plan_unavailable"}` without `planLimit`, and a Coach answer
   they allow names no `daily_limit` and no `remaining` (3.1), so the app
   shows a retryable error or keeps its counter, with no lock and no upgrade
   offer.
7. **Manual grants** (`platform = 'manual'`) let the operator give an account
   Premium by SQL, for testing before the stores exist and for support cases.
8. **Old app builds keep working:** every new response field is additive,
   `quota_exceeded` and `rate_limited` keep their meaning, `daily_limit` stays
   at least 1 wherever it is sent.

## 2. Database: migration `20261025100000_premium_subscriptions.sql`

Conventions as in `20261019100000_ai_consents_reports.sql`: header comment,
`text` plus named CHECK constraints instead of enums, RLS on every table,
explicit revokes and grants, `security definer set search_path = ''` with
fully qualified names, no `begin`/`commit`, no security DDL in DO blocks, no
pg_cron, idempotent where possible. `test/migrations/pg_bootstrap.sql` gets
`auth.users.created_at timestamptz not null default now()` (the GoTrue column
the legacy rule reads).

### 2.1 Tables

```sql
-- Server-owned tier configuration, three rows. Operators change values here.
create table public.plan_tiers (
  tier text primary key constraint plan_tiers_tier_check
    check (tier in ('free','premium','legacy')),
  coach_daily integer not null check (coach_daily between 1 and 10000),
  meal_analysis_daily integer not null check (meal_analysis_daily between 1 and 10000),
  recipe_import_daily integer not null check (recipe_import_daily between 1 and 10000),
  provider_calls_daily integer not null check (provider_calls_daily between 0 and 10000),
  recipe_picture boolean not null,
  updated_at timestamptz not null default now()
);
-- Seed (insert ... on conflict (tier) do nothing):
--   free    (3,  4,  2,  30, false)   -- 20261026100000 sets (2, 3, 1, 11, false)
--   premium (20, 30, 10, 150, true)
--   legacy  (5, 100, 20, 150, true)   -- today's limits for existing accounts

-- The legacy window. One row.
create table public.plan_settings (
  singleton boolean primary key default true check (singleton),
  legacy_created_before timestamptz not null,  -- set to now() by the migration
  legacy_until timestamptz,                    -- null: legacy accounts keep legacy limits
  updated_at timestamptz not null default now()
);

create table public.store_account_tokens (
  user_id uuid primary key references auth.users(id) on delete cascade,
  token uuid not null unique default gen_random_uuid(),
  created_at timestamptz not null default now()
);

create table public.store_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  platform text not null constraint store_subscriptions_platform_check
    check (platform in ('google','apple','manual')),
  -- Google purchaseToken, Apple originalTransactionId, 'manual:<label>'.
  store_key text not null check (char_length(store_key) between 1 and 4096),
  product_id text not null check (char_length(product_id) between 1 and 200),
  base_plan_id text check (base_plan_id is null or char_length(base_plan_id) between 1 and 200),
  status text not null constraint store_subscriptions_status_check
    check (status in ('active','grace','canceled','on_hold','paused','pending','expired','revoked')),
  expires_at timestamptz not null,
  auto_renewing boolean,
  environment text not null default 'production' constraint store_subscriptions_environment_check
    check (environment in ('production','sandbox','test')),
  ownership text,
  acknowledged boolean not null default false,
  superseded_by text,
  last_transaction_id text,
  last_event_at timestamptz,
  last_purchase_at timestamptz,  -- Apple purchaseDate of the binding transaction (2.5)
  last_verified_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint store_subscriptions_store_key_unique unique (platform, store_key)
);
-- index (user_id, expires_at desc)

create table public.store_notification_receipts (
  source text not null check (source in ('apple','google')),
  notification_id text not null check (char_length(notification_id) between 1 and 200),
  received_at timestamptz not null default now(),
  primary key (source, notification_id)
);
```

All five tables: RLS enabled, no policies, `revoke all ... from public, anon,
authenticated`, `service_role` gets what the functions need. Clients reach
them only through the two client RPCs below. Purchase tokens never leave the
server.

**Rules.**
- *Entitled* = a row with `status in ('active','grace','canceled')`,
  `expires_at > now()` and `superseded_by is null` (`canceled` = auto-renew
  off, still paid until `expires_at`). Tier `premium` if an entitled row
  exists, else `free`.
- *Legacy account* = `auth.users.created_at < plan_settings.legacy_created_before`
  and (`legacy_until is null` or `now() < legacy_until`).
- *Effective limits* (`current`): free and not legacy uses the `free` row;
  free and legacy uses `legacy`; premium and not legacy uses `premium`;
  premium and legacy uses per feature `greatest(premium, legacy)` and
  `premium.recipe_picture or legacy.recipe_picture`, with a
  `provider_calls_daily` that covers that feature maximum
  (`coach_daily x 3 + meal_analysis_daily + recipe_import_daily x 2`, 200
  with the seeded rows).
- *Effective Premium* for the upgrade hint: `premium`, or for a legacy
  account `greatest(premium, legacy)` per feature.

### 2.2 Functions

| Function | Execute | Purpose |
| --- | --- | --- |
| `plan_tier_for(p_user_id uuid) returns text` | service_role | `'premium'` or `'free'` |
| `resolve_plan(p_user_id uuid) returns jsonb` | service_role | One call per AI request (2.3) |
| `plan_snapshot(p_user_id uuid) returns jsonb` | service_role | The account view for Profile and paywall (2.4) |
| `get_my_plan() returns jsonb` | authenticated, service_role | `plan_snapshot(auth.uid())`; 42501 without a user |
| `get_store_account_token() returns uuid` | authenticated, service_role | Creates on first call (insert on conflict do nothing), returns the caller's token |
| `store_account_owner(p_token uuid) returns uuid` | service_role | Token to user, for webhooks |
| `store_subscription_owner(p_platform text, p_store_key text) returns uuid` | service_role | Owner of a stored purchase, or null |
| `record_store_subscription(...) returns jsonb` | service_role | Upsert with binding and ordering rules (2.5) |
| `mark_store_subscription_acknowledged(p_platform text, p_store_key text)` | service_role | Sets `acknowledged = true` on that one row after a successful Google acknowledgement (3.4) |
| `record_store_notification(p_source text, p_notification_id text) returns boolean` | service_role | True the first time, false for a duplicate; prunes receipts older than 90 days |
| `consume_edge_rate_limits(p_gates jsonb)` | service_role (unchanged signature) | Increments a bucket only while it is below its limit, so a denied attempt counts in no bucket and a mid-day upgrade gets its full allowance |
| `reserve_ai_provider_call(p_user_id uuid, p_operation text)` | service_role (unchanged) | Same signature and body, except the per-account ceiling becomes `least(ai_provider_limits.daily_user_limit, <effective provider_calls_daily>)` |

`create or replace` of `reserve_ai_provider_call` keeps the body of
`20260925100000` otherwise unchanged (diff it). The migration raises the
operator ceilings, never lowers them:
`update public.ai_provider_limits set daily_user_limit = greatest(daily_user_limit, 200), daily_image_limit = greatest(daily_image_limit, 200), daily_call_limit = greatest(daily_call_limit, 3000)`
(200 per account so a legacy account with Premium reaches its ceiling of
200, 2.1). `20261026100000` lowers the call and picture ceilings again to
`least(current, 400)` and `least(current, 20)` and adds the Free pool
(section 7).

### 2.3 `resolve_plan` result (contract with `_shared/plan.ts`)

```json
{
  "tier": "free", "legacy": false,
  "coach_daily": 2, "meal_analysis_daily": 3, "recipe_import_daily": 1,
  "provider_calls_daily": 11, "recipe_picture": false,
  "premium": { "coach_daily": 20, "meal_analysis_daily": 30, "recipe_import_daily": 10, "recipe_picture": true }
}
```

Top-level limits are the effective (`current`) limits; `premium` is the
effective Premium for this account.

### 2.4 `plan_snapshot` / `get_my_plan` result (contract with the app)

```json
{
  "tier": "premium",
  "subscription": {
    "platform": "google", "product_id": "eatova_premium", "base_plan_id": "yearly",
    "status": "active", "expires_at": "2027-10-25T08:00:00Z",
    "auto_renewing": true, "environment": "production"
  },
  "limits": {
    "current": { "coach_daily": 20, "meal_analysis_daily": 30, "recipe_import_daily": 10, "recipe_picture": true },
    "free":    { "coach_daily": 2,  "meal_analysis_daily": 3,  "recipe_import_daily": 1,  "recipe_picture": false },
    "premium": { "coach_daily": 20, "meal_analysis_daily": 30, "recipe_import_daily": 10, "recipe_picture": true }
  },
  "legacy": null,
  "usage": { "day": "2026-10-25", "coach": 3, "meal_analysis": 2, "recipe_import": 0 },
  "reset_at": "2026-10-26T00:00:00Z"
}
```

- `legacy`: `null`, or `{"until": null | "<iso>", "premium": {...}}` for a
  legacy account; `premium` holds the base Premium tier's daily limits as
  `{"coach_daily", "meal_analysis_daily", "recipe_import_daily"}` (no
  `recipe_picture`; the `premium` row without the legacy maximum), which
  apply to a legacy account with Premium after `until`.
- `subscription`: the entitled row with the latest `expires_at`; without one,
  the most recently updated row (so "payment failed" or "expired on" can be
  shown); `null` without any row. Never contains `store_key`, tokens or
  transaction ids. Manual rows report `platform: "manual"`.
- `usage.coach` = today's `chat_quota_usage.used_count`.
  `usage.meal_analysis` and `usage.recipe_import` = today's
  `edge_rate_limits.request_count` for scope `analyze-meal:user-day` and
  `recipe-import:user-day`, subject hash
  `encode(sha256(convert_to(<user id as text>, 'UTF8')), 'hex')` (the same hex digest the limiter's `extensions.digest` stores),
  `window_start` = today 00:00 UTC, `window_seconds` 86400. Denied attempts
  do not increment the bucket (`consume_edge_rate_limits`, 2.2); each value
  is still capped at the `current` limit, which only matters after a
  downgrade.

### 2.5 `record_store_subscription`

```
record_store_subscription(
  p_user_id uuid, p_platform text, p_store_key text, p_product_id text,
  p_base_plan_id text, p_status text, p_expires_at timestamptz,
  p_auto_renewing boolean, p_environment text, p_ownership text,
  p_acknowledged boolean, p_linked_store_key text,
  p_last_transaction_id text, p_event_at timestamptz,
  p_rebind boolean default false, p_purchase_at timestamptz default null
) returns jsonb   -- {"outcome": "stored"|"stale"|"owned_by_other", "tier": "free"|"premium"}
```

- `p_platform` must be `google` or `apple`; manual rows are SQL-only.
- An existing `(platform, store_key)` row of another user: nothing changes,
  `owned_by_other`. The one exception is Apple re-binding: with
  `p_platform = 'apple'`, `p_rebind` true and a `p_purchase_at` later than
  the row's `last_purchase_at` (or the row has none), the row moves to
  `p_user_id` and is updated as below. Callers pass `p_rebind` only for a
  transaction whose `appAccountToken` is the caller's own token
  (`subscription-verify`) or whose owner came from that token
  (`store-notifications`); Google never re-binds.
- Every write sets `last_purchase_at = greatest(p_purchase_at, last_purchase_at)`.
- `p_event_at` older than the stored `last_event_at`: nothing changes,
  `stale` (out-of-order notifications).
- Otherwise upsert every field, `last_verified_at = now()`,
  `updated_at = now()`.
- `p_linked_store_key` (Google `linkedPurchaseToken`): the row with that key
  on the same platform and the same user gets `superseded_by = p_store_key`.
- Every enum and length is validated (22023). Returns the account's tier
  after the write.

### 2.6 Tests and registries

- `test/migrations/premium_subscriptions_rls.sql` (new; `\ir` at the end of
  `rls_cross_user.sql`): clients can neither read nor write any of the five
  tables; `get_my_plan` returns only the caller's data, `anon` gets nothing;
  binding conflict, stale ordering and superseding in
  `record_store_subscription`; the tier rule including `canceled` before
  expiry and `expired`; the legacy rule (created before, `legacy_until` past
  and future, Premium plus legacy maximum); usage from `chat_quota_usage` and
  `edge_rate_limits`; the tier-aware `reserve_ai_provider_call` (rolled back:
  the concurrency script expects empty usage tables); cascade on deletion.
- `rls_invariants_test.dart` (`_erwartet`, `_erwarteteFunktionen`),
  `privacy_deletion.sql` (`store_subscriptions`, `store_account_tokens`),
  `profile_export_sheet_test.dart` (`_nichtExportierbar` for all five, with
  reasons), `supabase/SCHEMA_STATE.md` regenerated.

## 3. Edge Functions

### 3.1 `_shared/plan.ts`

```ts
export type PlanTier = 'free' | 'premium';
export type PlanFeature = 'coach' | 'meal_analysis' | 'recipe_import';
export interface TierLimits { coachDaily: number; mealAnalysisDaily: number; recipeImportDaily: number; recipePicture: boolean }
export interface ResolvedPlan extends TierLimits {
  tier: PlanTier; legacy: boolean; providerCallsDaily: number; premium: TierLimits; fallback: boolean;
}
export const FREE_FALLBACK: ResolvedPlan;  // free (2, 3, 1, 11, false), premium (20, 30, 10, true), fallback: true
export function resolvePlan(o: { supabaseUrl: string; serviceKey: string; userId: string; signal: AbortSignal }): Promise<ResolvedPlan>;  // never throws
export function limitFor(plan: ResolvedPlan, feature: PlanFeature): number;
export function premiumLimitFor(plan: ResolvedPlan, feature: PlanFeature): number;
export function nextUtcMidnightIso(nowMs?: number): string;
export function planLimitWire(plan: ResolvedPlan, feature: PlanFeature, resetAt: string): PlanLimitWire;
```

`resolvePlan` calls `/rest/v1/rpc/resolve_plan` with the service key
(`redirect: 'error'`, byte cap via `readProviderBody`), validates the shape
strictly and returns `FREE_FALLBACK` on any failure with one
`console.error('resolve_plan unavailable')` (no body, no user id).

**Limit-hit object** `planLimit`, added to the existing body of a tier-quota
denial in all three AI functions:

```json
"planLimit": { "feature": "coach", "tier": "free", "limit": 2, "resetAt": "2026-10-26T00:00:00.000Z", "premiumLimit": 20 }
```

`premiumLimit` only when `tier == "free"`, the plan is not the fallback and
the effective Premium limit is higher. A burst, IP, auth-fail or global gate
never carries `planLimit`; only the per-account daily quota does.

**Under the fallback** (`plan.fallback`), a denial of the per-account daily
quota is not a tier-quota denial: the account's real limit is unknown. All
three functions answer `503 {"error":"plan_unavailable"}` instead, with no
`planLimit` (and in `coach-chat` no `daily_limit` or `reply`). No slot is
used, because a denied attempt is not counted (2.2), and the next request
after the outage gets the real plan.

A request the fallback allows is answered as usual, but a successful
`coach-chat` answer names no limit: in every mode (chat, `/recipe`, `/plan`,
`/log`), streamed or buffered, and for a refusal after the claim, the body
carries neither `daily_limit` nor `remaining`. The app then keeps its
counter and asks the server for the count again (a forced plan read, else
the quota RPC), so the fallback's 2 never locks a Premium or legacy
account's composer. A `/recipe` answer under the fallback gets no picture
and no `image_locked` (3.2).

### 3.2 `coach-chat`

- Start `resolvePlan` right after authentication; await it before the claim.
- `claim_chat_quota(p_daily_limit = plan.coachDaily)`. Every `daily_limit`
  field and the quota text use the request's value (no module-load constant);
  under the fallback a successful answer sends no `daily_limit` and no
  `remaining` (3.1). `COACH_DAILY_LIMIT` is no longer read (not set live).
- Quota 429: the existing body (`error:"quota_exceeded"`, `reply`,
  `remaining:0`, `daily_limit`) plus `planLimit` and `reset_at`. The `reply`
  mentions the Premium allowance for Free accounts. Under the fallback the
  denial answers `503 plan_unavailable` instead (3.1).
- Recipe mode without `plan.recipePicture`: no image call and no `coach_image`
  reservation. Only when a real plan excludes the picture does the recipe
  response get `image_locked: true`, and the stored recipe JSON in
  `chat_messages` carries `image_locked: true` too, so the "KI-Bild mit
  Premium" line survives a reload. Under the fallback neither carries it:
  the account's plan may include the picture (Premium or legacy), so the
  recipe shows the plain placeholder instead of a lasting upgrade line. Old
  clients ignore the field and show the recipe without a picture.

### 3.3 `analyze-meal` and `recipe-import`

- The per-account daily gate uses `limitFor(plan, 'meal_analysis' | 'recipe_import')`.
  `ANALYZE_MEAL_USER_DAY_LIMIT` is no longer read for it (not set live); the
  hourly, IP and global gates keep their constants and overrides.
- A denial of exactly that gate adds `planLimit` (recipe-import also adds
  `resetAt` to its body). Everything else in the 429 stays
  (`error:'rate_limited'`, `rateLimit`, `Retry-After`). Under the fallback
  that denial answers `503 plan_unavailable` instead (3.1).

### 3.4 `subscription-verify` (new, `verify_jwt` on)

POST JSON, body cap 64 KiB, gates IP 60 per 600 s and user 30 per 3600 s,
authentication flow and 401 codes as in `analyze-meal`.

| Body | Meaning |
| --- | --- |
| `{"action":"verify","platform":"google","productId":"eatova_premium","purchaseToken":"…"}` | Verify a Play purchase |
| `{"action":"verify","platform":"apple","signedTransaction":"<JWS>"}` | Verify a StoreKit 2 transaction |
| `{"action":"refresh"}` | Re-check the caller's stored Google rows that are expired or expire within 48 h and were not verified in the last 10 minutes (at most 3), then return the plan |

| Status | Body |
| --- | --- |
| 200 | `{"outcome":"active"\|"inactive","plan":<plan_snapshot>}` |
| 202 | `{"error":"purchase_pending","plan":<plan_snapshot>}` (Google PENDING) |
| 400 | `{"error":"invalid_request"}` |
| 401 | `missing_bearer_token`, `user_token_required`, `invalid_user_token` |
| 409 | `{"error":"purchase_owned_by_other_account"}`: the purchase is bound to another account and carries no account token (or is an Apple transaction older than the binding one); the app shows "owned by another account" and completes it |
| 422 | `{"error":"purchase_invalid","reason":"signature"\|"bundle"\|"product"\|"environment"\|"ownership"\|"account"}`; `account` = the purchase carries another Eatova account's token, which the app shows as "owned by another account" without completing it |
| 429 | `{"error":"rate_limited"}` plus `Retry-After` |
| 503 | `{"error":"store_not_configured"\|"store_unavailable"\|"rate_limit_unavailable"}` |

**Google.** Service-account OAuth (RS256 JWT bearer via WebCrypto, token
cached per isolate), `purchases.subscriptionsv2.get` for
`EATOVA_PLAY_PACKAGE_NAME` (default `com.eatova.app`); a product in
`EATOVA_PREMIUM_PRODUCT_IDS` (default
`eatova_premium,eatova_premium_monthly,eatova_premium_yearly`);
`externalAccountIdentifiers.obfuscatedExternalAccountId` must equal the
caller's account token when present (else the first presenter binds);
states ACTIVE to active, IN_GRACE_PERIOD to grace, CANCELED to canceled,
ON_HOLD to on_hold, PAUSED to paused, EXPIRED and PENDING_PURCHASE_CANCELED to
expired, PENDING to pending (202); `expires_at` = the latest
`lineItems[].expiryTime`; `testPurchase` to environment `test`;
`linkedPurchaseToken` superseded; after storing an active or grace purchase
with `ACKNOWLEDGEMENT_STATE_PENDING`, POST
`purchases.subscriptions/…/tokens/{token}:acknowledge` (in `verify` and in
`refresh`); on success `mark_store_subscription_acknowledged` sets
`acknowledged = true` on that row (a failed mark is ignored; the next
verification stores Google's state). Secret
`EATOVA_PLAY_SERVICE_ACCOUNT_JSON` (the whole key JSON); without it Google
answers 503 `store_not_configured`.

**Apple.** StoreKit 2 JWS verified offline: `alg` must be ES256; `x5c` of
exactly three certificates; root SHA-256 pinned to Apple Root CA - G3
`63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179`; leaf
OID `1.2.840.113635.100.6.11.1`, intermediate OID `1.2.840.113635.100.6.2.1`;
chain signatures; validity at `signedDate`. Then `bundleId` =
`EATOVA_APPLE_BUNDLE_ID` (default `com.eatova.app`), the product allowlist,
an auto-renewable `type`, environment Production or Sandbox (stored as
`sandbox`; App Review buys in sandbox against production),
`inAppOwnershipType == PURCHASED`, `appAccountToken` equal to the caller's
token when present, `revocationDate` to `revoked`, `expiresDate` to
`expires_at`, store key `originalTransactionId`, event time `signedDate`,
`p_purchase_at` = `purchaseDate` and `p_rebind` = whether `appAccountToken`
is present (it was just checked to be the caller's), so a newer purchase on
the same Apple ID moves the binding to the account that made it (2.5).
`auto_renewing` stays null until a notification brings `signedRenewalInfo`.

Registries: `PROBES` and `ROLLBACK_FLOORS` (base main sha, `first_release`)
in `deploy_functions.py`, `cors_origin_contract_test.ts`, `docs/BACKEND.md`.

### 3.5 `store-notifications` (new, `verify_jwt` off, own authentication)

- `OPTIONS` 204; POST only; body cap 256 KiB; an IP gate (anon subject)
  before any verification.
- **Apple** (`{"signedPayload": "<JWS>"}`): verify the payload and the nested
  `signedTransactionInfo` and `signedRenewalInfo` with the same verifier;
  `bundleId` check; a receipt on `notificationUUID` written after applying
  (it labels a repeat `duplicate`; repeats are re-applied idempotently); map
  by `notificationType`
  (SUBSCRIBED, DID_RENEW, DID_CHANGE_RENEWAL_STATUS, DID_FAIL_TO_RENEW with
  GRACE_PERIOD to grace and otherwise on_hold, GRACE_PERIOD_EXPIRED, EXPIRED,
  REFUND and REVOKE to revoked, REFUND_REVERSED, TEST answers 200); owner =
  `store_account_owner(appAccountToken)` when the token is present and
  resolves (recorded with `p_rebind` and the transaction's `purchaseDate`),
  else the stored row of `originalTransactionId`; an unknown owner answers
  200 and drops it.
- **Google Pub/Sub push:** `Authorization: Bearer <Google OIDC JWT>` verified
  against the JWKS `https://www.googleapis.com/oauth2/v3/certs` (RS256,
  cached): `iss` accounts.google.com, `aud` = `EATOVA_PUBSUB_PUSH_AUDIENCE`,
  `email` = `EATOVA_PUBSUB_PUSH_SA_EMAIL`, `email_verified`, `exp`. Decode
  `message.data`, check `packageName`; a receipt on `message.messageId`
  written after applying (labels a repeat `duplicate`; repeats are re-applied
  idempotently);
  `subscriptionNotification` re-fetches `subscriptionsv2` and records;
  `voidedPurchaseNotification` revokes; `testNotification` answers 200.
- Answers: 200 processed, duplicate or unknown owner; 400
  `invalid_notification`; 401 `invalid_notification_auth`; 503
  `not_configured` or `store_unavailable` (the stores retry).
- **Tooling:** a tracked `supabase/config.toml` with `project_id = "eatova"`
  and only `[functions.store-notifications] verify_jwt = false`;
  `deploy_functions.py` gets an explicit allowlist of public webhook slugs
  (only this one): the probe expects the handler's `invalid_notification_auth`
  401 both without a token and with the anon key, and the record expects
  `verify_jwt` false for it and true for every other slug. Every other
  function keeps the gateway JWT check exactly as today.

### 3.6 Shared store modules

- `_shared/jws_apple.ts`: a small DER reader, x5c chain verification, ES256
  JWS verification, the embedded and pinned Apple root;
  `verifyAppleJws(jws, {nowMs?, rootSha256?})`. Tests build their own root,
  intermediate and leaf with WebCrypto and inject the pin; one test checks the
  embedded root's fingerprint.
- `_shared/google_auth.ts`: the service-account access token (RS256 JWT
  bearer, cached until 60 s before expiry) and Google OIDC verification
  against a cached JWKS.
- `_shared/play_subscriptions.ts`: `subscriptionsv2.get`, `acknowledge`,
  and the mapping to a stored row.
- `_shared/store_records.ts`: RPC clients for the `record_*`, owner, token
  and `plan_snapshot` functions.

All dependency-free (WebCrypto, `fetch`), byte-bounded reads,
`redirect: 'error'` on every request that carries a credential, never a token
or JWS in logs.

## 4. App

### 4.1 Packages and platform

- `in_app_purchase`, `in_app_purchase_android`, `in_app_purchase_storekit`
  as direct dependencies (latest compatible with Flutter 3.47.2;
  `pubspec.lock` written with the local 3.47.2 SDK).
- `android/permissions_allowlist.txt` gains `com.android.vending.BILLING`.
- `ios/Runner/PrivacyInfo.xcprivacy` gains
  `NSPrivacyCollectedDataTypePurchaseHistory` (linked, no tracking, app
  functionality), with its wiring test.

### 4.2 Layers

| File | Role |
| --- | --- |
| `lib/src/models/plan_status.dart` | `PlanTier`, `TierLimits`, `PlanUsage`, `SubscriptionInfo` (+ `SubscriptionState`, `StorePlatform`), `LegacyPlan`, `PlanStatus` (`fromJson` of 2.4, `toJson`, `==`, `PlanStatus.assumed()` = the decided defaults with `assumed: true`) |
| `lib/src/models/plan_limit_hit.dart` | `PlanLimitHit {feature, tier, limit, resetAt, premiumLimit?}` from the `planLimit` object; null for anything malformed |
| `lib/src/services/subscription_sync.dart` | `SubscriptionLog` interface and `SupabaseSubscriptionLog`: `fetchPlan()` (`get_my_plan` via `userRpc`), `accountToken()` (`get_store_account_token`), `verify(PurchaseProof)` and `refresh()` (`subscription-verify` with a pinned bearer, the `CoachChatService._capturedAuthorization` pattern). Result `VerifyResult {outcome: active, inactive, pending, ownedByOther, invalid, unavailable, unauthorized; plan?}` |
| `lib/src/services/billing/billing_client.dart` | `BillingClient` interface; `PremiumOffer {period: monthly/yearly, productId, basePlanId?, offerToken?, priceLabel, rawPrice, currencyCode, trialDays?}`; `StorePurchase {platform, productId, status, proof, handle}`; `PurchaseProof`; `NoBillingClient` for tests and unsupported platforms |
| `lib/src/services/billing/store_billing_client.dart` | The `in_app_purchase` implementation: availability, offers from both stores, `buy(offer, accountToken, {replacing})` including Google `ChangeSubscriptionParam` (monthly to yearly `withTimeProration`, yearly to monthly `deferred`), the purchase stream, silent `restore()`, `complete()`, `openManageSubscriptions(productId)` (iOS `showManageSubscriptions`, else the store URLs) |
| `lib/src/services/billing/purchase_coordinator.dart` | App-level, one per process, created in `EatovaApp`: listens to the purchase stream from app start, holds purchases until an account is bound, verifies each through the bound account's `SubscriptionLog`, completes only after `active`, `inactive` or `ownedByOther` (never after `unavailable`, `pending` or `invalid`; an `invalid` with reason `account` is shown as owned by another account and stays uncompleted), reports results to the bound account, restores silently once per bind |
| `lib/src/app/subscription.dart` | `SubscriptionController extends ChangeNotifier` per account (template `AiTrustController`): `plan`, `offers`, `purchaseState`, `load()` (cache first, then server), `refresh()`, `buy(period)`, `restore()`, `isPremium`, `takeUpsell(feature)` (true once per feature per UTC day, kept in the `upsell_shown` slot across restarts), `_revision` guard, `.preview()`; `SubscriptionBinding` and `SubscriptionScope` above `MaterialApp` like `AiTrustScope`; helpers `openPremium(context, {required PremiumSource source})` and `openManageSubscription(context)` |
| `lib/src/app/home_store_subscription.dart` | Store part: the cache slots `plan_status` (last `PlanStatus` JSON), `paywall_prompt` (`pending` / `answered`), `legacy_notice` (the `legacy_until` already shown) and `upsell_shown` (per feature the UTC day of the last "Mehr mit Premium" offer) |

Cache keys `eatova.v1.plan_status.<uid>`, `eatova.v1.paywall_prompt.<uid>`,
`eatova.v1.legacy_notice.<uid>` and `eatova.v1.upsell_shown.<uid>`:
registered in `durableCacheSlotNames`, the non-atomic clear list and the two
inventory tests; not in
`_mutationKeys` or the hydration waves (except reading `paywall_prompt`
before `_completeProfileReady`).

### 4.3 Paywall and purchase screen (`lib/src/screens/premium/`)

One screen, two modes: `PaywallMode.onboarding` (the root gate after a fresh
onboarding; close and system Back mean Free) and `PaywallMode.upsell` (a
pushed route, opened with a `PremiumSource`: profile, settings, coach,
mealAnalysis, recipeImport, recipePicture).

Layout (dark default, both palettes; no overflow at 320 px and 2.0x text):
1. Close button top right, visible at once.
2. Hero card in the IdentityCard recipe (rHero, glow): eyebrow
   "EATOVA PREMIUM", display title (the promise), the subline naming what
   stays free.
3. Free vs Premium table with the effective numbers from `PlanStatus`
   (`limits.free`, `limits.premium`; the assumed defaults until loaded): Coach
   questions, AI analyses, recipe imports, AI picture. For a legacy account
   without Premium a note under the table with its current limits and
   `legacy.until`; with Premium its current limits are not the previous
   ones, so the note does not show.
4. Two reassurance lines: the picture stays on the device; nothing is lost
   when the subscription ends.
5. Plan choice: two `OptionCard`s, yearly first and preselected (billed price
   large, monthly equivalent and savings badge secondary, trial badge when
   eligible), monthly second. Prices only from the store.
6. With a trial: the timeline (today unlocked; from {date} {price} per year,
   cancel before in {store}).
7. `PrimaryActionButton`: trial-eligible yearly "{days} Tage gratis testen",
   otherwise "Premium abonnieren"; busy while the store sheet is open. In the
   pinned foot, directly above it, the charge line of the selected offer: a
   trial's first charge date and price (`premiumTrialCharge`), otherwise the
   billed price (`premiumPlanYearlyPrice` / `premiumPlanMonthlyPrice`).
   The pinned foot never scrolls and caps its text scale at 1.3x, so at 2.0x
   it leaves the content its space.
8. Fine print: renewal sentence with the selected price and period, cancel any
   time in the store's subscription settings, links Nutzungsbedingungen and
   Datenschutz, and "Käufe wiederherstellen".
9. Onboarding mode: "Weiter mit Free" as a full-width soft capsule with the
   primary button's height.

States: loading offers; store unavailable (CalmState with retry; the table
and the Free choice stay); purchasing; pending payment; success ("Willkommen
bei Premium"); owned by another account (a `409`, or a `422` with reason
`account`); already Premium, or without Premium a store subscription still
live on hold, paused or pending (the status card and "Abo verwalten" in
place of the plan choice, and no purchase button: it is fixed in its store,
not bought twice); errors as a snack. A Google subscription on hold counts
as live for at most 60 days past its `expires_at`, a paused one for at most
92 days (Google's longest hold and pause); after that it reads as expired
and the screen sells again, even if no store answer ever closed the row.

The onboarding gate: `completeOnboarding`'s publish sets `paywall_prompt =
pending` (like `_deferHealthToIntro`); the shell shows the paywall between the
onboarding branch and the tabs while it is pending; "Weiter mit Free", close,
Back and a finished purchase write `answered`. The four deferred-entry guards
(`_scheduleRecipeImport`, `_resumePendingEntry`, `_syncAppShortcuts`,
`_resumeAfterRestAlert`) also wait for it.

### 4.4 Profile, Settings, deletion, legacy notice

- Profile: a new section "Abo" before "Verbindungen" with a
  `SubscriptionCard`: tier pill (Free or Premium), status line (renews on,
  ends on, payment problem with access until, unlocked until for manual,
  expired on), "über Google Play / über den App Store", a test-purchase badge
  for sandbox and test, today's usage (Coach 1/2, KI-Analysen 2/3,
  Importe 0/1), and the actions: "Mehr mit Premium" on Free without a live
  store subscription; "Abo verwalten" for a live store subscription (Premium,
  or on Free one on hold, paused or pending, with the spans of 4.3; when
  bought on the other platform: the note that it is managed there); always
  "Käufe wiederherstellen". A legacy account without Premium shows its
  current limits and `legacy.until` (`premiumLegacyNote` /
  `premiumLegacyNoteUntil`). A legacy account with Premium shows, once
  `legacy.until` is set, a lasting note with that date and the regular
  Premium limits from `legacy.premium` (`legacyNoticeBodyPremium`, or
  `legacyNoticeBodyPremiumPlain` without them), whatever was dismissed on
  Today.
- Settings, group "Konto": a row "Abo". Its subtitle is Premium; otherwise,
  for a live store subscription on hold, paused or pending, its status
  sentence (`subscriptionOnHold`, `subscriptionPaused`, `premiumPendingTitle`);
  otherwise Free. Free opens the paywall; Premium from a store or a live held
  subscription opens the store's management; a manual grant has no tap.
- Account deletion sheet: when a store subscription auto-renews, a warning
  note that billing continues in the store until cancelled, with an
  "Abo verwalten" pill. Deletion is never blocked.
- Today: a one-time legacy notice card once `legacy.until` is set. On Free
  it names the new Free limits (`legacyNoticeBody`), then
  `legacyNoticeMorePremium` and "Mehr mit Premium"; with Premium the regular
  Premium limits (`legacyNoticeBodyPremium`, or `legacyNoticeBodyPremiumPlain`
  without `legacy.premium`) and no upgrade action. Dismiss stores the date
  in `legacy_notice`; a later date shows it again.
- `profile_screen_design_test` keeps "no invented data" on the identity card;
  its `PREMIUM` assertion is narrowed to the identity card.

### 4.5 Upgrade hints

A shared `lib/src/widgets/shared/plan_limit_notice.dart` with
`PlanLimitNotice(hit, onUpgrade, secondary)` and
`planLimitMessage(l10n, hit, clockLabel)`; the upgrade action shows only when
`hit.premiumLimit != null` and `SubscriptionController.takeUpsell` allows it.

| Surface | Change |
| --- | --- |
| Photo-scan error card (`meal_analysis_sheet.dart`) | For a tier quota the card shows the notice and no "Erneut versuchen" until an upgrade lifts it: only once the account moved to Premium after the denial (a plan change seen after the 429, not a Premium plan the app already held) does the card say "Willkommen bei Premium" with `premiumSuccessBody` and offer "Erneut versuchen" for the same photo |
| Describe error card (`meal_describe_sheet.dart`) | The notice in the empty retry slot; "Text ändern" stays; after such an upgrade the same success card, whose "Erneut versuchen" sends the same text |
| Scan and Describe entry | "Heute noch {n} KI-Analysen" when 2 or fewer are left (from `PlanStatus.usage` and the 200 body's `rateLimit.userDay.remaining`) |
| Recipe import (`recipe_import_sheet.dart`) | The notice; the analyze button offers no retry for a tier quota until the same kind of upgrade lifts it (then the notice goes, without a success line); the service keeps `planLimit` and `resetAt` |
| Coach banner, composer, info sheets, brief lock | The banner gets the action slot; at 0 remaining the composer shows an upgrade pill instead of the counter; both info sheets show the Premium line and button; built from state, not a frozen string |
| Coach recipe card | `image_locked` (the live answer, or the stored recipe JSON after a reload) shows "KI-Bild mit Premium", which opens the paywall; a recipe made under the plan fallback carries none and shows the plain placeholder (3.2) |
| Free pool used up (`429 ai_budget_exhausted` with `scope: "free"`, section 7) | Coach, meal analysis and recipe import show a calm notice with the reset time in local time and no upgrade offer; the Coach composer is never locked; the meal analysis adds that barcode, search and favorites keep working. Every other scope, or none, keeps the earlier mapping |

The Coach counter and lock use `PlanStatus` (`usage.coach`, the `current`
limit) instead of the echoing `get_chat_quota_today`; a tier change resets
the remembered Coach limit, so an upgrade unlocks the composer at once. An
answer without `daily_limit` and `remaining` (the plan fallback, 3.1) keeps
the counter and asks the server for the count again.

### 4.6 Copy

German is the template (`app_de.arb`); English mirrors it with the same
placeholders. ICU plurals where a number precedes a noun; rows with several
counts show only the `other` form (`{coach} Coach-Fragen` stands for
`{coach, plural, =1{1 Coach-Frage} other{{coach} Coach-Fragen}}`), and
`app_de.arb` is authoritative. `{store}` is an ICU select on the billing
store's wire value (`apple`, otherwise Google Play), with the brand name
written in the text, because the German wording around it changes. `{date}` is a
`formatMediumDate` string, `{time}` a local clock string (German texts put
"Uhr" after it, English texts none), `{price}` the store's formatted price.
Numbers in the copy always come from `PlanStatus`, never literals.

| Key | German | Placeholders |
| --- | --- | --- |
| `premiumEyebrow` | EATOVA PREMIUM | |
| `premiumScreenLabel` | Eatova Premium | (screen semantics) |
| `premiumTitle` | Mehr KI an jedem Tag | |
| `premiumSubtitle` | Tagebuch, Barcode, Suche, Rezepte, Wochenplan, Einkaufsliste, Training und Trends bleiben für alle kostenlos. | |
| `premiumCompareTitle` | Free und Premium | |
| `premiumCompareFree` | Free | |
| `premiumComparePremium` | Premium | |
| `premiumRowCoach` | Coach-Fragen pro Tag | |
| `premiumRowMealAnalysis` | KI-Analysen pro Tag (Foto & Text) | |
| `premiumRowRecipeImport` | Rezept-Importe pro Tag | |
| `premiumRowRecipePicture` | KI-Bild zu Coach-Rezepten | |
| `premiumIncluded` | enthalten | (semantics) |
| `premiumNotIncluded` | nicht enthalten | (semantics) |
| `premiumLegacyNote` | Für dein Konto gelten vorerst weiter die bisherigen Limits: {coach} Coach-Fragen, {analyses} KI-Analysen und {imports} Rezept-Importe pro Tag. | coach:int, analyses:int, imports:int |
| `premiumLegacyNoteUntil` | Für dein Konto gelten bis {date} noch die bisherigen Limits: {coach} Coach-Fragen, {analyses} KI-Analysen und {imports} Rezept-Importe pro Tag. | date, coach:int, analyses:int, imports:int |
| `premiumBenefitPicture` | Coach-Rezepte mit KI-Bild – das Bild bleibt auf deinem Gerät | |
| `premiumBenefitKeep` | Endet dein Abo, bleibt alles erhalten – auch gespeicherte Rezepte und ihre Bilder | |
| `premiumPlanYearly` | Jährlich | |
| `premiumPlanMonthly` | Monatlich | |
| `premiumPlanYearlyPrice` | {price} pro Jahr | price |
| `premiumPlanMonthlyPrice` | {price} pro Monat | price |
| `premiumPlanPerMonth` | entspricht {price} im Monat | price |
| `premiumPlanSavings` | {percent} % günstiger | percent:int |
| `premiumPlanTrialBadge` | {days, plural, =1{1 Tag kostenlos} other{{days} Tage kostenlos}} | days:int |
| `premiumTrialToday` | Heute: Premium freigeschaltet | |
| `premiumTrialCharge` | Ab {date}: {price} pro Jahr, vorher jederzeit kündbar | date, price |
| `premiumCtaTrial` | {days, plural, =1{1 Tag gratis testen} other{{days} Tage gratis testen}} | days:int |
| `premiumCtaSubscribe` | Premium abonnieren | |
| `premiumContinueFree` | Weiter mit Free | |
| `premiumRenewalYearly` | Verlängert sich jedes Jahr automatisch zu {price}, bis du kündigst. | price |
| `premiumRenewalMonthly` | Verlängert sich jeden Monat automatisch zu {price}, bis du kündigst. | price |
| `premiumCancelAnytime` | {store, select, apple{Kündigen kannst du jederzeit in den App-Store-Abos deiner Apple-ID.} other{Kündigen kannst du jederzeit in deinen Google-Play-Abos.}} | store |
| `premiumTermsLink` | Nutzungsbedingungen | |
| `premiumPrivacyLink` | Datenschutz | |
| `premiumRestore` | Käufe wiederherstellen | |
| `premiumRestoreNothing` | Kein aktives Abo gefunden. | |
| `premiumRestoreDone` | Premium ist wieder aktiv. | |
| `premiumLoadingOffers` | Preise werden geladen … | |
| `premiumStoreUnavailableTitle` | Käufe sind gerade nicht möglich | |
| `premiumStoreUnavailableBody` | Der Store ist auf diesem Gerät gerade nicht erreichbar. Eatova Free kannst du ganz normal weiter nutzen. | |
| `premiumRetry` | Erneut versuchen | |
| `premiumPendingTitle` | Zahlung ausstehend | |
| `premiumPendingBody` | Sobald {store, select, apple{der App Store} other{Google Play}} die Zahlung bestätigt, schalten wir Premium frei. Das kann einen Moment dauern. | store |
| `premiumSuccessTitle` | Willkommen bei Premium | |
| `premiumSuccessBody` | Deine höheren Tageslimits gelten ab sofort. | |
| `premiumSuccessContinue` | Los geht's | |
| `premiumOwnedByOther` | Dieses Abo gehört zu einem anderen Eatova-Konto. Melde dich mit diesem Konto an, um es zu nutzen. | |
| `premiumPurchaseFailed` | Der Kauf hat nicht geklappt. Bitte versuch es noch einmal. | |
| `premiumVerifyLater` | Dein Kauf ist angekommen, die Bestätigung dauert noch. Wir versuchen es automatisch weiter. | |
| `premiumAlreadyActiveTitle` | Du hast Premium | |
| `premiumManage` | Abo verwalten | |
| `premiumClose` | Schließen | (tooltip) |
| `profileSectionSubscription` | Abo | |
| `subscriptionTierFree` | Free | |
| `subscriptionTierPremium` | Premium | |
| `subscriptionPlanYearly` | Jahresabo | |
| `subscriptionPlanMonthly` | Monatsabo | |
| `subscriptionRenewsOn` | Verlängert sich am {date} | date |
| `subscriptionEndsOn` | Endet am {date} | date |
| `subscriptionGrace` | Zahlung fehlgeschlagen – Premium bleibt bis {date} aktiv | date |
| `subscriptionOnHold` | Zahlung fehlgeschlagen – bitte in deinen {store, select, apple{App-Store-Abos} other{Google-Play-Abos}} prüfen | store |
| `subscriptionPaused` | Abo pausiert | |
| `subscriptionExpiredOn` | Abgelaufen am {date} | date |
| `subscriptionRevoked` | Abo erstattet oder widerrufen | |
| `subscriptionManualUntil` | Freigeschaltet bis {date} | date |
| `subscriptionVia` | {store, select, apple{über den App Store} other{über Google Play}} | store |
| `subscriptionTestPurchase` | Testkauf | |
| `subscriptionUsageTitle` | Heute genutzt | |
| `subscriptionUsageCoach` | Coach | |
| `subscriptionUsageAnalyses` | KI-Analysen | |
| `subscriptionUsageImports` | Importe | |
| `subscriptionUsageValue` | {used}/{limit} | used:int, limit:int |
| `subscriptionUsageValueLabel` | {used} von {limit} genutzt | used:int, limit:int (screen-reader label of `subscriptionUsageValue`) |
| `subscriptionFreeBody` | Mit Premium bekommst du {coach} Coach-Fragen und {analyses} KI-Analysen pro Tag. | coach:int, analyses:int |
| `subscriptionManagedElsewhere` | Dein Abo läuft über {store, select, apple{den App Store} other{Google Play}}. Verwalten kannst du es dort. | store |
| `settingsSubscriptionRow` | Abo | |
| `settingsDeleteSubscriptionWarning` | Dein Abo läuft über {store, select, apple{den App Store} other{Google Play}} weiter, bis du es dort kündigst. Das Löschen deines Kontos beendet es nicht. | store |
| `legacyNoticeTitle` | Neu: Eatova Premium | |
| `legacyNoticeBody` | Ab {date} gelten für Eatova Free neue Tageslimits: {coach} Coach-Fragen, {analyses} KI-Analysen und {imports} Rezept-Importe. Bis dahin bleibt für dich alles wie bisher. | date, coach:int, analyses:int, imports:int (Free only) |
| `legacyNoticeMorePremium` | Mehr KI gibt es mit Premium. | (Free only, after `legacyNoticeBody`) |
| `legacyNoticeBodyPremium` | Ab {date} gelten für dein Premium-Abo die regulären Premium-Limits: {coach} Coach-Fragen, {analyses} KI-Analysen und {imports} Rezept-Importe pro Tag. Bis dahin bleibt für dich alles wie bisher. | date, coach:int, analyses:int, imports:int (from `legacy.premium`) |
| `legacyNoticeBodyPremiumPlain` | Ab {date} gelten für dein Premium-Abo die regulären Premium-Limits. Bis dahin bleibt für dich alles wie bisher. | date (without `legacy.premium`) |
| `legacyNoticeTerms` | Geänderte AGB lesen | |
| `legacyNoticeDismiss` | Verstanden | |
| `planLimitTitle` | Tageslimit erreicht | |
| `planLimitCoach` | {limit, plural, =1{Deine Coach-Frage für heute ist genutzt.} other{Deine {limit} Coach-Fragen für heute sind genutzt.}} Ab {time} Uhr geht es weiter. | limit:int, time |
| `planLimitCoachPremium` | {limit, plural, =1{Deine Coach-Frage für heute ist genutzt.} other{Deine {limit} Coach-Fragen für heute sind genutzt.}} Ab {time} Uhr geht es weiter – mit Premium {premiumLimit} pro Tag. | limit:int, time, premiumLimit:int |
| `planLimitMeal` | {limit, plural, =1{Deine KI-Analyse für heute ist verbraucht.} other{Deine {limit} KI-Analysen für heute sind verbraucht.}} Barcode, Suche und Favoriten gehen weiter. Ab {time} Uhr wieder frei. | limit:int, time |
| `planLimitMealPremium` | {limit, plural, =1{Deine KI-Analyse für heute ist verbraucht.} other{Deine {limit} KI-Analysen für heute sind verbraucht.}} Barcode, Suche und Favoriten gehen weiter. Ab {time} Uhr wieder frei – mit Premium {premiumLimit} pro Tag. | limit:int, time, premiumLimit:int |
| `planLimitImport` | {limit, plural, =1{Dein Rezept-Import für heute ist genutzt.} other{Deine {limit} Rezept-Importe für heute sind genutzt.}} Eigene Rezepte kannst du weiter anlegen. Ab {time} Uhr wieder frei. | limit:int, time |
| `planLimitImportPremium` | {limit, plural, =1{Dein Rezept-Import für heute ist genutzt.} other{Deine {limit} Rezept-Importe für heute sind genutzt.}} Eigene Rezepte kannst du weiter anlegen. Ab {time} Uhr wieder frei – mit Premium {premiumLimit} pro Tag. | limit:int, time, premiumLimit:int |
| `planLimitUpgrade` | Mehr mit Premium | |
| `planRemainingAnalyses` | {count, plural, =0{Heute keine KI-Analyse mehr} =1{Heute noch 1 KI-Analyse} other{Heute noch {count} KI-Analysen}} | count:int |
| `coachComposerUpgrade` | Mehr Fragen mit Premium | |
| `coachInfoPremiumLine` | Mit Premium: {limit} Coach-Fragen pro Tag | limit:int |
| `coachRecipePictureLocked` | KI-Bild mit Premium | |

The plain `planLimit*` texts are the Premium and "already shown today"
variants; the `*Premium` texts carry the upgrade sentence and appear with the
"Mehr mit Premium" action.

## 5. Delivery and owner steps

Order: migration live (backward compatible: old handlers ignore the new
tables, the provider-budget change only lifts ceilings, and every existing
account is legacy) → merge → deploy `coach-chat`, `analyze-meal`,
`recipe-import`, `subscription-verify`, `store-notifications` → app build.

The Free pool (section 7) follows the same order: migration
`20261026100000` live (backward compatible: deployed handlers read only
`allowed` and `reason`) → merge → deploy `coach-chat`, `analyze-meal`,
`recipe-import` → app build.

Owner steps outside the repository (details in
[operations](OPERATIONS.md)):
1. Play Console: publish a build with Billing to the internal track, create
   `eatova_premium` with the base plans `monthly` (7,99 EUR) and `yearly`
   (49,99 EUR) and a 7-day free-trial offer on `yearly`, add license testers.
2. Google Cloud: a service account with Play "View financial data" and
   "Manage orders and subscriptions"; its key JSON as the function secret
   `EATOVA_PLAY_SERVICE_ACCOUNT_JSON`.
3. Optional: a Pub/Sub topic for Real-time developer notifications with a
   push subscription to `store-notifications` (OIDC audience and service
   account as `EATOVA_PUBSUB_PUSH_AUDIENCE` and `EATOVA_PUBSUB_PUSH_SA_EMAIL`).
4. Apple (after joining the paid program): the Paid Apps Agreement, the
   subscription group with both products and the introductory offer, the
   App Store Server Notifications V2 URL, sandbox testers.
5. Legal: publish new AGB (paid tier, store billing, cancellation, the new
   Free limits, the shared Free capacity) and the privacy text (purchase
   data). The four-week announcement and `plan_settings.legacy_until` were
   meant for other people's accounts; with only the owner's test accounts
   the window ended on 2026-10-25 (1.1). A draft is in
   [PREMIUM-LEGAL-DRAFT.md](PREMIUM-LEGAL-DRAFT.md).

## 6. Why these numbers (decision agents, summarized)

- **Cost per use** (estimates from the prompts and caps, not yet measured):
  Coach question about 0.015 USD, `/recipe` with picture about 0.087 USD (the
  picture alone 0.067), `/plan` 0.035, a meal analysis about 0.011, an import
  about 0.02. Net revenue = price / 1.19 (VAT) x 0.85 (store fee): 5,71 EUR a
  month on the monthly plan, 2,98 EUR a month on the yearly plan.
- **Premium:** a typical subscriber costs about 1,97 EUR of AI a month
  (+34 % on yearly, +66 % on monthly); a realistic heavy user is about break
  even on yearly once usage decays over the year. 49,99 EUR is the lowest
  round yearly price where both stay positive; 59,99 would sit above AI-first
  rivals (Cal AI 34,99-44,99, Foodvisor 47,99), 39,99 loses money on daily
  users. 7,99 EUR monthly stays below every AI rival's 9,99.
- **Free (first round):** a typical active Free user was estimated at about
  0,50 EUR a month with Coach 3, analyses 4 and imports 2.
- **Free (after the abuse review, section 7):** the per-account number does
  not bound a bot, so it is a product decision. Coach 2 keeps one real
  question and a follow-up; 3 analyses cover three meals logged by AI, and a
  fourth goes in through barcode, search or a favorite; 1 import is up to
  two paid attempts. Cutting Free was possible without notice because the
  app is not public; after the launch raising Free stays easy and cutting
  needs four weeks' notice.
- **Caps:** the Free feature maximum is 2 x 2 + 3 + 1 x 2 = 9 provider calls
  a day (a Coach question is a classifier and an answer call, an import an
  attempt and one retry); the cap of 11 adds one refunded Coach retry. The
  Premium maximum is 110 (cap 150). A legacy account with Premium gets
  20 x 3 + 100 + 20 x 2 = 200 (cap 200, with `daily_user_limit` at least
  200). The first round raised the global ceilings so a handful of heavy
  accounts could not exhaust them; the Free pool now does that job, and the
  ceilings stay low until the launch (section 7).
- **Triggers** (from the `ai_call` token logs 2-4 weeks after launch): above
  about 2,20 EUR AI cost per subscriber and month, move the picture to a
  cheaper image size or model first; if typical Free cost exceeds 0,75 EUR,
  lower Free analyses by one.
- **Follow-up:** refund an analysis slot after a provider outage; with a
  single-digit Free bucket that is fairer. `release_edge_rate_limit`
  (section 7) now gives the slot back after a capacity denial before any
  paid call; a release after an outage can reuse it.

## 7. Abuse protection

Contract of 2026-10-25, decided by three decision agents (median per number,
majority per measure) after five analyses (cost, a red team, sign-up,
attestation, quotas). Migration `20261026100000_free_ai_pool.sql`.

### 7.1 Why a pool and not the per-account number

Accounts are free, never expire, and every quota resets at 00:00 UTC. A bot
creates a stock of accounts once and uses each one every day, so a lower
per-account Free number only changes how many accounts it needs. Before this
change the only hard bound was one global ceiling shared by Free and
Premium, 3000 calls and 200 pictures per UTC day: about 215 Free accounts
(3000 / 14 calls) could spend about 150 to 330 USD a day and then lock
Premium out until midnight with `ai_budget_exhausted`.

A Free pool bounds the money whatever the number of accounts: all Free
accounts together get at most `daily_free_call_limit` provider calls a day.
It is counted in `reserve_ai_provider_call` under the existing singleton
lock, so parallel requests cannot pass it, and the tier is resolved in the
database, not by the client. The per-account numbers (2/3/1, cap 11) are
then a product choice.

### 7.2 Bounds in USD

The most expensive single call is a Coach answer with an image, 24,000
characters of history and the 4,096-token output cap: about 0.105 USD at
Sonnet 5.5 prices (2 USD input, 10 USD output per million tokens; the
characters-per-token ratio is an estimate). Before the launch:

| | Calls per UTC day | Worst case per day |
| --- | --- | --- |
| A bot without paying (the Free pool) | 150 | about 16 USD |
| Everything, Free and Premium | 400 | about 42 USD |
| Recipe pictures (Premium only) | 20 | about 1.5 USD |

Pictures count among the 400 calls, so about 43.5 USD a day is a safe upper
bound. The reservation layer keeps Premium at least 250 calls a day
(400 - 150) whatever Free does, but only while the monthly provider spend
limit (7.6) is not reached: a farm that uses the whole Free pool every day
spends about 7 to 16 USD a day, so a 50 USD monthly limit runs out after
about 3 to 7 days, and then the provider refuses every tier, Premium
included, until the month resets or the limit is raised. Before the launch
that is the accepted overall damage limit; the 20 USD alert or several days
of `free_calls_warning` mean: lower the pool or set it to 0. These are
request counts, not money limits; the spend limits are the only bound in
dollars.

### 7.3 Reservation order and the `scope` field

`reserve_ai_provider_call` resolves the plan once after the singleton lock.
An account counts as Free when its tier is not `premium` (a legacy account
without Premium included). It denies with reason `budget_exhausted` and a
`scope`, checked in this order:

| Order | Condition | `scope` |
| --- | --- | --- |
| 1 | the day's calls reach `daily_call_limit` | `all` |
| 2 | picture call and the day's pictures reach `daily_image_limit` | `images` |
| 3 | picture call and the plan has no `recipe_picture` | `plan` |
| 4 | Free account and the day's `free_calls` reach `daily_free_call_limit` | `free` |
| 5 | the account's calls reach `least(daily_user_limit, provider_calls_daily)` | `account` |

An allowed Free call also adds 1 to `ai_provider_daily_usage.free_calls`, a
global counter without a user id. The answer stays `{allowed, reason}`, so
deployed handlers keep working; only a `budget_exhausted` denial adds
`scope`.

### 7.4 What the user sees

- The three AI functions answer a budget denial with
  `429 {"error":"ai_budget_exhausted","scope":…,"resetAt":…}` (`scope` when
  the RPC named a known one, `resetAt` the next 00:00 UTC; `coach-chat` keeps
  `session_id`).
- A capacity denial, an AI switch-off or a reservation outage no longer
  costs an honest user a day slot. When the first reservation of a request
  ends in any provider budget error (a denial, `disabled`, or a reservation
  RPC that fails, times out or is aborted), no provider call was made, and
  `analyze-meal` gives back the `analyze-meal:user-day` and
  `analyze-meal:global` slots it took; `recipe-import` does the same for
  `recipe-import:user-day` on its first attempt. The reservation itself is
  never refunded, even when the RPC committed it before a timeout. Neither
  releases after a paid call or for any other error. The release is best
  effort: when it fails (3 s bound), the answer is the same and the slot
  stays spent. `coach-chat` already refunds the question on a budget error
  (not after a client abort).
- `release_edge_rate_limit(p_scope, p_subject, p_window_start,
  p_window_seconds)` takes one count off a limiter bucket, never below 0,
  and only for an aligned window that has started; `service_role` only.
- The app shows `scope: "free"` as "Die kostenlose KI ist für heute
  ausgelastet. Ab {time} Uhr geht es weiter." ("Free AI is at capacity for
  today. It is back at {time}."), the meal analysis adds "Barcode, Suche und
  Favoriten funktionieren weiter.", with no upgrade offer and no locked
  composer. Older builds show their generic "not reachable" message.

### 7.5 Switches and sizing

- Stop all Free AI, keep Premium:
  `update public.ai_provider_limits set daily_free_call_limit = 0 where singleton;`
  (scope `free`, the calm notice). Current apps then say Free AI is back at
  the next 00:00 UTC, so use it only for a stop that ends by then; for a
  longer or open-ended stop use the second switch or a general stop switch.
- Or through the per-account cap of the `free` row:
  `update public.plan_tiers set provider_calls_daily = 0, updated_at = now() where tier = 'free';`
  (scope `account`, the generic message; the column allows 0, only the
  feature limits need at least 1; a legacy account reads the `legacy` row
  instead).
- Before the launch: pool 150, total 400, pictures 20. Sizing and the
  checks are in [operations](OPERATIONS.md#free-ai-pool).

### 7.6 Owner steps now

- Anthropic Console: a monthly spend limit of about 50 USD before the launch,
  with an alert at about 20 USD, on the workspace of the production key.
- OpenRouter: a credit limit of about 10 USD on the picture key.
- Console labels are not verified; details in
  [operations](OPERATIONS.md#provider-spend-limits).

### 7.7 Before the public launch

Documented, not built in this change:

1. **Size the pools** from ops-watch data: `daily_free_call_limit` about
   Free daily active users x 5 calls x 1.5; `daily_call_limit` = the Free
   pool + a Premium reserve (at least 150 x the heavy Premium accounts);
   `daily_image_limit` about 50 to 100. Raise the Anthropic spend limit to
   match.
2. **Before User Created Postgres hook:** a blocklist table of disposable
   email domains and a per-IP throttle for new accounts (5 per hour, 20 per
   day, IPv6 by /64). Probe it on a disposable GoTrue first, because the hook
   fails closed.
3. **Cloudflare Turnstile through Supabase CAPTCHA:** an app release first
   (`captchaToken` on `signUp`, `signInWithPassword`, resend and
   `resetPasswordForEmail`), then switch it on. It protects the project-wide
   60 mails per hour.
4. **Play Integrity standard requests** on the three AI functions, with the
   `requestHash` bound to user, function and request id. Monitor mode for 2
   to 4 weeks, then enforce for Free only; unattested requests fall into a
   small pool. iOS after the paid Apple program. Update the privacy text and
   the Data safety form.
5. **Store trials:** count trial accounts against the Free pool, or cap their
   pictures, once trial phases are visible in verified store data.
6. **Real token cost:** measure it from the `ai_call` logs; then consider a
   smaller Free history budget or a Haiku evaluation (recipe import first).
7. Optional: a **canonical identity key** (an HMAC of the normalized email or
   the Google `sub`), so deleting and re-creating an account keeps the day's
   usage.
