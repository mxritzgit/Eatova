# Backend configuration and operations

Updated for the **2026-09-15 security work**. This guide describes
source contracts; environment values can override defaults. Runtime inspection
and deployment are separate from editing this documentation.

## Services and persistence

| Service | Responsibility |
| --- | --- |
| Supabase Auth | Email/password, Google token exchange, OTP/account flows |
| Postgres + RLS | Profiles, diary, favorites, weight, recipes, plans, shopping checks, workout history, chat and quota |
| `analyze-meal` | Authenticated photo/context input, or a typed or dictated meal description, to a structured nutrition estimate |
| `coach-chat` | Authenticated chat/stream, recipe, training-plan and workout-log proposals; quotas, validation and guardrails |
| `search-key` | Authenticated product-index URL and limited search credentials |
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
| `COACH_DAILY_LIMIT` | `5` | Daily per-user Coach quota |

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

The OpenRouter-era secrets `OPENROUTER_MODEL`, `COACH_MODEL_ANSWER`,
`COACH_MODEL_CLASSIFIER`, `COACH_MODEL_LOG` and `RECIPE_IMPORT_MODEL` are no
longer read and can be removed after the rollout.

Ordinary Coach replies support SSE and JSON. SSE text is held server-side until
the full provider completion and output checks pass. The wire format remains
meta/delta/done/error; the app shows its thinking state while approval is pending.
This also prevents already transmitted text from escaping a later refusal.

The classifier requests structured categories; benign approvals require an
explicit `stop` completion. Malformed ordinary-chat or image-plus-text
classification fails closed. Recipe and training modes keep
their dedicated validation paths. Provider `content_filter` completion is a
safety refusal across answer modes, with no accepted proposal or recipe-image
follow-up. Refusals do not refund a paid safety check. An image without text
does not gain a meaningful text-classifier check; the model's semantic safety
still requires separate evaluation. See the scoped [security checkbook](../SECURITY_AUDIT.md).

Chat receives a bounded nutrition/profile snapshot and recent messages. Recipe
drafting uses the explicit recipe wish; image generation uses the generated
title/description. Training can receive an explicit brief and selected-plan
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

The stored assistant row prefixes classifier categories with `classifier_`;
`classifier_unusable` keeps its name. A message over 1,000 characters is
`413 message_too_long` with `refusal_reason: "too_long"`, before any session
or quota work. Classifier and extraction refusals keep the slot; an invalid or
truncated draft, a provider outage or a failed user-row store refunds it once
to the claim day. The function never writes training history: the app saves
the workout only after the user confirms the card. Chat answers follow the app
language when a message mixes languages and point reported workouts to `/log`.

Quota is claimed atomically on the server. Failure/refund behavior depends on
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
| `daily_call_limit` | 1000 | All provider calls per UTC day |
| `daily_user_limit` | 150 | Provider calls per account per UTC day |
| `daily_image_limit` | 50 | Recipe image calls per UTC day, also counted globally |
| `enabled`, `coach_enabled`, `analysis_enabled`, `images_enabled` | true | Administrative stop switches |

Zero is a valid limit. Administrative configuration is not client-writable.
An exhausted budget returns `429/ai_budget_exhausted`; disabled or unavailable
budget verification returns a controlled `503`. Optional image exhaustion keeps
an otherwise valid recipe usable without a generated picture. The client does
not mislabel these service limits as the user's personal question quota.
These are request counts, **not dollar limits**, and they cannot cancel an
already reserved upstream call. See the [stop and recovery procedure](OPERATIONS.md).

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
Global counters have no user ID. See [privacy data flows](../PRIVACY.md).

Changing a model requires checking its input/output capabilities separately:
the recipe-image model must generate images; a chat/vision model is not a
drop-in replacement. Review server overrides when deploying, without printing
API keys or private configuration. A model ID in source does not independently
prove current provider availability or a successful live generation.

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
from a credential-store environment name such as `dev`.

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
[current audit](../SECURITY_AUDIT.md#runde-3--aktueller-stand).

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
