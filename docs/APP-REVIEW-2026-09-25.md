# App review and fixes — 2026-09-25

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
