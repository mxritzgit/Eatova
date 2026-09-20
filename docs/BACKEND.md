# Backend configuration and operations

Updated for the **2026-09-15 security work**. This guide describes
source contracts; environment values can override defaults. Runtime inspection
and deployment are separate from editing this documentation.

## Services and persistence

| Service | Responsibility |
| --- | --- |
| Supabase Auth | Email/password, Google token exchange, OTP/account flows |
| Postgres + RLS | Profiles, diary, favorites, weight, recipes, plans, shopping checks, workout history, chat and quota |
| `analyze-meal` | Authenticated photo/context input to a structured nutrition estimate |
| `coach-chat` | Authenticated chat/stream, recipe and training proposals; quotas, validation and guardrails |
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

| Setting | Source default | Used by |
| --- | --- | --- |
| `OPENROUTER_MODEL` | `google/gemini-3.8-flash` | Meal image analysis |
| `COACH_MODEL_ANSWER` | `google/gemini-3.8-flash` | Chat, recipe text, training drafts |
| `COACH_MODEL_CLASSIFIER` | `google/gemini-3.8-flash` | Coach safety/topic classifier |
| `COACH_IMAGE_MODEL` | `google/gemini-3.1-flash-image` | Recipe picture generation |
| `COACH_DAILY_LIMIT` | `5` | Daily per-user Coach quota |

The source of truth is [analyze-meal/handler.ts](../supabase/functions/analyze-meal/handler.ts)
and [coach-chat/handler.ts](../supabase/functions/coach-chat/handler.ts). Provider
credentials use `OPENROUTER_API_KEY`, only in the function environment. Function
secrets override source defaults, so an old `OPENROUTER_MODEL` can keep a
deployment on a different model even after merging a model change.

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
| `OPENROUTER_API_KEY` | Provider credential for meal analysis and Coach |
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
