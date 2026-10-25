# Backend configuration and operations

Updated for the **2026-09-15 security work**; the Premium tier (plans, store
subscriptions and two new functions) was added **2026-10-25**
([contract](PREMIUM.md), [section below](#premium-plans-and-store-subscriptions)),
and the same day the shared Free AI pool ([abuse protection](PREMIUM.md#7-abuse-protection))
and one account per mailbox ([below](#one-account-per-mailbox), not live yet).
This guide describes source contracts; environment values can override
defaults. Runtime inspection and deployment are separate from editing this
documentation.

## Services and persistence

| Service | Responsibility |
| --- | --- |
| Supabase Auth | Email/password, Google token exchange, OTP/account flows; one account per mailbox through the Before User Created hook and two BEFORE triggers on `auth.users` ([below](#one-account-per-mailbox)) |
| Postgres + RLS | Profiles, diary, favorites, weight, recipes, plans, shopping checks, workout history, chat and quota |
| `analyze-meal` | Authenticated photo/context input, or a typed or dictated meal description, to a structured nutrition estimate |
| `coach-chat` | Authenticated chat/stream, recipe, training-plan and workout-log proposals; quotas, validation and guardrails |
| `recipe-import` | Authenticated TikTok link or pasted text to recipe drafts |
| `search-key` | Authenticated product-index URL and limited search credentials |
| `subscription-verify` | Authenticated: verifies a Google Play or App Store purchase, binds it to the account, re-checks stored Google purchases, returns the plan |
| `store-notifications` | Public webhook with its own signature checks: App Store Server Notifications V2 and Google Play real-time notifications (Pub/Sub push) |
| Meilisearch / Open Food Facts | Public product data lookup; OFF fallback |

Apply the source migrations in version order to a new project. The generated
[schema access map](../supabase/SCHEMA_STATE.md) records the current migration count and
describes RLS, policies, grants and functions; table columns/constraints live in
the [migration files](../supabase/migrations). Do not hand-edit the generated map.

Client writes commit the account-scoped encrypted cache and durable outbox in
one SQLite transaction. [Offline sync](OFFLINE_SYNC.md) defines the server
receipt protocol, recipe version history, conflicts and rollout. Important
contracts include explicit/idempotent planned-meal consumption, immutable
completed workout snapshots and deletion receipts that prevent stale history
from reappearing. Training-history deletion markers retain identifiers rather
than workout content; operation receipts may retain their original result data.
Recipe and proposal image bytes stay on the device, not in Postgres.

Sources: [store and sync](../lib/src/app/home_store_sync.dart),
[meal plans](../lib/src/app/home_store_meal_plan.dart),
[training history](../lib/src/app/home_store_training_history.dart),
[core feature contracts](CORE-FEATURES-IMPLEMENTATION-2026-09-10.md).

### One account per mailbox

GoTrue matches addresses exactly, so `jane.doe@gmail.com` and
`janedoe@gmail.com`, one Gmail mailbox, could each hold an account and its
Free allowance. Migration `20261027100000_email_alias_guard.sql` allows one
account per canonical key, `public.email_canonical_key(text)`:

- trim and lowercase, split at the last `@`, drop one trailing dot from the
  domain, and read `googlemail.com` as `gmail.com`;
- for `gmail.com` only, remove every dot from the local part (dots matter
  for Workspace, Outlook and iCloud);
- for every domain, cut the local part at the first `+`;
- if that leaves the local part empty, keep it unstripped (`+x@gmail.com`
  stays itself); blank input gives null, an address without `@` or with an
  empty side stays lowercased.

Yahoo-style `-` addresses, IDN spellings and `name.fastmail.com` subdomains
are not folded. Another account holds a key when it is confirmed, or, for
an email signup, when it is unconfirmed, was created less than an hour ago
and no unconfirmed row of the key is older (`email_alias_holder_exists`): a
stranger's unconfirmed alias never gets its code and blocks the real owner
for one hour at most, also when it is renewed with a new spelling every
hour. The user's own account never counts.

| Path | Guard | Answer |
| --- | --- | --- |
| Signup by email or OTP, first Google, OAuth or ID-token sign-in | Before User Created hook `auth_before_user_created` | 422 `User already registered`, GoTrue's own duplicate answer (code `unknown`) |
| Any insert into `auth.users`: concurrent signups (per-key advisory lock), admin-created users, the hook switched off | BEFORE INSERT trigger | 500, raised as `P0001` without an address |
| The confirmed email change, the first confirmation of an address | BEFORE UPDATE trigger | 500 |

An email change request itself passes: refusing it would roll back
`email_change_sent_at` after GoTrue sent the change mails, and GoTrue's
per-user mail throttle reads that column, so one account could drain the
project's mail budget.

There is no key table and no unique index: each check scans `auth.users`,
first with a builtin prefix test (without dots, an address starts with the
first three characters of its key's local part) and only then with the key
function. Measured on the CI Postgres image with 100,000 synthetic accounts
whose first names share prefixes: about 115 ms per lookup (about 2 s
without the prefix test). A signup runs it twice (hook and insert trigger),
a first Google sign-in three times. GoTrue gives the hook no time limit of
its own (see [operations](OPERATIONS.md#before-user-created-hook)), so
revisit with a server-only, indexed key table at about 50,000 accounts.
Existing
rows are not changed (one pair of the owner's test accounts shares a key
and keeps working), and deleting an account frees its key at once. The hook
and the trigger function are SECURITY DEFINER with an empty `search_path`;
only `supabase_auth_admin` (which gets USAGE on `public`) and
`service_role` may execute the hook, the other three functions only
`service_role`. Enabling, fail-open behavior and rollback:
[operations](OPERATIONS.md#before-user-created-hook); what the app shows:
[email OTP contract](../supabase/AUTH_EMAIL_OTP.md#ein-konto-pro-postfach-2026-10-25)
and [Google](../supabase/OAUTH_SETUP.md#one-account-per-mailbox).

### AI consent and answer reports

Migration `20261019100000_ai_consents_reports.sql` adds two append-only,
client-written logs with RLS (own rows; insert and select only):

- `ai_consents`: one row per consent decision (`version`, `granted`,
  `health_data`; withdrawal = `granted false`). The latest row per user is the
  state. The client may insert only those three columns; `user_id`
  (`auth.uid()`), `id` and `created_at` come from defaults.
- `ai_reports`: "Report answer" / "Report picture" on Coach output
  (`message_id`, optional `session_id`, `target` `answer`/`recipe_image`,
  `reason` `incorrect`/`harmful`/`inappropriate`/`other`). No message content.

A trigger (`enforce_user_daily_row_cap`) bounds both per user and UTC day
(20 consents, 30 reports). The app gates every AI entry point through
`ensureAiConsent` ([sheet](../lib/src/widgets/shared/ai_consent_sheet.dart),
[controller](../lib/src/app/ai_trust.dart)): a grant counts only after this
insert succeeded, a withdrawal takes effect on the device at once and is
uploaded when the server is reachable. The Edge Functions do **not** check
the consent yet, because builds released before it would break; enforcing it
server-side (`analyze-meal`, `coach-chat`, `recipe-import` reading the latest
`ai_consents` row) is a follow-up once those builds are retired. Both tables
are in the in-app export and cascade with account deletion. Apply the
migration before shipping an app build that writes them; until then the
consent insert fails and the app sends no AI request.

## AI configuration

Text and photo understanding run on the **Anthropic Messages API** (Claude);
only recipe pictures are generated through OpenRouter.

| Setting | Source default | Used by |
| --- | --- | --- |
| `CLAUDE_MODEL` | `claude-sonnet-5-5` | Coach (classifier, replies, recipe text, training drafts, `/log`), meal photo and description analysis, recipe import |
| `COACH_EFFORT` | `high` | Thinking depth of Coach classifier (capped at `high`), replies, recipes and `/log` |
| `COACH_PLAN_EFFORT` | `medium` | Thinking depth of Coach training plans |
| `ANALYZE_MEAL_EFFORT` | `medium` | Thinking depth of meal photo analysis |
| `ANALYZE_MEAL_DESCRIBE_EFFORT` | `low` | Thinking depth of meal description analysis (voice flow, kept fast) |
| `RECIPE_IMPORT_EFFORT` | `medium` | Thinking depth of recipe import |
| `COACH_IMAGE_MODEL` | `google/gemini-3.1-flash-image` | Recipe picture generation (OpenRouter) |
| `COACH_DAILY_LIMIT` | no longer read | Was the daily per-user Coach quota (5); since Premium the limit comes from `plan_tiers` per request ([plans](#premium-plans-and-store-subscriptions)) |

The source of truth is [_shared/claude.ts](../supabase/functions/_shared/claude.ts),
[analyze-meal/handler.ts](../supabase/functions/analyze-meal/handler.ts),
[coach-chat/handler.ts](../supabase/functions/coach-chat/handler.ts) and
[recipe-import/handler.ts](../supabase/functions/recipe-import/handler.ts).
Credentials: `ANTHROPIC_API_KEY` (required by all three functions) and
`OPENROUTER_API_KEY` (recipe pictures only; without it a recipe arrives without
a picture). Both live only in the function environment. Effort accepts `low`,
`medium`, `high`, `xhigh` or `max`; an unknown value is logged and ignored.
Changing an effort or model secret needs no redeploy.

Calls use raw `fetch`, not the Anthropic SDK: the functions stay
dependency-free, provider bodies stay byte-bounded, and each call keeps its own
deadline, retry and refund policy. Every call sends adaptive thinking, an
explicit effort, no sampling parameters, and the system prompt as a cached
prefix. Structured routes (classifier, recipe, plan, `/log`, meal analysis,
import) request a JSON schema through `output_config.format`, so the model
returns exactly one object; the existing validators still enforce limits.
Claude's `stop_reason` maps onto the former completion vocabulary
(`end_turn` = stop, `max_tokens` = length, `refusal` = content filter). An
empty credit balance (HTTP 400) and a key-permission error (403) count as our
outage and refund the Coach slot; on a text-only call every input-fault
status (400, 413) counts as our outage, because the server validated the
text itself. A classifier call the provider declines for safety becomes a
signposting refusal, not an error. Lone UTF-16 surrogates (an emoji cut by a
length cap) are replaced before sending, since the API rejects them as
invalid JSON. Images with an edge above 8,000 px are rejected with
`image_too_large` before quota, because the API refuses them.

Measured on 2026-10-08 with the real prompts (Sonnet 5.5, single requests, not
a benchmark): greetings and classification about 1.5 s at any effort; Coach
answers 5-6 s, or about 9 s at `high` when they reason over app data
(about 6 s at `medium`); recipes about 5-16 s plus the picture; plans 17-21 s
at `medium` (at `high` a 5-7 session plan took 33 s or hit the token cap
near the 45 s deadline); `/log` 2-4 s; meal analysis 4-5 s at `medium` and
10-12 s at `high` with the same estimates; a three-recipe import about 10 s at
`medium` and 20-32 s at `high` with the same candidates (`low` missed a
variant). Plans use at most four distinct workouts, rotated across the week
when the user trains more often, so they fit that deadline. Meal description
at `low` has not been measured live yet.

Recipe import caps its output, thinking included, at 4,500 tokens (about 37 s
at ~120 tokens/s) and answers a reached cap with `source_too_long`. The cap is
fixed, not derived from measured throughput or effort: at `high`, thinking
uses more of it, so content that fits at `medium` can end as
`source_too_long`. Measure a 4-6 recipe paste before raising
`RECIPE_IMPORT_EFFORT` or changing the cap.

This settles R2-1 of the 2026-10-11 audit only in part. The 422 replaced a
paid 504 that invited a paid retry, and the import sheet does not resend the
same text, but the first attempt on content that cannot fit is still paid: the
cap shows only in the provider's answer, so such a request spends one
`recipe-import:user-day` slot, one `coach_recipe` reservation and up to about
37 s of paid output before the 422. Until a 4-6 recipe paste is measured at
`medium`, the text limits stay at 20,000 characters: `MAX_TEXT_CHARS` in
`recipe-import/handler.ts` and `MAX_SOURCE_CHARS` for fetched pages in
`source.ts`, `EdgeFunctionRecipeImportService.maxTextLength`, the import
sheet's field, `RecipeShareReceiver.maxTextLength`, iOS
`RecipeShareInbox.maxTextLength` with its `share.invalid` strings, Android
`RecipeShareBridge.MAX_TEXT_LENGTH`, and `recipeImportInvalidInput` in both ARB
files. After that measurement, a character check after `loadSource` and before
the user-day gate can answer `source_too_long` without spending the gate or the
reservation, and those limits and texts drop to match.

The OpenRouter-era secrets `OPENROUTER_MODEL`, `COACH_MODEL_ANSWER`,
`COACH_MODEL_CLASSIFIER`, `COACH_MODEL_LOG` and `RECIPE_IMPORT_MODEL` are no
longer read and can be removed after the rollout.

Ordinary Coach replies support SSE and JSON. SSE text is held server-side until
the full provider completion and output checks pass. The wire format remains
meta/delta/done/error; the app shows its thinking state while approval is pending.
This also prevents already transmitted text from escaping a later refusal.
A client disconnect (COACH-4) does not abort the reserved answer call: the
server reads it to the end within the 45 s answer deadline and 512 KiB cap,
runs the same final check, and stores the approved answer or the refusal once,
like the buffered path, without sending further bytes and without a refund.
A provider failure after the disconnect stores nothing and refunds nothing (a
client abort never refunds). The handler and the stream pump are registered
with `EdgeRuntime.waitUntil` so the worker outlives the request for that work.
/recipe, /plan and /log are buffered and finish and persist after a
disconnect once their draft call has started. A disconnect earlier, during
the classifier call or the user-row store, stops at the next provider budget
gate (it is reserved with the request's signal): the question stays stored
without an answer and the slot stays spent. That is pinned as a cost rule in
`handler_boundary_test.ts`; changing it is an open owner decision
(review 2026-10-22). After a lost connection the app checks the transcript; if the
question is stored without an answer, it keeps its thinking state and checks
again every 3 s (none while backgrounded) until the request's own deadline
from the send (chat 95 s, /recipe 165 s, /plan and /log 105 s), then shows the
answer or the usual error with retry. No second request is sent meanwhile.

The classifier requests structured categories; benign approvals require an
explicit `stop` completion. Malformed ordinary-chat or image-plus-text
classification fails closed. Recipe and training modes keep
their dedicated validation paths. Provider `content_filter` completion is a
safety refusal across answer modes, with no accepted proposal or recipe-image
follow-up. Refusals do not refund a paid safety check. An image without text
does not gain a meaningful text-classifier check; the model's semantic safety
still requires separate evaluation. See the scoped [security checkbook](../SECURITY_AUDIT.md).

Chat receives a bounded nutrition/profile snapshot and recent messages. Recipe
drafting uses the explicit recipe wish plus, when the user set any, a narrow
`preferences` field `{diet?, avoid?, dislikes?}`: closed codes shared with
`profiles_food_avoidances_check`, at most 120 characters of dislikes, and
`400 invalid_preferences` for anything else or outside `recipe` mode. The codes
become hard requirements in the uncached system tail; the dislikes pass Layer 1
and travel as framed data. An obvious break is labelled in the description and
listed in `preference_conflicts`, never re-drafted
([recipe_preferences.ts](../supabase/functions/coach-chat/recipe_preferences.ts)).
Image generation uses the generated title/description. Training can receive an explicit brief and selected-plan
snapshot. Proposals are returned/persisted as chat data, but user recipes and
training plans are adopted only after confirmation in the client.

Coach request modes are a closed set: absent (chat, plus the `/plan` text
command), `chat`, `recipe`, `plan` and `log`. Any other `mode` is
`400 invalid_mode`, and an explicit mode always wins over text commands.
`log` turns a finished workout into a proposal: the request is
`{message, mode: "log", local_date, locale, session_id}`, where `local_date`
(`YYYY-MM-DD`, the user's calendar day) is required for `log`, rejected
elsewhere and must lie within one day of the server's UTC day. `/log` text
without the mode, a log with a photo, `user_context` or `training_context`, and
an empty wish are `400` before session, quota or provider work. The flow is
prefilter, one daily slot, classifier (refuses self-harm, eating-disorder and
injection; a medical mention is logged with a fixed safety line at the end of
the summary; unusable output refuses), then one extraction call (`temperature`
0, JSON, low excluded reasoning, 4,096 tokens, 45 s) under the `coach_plan`
provider-budget operation. The server converts pounds to kilograms rounded to
0.01, nulls a `performed_on` outside `[local_date - 30, local_date]`, and
validates the result strictly (schema v1 in
[workout_log.ts](../supabase/functions/coach-chat/workout_log.ts), mirrored
by `is_valid_coach_workout_log` on `chat_messages.workout_log`). The
extraction's `weight_unit` is required only where a weight is given, and a
model refusal may omit `workout`. The buffered response is `{reply,
workout_log, remaining?, daily_limit, session_id, assistant_message_id?}`.

A log refusal is HTTP 200 with `{reply, refusal: true, refusal_reason,
session_id}` plus the quota fields of its stage:

| Stage | `refusal_reason` | Quota fields |
| --- | --- | --- |
| Prefilter (layer 1) | `doping`, `eating_disorder`, `illegal_drugs`, `self_harm`, `off_topic_homework`, `prompt_injection` | none: no slot is claimed, so `remaining` and `daily_limit` are omitted |
| Classifier (layer 2) | `self_harm`, `eating_disorder`, `injection`, `classifier_unusable` | `remaining?`, `daily_limit` |
| Extraction | `model_refusal` (provider safety filter), `log_not_a_workout`, `log_not_completed`, `log_too_large`, `log_unsafe` | `remaining?`, `daily_limit` |

Under the plan fallback both quota fields are left out at every stage and in
the successful answer as well ([fail-to-Free rule](#plan-per-request-and-the-fail-to-free-rule)).

The stored assistant row prefixes classifier categories with `classifier_`;
`classifier_unusable` keeps its name. A message over 1,000 characters is
`413 message_too_long` with `refusal_reason: "too_long"`, before any session
or quota work. Classifier and extraction refusals keep the slot; an invalid or
truncated draft, a provider outage or a failed user-row store refunds it once
to the claim day. The function never writes training history: the app saves
the workout only after the user confirms the card. Chat answers follow the app
language when a message mixes languages and point reported workouts to `/log`.

Quota is claimed atomically on the server, with the account's Coach limit
from its plan. Failure/refund behavior depends on
the outcome; it is not a promise that every unsuccessful request is free. A
failed recipe image can leave a usable recipe with a placeholder. See the
[recipe completion fix](SENTRY-RECIPE-2026-09-13.md) for the latest recorded
recipe validation and provider-completion work.

An independent provider-call budget is enforced before **each** billable HTTP
request, including classification and optional recipe images. The atomic
`reserve_ai_provider_call` RPC locks the configuration row and increments
non-refundable global and account counters. Missing configuration/RPC evidence
fails closed. Existing feature quotas and their selective refunds remain separate.

| `ai_provider_limits` setting | Default | Meaning |
| --- | --- | --- |
| `daily_call_limit` | 1000; raised to at least 3000 by `20261025100000`, lowered to at most 400 by `20261026100000` | All provider calls per UTC day, Free and Premium |
| `daily_user_limit` | 150; raised to at least 200 by `20261025100000` | Operator ceiling per account and UTC day; the effective ceiling is the lower of this and the account plan's `provider_calls_daily` (11 Free, 150 Premium or legacy, 200 for a legacy account with Premium) |
| `daily_image_limit` | 50; raised to at least 200 by `20261025100000`, lowered to at most 20 by `20261026100000` | Recipe image calls per UTC day, also counted globally |
| `daily_free_call_limit` | 150 (`20261026100000`, 0 to 100,000) | Provider calls of all Free accounts together per UTC day (the Free pool); 0 stops Free AI and keeps Premium working |
| `enabled`, `coach_enabled`, `analysis_enabled`, `images_enabled` | true | Administrative stop switches |

`20261025100000` only raised these values (`greatest(...)`);
`20261026100000` lowers the call and picture ceilings to pre-launch values
with `least(...)`, so a lower live value stays. The live values are not
recorded here; sizing is in [operations](OPERATIONS.md#free-ai-pool).
Zero is a valid limit. Administrative configuration is not client-writable.
An exhausted budget returns `429/ai_budget_exhausted` with the `scope` of
the denial and `resetAt` (the next 00:00 UTC); disabled or unavailable
budget verification returns a controlled `503`. Optional image exhaustion keeps
an otherwise valid recipe usable without a generated picture. The client does
not mislabel these service limits as the user's personal question quota.
These are request counts, **not dollar limits**, and they cannot cancel an
already reserved upstream call. See the [stop and recovery procedure](OPERATIONS.md).

Since `20261026100000` the RPC resolves the plan once per call and counts an
account as Free when its tier is not `premium`. An allowed Free call also
adds 1 to the global `ai_provider_daily_usage.free_calls`, and a Free call is
denied once that reaches `daily_free_call_limit`. The answer stays
`{allowed, reason}`, plus `scope` on a `budget_exhausted` denial (`all`,
`images`, `plan`, `free`, `account`, checked in that order), so older
handlers keep working. When the first reservation of a request ends in any
provider budget error (a denial, `disabled`, or a failed, timed-out or
aborted reservation RPC), nothing was paid: `analyze-meal` gives back the
`analyze-meal:user-day` and `analyze-meal:global` slots it took, and
`recipe-import` its `recipe-import:user-day` slot, through
`release_edge_rate_limit`, best effort; neither releases after a paid call,
and the reservation itself is never refunded. `coach-chat` refunds the question as before. The
app shows `scope: "free"` as a calm "at capacity" notice with the reset time
([contract](PREMIUM.md#74-what-the-user-sees)).

The Coach upload reader has a 30-second total and 10-second idle deadline while
preserving its byte limit. Provider text/error envelopes are capped at 512 KiB;
successful recipe-image envelopes at 8 MiB. All three functions validate the
verified Auth response and user token context; clients cannot add privileged
request fields. Meal-photo checks bound container dimensions before quota work;
the Flutter compressor additionally removes opaque metadata and checks PNG/ICC
inflation before the relevant decoder stage. Structural checks do not establish
complete pixel validity or provider-decoder safety.

`analyze-meal` also takes a meal description instead of a photo
(`{mealText, language}`, contract in [MEAL-DESCRIBE.md](MEAL-DESCRIBE.md)). It
runs through the same gates, provider budget (`analyze_meal`) and deadlines.
Before any day slot, `mealText` with `imageBase64`, `portionHint` or
`freeTextHint` is `400 ambiguous_input`; a text with control or bidi
characters, or outside 2-500 characters after whitespace collapse, is
`400 invalid_meal_text`; neither field is still `missing_image`. The text
reaches the model only as a JSON string value in the user turn, under its own
prompt and schema, and is never logged (counts and lengths only). A text
without food answers `422 no_food_in_text` after the paid call. The photo
response is unchanged; only a describe result carries `mode: "describe"`,
`slotHint` and the item fields `proteinG`, `carbsG`, `fatG`, `searchQuery`,
`brand`, `amountText` and `gramsSource`.

Per-account provider counters contain only user ID, UTC date and reserved-call
count; own counters are exportable and cascade on account deletion. Records
older than 30 days are pruned on the first permitted call of a new UTC day,
not by a guaranteed background TTL. Inactivity or disabled AI can delay pruning.
Global counters, the Free pool's `free_calls` included, have no user ID.
See [privacy data flows](../PRIVACY.md).

Changing a model requires checking its input/output capabilities separately:
the recipe-image model must generate images; a chat/vision model is not a
drop-in replacement. Review server overrides when deploying, without printing
API keys or private configuration. A model ID in source does not independently
prove current provider availability or a successful live generation.

## Premium plans and store subscriptions

Migration `20261025100000_premium_subscriptions.sql`, `_shared/plan.ts`, the
store modules in `_shared/` and the two functions `subscription-verify` and
`store-notifications` implement the [Premium contract](PREMIUM.md) of
2026-10-25. Only the server grants Premium, after verifying the store's proof;
the client never decides its tier, and request bodies still cannot carry a
premium claim ([request_fields_test.ts](../supabase/functions/_shared/request_fields_test.ts)).
Delivery order: migration, merge, deploy of `coach-chat`, `analyze-meal`,
`recipe-import`, `subscription-verify` and `store-notifications`, then an app
build ([owner steps](PREMIUM.md#5-delivery-and-owner-steps),
[store setup](OPERATIONS.md#premium-store-setup)).

### Tables

| Table | Content | Access |
| --- | --- | --- |
| `plan_tiers` | Three rows `free`, `premium`, `legacy` with `coach_daily`, `meal_analysis_daily`, `recipe_import_daily`, `provider_calls_daily` and `recipe_picture` | `service_role` reads; operators change values by SQL |
| `plan_settings` | One row: `legacy_created_before` (set to the migration's time) and `legacy_until` (null) | `service_role` reads |
| `store_account_tokens` | One random UUID per account, sent to the stores as `applicationUserName` (Google `obfuscatedAccountId`, Apple `appAccountToken`); not the user id | `service_role` reads; created by `get_store_account_token` |
| `store_subscriptions` | One row per verified store purchase or manual grant: platform, `store_key` (Google `purchaseToken`, Apple `originalTransactionId`, `manual:<label>`), product, base plan, status, `expires_at`, `auto_renewing`, environment, ownership, acknowledgement, `superseded_by`, last order/transaction id, event time and (Apple) `last_purchase_at`, the purchase date of the binding transaction; unique per `(platform, store_key)` | `service_role` reads; written only by `record_store_subscription` or an operator |
| `store_notification_receipts` | Notification ids already received (Apple `notificationUUID`, Pub/Sub `messageId`), no user id, pruned after 90 days | no role; only `record_store_notification` |

All five have RLS on and no policies; `anon` and `authenticated` hold no
privilege on any of them, so store keys never leave the server. They are not
part of the in-app export (the Profile shows the plan through `get_my_plan`).
`store_account_tokens` and `store_subscriptions` cascade with account
deletion; deleting the account does not cancel the store subscription.

Seeded limits per UTC day (reset 00:00 UTC; the `free` row as set by
`20261026100000`, first seeded as 3 / 4 / 2 / 30):

| Tier | Coach questions | AI meal analyses | Recipe imports | Provider calls | Coach recipe picture |
| --- | --- | --- | --- | --- | --- |
| `free` | 2 | 3 | 1 | 11 | no |
| `premium` | 20 | 30 | 10 | 150 | yes |
| `legacy` | 5 | 100 | 20 | 150 | yes |

Rules, all in `resolve_plan`:

- **Entitled** is a row with status `active`, `grace` or `canceled`
  (auto-renew off, paid until `expires_at`), `expires_at > now()` and
  `superseded_by is null`. The tier is `premium` with such a row, else
  `free`. Expiry is computed on every read; nothing is scheduled.
- **Legacy account**: created before `plan_settings.legacy_created_before`,
  while `legacy_until` is null or in the future. Without a settings row no
  account is legacy.
- **Current limits**: Free uses `free`, a legacy Free account `legacy`,
  Premium `premium`; a legacy Premium account gets the higher value of
  `premium` and `legacy` per feature (and the picture if either has it) and
  a provider-call ceiling that covers that maximum (Coach x 3 + analyses +
  imports x 2: 20 x 3 + 100 + 20 x 2 = 200 with the seeded rows).
- A downgrade or expiry deletes nothing; Free limits apply from the next
  request. Denied attempts are not counted, so a mid-day upgrade gets the
  full new allowance at once; because the daily counters keep their count, a
  downgrade can deny until the next reset.

### Functions

| Function | Execute | Purpose |
| --- | --- | --- |
| `plan_tier_for(uuid)` | `service_role` | `'premium'` or `'free'` |
| `resolve_plan(uuid)` | `service_role` | Tier, legacy flag, current limits and the effective Premium limits; one call per AI request. A missing tier row raises `55000` |
| `plan_snapshot(uuid)` | `service_role` | The account view: tier, subscription (never `store_key`, tokens or transaction ids), current/free/premium limits, legacy window, today's usage, `reset_at` |
| `get_my_plan()` | `authenticated`, `service_role` | `plan_snapshot(auth.uid())`; `42501` without a user |
| `get_store_account_token()` | `authenticated`, `service_role` | The caller's token, created on the first call (volatile: call it with POST) |
| `store_account_owner(uuid)` | `service_role` | Token to account, for notifications |
| `store_subscription_owner(text, text)` | `service_role` | Owner of a stored purchase, or null |
| `record_store_subscription(...)` | `service_role` | Upsert of one verified Google or Apple purchase: `{outcome: stored \| stale \| owned_by_other, tier}`; trailing `p_rebind` and `p_purchase_at` for Apple re-binding |
| `mark_store_subscription_acknowledged(text, text)` | `service_role` | Sets `acknowledged = true` on one row after the server's Google acknowledgement succeeded |
| `record_store_notification(text, text)` | `service_role` | True the first time an id is seen; prunes receipts older than 90 days |
| `consume_edge_rate_limits(jsonb)` | `service_role` | The shared limiter, same signature: increments a bucket only while it is below its limit, so a denied attempt counts in no bucket |
| `reserve_ai_provider_call(uuid, text)` | `service_role` | `20261025100000`: the per-account ceiling is `least(daily_user_limit, provider_calls_daily of the plan)`. `20261026100000`: the plan is resolved once; a Free account also counts in `free_calls` against `daily_free_call_limit`; a picture call needs `recipe_picture`; a `budget_exhausted` denial carries `scope` |
| `release_edge_rate_limit(text, text, timestamptz, integer)` | `service_role` | `20261026100000`: takes one count off a limiter bucket (scope, raw subject hashed like `consume_edge_rate_limits`, window start, window seconds), never below 0; the window start must be aligned and not in the future; returns whether a row changed |

`record_store_subscription` validates every enum and length (`22023`, also
for an unknown account). The first verified binding of a `(platform,
store_key)` wins: another account gets `owned_by_other` and nothing changes.
The one exception is Apple, which keeps one `originalTransactionId` per
Apple ID across the subscription group (renewals, crossgrades,
resubscribes): with `p_rebind` and a `p_purchase_at` later than the row's
`last_purchase_at`, the row moves to the caller. `subscription-verify`
passes `p_rebind` only for a transaction whose `appAccountToken` is the
caller's own token, `store-notifications` only when the owner came from that
token; without a token, with a foreign one, or for Google, the binding
stays. Every write keeps the latest `last_purchase_at`.
An event older than the stored `last_event_at` is `stale` (notifications
arrive out of order). A null optional field (`base_plan_id`,
`auto_renewing`, `ownership`, `acknowledged`, `last_transaction_id`) keeps
the stored value, so an Apple re-verification without renewal info does not
erase what a notification stored. A Google `linkedPurchaseToken` marks the
replaced row of the same account as superseded. Manual rows
(`platform = 'manual'`) are SQL-only.

`plan_snapshot` reads usage from the same buckets the functions count:
`chat_quota_usage.used_count` for the Coach, and `edge_rate_limits` scopes
`analyze-meal:user-day` and `recipe-import:user-day` (subject hash
`sha256(<user id>)` in hex, today's 86,400 s window). Denied attempts do not
count in those buckets; each value is still capped at the current limit,
which matters only after a downgrade. The subscription shown is the entitled
row that runs longest, otherwise the most recently updated row (for "payment
failed" or "expired on"), otherwise null. For a legacy account, `legacy`
carries `until` and `premium`, the base Premium tier limits without the
legacy maximum.

### Plan per request and the fail-to-Free rule

`coach-chat`, `analyze-meal` and `recipe-import` call `resolvePlan`
([plan.ts](../supabase/functions/_shared/plan.ts)) once per request after
authentication: `/rest/v1/rpc/resolve_plan` with the service key,
`redirect: 'error'`, a 4 KiB answer cap, at most 5 s, and a strict check of
the answer's shape. Any failure (transport, timeout, non-2xx, another shape)
returns `FREE_FALLBACK`, never more: Free 2/3/1 with 11 provider calls and no
picture, Premium 20/30/10 for the upgrade hint, `fallback: true`. The request
keeps working with those limits and writes one log line,
`resolve_plan unavailable`, without a body or a user id. During such an
outage Premium accounts get the Free limits. A request those limits would
deny is not answered as the account's daily quota, because its real limit is
unknown: `coach-chat`, `analyze-meal` and `recipe-import` answer
`503 {"error":"plan_unavailable"}` without `planLimit`, so the app shows a
retryable error with no lock and no upgrade offer, and the next request after
the outage gets the real plan. A `coach-chat` request the fallback allows is
answered as usual, but its 200 names no limit: in every mode (chat,
`/recipe`, `/plan`, `/log`), streamed or buffered, and for a refusal after
the claim, the body carries neither `daily_limit` nor `remaining`. The app
then keeps its counter and asks for the count again, so the fallback's 2
never locks a Premium or legacy account's composer. A `/recipe` under the
fallback gets no picture and no `image_locked`, neither in the response nor
in the stored row, because the account's plan may include the picture.
`FREE_FALLBACK` is code: changing the `free` row does not change it.

`reserve_ai_provider_call` reads `resolve_plan` inside SQL. A missing tier
row therefore fails the reservation closed (`503 ai_budget_unavailable`),
like any other unavailable budget configuration.

| Gate | Before Premium | With Premium |
| --- | --- | --- |
| Coach daily questions (`claim_chat_quota`) | `COACH_DAILY_LIMIT`, default 5 | `coach_daily` of the plan, passed as `p_daily_limit`; every `daily_limit` field and the quota text use the request's value (a 200 under the fallback sends no `daily_limit` and no `remaining`). `COACH_DAILY_LIMIT` is no longer read |
| Meal analyses per day (`analyze-meal:user-day`, photo and Describe together) | `ANALYZE_MEAL_USER_DAY_LIMIT`, default 100 | `meal_analysis_daily` of the plan. `ANALYZE_MEAL_USER_DAY_LIMIT` is no longer read for this gate |
| Recipe imports per day (`recipe-import:user-day`) | 20 (constant) | `recipe_import_daily` of the plan |
| Coach `/recipe` picture | every recipe | only with `recipe_picture`; otherwise no image call and no `coach_image` reservation. When a real plan excludes the picture, the recipe response and the stored recipe JSON in `chat_messages` carry `image_locked: true` (so the app shows the lock again after a reload); under the fallback neither does |
| Provider calls per account | `daily_user_limit` (150) | `least(daily_user_limit, provider_calls_daily)` |
| Free pool | none: Free and Premium shared one ceiling | `daily_free_call_limit` for all Free accounts together (`20261026100000`); Premium is not counted |
| Burst, IP, auth-fail and global gates | constants and overrides | unchanged: Coach 60/h and IP 120/600 s; `analyze-meal` hourly, IP and global gates with their `ANALYZE_MEAL_*` overrides; `recipe-import` 20/h and IP 60/600 s; the global provider and image ceilings |

The contract records `COACH_DAILY_LIMIT` and `ANALYZE_MEAL_USER_DAY_LIMIT`
as not set live; a value set later has no effect on these gates.

### The `planLimit` object

A denial of exactly the per-account daily quota adds this object to the
existing 429 body of all three AI functions:

```json
"planLimit": { "feature": "coach", "tier": "free", "limit": 2, "resetAt": "2026-10-26T00:00:00.000Z", "premiumLimit": 20 }
```

`feature` is `coach`, `meal_analysis` or `recipe_import`; `resetAt` is the
next 00:00 UTC. `premiumLimit` is present only for a Free account whose
effective Premium limit is higher, and never for the fallback plan, so the
app offers an upgrade only then. Under the fallback the denial answers
`503 plan_unavailable` instead (see above).
A burst, IP, auth-fail or global gate never carries `planLimit`. Everything
else stays for older app builds: `coach-chat` keeps `error:"quota_exceeded"`,
`reply`, `remaining: 0` and `daily_limit` (at least 1) and adds `reset_at`,
and its `reply` names the Premium allowance for Free accounts; `analyze-meal`
and `recipe-import` keep `error:"rate_limited"`, `rateLimit` and
`Retry-After`, and `recipe-import` also adds `resetAt`.

### `subscription-verify`

`verify_jwt` on. POST JSON, body at most 64 KiB, gates IP 60 per 600 s and
user 30 per 3,600 s, authentication and 401 codes as in `analyze-meal`
(`missing_bearer_token`, `user_token_required`, `invalid_user_token`).

| Body | Meaning |
| --- | --- |
| `{"action":"verify","platform":"google","productId":"eatova_premium","purchaseToken":"…"}` | Verify a Play purchase |
| `{"action":"verify","platform":"apple","signedTransaction":"<JWS>"}` | Verify a StoreKit 2 transaction |
| `{"action":"refresh"}` | Re-check up to three stored Google rows of the caller that expired or expire within 48 h and were not verified in the last 10 minutes, then return the plan |

Answers: 200 `{"outcome":"active"|"inactive","plan":<plan_snapshot>}`; 202
`purchase_pending` with the plan (Google PENDING); 400 `invalid_request`; 401
as above; 409 `purchase_owned_by_other_account`; 422 `purchase_invalid` with
`reason` `signature`, `bundle`, `product`, `environment`, `ownership` or
`account`; 429 `rate_limited` with `Retry-After`; 503 `store_not_configured`,
`store_unavailable` or `rate_limit_unavailable`.

Every in-app purchase carries the buyer's account token, so another Eatova
account presenting it gets 422 `account`, before anything is stored. The app
shows that as "Dieses Abo gehört zu einem anderen Eatova-Konto" and never
completes the purchase, so this session neither acknowledges nor finishes a
transaction that may not be stored for anyone. 409 applies to a token-less
purchase (bought outside the app) already bound to another account, or an
Apple transaction older than the binding one; the app shows the same text
and completes it.

- **Google**: a service-account access token (RS256 JWT bearer through
  WebCrypto, cached per isolate until 60 s before expiry,
  [google_auth.ts](../supabase/functions/_shared/google_auth.ts)), then
  `purchases.subscriptionsv2.get`
  ([play_subscriptions.ts](../supabase/functions/_shared/play_subscriptions.ts)).
  The product must be allowlisted; `obfuscatedExternalAccountId`, when
  present, must equal the caller's account token (otherwise the first
  presenter binds). States map ACTIVE to `active`, IN_GRACE_PERIOD to
  `grace`, CANCELED to `canceled`, ON_HOLD to `on_hold`, PAUSED to `paused`,
  EXPIRED and PENDING_PURCHASE_CANCELED to `expired`; PENDING answers 202 and
  grants nothing. `expires_at` is the latest `expiryTime` of the allowlisted
  line items, `testPurchase` becomes environment `test`, and a
  `linkedPurchaseToken` is superseded. An active or grace purchase that is
  still unacknowledged is acknowledged after it is stored (in `verify` and
  in `refresh`); when that succeeds, `mark_store_subscription_acknowledged`
  sets `acknowledged = true` on the row, a failure is logged as
  `subscription-verify acknowledge failed` with the HTTP status only. Without
  `EATOVA_PLAY_SERVICE_ACCOUNT_JSON` Google purchases answer 503
  `store_not_configured`.
- **Apple**: the StoreKit 2 JWS is verified offline
  ([jws_apple.ts](../supabase/functions/_shared/jws_apple.ts)): `alg` ES256
  only, exactly three `x5c` certificates, the root pinned to Apple Root CA - G3
  by SHA-256, Apple's leaf and intermediate marker OIDs, the chain signatures
  and validity at `signedDate`; the payload is read only after the signature
  verified. Then `bundleId`, the product allowlist, an auto-renewable type,
  environment Production or Sandbox (Sandbox is stored as `sandbox`: App
  Review buys in the sandbox against the production backend),
  `inAppOwnershipType` `PURCHASED`, `appAccountToken` equal to the caller's
  token when present, `revocationDate` to `revoked`. The store key is
  `originalTransactionId`, the event time `signedDate`; `purchaseDate` is
  passed as `p_purchase_at` and `p_rebind` is set when `appAccountToken` is
  present, so a newer purchase on the same Apple ID moves the binding to the
  account that made it. `auto_renewing` stays
  null until a notification brings the renewal info. The server sends
  nothing to Apple.

Sandbox and test purchases grant Premium on the production backend by
design (App Review, Google license testers); the snapshot names their
environment and the Profile marks them as test purchases.

### `store-notifications`

`verify_jwt` off, set only for this slug in the tracked
`supabase/config.toml`; it authenticates every request itself. `OPTIONS` 204;
POST only; body at most 256 KiB; an IP gate before any verification.

- **Apple** (`{"signedPayload":"<JWS>"}`): the payload and its nested
  `signedTransactionInfo` and `signedRenewalInfo` pass the same verifier and
  the `bundleId` check. The `notificationType` decides the row: SUBSCRIBED,
  DID_RENEW, DID_CHANGE_RENEWAL_STATUS, DID_FAIL_TO_RENEW (with GRACE_PERIOD
  `grace`, otherwise `on_hold`), GRACE_PERIOD_EXPIRED, EXPIRED, REFUND and
  REVOKE (`revoked`), REFUND_REVERSED; TEST answers 200. The owner is the
  account of `appAccountToken` when the token is present and resolves
  (recorded with `p_rebind` and the transaction's `purchaseDate`, so a newer
  purchase re-binds as in `subscription-verify`), else the stored row of
  `originalTransactionId`.
- **Google** (Pub/Sub push): `Authorization: Bearer <Google OIDC JWT>`,
  verified against Google's JWKS (RS256, cached): issuer
  `accounts.google.com`, `aud` equal to `EATOVA_PUBSUB_PUSH_AUDIENCE`,
  `email` equal to `EATOVA_PUBSUB_PUSH_SA_EMAIL` and verified, not expired.
  Then `message.data` is decoded and `packageName` checked. A
  `subscriptionNotification` re-fetches `subscriptionsv2` and records the
  result, a `voidedPurchaseNotification` revokes, a `testNotification`
  answers 200.
- **Repeats**: every delivery is verified and applied.
  `record_store_subscription` orders events by `last_event_at`, so a repeated
  Apple delivery writes the same signed state again and an older event is
  `stale`; a Google delivery always re-reads the current state from Play.
  Either way a repeat adds no change of its own; it only refreshes
  `last_verified_at` and `updated_at`. Afterwards
  `record_store_notification` (Apple `notificationUUID`, Pub/Sub
  `message.messageId`) labels a repeat as `duplicate`. Applying first and
  writing the receipt afterwards keeps a delivery that failed with 503 from
  being dropped as a duplicate on the store's retry.
- Answers: 200 processed, duplicate or unknown owner (dropped, for example a
  deleted account); 400 `invalid_notification`; 401
  `invalid_notification_auth`; 503 `not_configured` or `store_unavailable`,
  so the store retries.

Without notifications, renewals still reach the account: the app restores
silently on start and re-verifies, and `refresh` re-checks stored Google
purchases. Refunds and cancellations are then learned only at the next
restore or refresh, which is the gap the notifications close.

### App side

The app reads `get_my_plan` and `get_store_account_token` through its user
session and calls `subscription-verify` with a bearer pinned to the account
([subscription_sync.dart](../lib/src/services/subscription_sync.dart)). The
last plan is cached per account in the encrypted cache (slot `plan_status`,
next to `paywall_prompt`, `legacy_notice` and `upsell_shown`, the UTC day of
the last "Mehr mit Premium" offer per feature, so the offer stays once per
day across restarts); until the first answer the app shows the decided
defaults (`PlanStatus.assumed()`), and every number on screen afterwards
comes from the server. A purchase is completed in the store only after the
server answered `active`, `inactive` or `owned_by_other` (409), never after
a 422.

## Function environment

| Variable | Purpose |
| --- | --- |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | Function-side project/auth/database clients; privileged key stays on the server |
| `ANTHROPIC_API_KEY` | Claude credential for Coach, meal analysis and recipe import |
| `OPENROUTER_API_KEY` | Image-model credential for Coach recipe pictures (optional) |
| Model/quota settings above | Optional overrides |
| `EATOVA_ALLOWED_ORIGINS` | Optional comma-separated CORS allow-list |
| `EATOVA_MIRROR_SEARCH_KEY` | Search-only Meilisearch key; required for normal mirror operation |
| `EATOVA_MIRROR_BASE_URL` | Mirror URL; source default `https://eatova.de/meili` |
| `EATOVA_MIRROR_KEY_UID` | Optional UID enabling scoped, expiring tenant tokens |
| `EATOVA_MIRROR_SEARCH_INDEX` | Tenant-token index scope, default `products` |
| `EATOVA_SEARCH_KEY_TTL_SECONDS` | Credential refresh TTL, default 43,200 seconds; clamped to 3,600–604,800 |
| `EATOVA_PLAY_SERVICE_ACCOUNT_JSON` | Secret: the whole key JSON of the Google service account for the Play Developer API (`subscription-verify`, `store-notifications`); without it Google purchases answer `503 store_not_configured` |
| `EATOVA_PLAY_PACKAGE_NAME` | Play package, default `com.eatova.app` |
| `EATOVA_PREMIUM_PRODUCT_IDS` | Product allowlist, default `eatova_premium,eatova_premium_monthly,eatova_premium_yearly` |
| `EATOVA_APPLE_BUNDLE_ID` | Expected App Store `bundleId`, default `com.eatova.app` |
| `EATOVA_PUBSUB_PUSH_AUDIENCE`, `EATOVA_PUBSUB_PUSH_SA_EMAIL` | OIDC audience and service-account email of the Pub/Sub push subscription (`store-notifications`); without them Google notifications answer `503 not_configured` |

These are the principal operator settings, not a dump of private runtime
configuration. Rate-limit tuning and validation remain in the function sources.

## Product-search key rotation

The client resolves credentials through [SearchCredentials](../lib/src/services/search_credentials.dart):

1. Use the device-global cached URL/key; stale credentials can be served while
   a refresh runs. This cache is public service configuration, not account data.
2. Refresh from `search-key`, receiving URL and key/token together.
3. Use the configured client fallback when no usable runtime credentials exist.
4. Fall back to public Open Food Facts when the mirror cannot be used.

`EATOVA_MIRROR_KEY_UID` enables tenant-token mode: the server signs an expiring
token restricted to the configured index instead of returning the underlying
search key. Without a UID it returns the static search-only key. Token expiry
includes a ten-minute grace beyond the announced refresh TTL. This documents
available behavior, not which mode is currently enabled in production.

For rotation, provision a replacement search-only key, update the server key
and matching UID if tenant mode is used, then retire the old key. A rejected
credential (`403`) makes the client invalidate, refetch and retry the query once.
Refetch is single-flight and has a one-minute cooldown. TTL refresh also
propagates URL changes, which need not produce a `403`.

- Server disable: `EATOVA_MIRROR_SEARCH_KEY=disabled` returns empty credentials.
- Missing server key: configuration error, not an intentional disable.
- Local build disable: explicitly empty `OFF_MIRROR_URL` prevents that client
  from contacting the mirror even if the server later enables it.

See [search-key/index.ts](../supabase/functions/search-key/index.ts) and
[client configuration](DEVELOPMENT.md#client-configuration). Never distribute
the Meilisearch master key to clients.

## Verification and deployment

Use a separate project or disposable local Postgres for development and RLS
tests. Follow [CONTRIBUTING.md](../CONTRIBUTING.md) before a code PR. A production
rollout requires verifying the target project, the exact reviewed revision,
pending migrations and function configuration. Do not infer the target's role
from a credential-store environment name such as `dev`. Deploy Edge Functions
with the approved workflow, which also verifies the live source and keeps a
deploy record ([Edge Function deploys](OPERATIONS.md#edge-function-deploys)).

Source history records the Gemini switch in [PR #74](https://github.com/mxritzgit/Eatova/pull/74),
the six-feature backend rollout in [PR #77](https://github.com/mxritzgit/Eatova/pull/77),
and the latest recipe completion fix in [PR #83](https://github.com/mxritzgit/Eatova/pull/83).
The latter record verifies `coach-chat` v46 against the merged source;
`analyze-meal` v29 and `search-key` v9 were unchanged at that checkpoint.
After explicit rollout approval on 2026-09-14, security [PR #90](https://github.com/mxritzgit/Eatova/pull/90)
was deployed as `coach-chat` **v47** and `analyze-meal` **v30**; `search-key` remained
**v9** at that checkpoint. Both changed functions were ACTIVE with JWT verification enabled, and their
downloaded production import graphs match the reviewed source. Model overrides
were checked without changing settings or invoking billable AI. See the
[deployment evidence and limits](../SECURITY_AUDIT.md#verifizierte-veröffentlichung-am-14092026).
These are dated deployment records, not a fresh live inspection on every read.

CI replays migrations and RLS against disposable Postgres. The separate
production migration comparison runs only on `main` in the protected
`supabase-drift` environment; its success checks migration history, not every
function deployment or provider response. See [workflows](../.github/workflows).

On **2026-09-15 at 00:03–00:04 UTC**, all three `20260915...` migrations were
applied atomically before deploying `coach-chat` **v48**, `analyze-meal` **v31**
and `search-key` **v10**. Their complete source graphs (16, 13 and 6 files)
match the reviewed code; all are ACTIVE with JWT verification enabled. The
independent live catalog comparison confirms all 46 migrations and the tested
RLS, grants and function definitions. Source commit `78f8d55` passed the full
protected CI before deployment: 4620 Flutter tests, 95.0% coverage and all builds.
See the [versioned rollout evidence](SECURITY-ROLLOUT-2026-09-15.json) and
[current audit](../SECURITY_AUDIT.md#runde-3--abschlussstand-vor-runde-4).

The configuration readback also confirmed the actual injected key types:
`SUPABASE_ANON_KEY` contains a project publishable key here, and
`SUPABASE_SERVICE_ROLE_KEY` contains a project secret key. Do not infer the key
format from a legacy variable name. The platform-managed update timestamps
changed during deployment; current project bindings and known model overrides
were verified without writing or disclosing credentials. Full pre/post secret
value equality was not retained or asserted. No production behavioral tests
were performed. The three text-model overrides match the table above; recipe
images use the source default because no image-model override is configured.

The outgoing service REST/RPC requests put the identical key in `apikey` and
Bearer, satisfying Supabase's [documented compatibility exception](https://github.com/orgs/supabase/discussions/29260).
The official [supabase-js v2.110.7 REST initialization](https://github.com/supabase/supabase-js/blob/v2.110.7/packages/core/supabase-js/src/SupabaseClient.ts#L353)
also retains this combination; that SDK is a comparison reference here.
User authentication still requires a real user JWT and verified account binding.
No header change was justified. This source review does not prove execution by
the hosted gateway; the local Auth probe stubs REST/RPC. Obtain any additional
gateway execution evidence in an approved synthetic staging environment.

CI now exercises PostgreSQL 17.6, atomic budget races, synthetic two-cluster
restore, native dependency inventories and the offline Coach evaluation harness.

## Published privacy documentation follow-up

The [German website policy](https://eatova.de/datenschutz) was first corrected
after explicit approval on 2026-09-14 at 21:34 UTC. Its **2026-09-15 00:13 UTC**
extension now documents the deployed provider-call counters and activity-triggered
retention accurately. Gemini, Android steps, planning and approved-response
data flows remain documented. Provider contracts, account
privacy/retention settings and legal requirements still need separate assessment.

The [single-file correction record](PRIVACY-WEBSITE-CORRECTION-2026-09-14.md)
identifies the separate `EatovaTest21st` source. The public HTML and updated local
privacy file match; all 34 other website files remained unchanged. Live Chromium
checks at four widths passed with the actual CSP. No device build was installed.
