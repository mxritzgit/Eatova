# Backend configuration and operations

Checked against main through PR #88 on **2026-09-14**. This guide describes
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

There are **43 SQL migrations** in the reviewed source. Apply them in version
order to a new project. The generated [schema access map](../supabase/SCHEMA_STATE.md)
describes RLS, policies, grants and functions; table columns/constraints live in
the [migration files](../supabase/migrations). Do not hand-edit the generated map.

Client writes use an account-scoped encrypted cache and durable outbox. Important
contracts include explicit/idempotent planned-meal consumption, immutable
completed workout snapshots and deletion receipts that prevent stale history
from reappearing. Receipt rows retain identifiers rather than workout content.
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

Ordinary Coach replies support SSE and JSON. The classifier requests structured
categories; malformed ordinary-chat classification is handled as a provider
error instead of an invented off-topic refusal. Prefilter, classifier and output
guardrails remain active. Recipe and training modes have their own validation
paths; do not assume every mode sends the same prompt/context.

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
These are dated deployment records, not a fresh live inspection on every read.

CI replays migrations and RLS against disposable Postgres. The separate
production migration comparison runs only on `main` in the protected
`supabase-drift` environment; its success checks migration history, not every
function deployment or provider response. See [workflows](../.github/workflows).

## Published privacy documentation follow-up

The GitHub [privacy data-flow document](../PRIVACY.md) is updated with Gemini,
Android steps, meal planning and training history. The published
[German website policy](https://eatova.de/datenschutz), inspected on 2026-09-14,
still names Grok/xAI and old water/sleep goals. Website publication is a separate
follow-up; changing this repository does not update that page. Provider/account
terms and the published notice must be reconciled with the actual deployment.
