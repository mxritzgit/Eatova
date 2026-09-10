# Eatova core feature implementation

Requested on 2026-09-10 after the three-agent feature review. The user authorized
six implementation subagents, coordinator review and corrections, push, and merge
to main after successful CI. Backend deployment and a production device/store
release are separate delivery steps and are not implied by a successful merge.

Baseline: `1b03c18`; integration branch: `feat/complete-core-features`.
The previous review documents remain preserved and describe the pre-feature state.

## Accepted scope and acceptance criteria

- [x] Saved own and adopted Coach recipes can be edited under the same identity,
  with preparation text, retained local images/provenance, explicit save/discard,
  durable offline confirmation and unchanged historical diary entries.
- [x] Completed workouts have account-isolated, durable history, actual repetitions
  and weight per set, and previous performance in the player. Retries do not
  duplicate completion; discarding creates no completion; recovery is retained
  until completion is safely stored. Plan edits/deletes do not rewrite history.
- [x] Android Health Connect provides aggregated steps with honest permission,
  unavailable, missing-data and measured-zero states. iOS behavior and the calorie
  model remain intact. Only scopes supporting implemented features are requested.
- [x] Structured recipe ingredients support product/manual entry, grams, calculated
  known nutrients, batch portions and fractional logging. Unknown values are not
  invented. Existing free-text/manual recipes remain compatible.
- [x] Coach plan generation offers a brief for goal, experience, equipment and
  available time; a deliberately selected saved plan can be discussed/adapted.
  Submitting is explicit, output remains a draft and existing plans are preserved.
- [x] A weekly meal planner and persistent shopping checklist support future
  recipe/portion/slot choices. Planned meals do not count as eaten. Confirming
  consumption is durable and idempotent. Structured shopping quantities aggregate;
  legacy text stays visibly unquantified rather than guessed.

Additional review suggestions (bulk diary copy, diet editing, export file sharing,
extra nutrients, new reminder types) are outside this implementation request.

## Ownership and dependency contracts

Six isolated worktrees live under ignored `.agents/feature-wave/`.
Only the coordinator changes the integration working tree.

| Agent | Responsibility | Shared interface |
| --- | --- | --- |
| `feature_ingredients` | Recipe models, serialization, ingredient/portion widgets, SQL validation | Publishes model foundation to recipes and mealplan first |
| `feature_recipes` | Existing recipe editor/detail/list and ingredient UI integration | Owns existing recipe screens; accepts planner entry callback |
| `feature_training` | Completed workouts, actual set values, history UI, storage | Coordinates selected-plan action with coach |
| `feature_health` | Android service/native bridge, platform choice and connection states | Preserves HealthService/iOS behavior |
| `feature_coach` | Plan brief, intentional plan context, bounded client/server contract | No extra profile migration required for per-request brief |
| `feature_mealplan` | Planned meals, grocery checklist, consumption transition and storage | Uses structured recipe model and a standalone route |

Coordinator provides a shared confirmed-mutation helper on the existing outbox
receipt machinery. New mutations publish only after server or durable local
acknowledgment. Feature owners retain per-entity ordering and idempotency.
No unrelated refactor or dependency upgrade is part of this work.

New migrations: `20260910180000_recipe_ingredients.sql`,
`20260910181000_training_history.sql`, `20260910182000_meal_plans.sql`.
Do not hand-edit generated `supabase/SCHEMA_STATE.md`; use migration replay.

## Verification and delivery gates

- [x] Scoped behavioral and negative-control regressions for each feature.
- [x] Independent general and security review; reproduce/fix actionable findings.
- [x] Integrated strict Flutter analysis and full dummy-defined test suite.
- [x] Coverage at least 88%, generated localization excluded.
- [x] Deno lint/check/tests and real PostgreSQL migration/RLS checks.
- [x] Android build and user-flow/visual checks (light/dark, small width, large text,
  keyboard and failure paths); document native-device limitations explicitly.
- [x] Changed-source and commit-history secret scans; no incidental dependency
  upgrade or large generated artifacts.

Delivery uses a protected-main PR. Every required/applicable CI check must pass
for the exact submitted head before merge; the coordinator then verifies the
merged tree and clean local main. Consult the PR for the final CI and merge state.
Backend/device delivery requirements are recorded separately below.

## Implemented contracts and review corrections

Recipe editing preserves the saved slug, local photo and Coach provenance. The
editor accepts preparation and structured ingredients, while supplementary
free-text ingredients remain independent shopping items. Batch nutrition is
computed from ingredient grams and per-100g snapshots, then divided by the recipe
yield. Unknown nutrient values remain unknown. Raw ingredient weight does not
establish cooked yield, so these recipes use portions and do not invent a gram
density in the diary, recent meals or favorites.

Training completion freezes actual set values, optional weight, note, completion
time and stable exercise identities. Recovery preserves the same pending
completion through ambiguous delivery and restart. Reordering/deleting source
plans does not rewrite history. Previous performance follows exercise identity,
not its current list position. Rewinding/skipping removes stale validation flags.

Notes retain complete grapheme clusters within the existing 500-codepoint model
limit. Validation is guarded in checkpoint, exit and disposal paths. Permanent
deletion responses are acknowledged only after a UUID-only local receipt is
durably written to the encrypted account cache. Hydration applies these receipts
before publishing history or recovery, so failed mirror/checkpoint cleanup cannot
restore a deleted workout after an offline restart. Transient unreadable receipt
storage fails closed; failed writes keep the outbox retryable. Logout preserves
the receipt with retained sync state; full account cleanup removes it.

Starting/resuming waits for readable receipts and recovery before opening the
player. The repaired checkpoint is protected against replacement by another
session, including completion attempts. Explicit retry rereads local storage;
temporarily hidden history is never persisted as an empty snapshot.

Receipt writes check the actual preferences acknowledgment, including `false`;
an optimistically cached UUID cannot acknowledge a failed disk write. Reads,
merges and full cleanup share an account-namespace queue across cache instances.
A timeout releases the caller without releasing an unfinished operation's lock.
Damaged receipt ciphertext remains occupied and fails closed across restarts;
ordinary Retry can repair a transient read failure, but does not discard a
permanently damaged deletion fence. Explicit full account cleanup removes it.
Cleanup reserves its queue position immediately, but removes the receipt only
after every dependent cache slot has been removed successfully. If an earlier
removal fails, it releases the reservation while retaining the deletion fence.

The server accepts history writes only through `record_training_history` and
`delete_training_history`. Deletion atomically removes all performance payload and
keeps only `(user_id, id)` in `training_history_deletions`, preventing late devices
from recreating the deleted completion. Own receipts are included in account
export and cascade with account deletion. Active history is capped at 2,000;
active rows plus deletion receipts share a 100,000-identity budget. Deleting an
existing completion remains possible at capacity. No authenticated direct
mutation grants bypass these rules. See the generated
[schema state](../supabase/SCHEMA_STATE.md) and the real SQL regression fixture.

Meal planning uses recipe snapshots, explicit date/meal slot and fractional
servings. Shopping quantities aggregate only compatible structured identities;
additional/legacy text is displayed without guessed quantities. Planned meals
remain separate from consumed calories. `eat_planned_meal` returns the canonical
plan, nullable diary meal, statistics and creation receipt atomically. Repeated
consumption, including after diary deletion, does not duplicate meals or counters.
The editor reuses its draft UUID after ambiguous failed saves, even if the user
changes portions before retrying. The recipe picker respects Android safe insets.

Android connection is explicitly enabled per account. Cold restore checks the
existing permission silently; stale account callbacks are discarded. The native
bridge aggregates steps and requests only `READ_STEPS`. It distinguishes no data
from measured zero, and does not request Android weight, background or extended
history access. iOS HealthService behavior and the calorie model are preserved.
The implementation follows the official [Health Connect setup](https://developer.android.com/health-and-fitness/health-connect/get-started)
and [aggregate-data guidance](https://developer.android.com/health-and-fitness/health-connect/read-data/aggregate-data).

Coach plan briefs collect goal, experience, equipment, sessions per week, minutes
and an optional wish. Discuss/adapt deliberately passes the selected saved-plan
snapshot. Existing literal `/plan` input remains compatible. No request is sent
by merely opening the brief, and generated plans require explicit adoption.
Retries retain the same bounded context; profile and workout performance are not
automatically attached. Existing safety, quota and refund paths remain active.

Independent general and security reviews found and prompted corrections for
lost review notes, stale set errors, deleted-history resurrection, ambiguous
planner IDs and omitted supplementary ingredients. Native inspection additionally
found the recipe-picker safe-inset issue. Follow-up reviews prompted the storage,
recovery and cleanup corrections above. Final general and security follow-ups
on `694f0a3` report no remaining actionable findings in their scoped diffs.

## Verification evidence

The integrated `c92f2db` tree passed all 4,322 Flutter tests with the CI dummy
defines; line coverage excluding generated localization was 24,918 / 26,205
(95.09%, required 88%). Strict analyzer and the main-entry Android debug APK
build passed. After the final cleanup-order correction, strict analysis and all
257 scoped cache, account and application-flow tests passed across 21 files.
Negative controls specifically detect receipt loss after failed cleanup and
after delayed encryption plus a new same-account cache instance. The final PR
head must additionally pass the complete CI suite before merge.

Deno lint checked 43 files, all three function entrypoints type-checked, and all
503 tests passed together and in 27 independent file runs. No function source
changed after those checks. Real PostgreSQL replayed all 43 migrations and all
cross-user RLS fixtures, including training deletion receipts and capacity limits.
An isolated negative replay without the deletion guard failed specifically on
the delayed-device resurrection assertion. Feature-level negative controls also
exercise recipe identity/durable acknowledgment, unknown nutrition/cooked mass,
Coach context bounds, planner retry identity/text retention and training recovery.

Ignored local logs and native screenshots are under `.agents/feature-wave/`;
the reproducible tests and SQL fixtures are committed under `test/`. The PR and
its check runs are the durable evidence for final-head CI and merge status.

## Release boundary

This PR changes app code, three migrations and `coach-chat`. Merge alone does not
deploy Supabase or install a new production app. Apply the migrations and deploy
the updated function before releasing clients that use the new RPCs. The protected
main migration-drift job is a separate live check; the PR's stable required gate
does not query production.

Android permission denial/retry/grant and empty Health Connect data are checked
in a synthetic emulator account. Actual physical-device step records, overlapping
phone/watch sources, Play Console declarations and production app/store rollout
remain release verification tasks. No live user health data is used by the tests.

Native Android checks exercised preparation editing with the keyboard visible,
batch recalculation, fractional diary logging, future planning, grocery quantities
and checks, planned-to-eaten conversion, workout actuals/note/history and Last time.
The final picker title clears the status bar. Recipe, training, planner and Coach
widget tests additionally cover narrow layouts, large text and both themes;
real-font screenshots were inspected. The Coach native walk is unverified: opening
Coach reproducibly crashed the host QEMU process with Windows exception
`0xc0000005`, including with SwiftShader. This is recorded as an emulator
limitation, not a successful native check or evidence of a Dart crash.

All native scenarios used an ignored offline fixture with process-local fake
PostgREST, dummy identity, memory cache and no external requests. Health Connect
used the real OS permission/aggregation boundary with no health records. The
original installed APK was restored and its SHA256 matched the pre-test backup;
the temporary step permission was revoked. No user app data was cleared.
