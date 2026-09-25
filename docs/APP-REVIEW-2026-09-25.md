# App review and fixes — 2026-09-25

Latest findings, verification and deployment boundaries: [deep review with ten specialists](#deep-review-with-ten-specialists-2026-09-25-to-2026-09-26). The initial two-agent round remains below as dated history.

Reviewed fetched `origin/main` at `af69a95c68511ae14219585978c65b862a1d2bde`
using exactly two subagents plus the primary reviewer. The primary reviewer owns
integration, authentication, local persistence and sync; the subagents examined
client features and backend/database boundaries, then independently reviewed the
sync fixes. Review used source/diff inspection, behavioral regressions, the full
Flutter suite and isolated backend services. No production traffic was required.

The original working directory is an older, dirty checkout on
`chore/agent-instruction-cleanup`; its existing work was preserved. The complete
local result is on `fix/app-review-2026-09-25`, in
`.agents/app-review-2026-09-25/integration` relative to that original checkout.
Git delivery was authorized after the local review; the delivery pull request
records CI and merge evidence separately. These client-only fixes require no
backend deployment. No device installation was performed.

## Confirmed findings, all fixed locally

### P1 — blocked recipe successors can stop unrelated foreground sync

A rejected recipe operation followed by at least twenty later edits consumed
the foreground dispatch budget without sending any request. Each retry selected
the same ineligible successors before reaching independent entries, so even a
valid weight entry could remain unsynced indefinitely. The encrypted queue
retained the data; actual data loss was not demonstrated.

[Foreground replay](../lib/src/app/home_store_sync.dart) now selects only the
first operation for each entity and only operations whose predecessor receipt
has already been reconciled. The 20-operation limit applies to eligible work,
while per-entity ordering and frozen request identities remain intact.
[Regression](../test/outbox/outbox_delivery_progress_test.dart): 25 edits behind
a rejected recipe plus an independent weigh-in; the prior code failed to send
the weigh-in, and the corrected code sends it while retaining all recipe edits.

### P2 — local receipt failures incorrectly exhaust server retry attempts

Successful server delivery and local acknowledgement shared one error handler.
Repeated failure to commit the local receipt counted as rejected delivery and,
after eight attempts, blocked automatic replay even though the server had
accepted the operation. This could also block later edits of the same entity.

[Replay](../lib/src/app/home_store_sync.dart) now distinguishes accepted remote
delivery from local reconciliation. Local failures retain the frozen operation
without consuming the rejection budget. The regression failed on the original
code with eight counted attempts. It now proves recovery without a manual
unblock, one server row/counter despite repeated delivery, and progress for an
unrelated entity in the same pass. A second regression injects the actual
`DurableStorageException` at the atomic commit boundary.

### P2 — conflict-copy dependencies can starve background sync

A recipe conflict moves its direct successor onto the saved conflict copy;
later successors still reference their predecessor under the original recipe
identity. Twenty such waiting heads could consume the background dispatch
budget ahead of independent changes.

[Background replay](../lib/src/services/background_sync.dart) now checks
predecessor eligibility before spending the dispatch budget. The
[regression](../test/services/background_sync_test.dart) constructs these chains
through real local commits and receipt reconciliation, verifies their distinct
entity identities, and checks that an independent operation is delivered. The
prior code dispatched nothing in this scenario.

### P2 — failed Coach recipe saving leaves adoption locked

When `createUserRecipe` threw before local persistence succeeded, the Coach did
not handle the exception or reset `_addingRecipe`. Recipe actions stayed
disabled until the screen was recreated, with no useful failure message.

The [Coach](../lib/src/screens/coach/coach_chat_screen.dart) now displays the
existing localized save error and always releases the busy state. The
[regression](../test/coach_recipe_flow_test.dart) proves failure without a false
success message followed by successful retry with the same proposal identity.
It failed against the original screen with the unhandled save exception.

## Functional coverage

“Passed” below means the inspected source and automated local behavior passed;
it does not mean every real device/provider combination was exercised.

| Area | Verified local behavior | Remaining boundary |
| --- | --- | --- |
| Auth/accounts | Signup/login, recovery and temporary OTP sessions, account changes/deletion, refresh/logout, session isolation | Real mailbox delivery and Google/Apple account chooser |
| Today/profile/goals | Daily totals, macros, activity/weight calculations, day rollover, target consistency, profile refresh | Real sensor data and device time transitions |
| Food | Manual entry, search/fallback, barcode/photo fixtures, portions, meal slots/dates, edits/deletion, favorites | Physical camera/scanner and production search/AI responses |
| Recipes/import | Catalog/user recipes, explicit adoption, source-backed partial nutrition, serving-basis confirmation, diary handoff | Actual social-app sharing, signed iOS switching, public source availability |
| Meal planning | Shopping checks, fractional portions, idempotent consumption, deletion races | Live cross-device observation |
| Training | Plan edits, timer, pause/resume, checkpoint recovery, completion/history and stale-plan protection | Real background/suspension scheduling |
| Coach | Chat/sessions, quota/cancellation, recipe/training proposals, save failure/retry | Actual model quality, voice input and external provider availability |
| Offline/storage | Encrypted persistence, atomic commits, queue capacity, immutable retries, conflict copies and account fences | OS keystore behavior on physical devices |
| Settings/export | Preferences, export pagination/completeness, clipboard behavior, reminder permission/concurrency/planning | OS notifications and permission prompts; export is JSON/clipboard by current scope |
| Navigation/accessibility | Main tabs, feature flows, theme/language, existing accessibility/layout regressions | Physical device visual and gesture acceptance |
| Backend/data | Four function entry points, authorization, RLS, quotas, receipts, concurrent mutations, migrations/restore | Currently deployed source/config and real production behavior |

No additional confirmed High/Critical backend security finding was identified.
This is not a blanket security certification; residual device/operational work
remains in [the existing checkbook](../SECURITY_AUDIT.md).

## Verification

- Baseline: 5,132 Flutter tests, strict analyzer, 94.97% line coverage
  (31,332 / 32,993, excluding generated localization).
- Final integrated Flutter suite: **5,137 passing tests**, strict analyzer
  clean, **94.98% line coverage (31,343 / 33,001)** excluding generated
  localization; the required floor is 88%.
- Focused client checks: 318 tests; focused outbox/delivery checks: 143, then
  29 affected checks after the background and independent-ACK cases were added.
- Android debug APK and release AAB built successfully from the same six changed
  source/test files, with dummy Supabase defines. Release used a throwaway test
  key, with R8 mapping output and Dart-AOT/resource shrinking verified; temporary
  signing material was removed. Existing Gradle/Kotlin future-support warnings
  remain; no dependency or lockfile change was made.
- Backend: 763 offline Deno tests, all 45 discovered files independently,
  four entry-point type checks, lint and 11 offline evaluations.
- Disposable PostgreSQL: all 49 migrations, cross-user/anonymous RLS,
  provider-budget races, recipe CAS/idempotency, conversion/deletion and training
  incarnation races; upgrade with 1,800 existing recipes. Restore rehearsal
  verified 25 tables, schema/grants/roles/data and deliberate failure detection.
- Disposable GoTrue: 47 handler checks and 160 lifecycle checks, including a
  disabled-rotation negative control; 177 current-password and 150 legacy-policy
  checks, with email-purpose and policy negative controls. The real-Auth handler
  harness covers coach/analyze/search; recipe-import auth is covered offline.
- Python guards: auth email templates 4, storage release/rollback 7,
  password policy 7, iOS test tooling 9; backend operations readiness 26,
  loopback transport 7 and lifecycle timing 4.

All four defect regressions failed for the relevant original behavior before
their fixes. An additional ACK regression checks continued progress of another
entity. No network permission was granted to Deno unit tests; real Auth/SQL
checks used disposable local services and synthetic data. Temporary backend
containers were removed after testing.

Sanitized machine-local evidence is under `.agents/app-review-2026-09-25/` in
the original checkout: `flutter-baseline.log`, `flutter-final.log`,
`analyze-final.log`, `android-debug.log`, `android-release.log`, `sync-negative-control.log`,
`background-negative-control.log`, and each subagent's logs. Backend details
are in `backend/.agents/REVIEW.md` there. These ignored logs are not production
records and are not required runtime artifacts.

There was no connected Android/iOS device. iOS compilation was not rerun for
this patch on Windows. Android artifacts use dummy endpoints/test signing and
are verification artifacts, not a production release. Camera,
HealthKit/Health Connect, native notifications, voice, OAuth and the signed iOS
social-share transition remain unverified on hardware. No live AI generation,
production database or production authentication configuration was tested.

## Deep review with ten specialists (2026-09-25 to 2026-09-26)

This second review starts at `8b8ee122fc8fac04b1ff3221587ec47bfea4a2e6`
(PR #107), so the four fixes above are baseline behavior, not new findings.
Exactly ten specialists ran with GPT-6 Sol and xhigh reasoning in isolated
worktrees: authentication/accounts, sync/cache, food tracking, recipes/import,
Coach client, training, profile/health/settings, Edge AI services, database/RLS,
and tests/platforms. Each inspected its existing tests as well as production
paths. Another specialist reviewed each patch; the primary reviewer challenged
oracles, reviewed the combined changes and owns final verification/delivery.
The user's unrelated working directory remained untouched.

### Findings and behavior after correction

| Area / severity | Confirmed behavior and correction | Regression evidence |
| --- | --- | --- |
| Auth / medium | An external sign-in or repository replacement could leave an OTP route above the signed-in app. Dismiss only the appropriate auth overlay, and prevent a late OTP callback from popping the newly opened page. | [Auth gate races](../test/gate_sync_auth_gate_test.dart) |
| Sync / medium | A partial acknowledgement or reload could replace optimistic lifetime counts while later inserts remained queued. Preserve a bounded local count while nonrejected counting intents remain; authoritative state wins after the queue drains. Rejected tracking intents no longer restore streaks after an authoritative refresh. | [Encrypted cache reconciliation](../test/services/sync_pending_stats_reconciliation_test.dart), [store delivery](../test/outbox/outbox_delivery_progress_test.dart) |
| Food / medium | Archive days stopped at 50 entries, and the 1,000-row boot cap could hide an in-window day indefinitely. Complete-day UUID cursor pagination preserves owner/day filters, withstands deletion between pages, and fails the whole read above its explicit 1,000-row bound. A capped boot triggers complete selected-day loading. | [Wire pagination](../test/wire_meals_sync_window_test.dart), [boot/day loading](../test/home_store_day_load_test.dart) |
| Food / medium | A serialized meal write could use a date selected after the action began. Capture the requested date/timestamps before entering the queue. An empty regional search plus an unanswered world search no longer becomes a cached definitive miss. | [Atomic meal actions](../test/atomic_store_mutations_test.dart), [real HTTP fallback](../test/services/open_food_facts_incomplete_search_test.dart), [retry UI](../test/add_meal_search_throttle_test.dart) |
| Import / medium | Edited ingredient/preparation content retained the original content-derived identity, causing false duplicate saves. Recompute identity for edited content, then freeze the entire attempted row for an immutable retry. | [Import sheet identity/retry](../test/recipe_import_sheet_test.dart) |
| Coach / medium | Delayed history/quota/session-list results and create/delete/photo actions could apply to a later visit, including A -> B -> A. Fence reads and navigation by service and visit revision. Accepted replies must remain available in their original chat without duplicate history rows. A delayed resume quota refresh also preserves newer action errors. | [Session races](../test/coach_session_race_test.dart), [photo privacy](../test/coach_image_privacy_test.dart) |
| Training / medium | Offset paging skipped history after a preceding row was deleted. Use the `(finished_at, id)` cursor with microsecond precision. Keep selected workout identity through a plan edit/reorder using its stable exercise IDs. | [History wire test](../test/training/training_history_sync_test.dart), [training screen](../test/training_page_test.dart) |
| Weight history / medium | Same-day/backdated writes and replay could exceed the 365-entry projection or leave the wrong latest entry. Apply stable chronological capping in model, store, boot and atomic cache projection; keep all durable outbox intents. | [Weight input](../test/fixlauf_g_weight_input_test.dart), [cache projection](../test/services/sync_pending_stats_reconciliation_test.dart) |
| Settings / medium | Overlapping native preference writes could restore the older theme/language after restart. Serialize writes while updating the current UI immediately. Failed profile persistence could already request reminder permission; start that side effect only after the durable commit. | [Locale](../test/app/locale_controller_test.dart), [theme](../test/theme/theme_mode_controller_test.dart), [actual commit failure](../test/settings_save_side_effect_test.dart) |
| Edge services / medium | Selected diagnostics emitted untrusted upstream bodies, exception text, field names or reset metadata. Keep bounded status/error classification. Connect analysis/search cancellation to outbound work, and discard late completion after cancellation. Awaiting a stalled stream cancellation could hold error responses forever; cleanup is now nonblocking with rejected promises handled. Quota reservation/refund rules are unchanged. | [Analysis](../supabase/functions/analyze-meal/handler_test.ts), [Coach RPC failures](../supabase/functions/coach-chat/handler_supabase_errors_test.ts), [provider budget](../supabase/functions/_shared/provider_budget_test.ts), [recipe source](../supabase/functions/recipe-import/source_test.ts), [search deadline](../supabase/functions/search-key/deadline_test.ts) |
| Native test gate / medium | The iOS result checker accepted only a few passing cases from each suite. It now requires every one of the 22 declared share-extension XCTest cases and rejects missing, skipped, failed, duplicate or ambiguous results. | [Checker negative controls](../scripts/ci/test_ios_test_support.py) |
| Bounded hardening / low | Strict profile hydration rejects fractional/nonfinite values for integer columns; stored recipe proposals are restricted to nonrefused assistant messages; a single tracked day is visible in Trends. Request-driven 30-day provider-usage cleanup also runs on a denied first request of a new day without charging quota. | [Profile parser](../test/services/profile_sync_load_strict_test.dart), [proposal parser](../test/models/coach_recipe_proposal_test.dart), [Trends](../test/widgets/trends_screen_test.dart), [SQL boundary checks](../test/migrations/ai_provider_budget.sql) |

The lifetime counter fix is a conservative display floor, not an exact
cross-device total while delivery/acknowledgement is uncertain. Rejected local
meal content remains visible for recovery; a fresh authoritative snapshot can
remove its optimistic counter/streak contribution. The 365-point weight limit
applies to the projection, not to pending deliveries. Archive paging provides
bounded completeness, not a transactional snapshot across concurrent inserts.

### Test correctness and rejected suspicions

Important behavioral regressions were run against the faulty implementation
before their fixes. Tests exercise real encrypted SQLite transactions, actual
PostgREST query filtering, delayed native preference writes, real loopback HTTP,
malformed upstream sentinels, and PostgreSQL concurrency where applicable.
The settings test also fails if permission is moved below the readiness check
but still above the actual atomic commit; it verifies recovery on retry.

The first integrated Flutter run also caught the new `request_aborted` server
code falling through to a misleading network fallback. The client now maps a
received remote abort to existing localized service-unavailable text, while a
local user cancellation remains silent. The unchanged [cross-language contract](../test/review_31/i_analyze_meal_error_contract_test.dart)
checks this mapping, alongside [both-language UI regressions](../test/widgets/meal_analysis_error_mapping_test.dart). Two older assertions were updated to the new UUID cursor
order and to an explicit timeout for incomplete catalog coverage; their
ownership, day, page-size and elapsed-time checks remain enforced.

The primary review rejected a Coach oracle that treated every late A -> B -> A reply
as stale: an accepted reply still belongs to A. The final contract requires
reconciliation and deduplication, including accepted proposals whose history
write failed. History-load ABA is a separate stale-read problem. Photo race controls wait for the real temporary-file cleanup before asserting
that nothing was sent, rather than assuming image processing finishes within
a fixed sleep. The retained
Coach-tab harness now includes its real TickerMode behavior and expects quota
to refresh on return while history/draft stay retained.

A suspected preference startup-load race was not reproduced because the plugin
coalesces its initial load. The demonstrated bug was reordered native writes.
Local `dart:developer` stack traces were not treated as remote data exposure;
no remote egress was established there. A SQL assertion inside a rolled-back
exception block cannot by itself prove statement ordering: source review
verified validation before cleanup and the existing account-FK-before-prune
lock order. SQL tests explicitly reject null denial results and check the exact
30-day retention boundary, in addition to real cross-user and race tests.

### Verification and delivery for this round

- Final integrated Flutter run: **5,194 passing tests**, no failures;
  strict analyzer has zero warnings/infos. **95.02% line coverage
  (31,563 / 33,217)**, excluding generated localization;
  the required floor is 88%. Flutter 3.47.2 / Dart 3.13.2 match CI.
- Independent root backend verification: **795 offline Deno tests** (784 function
  tests and 11 evaluations), lint of 78 function/evaluation files, and all four
  entrypoint type checks passed. The 84 backend/evaluation source files matched
  the integrated source after normalizing line endings.
- Python operations tests: **26**; loopback auth transport tests: **7**;
  native result checker tests: **12**, all passing.
- Synthetic GoTrue/PostgreSQL/Edge verification: **47 handler checks** and
  **178 auth lifecycle checks** passed. Disabling refresh-token rotation was
  detected by the negative control. Test providers were stubbed; no mail or
  production requests were sent.
- All **50 migrations** replayed on fresh disposable PostgreSQL and passed an
  idempotent replay, cross-user RLS, provider-budget and sync concurrency,
  1,800-recipe upgrade, and 25-table backup/restore negative-control checks.
- Final **Android debug APK and release AAB passed**, using dummy configuration
  and throwaway signing. The release pipeline retained a nonempty R8 mapping.
  All 393 app/build inputs matched integration; signing material was removed.
  Artifact hashes are retained in the local review evidence; neither artifact
  is a production-signed release or an installed build.
- The first integrated run had 5,189 passes and the three contract failures
  described above. All three were fixed and the complete suite rerun; the
  final count above includes the two added remote-abort regressions.
- Source and test changes were frozen during verification. Git delivery uses
  `fix/deep-app-review-2026-09-25`; protected PR CI and merge evidence are
  recorded by its delivery pull request, separately from these local results.

No new High/Critical security defect was established by this round. This is a
bounded functional and test review, not proof that every external integration
works on every device. Legacy Coach responses without a server message ID use
newly observed message IDs and matching answer/proposal content for fallback
deduplication. An unseen identical concurrent response from another device
remains ambiguous without a correlation ID. Real camera/scanner, mailbox and OAuth delivery, physical
HealthKit/Health Connect and notification behavior, installed signed app/share
flows, production provider quality, and live cross-device behavior were not
exercised. Windows cannot locally execute Xcode/XCTest; the changed native test
checker also requires its actual macOS CI run.

This round adds migration
[`20260925100000_provider_usage_denied_retention.sql`](../supabase/migrations/20260925100000_provider_usage_denied_retention.sql)
and changes all four Edge Functions/shared modules. Neither the migration nor
these function changes were deployed to production. Backend deployment and a
new installed device build remain distinct from a Git merge. The existing
main-only live migration drift check can report the intentionally undeployed
migration until a separately authorized rollout occurs.
