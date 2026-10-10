# Eatova project handoff

Current documentation entry point: [docs index](README.md),
[features/platforms](FEATURES.md), [backend/models](BACKEND.md).
The product docs were reconciled with main through PR #88 on 2026-09-14.
Current security work is recorded in the [91-point checkbook](../SECURITY_AUDIT.md)
and the [operations runbook](OPERATIONS.md); its dated evidence supersedes older
unchecked security items below.

This file is an append-only, dated handoff from Claude Code to Codex. The initial
snapshot below is from 2026-09-06; subsequent entries supersede earlier open
items and delivery states. It is not a fresh security clearance, live deployment
inspection or test run. Follow the specific PR/source links for each checkpoint.

## Initial position, 2026-09-06

- Eatova is an existing Flutter/Supabase nutrition app for Android and iOS.
  Main areas: Today, Food diary, Recipes, Coach; offline cache/outbox, scanning,
  own recipes, account management, and German/English localization.
- After fetching origin, `main` and `origin/main` point to `0217ba3` (PR #65).
- The initial checkout was `fix/coach-recipe-image-undo`, HEAD `607e5fd`, one commit ahead
  of main. The working tree was clean before these handoff documentation edits.
- [PR #66](https://github.com/mxritzgit/Eatova/pull/66) is **open and unmerged**,
  verified through the GitHub API on 2026-09-06.
- Its [Flutter analyze + test job](https://github.com/mxritzgit/Eatova/actions/runs/33568496633/job/100057046554)
  failed: **3654 tests passed, 1 failed**. The annotations do not identify the
  test in the annotations. Follow-up diagnosis is recorded below. Android debug/release,
  Deno, RLS, secret scanning, and dependency checks succeeded; the separate live
  migration check was skipped. These are historical CI results, not fresh local tests.
- PR #66 raises the image-provider timeout from 30 to 60 seconds and the client
  recipe deadline from 135 to 165 seconds. It also makes the Coach card reflect
  a pending recipe deletion immediately, including Undo behavior.
- The commit and latest Claude note say **coach-chat must be deployed** for the
  timeout fix (expected v37 at that time). No later deployment confirmation was
  found in the inspected notes. Current live deployment and installed device
  build were not queried during this handoff.

### PR #66 follow-up, 2026-09-06

The failed test was `test/review_31/f_coach_frist_nachzuegler_test.dart`: it still
expected the old 135-second recipe deadline and 30-second image budget. Commit
`b9ed6bb` updates the ledger to 165/60 seconds and adds a behavior test for a
recipe response with image after 145 seconds, without history fallback or retry.
Reverting the production deadline to 135 seconds makes that new test fail; the
production file was restored byte-for-byte afterwards.

The fix is pushed to the existing PR branch (now two commits ahead of main).
Local verification: strict analyzer clean, all 3656 Flutter tests passed,
94.8% coverage excluding generated localization, review without actionable
findings. [GitHub CI run 34052297234](https://github.com/mxritzgit/Eatova/actions/runs/34052297234)
finished successfully: ten checks passed, the separate live migration check was
skipped as configured. GitHub reports `mergeable_state: clean` for `b9ed6bb`.
No merge or backend deploy performed.
Only the test fix was committed; the handoff documents remain local changes.

### PR #66 merged, 2026-09-06

The user authorized merging to main. PR #66 was squash-merged as `9a0afdf`
after verifying the exact PR head and successful checks. The local checkout is
now `main`, matching `origin/main` at that commit. The three local documentation
files were preserved during the switch and remain uncommitted. The earlier
open/unmerged statements above describe the initial handoff, not the current
state. Backend deployment and a device build remain separate delivery steps.

### Coach backend deployed, 2026-09-06

With the user's explicit approval, `coach-chat` was deployed from main commit
`9a0afdf` to the linked Eatova project (dashboard name still `Shiftfit`), using
the existing Supabase CLI 2.116.0 and API-based bundling. Remote version advanced
from 36 to **37**, status `ACTIVE`, with `verify_jwt=true` preserved.

Live checks: CORS preflight returned 204; a request with the project's public
anon JWT reached the initialized handler and returned its expected 401
`{"error":"Unauthorized"}` after configuration validation. A request without
authentication was rejected with 401. No user data or paid provider call was
needed. `analyze-meal` v25 and `search-key` v7 were unchanged. Deployment evidence
is stored locally at `.agents/pr66/supabase-deployment-verified.json` (ignored).
An authenticated end-to-end recipe generation on a device was not performed.

## Review history already incorporated

| Work | Evidence in current Git ancestry | Meaning for future work |
| --- | --- | --- |
| Review of 2026-08-27 and fix run | PR #54 `8cc6ef1` | High/medium findings recorded as addressed by that run. |
| Test consolidation | PR #55 `d27d2a5` | Shared harnesses and additional end-to-end flows; reuse them. |
| Auth-failure throttling | PR #56 `ec1244b` | Shared gate for the three Edge Functions. |
| Full review of 2026-08-29 | PR #57 `67a862a` | 72 findings plus 41 follow-ups recorded as fixed. |
| Review of 2026-08-31 | PR #58 `490c073` | 15 findings fixed, including recipe-photo loss paths. |
| Performance audit and fixes | PR #59 `9430a8e`, PR #60 `480c8b4` | Streaming, rate-limit batching, cache encryption improvements. |
| AI-image disclosure | PR #61 `16eec18` | Honest catalog copy and visible Coach image labels. |
| Test effectiveness review | PR #62 `b9c2990` | About 700 mutations; coverage floor raised to 88%, Postgres RLS gate strengthened. |
| Four bugs found by that review | PR #63 `325203c` | Photo error notification, text scaling, sanitized diagnostics, and prefilter fixes are done. Older memory still says open. |
| Auth mail quota/configuration | PR #64 `52bf5cc` | Code/docs fixed; Claude's later note records the user's live patch as verified on 2026-09-01. Live state not rechecked here. |
| iOS/toolchain alignment | PR #65 `0217ba3` | SPM integration and Flutter 3.47.2; old CocoaPods downgrade advice is obsolete. |

These are bounded historical results. Do not repeat entire completed audits by
default, or infer that all later findings are fixed just because an earlier run closed.

## Open work to pick up deliberately

1. **Device delivery of the Coach fix:** PR #66 is merged to main as `9a0afdf`
   with green pre-merge CI, and `coach-chat` v37 is deployed and startup-verified.
   Produce/install a new device build through the usual workflow to include the
   165-second client deadline and Undo-state fix, then check the real recipe flow.
2. **Auth-review findings of 2026-09-01:** closed in code. A 2026-10-01 check
   against `91ad800` found most already fixed by earlier work; the remainder
   was fixed in the 2026-10-01 run (see "Remaining findings, 2026-10-01"). Its
   rollout steps (migration, function deploy, live config confirmation) are
   tracked there.
3. **Release/website follow-ups:** older notes mention real-device Google login,
   privacy text synchronization, and store/legal-page finishing work. These need
   current verification before being scheduled. The marketing site is a separate
   repository (`Desktop/EatovaTest21st` per Claude), not this Flutter repository.

## Decisions and useful constraints

- Preserve the selected calorie model unless asked to revisit it. Its rationale
  is in `docs/REVIEW-KCAL-2026-08-21.md` and Claude's calorie-review note. The
  user revisited it on 2026-10-03: the plan follows the weight trend, and a
  weekly check proposes a bounded calibration ([WEIGHT-TREND.md](WEIGHT-TREND.md)).
- OpenRouter-backed meal analysis and Coach answer/classifier calls default to
  `google/gemini-3.8-flash`, which accepts the existing image-to-text payload.
  Function secrets can still pin an operator-selected model explicitly.
- Keep the existing `list_chat_sessions` query: the proposed rewrite was measured
  slower and reverted. Preserve per-operation outbox persistence (DATA-7); the
  candidate search, not the persistence cadence, was optimized.
- Native AES-GCM with DartAesGcm/pointycastle fallback is intentional. Do not
  discard security fallbacks to optimize a benchmark.
- Current local SDK verified: **Flutter 3.47.2 / Dart 3.13.2**; both CI workflows
  pin Flutter 3.47.2. Version is `1.1.0+3`; iOS minimum is 15 after PR #65.
- `supabase/SCHEMA_STATE.md` is generated by the migration replay test. Do not
  edit it by hand; read its regeneration instructions when migrations change.

## Sources and continuation

Read in this order: `AGENTS.md`, this handoff, the relevant source/tests and CI,
then the specific review/fix notes. `README.md` is the architecture entry point;
`CONTRIBUTING.md` has test commands; `CHANGELOG.md` records product history.

Claude's detailed memories remain at this machine-local directory:

```text
C:/Users/morit/.claude/projects/C--Users-morit-Desktop-Bridgespace-Projects-Eatova/memory/
```

Start with `MEMORY.md`, then read only the relevant note:

- `eatova-coach-fixes-2026-09-02.md`
- `eatova-auth-review-2026-09-01.md` (read the final updates, not only the header)
- `eatova-testhaertung-2026-09-01.md` (its four open bugs were closed by PR #63)
- `eatova-perf-fixlauf-2026-09-01.md`
- `eatova-fixlauf-2026-08-31.md` and `eatova-fixlauf-2026-08-29.md`
- `eatova-mac-cocoapods-modus.md` (final SPM/3.47.2 update supersedes opening text)
- `feedback-borderless-inputs.md`

These files are historical evidence and may contain stale status. Keep this
shared handoff concise and update resolved items with commit/PR evidence. Do not
copy credentials, personal infrastructure notes, or full session logs into Git.

## Project review, 2026-09-07

See [REVIEW-2026-09-07.md](REVIEW-2026-09-07.md) for the review of main `9a0afdf`.
Strict analyzer clean, 3,656 Flutter tests and 394 Deno tests passed; line
coverage excluding generated l10n 94.81%. Current main CI and RLS job passed.
Isolated counterexamples reproduced an old outbox sending the next stats RPC
under the new account's bearer after dispose, temporary GoTrue HTTP failures
mapped to 401, and no nonce-renewal action after a password-change error.
GitHub API confirmed no environments and Supabase credentials still stored as
repository secrets. RLS test contains a blind foreign-row assertion; four
health tests only test their local fake. Deno per-file process runs remain
useful because environment changes survive across modules. No production fixes,
CI edits, deployment, or commits were made as part of this review.

## Six-finding fix follow-up, 2026-09-07

The user authorized fixing R1–R6, pushing a topic branch and merging only after
green CI. See the final "Fixlauf" section in `REVIEW-2026-09-07.md` for the fixes
and mutation evidence; it supersedes those six open findings above. Work is on
`fix/review-2026-09-07`; delivery status must be checked against GitHub.

RPCs now pin the account bearer, disposed outboxes stop, temporary Auth HTTP
failures return 503 without charging the failure quota, password changes can
renew consumed nonces with a cooldown, real SQL tests cover foreign counters and
account deletion AMR, and four fake-only health tests are removed. GitHub's
`supabase-drift` environment is configured main-only and holds both Supabase
secrets; repository secrets are empty. Preserve this server-enforced boundary.
The existing PAT was moved, not rotated.

Local full Flutter and Deno suites and the real PostgreSQL suite passed; isolated
mutations demonstrate the new guards are detected. Two Codex review passes found
no actionable regressions. Device installation and authenticated live flows
remain distinct from merge and backend deployment.

## App design polish, 2026-09-07

The user requested replacing Today Steps' person icon and Coach sparkles, plus
a broader design review. Local branch `design/app-icon-polish` starts from
merged main `4ae47eb`. See [DESIGN-REVIEW-2026-09-07.md](DESIGN-REVIEW-2026-09-07.md)
for the ten audit assignments, implemented icon/readability improvements,
verification, and deferred profile-header details. The existing theme tokens
remain authoritative. This work is local; commit, push, merge and installed
device delivery are separate steps.

### Resume context, 2026-09-08

- Current local branch: `design/app-icon-polish`. The design changes and this
  documentation are uncommitted and unpushed; preserve the working tree. Refresh
  Git status before editing rather than assuming this snapshot is current.
- Implemented: shared shoe-print icon for Today/profile steps, conversation
  icons instead of Coach stars, contextual icons elsewhere, larger chat and
  recipe text, clearer Food metadata, and responsive nutrition/statistics.
  Detailed scope and follow-ups are in `DESIGN-REVIEW-2026-09-07.md`.
- Verified on that code: 3,666 Flutter tests passed, 94.82% coverage excluding
  generated localization, strict analyzer clean, independent Codex review clean.
  Screenshots/logs are ignored under `build/design-polish/` and
  `.agents/design-polish/`.
- A debug APK was subsequently built and installed as an update on Android
  emulator `fitpilot_pixel` (`emulator-5554`, Android 16/API 36). Today opened
  successfully; existing app data was retained. No physical device/iOS build
  has been installed in this design task.
- The user noticed Steps missing above Macros in that Android build. This is
  existing behavior, not removal by the icon changes: `stepsForFoodDate()` in
  `lib/src/app/home_store_tracking.dart` returns null without available steps;
  `today_screen.dart` omits the card for null. Health integration currently
  uses Apple Health on iOS, with no Android step integration. The earlier
  widget previews used explicit fixture steps. A visible unavailable-data
  state was suggested but has NOT been implemented or selected by the user.
- The user requested ten concurrent subagents. The previous session could
  create only three, so ten audit assignments reused those three threads.
  On 2026-09-08 the user authorized setting the machine-local Codex config's
  `agents.max_concurrent_threads_per_session` to 10. TOML validity and unchanged
  unrelated values were checked, and the original config was backed up beside
  it. The effective limit must be checked in a fresh session; it has not been
  demonstrated by spawning ten agents. This is machine-local configuration,
  not part of the Git project.

## Ten-agent review and fixes, 2026-09-08

The user requested ten simultaneous subagents, a broad review of broken,
unnecessary and outdated functionality, followed by validated fixes. This
session successfully spawned **all ten concurrently** (11 runtime slots
including the commander), superseding the unverified limit note above.
Each used an isolated worktree with the original uncommitted design baseline.

See [REVIEW-2026-09-08.md](REVIEW-2026-09-08.md) for 25 addressed findings,
regression and mutation evidence, retained design decisions, and delivery
constraints. The commander checked and integrated the changes and requested
additional independent reviews and counterexamples.

- At local review completion, branch `design/app-icon-polish` was based on
  `4ae47eb`, with design and review fixes uncommitted. The delivery follow-up
  below supersedes that local snapshot.
- Fixed account-session races, logout stats delivery, trend invalidation,
  Coach history/image/dictation lifecycle, food search/barcode errors, recipe
  save/delete races, reminders and responsive profile/settings behavior.
  Removed unused sleep API/layout wrapper, modernized Android compiler options
  with the same JVM 17 target, and refreshed stale platform notes.
- Final verification: strict analyzer clean, **3,734 Flutter tests passed**,
  **95.04%** line coverage excluding generated l10n, **436 Deno tests passed**,
  Deno lint/type checks clean. All 39 migrations and the full RLS suite passed
  on isolated PostgreSQL 16. General and security Codex reviews found no
  actionable introduced regressions. Lockfiles remain unchanged.
- A new debug APK built successfully with CI dummy defines. It was **not
  installed**; the emulator still has the earlier design build. Native iOS
  compilation and microphone/permission testing remain unverified on Windows.
  Android toolchain future-support warnings concern still-supported versions;
  the coordinated AGP 9 migration is documented as future maintenance. The
  final compiler-options change passed another debug build and scoped review.
- Before deploying updated `coach-chat`, apply
  `20260908120000_chat_quota_refund_day.sql`; neither has been deployed here.
  The date-bound refund fix is only live after both steps.
- Android Steps still hides for null data; no provider/unavailable-state
  behavior was added. Existing stats-bundle deduplication and post-OTP
  recovery navigation decisions are explicitly bounded in the review.
- Ignored evidence/backups: `.agents/review-2026-09-08/`, including each
  worktree's targeted proofs and root `final-*.log` combined verification.

### Delivery follow-up, 2026-09-08

The user authorized committing and pushing the entire reviewed stand, waiting
for green CI, then merging to `main`. Implementation commit `919a55c` contains
all 88 reviewed files, including the original design work. Its Gitleaks scan
found no secrets; the working tree matched the preserved delivery hashes.

[PR #68](https://github.com/mxritzgit/Eatova/pull/68) tracks this delivery from
`design/app-icon-polish` to `main`. GitHub's current PR state, head SHA and
check results are authoritative; do not infer pending or completed delivery
from the earlier local-only notes. Merge is authorized only after all
applicable CI checks, including native iOS and Android release, pass.
Backend deployment and device installation remain separate from this merge.

### Steps layout follow-up, 2026-09-08

PR #68 was merged as `77d0a72` after green CI, including native iOS. The user
then reported that the Steps calorie explanation had moved underneath the
entire header. At normal phone widths this placed it 53 pixels left of the
title. `TodayStepsCard` now keeps the explanation below the title beside the
footstep icon, with the count on the right. Narrow layouts with large text
retain the readable stacked fallback. This supersedes the earlier full-width
subtitle design decision; card placement and Android null-data behavior stay
as documented above.

- Four new geometry tests failed against the previous layout and pass with the
  fix. All 82 Today tests and strict analysis pass. Four rendered cases cover
  German/English, normal phone widths, and 320 pixels with doubled text.
  Independent Codex review found no actionable regression. Evidence is ignored
  under `.agents/steps-card-layout/` and `build/steps-card-layout/`.
- Topic branch: `fix/today-steps-card-layout`. Full CI must pass before merge;
  the branch's GitHub PR records the current delivery state.
- The user also authorized the outstanding production migration
  `20260908120000_chat_quota_refund_day.sql` and then deployment of `coach-chat`
  after this merge. This is authorization, not evidence of deployment. Verify
  live migration history, RPC permissions, deployed function version and the
  main-branch live drift check; record the results in the PR delivery follow-up.
  A device build installation remains separate.


## Training implementation, 2026-09-08

The user requested a complete Training tab, Coach `/plan` with explicit adoption,
editable plans, and reversible exercise timers. Ten implementation/review agents
worked in isolated worktrees: eight collaboration agents plus two Codex CLI
agents after the collaboration surface refused additional concurrent threads.
Root integrated their owned files and independently reviewed/tested the seams.
Branch `feat/training-plans` starts at merged main `d17984a` (PR #69). The
implementation was verified locally before delivery; its Training PR records
the commit, CI, merge and backend deployment evidence.

- Five lazy retained tabs: Today, Food, Recipes, Training, Coach. The new page
  follows existing forest/lime tokens and Bricolage/Archivo typography. See
  `TRAINING-DESIGN-2026-09-08.md` and `TRAINING-VISUAL-REVIEW-2026-09-08.md`.
- Saved plan library, multiple workout days, timed or repetition-based exercises,
  sets/rest/instructions; complete manual creation/editing, ordering and deletion.
  The Training CTA fills `/plan ` in Coach without sending. Review/Edit/Adopt is
  explicit; merely generating or dismissing a proposal never saves a plan.
- The buffered `/plan` handler validates a strict versioned proposal in Dart,
  TypeScript and PostgreSQL, uses existing quota/refund rules and stores only a
  draft in assistant history. No AI write to the user's Training library.
  Photos plus plan requests are rejected before generation/quota consumption.
- Plan IDs are stable across retries/adoption. Existing encrypted account cache
  and durable outbox handle offline CRUD; export includes accepted plans. A save
  is acknowledged only after server delivery or verified local durability.
- Player: start/pause/resume, +/-10 seconds, reset phase, previous/next set and
  exercise, explicit set completion and rest skipping. Skips never count as
  completed sets; stepping backward reverses later completion. At zero the timer
  waits for confirmation. Timing uses elapsed monotonic time, not tick counts.
- Background/covered routes pause. Save-and-leave/discard/finish wait for serialized
  durable writes, with visible retry on failure. Recovery stores a full plan and
  always resumes paused. Forced process termination can recover only the latest
  durable checkpoint, not a guarantee of its very last millisecond. No automatic
  training calories, invented history, notifications or new package dependencies.

The general and security reviews reproduced and fixed lost acknowledged offline
edits, replay changing an unacknowledged operation's identity, full-queue eviction,
same-user token refresh invalidating player/Coach callbacks, stale Coach-tab test
indices, and valid backend fallback-session rejection. The commander additionally
checked usable buffered drafts when fallback history persistence fails. Critical
regressions have red-before/green-after evidence. Real AuthGate tests cover token
refresh, logout, A-to-B, late callbacks, and encrypted recovery/account isolation.
The final store follow-up also fences saves during initial outbox hydration,
prevents live sends when recovered ordering is unknown or queue admission fails,
retains FIFO after a timed-out undurable write, and waits for actual persistence
receipts before resolving Training capacity pressure. Successful immutable
outbox snapshots establish durability even if a later verification write fails;
a late live server acknowledgment is checked again after storage settles.
Ordinary enqueue and hydration repair defer capacity trimming while a Training
confirmation is unresolved. A never-persisted failed draft is removed first;
once a save is confirmed, the existing generic cap/loss policy applies. Failed
drafts leave the last confirmed UI state intact and report save failure.
Logout cleanup also settles the affected operation's receipts before releasing
its confirmation guard: durable pending changes survive, while only the exact
never-durable draft is removed during the still-open account-cache window.
Account retirement still prevents publishing a late Training result.

Verification on the final integrated source:

- **4,007 Flutter tests passed**; coverage **21,363 / 22,417 = 95.30%**, using
  the CI exclusion for generated localization and exceeding the 88% floor.
- Strict Flutter analyzer passed. The regular Android x64 debug APK built
  successfully. Existing AGP/Kotlin future-support warnings remain; no toolchain
  or dependency/lockfile upgrade was folded into this feature.
- **470 Deno tests passed**, both together and in CI-style isolation across all
  26 test files; Deno lint and all three function entrypoints passed.
- All **40 migrations** replayed successfully against isolated PostgreSQL,
  including Training JSON constraints, cross-account RLS and row-cap assertions.
  SQL, Dart and backend validators have negative-control evidence.
- General and security review findings were reproduced and corrected. The final
  Coach remap review and final Training logout/receipt correction review found
  no actionable residual issues. The store's final adjacent batch passed all
  154 cases; the complete integrated Flutter suite above includes the final fix.
- Independent visual renders checked Page/Coach with the real bundled fonts,
  light/dark themes, 320-pixel width, 2x text and keyboard insets. All six design
  findings were closed; the timer also passed its owner visual/lifecycle checks.
- Final Gitleaks scan of all 75 changed/new files found no secrets; no changed
  file exceeds 50 MiB. Dependency manifests and lockfiles remain unchanged.

Root evidence: `root-test-1.log`, `root-analyze-1.log`, `root-apk-1.log`,
`root-deno-individual.log`, `root-postgres.log`, `root-ui-final-review-1.log`, and
`root-logout-final-review-1.log` under the ignored training evidence directory.
All checks use dummy defines/stubbed requests and isolated PostgreSQL; no real AI
generation, production user writes, or native iOS compilation in this task.
The native Android fixture exercised Training, +/-10s, elapsed countdown/pause,
background pause, save-and-leave, paused resume, explicit set completion and rest.
It used an in-memory account cache and closed network stub. An initial load-error
banner was traced to the fixture's missing `request: request` on `http.Response`:
Postgrest dereferenced `response.request!`, so both load and upsert threw. Three
isolated tests reproduced this without emulator timing; fixing only that mock
field restored both operations. Root rebuilt and reinstalled the corrected
fixture: the Training library had no error banner and the player opened normally
(`native-corrected-training.png`, `native-corrected-player.png`). No product fix
was needed for this fixture issue. A System UI ANR during the first heavily
loaded emulator boot remains a separate observation, not an Eatova crash or a
proven performance diagnosis. This fixture is not a live-backend or cold-start
performance claim. The original emulator APK was backed up/restored after both
passes without clearing app data; the headless emulator was stopped. The final
regular Android debug build uses CI dummy defines and is not installed over the
user's original build.

Delivery remains separate: apply `20260908130000_training_plans.sql` before
deploying the updated `coach-chat` and releasing this client (history now selects
`training_plan`). At implementation handoff this migration and handler were not
deployed, and no production-configured build was installed. The user subsequently
authorized committing/pushing this feature, merging after green PR CI, and then
applying the migration and deploying the handler. Record verified delivery in
the Training PR (head `feat/training-plans`); authorization alone is not evidence
of a successful rollout. A device/store release remains separate.
Prior quota-refund migration and coach-chat v39 deployment belong to the earlier
PR #69 delivery; they do not establish Training is live. Android Steps' null-data
visibility behavior remains unchanged.

Ignored evidence: `.agents/training-2026-09-08/` holds agent worktrees, root test,
review and native logs, mutation proofs, and device/render captures. The shared
documents are the continuation source; do not duplicate this archive.

## Workout and scan follow-up, 2026-09-09

The previous Training delivery is complete: [PR #70](https://github.com/mxritzgit/Eatova/pull/70)
merged as `3b50178`, migration `20260908130000_training_plans` is registered,
and `coach-chat` v40 is active with JWT verification. The dated implementation
handoff above predates that rollout. At the start of this follow-up all 40 local
migrations matched live history, with `analyze-meal` v26 and `search-key` v8.

Four requested fixes were developed by four agents in isolated worktrees from
that clean main commit, then independently reviewed and integrated by root on
`fix/workout-flow-dialogs-scan-context`:

- Natural expiry now completes a timed set, runs its inter-set rest and starts
  the next timed interval. Repetition sets remain manually completed; the final
  review remains paused. Delayed ticks advance one visible phase only, and
  manual seeking/skipping does not invent completion. Backgrounding, covered
  routes and recovery remain paused; automatic transitions save checkpoints.
- Ten confirmation/input dialog callsites share the new Eatova dialog family,
  preserving explicit confirmation, cancel/back/barrier and dirty-form guards.
  Real fonts, light/dark themes, 320-pixel width, double-size text and keyboard
  insets were checked. A related component-calorie row now wraps after input.
- Recovery is tied to its source workout. Deletion or an edit/removal retires
  its checkpoint; unchanged reordering and unrelated deletion preserve it.
  With no independent workout IDs, removing an identical duplicate is treated
  conservatively. An encrypted suspension in the same checkpoint envelope is
  durably written before a source mutation; a failed final clear cannot revive
  the workout. Late player callbacks carry a per-source retirement generation.
  Cached libraries can be unreadable or stale, including an empty list after a
  failed mirror write. Only authoritative server data or an observed source
  change can invalidate a full checkpoint, preserving offline recovery. A player
  whose source was retired can leave without
  writing; its callbacks cannot clear or replace newer recovery. Transient
  checkpoint read failures require repair before mutation, while provably
  malformed JSON cannot permanently block Training CRUD.
- Camera/gallery scans first show a local photo preview with an optional food
  note. Start sends it through the existing `freeTextHint`; cancel discards it,
  retry retains the same request. Client/server enforce 400 UTF-16 units and
  reject unsupported control characters without silent truncation. Provider
  instructions and food observations have separate system/user roles. Context
  is not independently persisted or logged. Account identity and photo-store
  epoch guards also cover start/retry immediately before a widget rebuild.

Root exercised the ordinary flows in an Android emulator with the full shell,
an in-memory account/cache and a closed network mock: one start through timed
set/rest/next set into paused repetitions; Save-and-leave followed by deletion
removing Resume; photo/context/keyboard/start/loading/result/cancel and a fresh
empty context. Real-font screenshots were inspected. Later review edge fixes
have separate production-shell regression coverage; this native fixture is not
a live provider or device-release claim. The original emulator APK was restored
and its SHA256 verified without clearing app data; the emulator was stopped.

Final integrated verification passed **4,122 Flutter tests** with **95.4% line
coverage** (generated localization excluded), strict analysis and the regular
Android x64 debug build. All **488 Deno tests** passed both together and in
CI-style isolation across 26 files; lint and all three entrypoints passed.
General and final security reviews have no remaining actionable findings.
Review regressions were demonstrated before correction, including a stale
encrypted plan mirror hiding newer durable recovery. Final source hashes were
checked against the unchanged files used by the full test run. Root logs include
`root-test-final2-1.log`, `root-analyze-final2-1.log`, `root-apk-final2-1.log`,
`root-security-final2-1.log` and `root-deno-individual.log` in the evidence folder.
The build retains existing AGP/Kotlin future-support warnings; no unrelated
toolchain upgrade was included. Native iOS compilation and live AI output were
not exercised.

No schema or dependency change is required. Delivery must deploy `analyze-meal`
from the merged source; client changes require a new app build. The authorized
PR for `fix/workout-flow-dialogs-scan-context` records final test, CI, merge and
deployment evidence. Authorization and local tests alone do not establish live
delivery. Root evidence is in ignored `.agents/fixes-2026-09-09/`; reuse these
shared documents and that PR instead of creating another full archive.

## Training and recipe creation design, 2026-09-09

The creation forms now share numbered sections, readable sentence-case labels,
responsive field grids and contextual forest/lime headers. Training exercises
have distinct expandable surfaces and full-width add actions; unavailable reorder
controls stay out of single-item lists. Recipe nutrition uses two readable columns
or one at larger text sizes, with measured label heights and full nutrient names.
Photo actions retain their full labels and at least 48-pixel targets. Recipe Save
and Close remain outside the scroll area; a compact keyboard header leaves room
for focused input. Existing borderless field/focus tokens remain authoritative.

The recipe discard guard now keeps its child mounted as the form becomes dirty,
preserving keyboard focus. Validation, explicit save/discard, account callbacks,
photo storage and draft data contracts are retained. Review caught a temporary
single-line workout-notes regression; multiline input was restored and a test
checks the saved line breaks. The reviewer reproduced that failure against the
patch and verified the old behavior separately. Final general/security review
found no remaining actionable introduced findings.

Verification: **4,133 Flutter tests passed**, strict analysis passed, and the regular
Android x64 debug APK built with CI dummy defines. Real-font renders cover light
and dark, with German/English 320-pixel, double-text and keyboard regressions.
The native Android fixture exercised new Training/recipe drafts, validation,
keyboard input, scrolling, save and discard using an in-memory account/cache and
closed network stubs. The original emulator APK was restored and hash-verified
without clearing app data; the emulator was stopped. This does not install a
production-configured release or exercise live provider calls.

Delivery is authorized via the PR from `design/creation-editors`, merging only
after green CI. Consult that PR for the final commit/merge state. No backend,
schema or dependency update is needed; installed clients need a new app build.
Ignored evidence lives in `.agents/creation-editors/` (final test/analyzer/review
logs, visual renders and native captures).

## Meal scan context preview design, 2026-09-10

The photo-analysis preview now gives the captured meal a clear visual entry
point: a photo-check header, ready status, branded photo surface and a focused
context workspace. The context input keeps the existing 400 UTF-16-unit and
control-character contract, shows a live limit indicator, and offers localized
one-tap suggestions that become check states instead of duplicating text.

The account, cancel-before-upload, retry, language and request normalization
contracts remain unchanged. The new behavior is covered in
`test/meal_scan_context_test.dart`; the preview was rendered in both palettes
at 390 px and the existing 320 px/2x-text/keyboard matrix remains green.
Delivery is still separate until this branch passes full CI and is merged.

## OpenRouter Gemini and Coach latency, 2026-09-10

The default OpenRouter model for `analyze-meal`, Coach answers, and the Coach
classifier is now `google/gemini-3.8-flash`. The Coach image-generation model
remains separate because it serves a different image-output contract.

Coach bootstrap starts the quota read alongside history loading. The normal
message path schedules the cosmetic auto-title update while the provider works,
so neither operation adds avoidable serial latency to the first response. The
ownership filter, quota/refund paths, stream handling, and persistence checks
remain unchanged.

## Coach false refusals, 2026-09-10

Production records for the reported greeting and lighter Raising Cane's sauce
request both show `classifier_off_topic` (Layer 2). The earlier rollout is active
as `coach-chat` v42, but its smoke checks covered authentication only. Historical
records do not distinguish a semantic misclassification from the old malformed
JSON fallback; the old classifier also classified both synthetic examples
correctly during this investigation. Do not claim the original provider output
or a specific token-exhaustion cause was recovered from logs.

The classifier now uses a strict category/confidence schema, compatible-provider
routing, and a 256-token budget with minimal reasoning. The classifier and answer
prompts explicitly include cooking, lighter sauces and restaurant-inspired
recipes; ordinary lower-calorie food is not itself an eating-disorder signal.
All messages still pass the prefilter and classifier, including greetings.

Unusable ordinary-chat classifications now stop before answering or persisting,
return a retryable provider error, and use the existing outage refund path.
Explicit provider content filtering remains charged and stops every mode.
Recognized safety categories retain their refusal even if confidence metadata is
missing or completion is truncated. Recipe/plan fail-closed behavior, image
fallback, crisis replies and Layer-3 prompt-leak checks remain covered.
Diagnostics contain fixed labels and allowlisted completion metadata only.

Verification: 4,134 Flutter tests and strict analysis passed; all 494 Deno tests,
lint and entrypoint checks passed. Regression tests reproduced the false-topic
fallback and both security-review findings before correction. A local production
handler with isolated database stubs and real OpenRouter calls answered both
reported examples and blocked crisis, dangerous-diet and off-topic controls.
One recipe answer reached the existing answer-length cap; this change does not
raise that cap. Final review, CI, merge and deployed verification are recorded in
the PR for `fix/coach-guardrail-false-refusals`. Only `coach-chat` needs deployment;
no schema or app-build change is needed. Ignored evidence is in
`.agents/coach-guardrails-2026-09-10/`.

## Coach answer completion, 2026-09-10

The false-refusal fix above is merged in [PR #75](https://github.com/mxritzgit/Eatova/pull/75)
(`5f1ac3d`), with successful PR/main CI and authenticated streaming checks on
`coach-chat` v43. The subsequent mid-answer ellipsis is a separate, confirmed
output-budget problem: production logged `finish_reason=length` at 16:17 UTC,
with 526 visible characters, and the stored answer contains the server's suffix.
No user message content was needed to establish this.

A synthetic recipe request reproduced the cutoff through the production handler
and real OpenRouter: 528 reasoning tokens consumed most of the old 800-token
completion budget. Ordinary JSON and SSE answers now share a 3,072-token cap
and `reasoning: { effort: "low", exclude: true }`. Low is the lowest effort
advertised for Gemini 3.8 Flash in the model catalog checked on this date.
[OpenRouter's reasoning contract](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens)
counts reasoning as output; exclusion alone does not free this budget.
The concise-answer prompt, three guardrails, deadlines and quota rules remain.
The existing ellipsis still identifies an exceptional provider length limit;
the fix does not hide that signal or add paid continuation loops.

Both new regression cases fail on the former implementation and pass with the
fix, checking complete JSON/SSE output, persistence and a single quota claim.
Verification: 4,134 Flutter tests, strict analysis, 496 Deno tests, lint and all
entrypoint checks passed. General and security reviews found no introduced
issues. The same live synthetic request finished normally with 1,650 visible
characters in 5.4 seconds (previous truncated response: 7.4 seconds); these are
individual observations, not a latency benchmark.

Delivery uses the PR from `fix/coach-complete-responses`, after successful CI.
Only `coach-chat` needs deployment; no migration or new app build is required.
Deployed authenticated streaming, stored-answer parity and disposable-account
cleanup are verified separately after deployment. Consult the PR for final
delivery status; ignored evidence is in `.agents/coach-completion-2026-09-10/`.

## Feature-gap review, 2026-09-10

The user requested a product-completeness review with three subagents. See
[FEATURE-REVIEW-2026-09-10.md](FEATURE-REVIEW-2026-09-10.md), based on clean local
main `1b03c18`. Strong candidates are saved-recipe editing/preparation, persistent
workout completions and actual set values, Android Health Connect, and ingredient-
based recipe calculations. Smaller gaps include changing diet after onboarding
and exposing the already-prepared JSON file-share action. Existing trends, manual
macro goals, localized auth, reminders and data export are not missing features.

This is a source-based product recommendation, not an approved implementation
roadmap or runtime/security clearance. Removed water/sleep/habit features should
not be restored merely because old documents or fields still mention them.
Only review documentation changed; no tests, production changes or deployment.

## Six core features, 2026-09-10

The user subsequently authorized implementation with six isolated feature agents
and coordinator review, followed by a PR and protected-main merge after green CI.
The earlier gap review describes the baseline, not the resulting feature state.
See [CORE-FEATURES-IMPLEMENTATION-2026-09-10.md](CORE-FEATURES-IMPLEMENTATION-2026-09-10.md)
for acceptance criteria, validation evidence and release boundaries.

The implementation adds recipe editing/preparation, structured ingredient and
portion calculation, persistent workout actuals/history/previous performance,
Android Health Connect steps, explicit Coach training briefs and selected-plan
context, and a weekly meal planner with persistent aggregated shopping checks.
The five existing tabs, localization/theme conventions, explicit Coach adoption,
local recipe images, account isolation and calorie model are preserved.

Review corrections address durable save/retry identities, unknown cooked weight,
stale set validation, pending completion notes, deleted workout resurrection and
additional free-text shopping items. Workout deletion keeps only account-scoped
UUID receipts; performance payloads and notes are removed. New tables/RPCs and
export expectations are documented by migration replay in
[SCHEMA_STATE.md](../supabase/SCHEMA_STATE.md).

Delivery is tracked on `feat/complete-core-features` and its PR. Three new
migrations and the updated `coach-chat` function require a separate backend
rollout before releasing the new client. Code merge, deployed backend, installed
app and physical-device Health Connect data are separate facts. No backend or
store deployment is established by this implementation review.


## Today Balance Duo design, 2026-09-11

The user selected the pastel Balance Duo mockup and authorized a Today redesign
with matching app-wide colors, while preserving the other tabs' layouts and
features. See [TODAY-DESIGN.md](TODAY-DESIGN.md) for the design contract and
verification record. This supersedes earlier unselected Today design concepts.

The topic branch is `design/today-balance-duo`, based on main `9e103ac`.
It introduces the split lavender calorie hero, nutrient-colored rows, compact
steps, meal rows and fixed add-meal action. Existing date/slot/calorie rules,
Health Connect recovery, localization and dark mode remain. Legacy token names
are compatibility fields; photograph/camera foregrounds have separate tokens.

The user authorized push and protected-main merge after green CI. Delivery is
tracked by the PR from this topic branch. No backend or schema rollout is needed;
an installed device build or store release remains a separate step. Final checks
and known verification limits are recorded in the linked document.

## Meal entry design, 2026-09-11

The add-meal sheet now continues Today's Balance Duo design: lavender photo
action, labeled gallery/barcode alternatives, quiet manual entry and sentence-case
favorites. Normal entry keeps the keyboard closed until search is chosen; the
explicit search entry still focuses it. Date/slot context and a clear-search
action preserve orientation. Large text reflows the methods and slot selector;
the header compacts above the keyboard and the remaining content scrolls.

The topic branch is `design/meal-entry`, based on main `3395a1a`. Existing
service/store boundaries, photo confirmation, account isolation, search budgets,
meal arithmetic, portions and undo remain. See
[MEAL-ENTRY-DESIGN.md](MEAL-ENTRY-DESIGN.md) for acceptance and evidence: 4,339
passing Flutter tests, 95.13% coverage, strict analysis, debug APK, independent
general/security review and real-font modal/flow checks.

The user authorized push and protected-main merge after green CI; the PR records
delivery status. This client change requires a new installed app build to appear
on a device. No backend, schema or dependency changes are needed.

## Favorites library design, 2026-09-11

The user requested a less generic presentation for inline favorites and their
full menu. Both now share an open collection surface, saved-portion calorie
hierarchy, a visible portion control and a lavender expanded state with Today's
nutrient colors. Search, close, meal context and empty-state actions clarify the
full library. Existing portion arithmetic, pin/unpin identity, deletion,
filtering, selected day/slot and account boundaries are preserved.

See [FAVORITES-DESIGN.md](FAVORITES-DESIGN.md) for acceptance and verification:
4,344 passing tests, 95.12% coverage, strict analysis, independent general and
security reviews, and real-font modal/app-shell checks. The toast host no longer
counts the library's consumed bottom safe-area inset twice.

The topic branch is `design/favorites-library`, based on main `9467a29` (meal
entry PR #79). The user authorized push and protected-main merge after green CI;
the PR records delivery status. This is a client-only change; an installed app
build or store release remains a separate step.

## Keyboard and gesture navigation, 2026-09-12

Coach and other input surfaces now share outside-release and scroll-drag
keyboard dismissal. Tab changes release focus while preserving local drafts.
iOS retains native interactive page-back gestures and adds a narrow edge-pull
fallback for root tabs and guarded routes. Training sheets now support guarded
pull-down and backdrop dismissal, including dirty/busy changes during a drag.
Canceled/reversed gestures, delayed callbacks and focus-transfer races are
covered by regressions. Existing unsaved-work and save protections remain.

See [GESTURE-NAVIGATION.md](GESTURE-NAVIGATION.md) for the contract and evidence:
4,358 passing tests, 95.12% coverage, strict analysis, Android debug APK and clean
independent follow-up review. The local Android emulator repeatedly terminated;
native keyboard and physical iOS verification are explicitly not established.

The branch is `fix/gesture-navigation`, based on main `198b74b` (favorites PR #80).
The user authorized push and protected-main merge after green CI. This change
requires a new client build, with no backend, schema or dependency rollout.

## Food Thumb First design, 2026-09-12

The user selected Food concept 09, Thumb First, and asked for an implementation
that remains readable with ten entries in one meal. Open pastel meal sections
now show compact summaries and expand into individual entries. A lavender dock
provides search, camera, barcode and direct manual entry; date arrows/calendar
replace the chip strip. Favorites retain their accepted design.

See [FOOD-DESIGN.md](FOOD-DESIGN.md) for the interaction contract, review fixes
and verification. New dates reset scroll; responsive layout changes retain the
current date's browsing state, including when another tab's keyboard resizes
Food. Existing editing, undo, canonical date grouping and account boundaries
remain. Review findings were reproduced with regression tests before correction.

The branch is `design/food-thumb-first`, based on main `90f4b03` (gesture PR #81).
The user authorized push and protected-main merge after green CI. Local checks:
4,372 passing tests, 95.12% coverage, strict analysis, Android debug APK and
clean final reviews. Delivery is recorded in the PR. This is a client change, without
backend, schema or dependency rollout; an installed app build is separate.

## Sentry recipe failures, 2026-09-13

Sentry FLUTTER-D/E are three failed Coach recipe requests, including a retry.
Read-only server logs on v45 confirm unusable recipe JSON. The recipe path still
had a 900-token cap without reasoning control; completion reason was not logged,
so the exact historical truncation cause is not proven. A local regression
reproduces the insufficient-budget failure.

`fix/coach-recipe-completion` adds output headroom, rejects explicitly truncated
recipes, and records sanitized completion metadata. See
[SENTRY-RECIPE-2026-09-13.md](SENTRY-RECIPE-2026-09-13.md) for evidence, verification
and rollout limits. With the user's write authorization, `coach-chat` v46 is live
with JWT verification enabled and downloaded source matching the tested fix.
Two real-provider recipe checks pass (DE/EN); the disposable account and related
data were removed and verified. All 4,372 Flutter tests (93.32% coverage), strict
analysis and 507 Deno tests pass. No migration or client build is needed.

The user authorized push and protected-main merge of `fix/coach-recipe-completion`
after green CI. The branch's pull request records the final Git delivery. The fix
already runs as v46; merging the same source requires no additional deployment.


## Recipe Spotlight design, 2026-09-13

The user selected Recipe concept 05 and extended the redesign to recipe details,
the portion sheet, Meal Plan, its editor and Shopping List. All now share the
accepted Today/Food typography and pastel surfaces. Recipes has For you, All and
persistent Own tabs; weekly planning has photo cards and compact action menus;
shopping has stable checkable rows and weekly progress.

See [RECIPES-DESIGN.md](RECIPES-DESIGN.md) for the interaction contract, rendered
previews and verification. Photo snapshots use an exact catalog slug/path match;
selection after scrolling resets the planner editor to its heading. Regression
checks detect both faulty variants. Persistence, account guards, explicit diary
confirmation and existing photo/undo rules remain unchanged.

Local verification: 4,379 tests passed, 95.19% coverage, strict analysis,
Android debug APK, direct diff review and 21 real-font visual cases. Delivery uses
`design/recipe-spotlight`, based on `38bd0e0` (PR #83), through protected main after
green CI as authorized by the user. The PR records the final merge. No backend,
schema or dependency rollout is required; device installation is separate.

## Training Nachtstudio design, 2026-09-13

The user selected Training concept 09 and requested a matching plan-selection
redesign. Training now uses the existing dark Eatova theme with bundled studio
photography, a lavender start/resume action, lettered workouts and expandable
exercise details. The plan library shows the active plan first and supports
search by plan, goal or workout, with descriptions accessible before selection.

See [TRAINING-DESIGN.md](TRAINING-DESIGN.md) for the visual/interaction contract,
real Flutter previews and verification. The redesign preserves the existing
editor, confirmed deletion, history, recovery, explicit Coach adoption and
account-bound callbacks. Hidden or covered Training pages yield their toast
host; retry feedback cannot cover the start action. Screen-reader selection is
verified by a regression that first reproduced the missing semantic action.

Local checks: full suite 4,390 tests and 95.25% coverage; 94 focused checks after
the final refinements; strict analysis, Android debug build and thirteen
real-font render cases. `design/training-nightstudio` starts at main `ab7d9f3`
(PR #84), with protected-main delivery after green CI under the user's existing
authorization. The PR records the final merge. No backend, schema or dependency
rollout is required; device installation remains separate.

## Today, meal entry and account polish, 2026-09-13

The user requested complete first-viewport Steps visibility, a cleaner meal
selection in Add Meal and Barcode, consistent page headers, Today-only tab
entry points for Profile/Settings, and redesigned account pages. Four agents
implemented isolated scopes; the commander integrated and reviewed the result.

See [APP-POLISH-2026-09-13.md](APP-POLISH-2026-09-13.md) for the interaction
contract and integrated Flutter previews. Today spacing preserves type and tap
targets. Shared root/subpage title styles also cover Meal Plan and training
history. Profile uses a lavender identity and open statistics; Settings uses
clear groups and full-width adaptive preferences with visible keyboard focus.

Review regressions reproduce the clipped Steps card, missing picker semantic
activation, Android duplicate suppression after a covered scan, and the
collapsed profile macro bar. Account guards and selected date/slot/draft behavior
remain intact. The final full-suite follow-up keeps Coach review actions visible
with enlarged text and a keyboard, and preserves disabled history navigation
during deletion.

Local verification on Flutter 3.47.2: all 4,421 tests passed, zero skips,
94.94% coverage, strict analysis and an Android x64 debug build. Eight integrated
real-font captures were inspected after the individual surface reviews.
`design/app-polish` starts at main `44db638` (PR #85) and uses protected-main
delivery after green CI under the user's explicit authorization. The PR records
the final merge. No backend, schema or dependency changes are included; camera
hardware testing and device installation remain separate.


## Food entry and calendar polish, 2026-09-14

The user requested the accepted meal picker in Camera and Manual plus a
significant redesign of manual nutrition, product search results and the
Food date picker. See [FOOD-ENTRY-POLISH-2026-09-14.md](FOOD-ENTRY-POLISH-2026-09-14.md)
for the interaction contract, regression evidence and real-font previews.

Camera keeps selection outside the preview and preserves its lifecycle;
manual label values and the live portion have separate visual sections.
Product rows separate brand, name and label density, with the exact saved
portion visible when expanded. The calendar keeps date changes local until
confirmation and retains native navigation, date input and date bounds.
Favorites and persistent meal/account contracts remain intact.

Local validation: 4,452 tests passed without skips, 94.96% coverage and
strict Flutter analysis on 3.47.2. Tests cover light/dark, German/English,
200% text, keyboard access, drafts, invalid input and saved values. The
two-digit calendar-width regression was demonstrated failing before the fix.
`design/food-entry-polish` starts at main `78f2b44` (PR #86); delivery uses
a protected PR and merge after green CI, as explicitly requested. The PR
records the final merge. The original instruction-cleanup worktree remains
untouched. No backend deployment or device installation is included.

## Today, Food and footer icon family, 2026-09-14

The user requested distinctive icons for Today, Food meal slots and the five
footer tabs. A shared set of 16 original vector pictograms now supplies these
surfaces, including the shared meal pickers. See
[ICON-FAMILY-2026-09-14.md](ICON-FAMILY-2026-09-14.md) for motifs, actual Flutter
previews and the integration contract. Existing theme colors and meal selection
behavior are retained; the footer has larger glyphs at the same overall height.

Local validation on Flutter 3.47.2: 4,464 tests passed without skips, 95.01%
coverage and strict analysis. The icon tests cover repaint/opacity, small-glyph
clipping, all five selected tabs, semantic selection and real screens in both
themes/languages at normal and 200% text. A badge-sizing regression was shown
failing before the centering fix. Existing full Steps-card visibility tests pass.

`design/icon-family` starts at main `767ab93` (PR #87). Delivery uses a protected
PR and merge after green CI under the user's explicit authorization; the PR
records the final merge. Original instruction-cleanup work remains untouched.
Device installation and backend deployment are separate from this code change.

## Documentation reconciliation, 2026-09-14

The user requested the GitHub documentation be checked against the current app,
including the old Grok Coach claim. [README](../README.md) and the
[documentation index](README.md) now lead to current feature/platform, backend
and development guides. Source defaults are Gemini 3.8 Flash for meal analysis,
Coach answers and classification; recipe images use Gemini 3.1 Flash Image.
The documented model override rollout was also checked in PR #74's delivery
record. No Supabase configuration was changed or freshly queried for this task.

The inventory includes recipe editing/ingredients, planned versus eaten meals,
Shopping List, training actuals/history, Android steps, localized auth and the
subsequent UI work through PR #88. Boundaries include no Android weight sync,
no current native export sharing, no post-onboarding diet editor and no exposed
Apple sign-in button. Historical reviews and plans are marked as dated evidence;
completed backend/Git rollout notes are corrected using PR #77/#83 records.

Only Markdown changed. Validation covers repository-wide local links/anchors,
index coverage, source/configuration references, diff checks and secret scanning.
GitHub access uses the named Infisical credential inside the process. Delivery
uses `docs/current-product-documentation`, based on main `378fbc5`, with a
protected PR and merge after required CI.

The [published website privacy policy](https://eatova.de/datenschutz) still names
Grok/xAI and old profile goals as of the read-only 2026-09-14 check. The repository
privacy data-flow document now matches current source; publishing the website
update remains separate from the requested GitHub documentation work.

## Security audit and confirmed-finding fixes, 2026-09-14

The initial audit created [SECURITY_AUDIT.md](../SECURITY_AUDIT.md) with all 91
requested points and seven confirmed findings, keeping source inspection,
synthetic local tests and missing live evidence distinct. The user then explicitly
authorized fixes with five subagents, functional review and a protected PR merge
after green CI. Work starts at main `a3a7422` in isolated worktrees; the original
instruction-cleanup branch and unrelated local documents remain untouched.

Coach responses now wait for complete provider/output approval before SSE text
delivery. Provider safety filters and invalid completion/classification metadata
fail closed across JSON, SSE, recipe and training modes. Valid suggestions retain
their explicit adoption flow. A cancelled SSE request does not receive a quota
refund or store an unapproved assistant prefix. The first text arrives later;
client deadlines and the SSE transport shape remain compatible.

Photo analysis validates supported image containers before paid quota/provider
work. The entire Flutter Navigator holds the existing native private-screen
guard. Session logout uses token-free revocation records and ordered persistence;
the integration review additionally covers native Preferences acknowledgements,
cleanup ordering and the pinned SDK's PKCE failure path. Regression tests cover
the unsafe prior behavior and legitimate login/refresh/retry flows.

The app's German/English Coach disclosure and privacy data-flow documentation now
name OpenRouter/Google/Gemini and the actual context types. The published website
source was located in `C:/Users/morit/Desktop/EatovaTest21st/public/datenschutz.html`;
it matches the currently published policy. A reviewed, isolated
[single-file correction](PRIVACY-WEBSITE-CORRECTION-2026-09-14.md) is ready without
changing that project's existing uncommitted design work.

Security checkbook Runde 2 records the final local validation and delivery
checkpoint. This change does not deploy `coach-chat`/`analyze-meal`, publish the
website, install a device build or establish live RLS/Auth/provider/backup safety.
These remain separate actions/evidence. In particular, cancelling a local
OpenRouter stream does not prove a Gemini billing stop. The next five broader
audit points and safe read-only verification steps remain in the checkbook.

Local final verification: **4500 Flutter tests**, **95.07%** line coverage
excluding generated localization, strict analysis, **541 Deno tests** and all
**28 Deno files independently** passed. All 58 Markdown files / 325 local links
and the source secret scan pass. `fix/security-audit-findings` is the delivery
branch; its protected PR records the later CI and merge checkpoint. No local
database/schema changes required; the CI still replays all migrations and RLS.


## 2026-09-14: authorized backend and privacy publication completed

The user subsequently explicitly approved both deployments. Security PR #90 was
already merged after green protected CI. `coach-chat` v47 and `analyze-meal` v30
are ACTIVE with JWT verification; their downloaded production import graphs
(12 and 9 TypeScript files) match the tested source. `search-key` stays v9.
The existing Gemini model overrides were verified, with no settings or database
changes and no billable production AI calls. Rollback sources were retained.

The prepared privacy HTML was published separately at 21:34 UTC on 2026-09-14.
Public HTML, server file and the updated `EatovaTest21st/public/datenschutz.html`
match; all 34 other public files are unchanged. Live Chromium at four widths
passes under the real CSP. Original HTML is retained outside the web root for
rollback. Only the intended local privacy file changed; unrelated design work
remains untouched. No new device build was installed.

The [security checkbook](../SECURITY_AUDIT.md#verifizierte-veröffentlichung-am-14092026)
records current versions, public HTML hash, evidence and remaining limits.
Earlier "prepared/not deployed" entries describe their historical checkpoints.


## Security completion round 3, 2026-09-15

Ten isolated specialist worktrees and independent cross-reviews addressed the
full 91-point audit from main `8e836456` (PR #91). The [current checkbook](../SECURITY_AUDIT.md)
contains the concrete findings, regression links, verification boundaries and
remaining owner actions; avoid treating historical open lists as current state.

Account-bound OTP completion, image reads/cleanup and cache ownership are fixed;
exports now report actual completeness and include own provider usage. Every
paid AI call has a separate atomic, non-refundable reservation and configurable
stop switch. Upload/response bodies and photo metadata/decoder boundaries are
bounded. Database defaults and PG17 maintenance grants are tightened. The
Gradle resolver is patched to 8.14.4; native runtime scans, separately triaged
build-tool findings, offline Coach evaluation and synthetic restore are in CI.

Commander checks: 662 offline Deno tests plus 35 files independently; 38 real local
GoTrue/handler cases with 9 paid stubs and 9 prior reservations; 46 migrations,
restricted-role RLS/deletion/budget races, atomic rollout/rollback rehearsal and
synthetic restore. The first full Flutter run found four integration contract
failures; they were corrected, and 228 affected tests plus strict analysis pass.
The full protected CI on `78f8d55` then passed: 4620 Flutter tests, 95.0% coverage,
Android debug/release and iOS without signing. The scanner's ignored relative
inventory failure was reproduced in a real Git fixture and fixed; nonzero scanner
exits still fail. PR #92 contains the final merge/check status.

Live hardening already verified: DB SSL enforcement, private-only Realtime,
four Auth-security notification flags and GitHub private reporting. No actual
security email or alarm was sent. All three new migrations were deployed atomically
before Functions coach-chat v48, analyze-meal v31 and search-key v10. Complete
source graphs and an independent live catalog comparison passed. The public
privacy extension was published on 2026-09-15 at 00:13 UTC; all 34 other website
files were preserved. [Sanitized rollout evidence](SECURITY-ROLLOUT-2026-09-15.json)
records the actual checks. Platform-managed secret timestamps changed during
deployment; current injected project key types are publishable/secret even under
the legacy variable names. Values were compared only in memory; do not equate a
timestamp change or legacy label with a credential leak. No app-store or
user-device installation is implied by source, CI, merge or backend deployment.

Owner requirements remain: sole Supabase Owner MFA, production backup/restore
and separate staging, actual runtime provider-key money/privacy settings,
Sentry/admin alert access and delivery proof, clinical/legal review and physical
iOS/store checks. The named Vault provider key differs from the deployed one;
never replace it or attribute its limits to production without proper account
identification. Provider call ceilings are not dollar budgets. Build-tool
advisories remain explicitly triaged, not silently ignored.

## Security follow-up round 4, 2026-09-15

Exactly five isolated agents plus root follow up the owner-requested actionable
items from PR #92. The [current checkbook](../SECURITY_AUDIT.md#runde-4--nacharbeit-mit-fünf-agents)
records fixes, red/green controls, live readback and explicit remaining work.
Export now uses a timestamp/ID cursor so deleting a previously exported row does
not skip an unread row. Coach cancellation paths preserve consumed question
quota and sanitize transport/persistence errors; client and server reject orphan
APNG chunks. The Gradle policy enforces the reviewed Jetifier/KAPT exclusions.
An actual AGP 8.13.2 trial leaves the same 45 toolchain advisory IDs, so no
ineffective version bump or lockfile churn was retained.

The local GoTrue lifecycle, bounded operations checker and Gradle regression
fixtures run in existing CI jobs. The decoder now has a reproducible Android
profile/AOT probe: four synthetic cases pass, but total process RSS reaches
465.1 MiB. The 64-MiB raster guard is not a process-memory cap. See the
[measurement guide](../scripts/security/PHOTO_DECODER_PROBE.md).

The [21:45 UTC metadata readback](SECURITY-READINESS-2026-09-15.json) confirms
active 1000/150/50 call/account/image limits, no completed backup recovery point
and PITR off.
Initial HTTP 503 coincided with scheduled Management API maintenance; do not
interpret those failed reads as an app outage. The checker is not a scheduler,
dollar budget or alert-delivery proof. Export/erasure handling and concrete
backup/monitoring setup steps are in [operations](OPERATIONS.md).

No new database migration, provider-key change, paid model test, real health-data
read, external notification or user-device installation. Backend rollout/PR-CI
delivery is recorded separately in the checkbook; never infer it from a local
commit. MFA, actual backup/restore, alert recipients/delivery, staging,
provider-account money/privacy choices, signed device release and legal/clinical
acceptance remain owner work. All 91 status categories remain unchanged because
those independent requirements still matter.

Round-four backend delivery completed at 2026-09-15T22:16:37.599024+00:00: coach-chat v49, analyze-meal v32; search-key remains v10. All deployed TypeScript import graphs match the green PR-tested source, JWT verification stays on, and secret fingerprints/model choices were compared only in memory. [Sanitized delivery evidence](SECURITY-ROLLOUT-FOLLOWUP-2026-09-15.json). [PR #93](https://github.com/mxritzgit/Eatova/pull/93) carries the final protected checks/merge. No device installation or production behavior test is implied.


## Authentication and onboarding redesign, 2026-09-16

The user requested three coordinated workstreams, a distinct Eatova login/signup
and onboarding design, auth defect fixes, and delivery through protected main.
Work started from security follow-up main `0128339` in isolated worktrees; the
original checkout's unrelated instruction/security documentation was preserved.

- **Entry:** Balance Duo surfaces, Bricolage/Archivo typography and app symbols;
  responsive login, signup and verification/recovery. Keyboard/autofill, legal
  links, neutral errors, resend/cooldowns and reduced motion remain.
- **Setup:** six groups replace up to eleven screens: basics, body, activity,
  goal with conditional target/pace, optional diet, editable plan. Summary edits
  return directly. `ProfileLimits` and the nutrition calculator are unchanged.
- **Confirmed fixes:** late password/signup/native-Google responses cannot
  replace a newer session; a password response without a session fails. Existing
  nonempty login passwords reach the server without signup-only length rules.
  Typed account conflicts and competing form/code routes are handled correctly.
  Goal reselection preserves custom targets. Completion is idempotent, rejects
  disposed callbacks and does not automatically request notification permission.
- **Verification:** Flutter 3.47.2; strict analyzer clean; **4,675 tests passed**
  with dummy service defines; **95.09% coverage (27,432 / 28,849 lines)** excluding
  generated localization, above the unchanged 88% floor. Regression tests detect
  the original session races, goal reset and completion/notification faults.
  The combined [app journey](../test/flows/auth_onboarding_journey_test.dart)
  verifies confirmation before setup, exactly one profile write, and returning
  login without repeated setup or unsolicited notification prompts.
- **Review:** independent read-only review found route races and a weak legacy
  boundary assertion; both were corrected. Full-suite fixes preserve original
  assertions while scrolling before taps, deriving the changed greeting from
  localization and using shared ranked `HeadingSemantics`.
- **Visual evidence:** [design contract and six previews](AUTH-ONBOARDING-DESIGN.md).
  Real-font Flutter matrices cover German/English, both themes, normal and 200%
  text, narrow screens, keyboard insets, tablet layout and landscape welcome.
  These are test renders, not device captures.

Delivery uses branch `design/auth-onboarding`; the protected PR/check records
are the authority for push and merge status. No dependency, schema or backend
function changed. No device build was installed or published. Physical-device
Google selection, OS autofill and live mail delivery were not exercised here.

## Authentication entry revision and welcome alignment, 2026-09-17

The user rejected the September 16 login/signup composition as generic and
static, and requested a focused revision plus the left-shifted lavender
startup/sign-in surface fix. Five coordinated agents worked in an isolated
`design/auth-refresh` worktree from main `86b4525`; the original checkout's
unrelated work was preserved. The six-step onboarding and app identity remain
unchanged. The [existing auth design contract](AUTH-ONBOARDING-DESIGN.md) records
the revised composition without creating a second design archive.

- **Entry:** open theme background, enlarged Bricolage Eatova wordmark, concise
  German/English headline and visible login/signup choices above the form.
  The [header and mode selector](../lib/src/widgets/auth/auth_entry_header.dart)
  use finite focus-reticle motion and an animated selection underline, with
  immediate reduced-motion states. Large text can stack the mode choices; the
  keyboard collapses the headline. Registration expands the name field while
  preserving email/password state and the existing soft-fill focus contract.
- **Welcome fix:** [scroll content](../lib/src/widgets/auth/welcome_screen.dart)
  now has the available viewport's minimum width after padding. The previous
  shrink-wrap centered the painted mark within its content width, causing the
  reported left shift. Existing profile readiness and completion behavior stay
  intact.
- **Regression scope:** [auth interaction tests](../test/auth_entry_regression_test.dart)
  cover interrupted mode changes, credential/selection retention, autofill and
  keyboard traversal, reduced motion, and busy-state guards. The
  [render matrix](../test/auth_entry_design_test.dart) adds small-phone keyboard
  cases at 200% text in both themes/languages. The
  [welcome regression](../test/widgets/welcome_screen_centering_test.dart)
  measures both layout and actual mark pixels at phone, compact, landscape and
  tablet sizes, including reduced motion.
- **Visual evidence:** the [design contract](AUTH-ONBOARDING-DESIGN.md) includes
  refreshed real-font Flutter login, signup and centered welcome frames.
  Native review used a separate synthetic preview package on the
  `fitpilot_pixel` Android emulator in light/dark themes, with the real Android
  keyboard and an expanded 800 × 1280 dp window. It did not touch the installed
  production app and does not establish iOS or physical-device validation.

Verification: Flutter 3.47.2 strict analyzer passed. The final local coverage
run passed 4,673 tests but one existing recipe-photo test file did not complete;
all 26 tests in that file passed on the immediate isolated rerun. The full CI run
remains the merge gate. Collected line coverage was 95.02% (27,475 / 28,914
lines), excluding generated localization, above the unchanged 88% floor.
The 35 focused auth tests passed after the keyboard correction. Red controls
reproduce the old welcome offset (164 instead of 195 px) and the header's lost
keyboard inset. Independent source/render review returned `ship` after that
keyboard finding was fixed and recaptured. Gitleaks found no source secrets.

The user authorized pushing a protected PR and merging after green CI. The PR
and its checks record final push/merge status; authorization alone does not
establish delivery. This revision does not deploy backend functions or change
live authentication settings. No production build installation, physical-device
Google selection, OS autofill or live mail delivery is established here.

## Sentry HealthKit background reads, 2026-09-17

Chrome inspection of [FLUTTER-F](https://eatova.sentry.io/issues/147438147/)
and [FLUTTER-G](https://eatova.sentry.io/issues/147438150/) found one event each
in the same trace, from iOS release `1.1.0 (3)`. The step query failed at
2026-09-16 04:27:52.366 UTC (`health.readSteps`, `STEPS_ERROR`); the following
weight query failed at .370 (`health.readSnapshot.weight`, `HEALTH_ERROR`).
Both followed the background lifecycle event at .287 and report foreground=false.
These are captured read failures, not evidence that the app terminated.

The confirmed code defect is an unfenced refresh continuing across that
lifecycle transition. Failed step queries could also become a fresh zero via
the verifier's retained read evidence. A locked HealthKit store is consistent
with [Apple's privacy documentation](https://developer.apple.com/documentation/healthkit/protecting-user-privacy),
but the historical native reason is not proven: health 13.3.1 discards the native
error code, and Sentry removes the free-text message.

[AppleHealthService](../lib/src/services/apple_health_service.dart) now defers
reads outside the resumed state, checks lifecycle/account validity around native
queries, and discards interrupted results. Scoped observers catch a background
round trip even if the app is already resumed when a query completes. One bounded
read retry handles that case when the shell's resume refresh was blocked by the
existing in-flight request. Missing steps never become a measured zero; the
store keeps its previous value and fetch time. Foreground failures still reach
sanitized reporting, and an optional weight failure does not discard valid steps.
The generic HEALTH_ERROR/STEPS_ERROR codes are suppressed only after an observed
lifecycle interruption, not globally. Reset invalidates pending account evidence.

Verification: [21 new regressions](../test/services/apple_health_lifecycle_test.dart)
cover lifecycle changes, recovery, true zero versus unavailable steps, retained
store state, reporting and account reset. Before the fix, two controls reproduced
the false-zero snapshot and the continued weight query after background failure;
only the existing platform seam and clock were aligned to run them on Windows.
All **4,715 Flutter tests** pass with dummy defines; strict analysis passes with
fatal infos/warnings. Coverage excluding generated localization is
**95.16% (27,559 / 28,960 lines)**, above the 88% floor. Scoped Gitleaks and
`git diff --check` pass. Review was a direct source/diff review, without subagents.

The fix was prepared on `fix/healthkit-background-refresh`, based on main
`a193282`, in `.agents/sentry-health-2026-09-17/worktree`. The original dirty
checkout is preserved. The user authorized push and protected-main merge after
green CI; the branch's PR records final Git delivery and check results. No
backend deployment is needed. An updated iOS build and a physical-device
foreground/lock/resume check remain necessary; no device installation was
performed and the historical Sentry issues stay open. Local test logs are ignored
under `.agents/sentry-health-2026-09-17/`.

## Review fixes: calorie budgets, Health days and archive meals, 2026-09-19

Three coordinated agents implemented and independently cross-reviewed three
reproduced defects against main `79821e1`. The original dirty checkout was
preserved; the integrated worktree is
`.agents/review-fixes-2026-09-19/integration`, branch
`fix/review-calories-health-archive`.

- **Calorie budget:** [DailyCalorieBalance](../lib/src/models/daily_calorie_balance.dart)
  now supplies both Today and Coach with base goal plus valid activity minus
  consumed calories. The displayed base goal remains separate, and an over-budget
  remainder keeps its sign. The mounted Coach observes changes to the valid bonus
  without rebuilding for an unchanged fetch timestamp. The
  [Coach regressions](../test/coach_calorie_balance_test.dart) exercise measured
  activity, unknown activity, overshoot and an already open screen.
- **Health day validity:** the [tracking store](../lib/src/app/home_store_tracking.dart)
  requires a snapshot from the same local calendar day on both platforms.
  Unknown steps remain nullable; a measured zero is real data. iOS retains a
  same-day reading through a failed refresh and preserves historical activity.
  A read spanning midnight can perform exactly one current-day catch-up, with
  account-generation and disposal checks before platform reads and weight offers.
  Android additionally requires verified permission, including after a settings
  failure. Profile, Today, Food and Coach use the central validity rule.
  [Store regressions](../test/home_store_health_day_validity_test.dart),
  [screen wiring](../test/health_day_screen_wiring_test.dart),
  [Android settings checks](../test/home_store_health_connect_test.dart) and the
  [non-UTC probe](../test/wire_local_day_probe.dart) cover these boundaries.
- **Archive loading:** [MealsSync](../lib/src/services/meals_sync.dart) uses the
  persisted `local_day`; only legacy rows with a null day use the half-open
  timestamp window between local midnights. One query preserves the owner filter,
  descending order, shared 50-row cap and existing failure/retry behavior.
  [Wire regressions](../test/wire_meals_sync_window_test.dart) and the
  [HomeStore archive flow](../test/home_store_day_load_test.dart) cover timezone
  travel, wrong-day rows consuming the cap, legacy bounds, owner isolation and
  DST. The existing indexes suffice; no migration is needed.

Verification on Flutter 3.47.2 / Dart 3.13.2: the original three independent review
probes now pass, and each fix has a failing-before regression control. The full
suite passes **4,745 tests**, including 30 added cases, with dummy service defines.
Coverage excluding generated localization is **95.23% (27,602 / 28,986 lines)**,
above the unchanged 88% floor. Strict analysis passes with fatal infos/warnings.
The Android debug APK builds successfully with dummy service defines.
All three agents completed independent source/diff review of the combined work.
Local evidence is ignored under `.agents/review-fixes-2026-09-19/`.

The user authorized pushing a PR and merging through protected main after green
CI. The PR and its required checks establish delivery status; local preparation
does not establish merge. No backend function, schema, dependency or runtime
configuration changed. No device installation or physical iOS validation was
performed.

## Transactional offline sync and Auth emails, 2026-09-20

Five coordinated review/implementation areas verified the requested findings
against main `c67e3f5`. SharedPreferences did not provide the assumed critical-data
durability guarantee. The favorite owner-reassignment omission was a test gap,
not evidence of an exploitable policy: the new collision-free mutation requires
SQLSTATE `42501` from the existing ownership boundary. The original dirty checkout
was preserved; integration uses `feat/transactional-offline-sync` in
`.agents/offline-sync-2026-09-20/integration`.

- [Local persistence and sync contracts](OFFLINE_SYNC.md): encrypted SQLite
  commits entities, derived state and outbox intents atomically before confirming
  a save. Legacy import is transactional. Frozen requests, permanent server
  receipts, current-state reconciliation and account/session claims preserve
  uncertain delivery and coordinate foreground/background work. Unreadable and
  blocked queues remain visible; exhausted retries never evict confirmed intent.
- Recipes use server revisions, deterministic conflict copies, visible history
  and explicit restore. Snapshot pagination, export and historical photo
  references cover complete collections. The detail screen follows its exact
  acknowledged conflict copy. A delete-before-first-create marker has no content
  to restore and remains an exact event in exported history.
- Coach plans keep their stable proposal identity. Explicit incarnations separate
  deletion from re-adoption; old first requests and receipts cannot change a
  newer adoption. Conflict review retains the latest confirmed draft, checks for
  another edit before committing, and replaces only the reviewed unsent intents.
  Workout checkpoints remain bound to their source incarnation; already durable
  completions retain their recovery path. Discard is a confirmed local operation.
- Reconnection triggers foreground replay. Native background work is bounded and
  uses the same encrypted queue and session claims. OS scheduling and physical
  device behavior remain distinct from simulated runner tests and native builds.
- [Auth email contracts](../supabase/AUTH_EMAIL_OTP.md): all 13 templates share
  a maintained mobile/dark layout. A per-request purpose distinguishes account
  deletion from password recovery, with a neutral fallback for older clients.
  Deletion verifies in an isolated recovery session bound to the initiating
  account and session; account switches cannot redirect deletion or cleanup.

Regression evidence includes
[real SQLite process crashes](../test/services/sqlite_process_crash_test.dart),
[atomic mutation failures](../test/atomic_store_mutations_test.dart),
[recipe result races](../test/recipe_edit_result_test.dart),
[account deletion scope](../test/delete_account_scope_test.dart) and
[disposable PostgreSQL concurrency](../test/migrations/offline_sync_concurrency.py).
The final integrated database run applied all **49 migrations**, passed the RLS
suite and concurrent recipe/training/ownership races, and upgraded **1,800 recipes
(72,974,079 bytes)** plus legacy training heads. Deliberately removing receipt
ownership checks or the upgrade storage allowance was detected. The email probe
rendered and verified real OTPs through disposable GoTrue/SMTP with synthetic
accounts; no real user mail was sent. Local evidence remains ignored under
`.agents/offline-sync-2026-09-20/`.

Final Flutter verification on 3.47.2 / Dart 3.13.2 passes **5,013 tests with no
skips**, strict analysis with fatal infos/warnings, and **94.85% coverage
(30,012 / 31,641 lines)** excluding generated localization. One legacy test
still used an ordinary save after deleting a Coach plan; its fixture now uses
explicit same-ID re-adoption and additionally rejects the old checkpoint before
and after that adoption. The subsequent complete suite is green; product guards
were preserved.

The final Android debug APK builds with dummy service defines. Deno lint,
entry-point/evaluation type checks and **700 tests** pass. Backup/restore verifies
all **25 tables**, schema, grants and restricted roles; missing RLS and missing
data controls fail as expected. Global/account provider-budget concurrency
checks pass against the new schema. The independent final source review reports
no remaining actionable findings in the changed scope.

The 13 email templates, their subjects and the two exact purpose allowlist entries
were published and read back exactly. The three new database migrations have
**not** been applied to the live backend. Apply them in timestamp order and
reconcile the separately hosted privacy notice before releasing the new client;
missing RPCs deliberately leave local work pending. No app was installed on a
device. The protected PR checks establish push/merge delivery independently of
these rollout steps.


## Offline sync migrations deployed, 2026-09-20

Following explicit user authorization, the three migrations from merged
[PR #98](https://github.com/mxritzgit/Eatova/pull/98), source commit
`01acb77f2d6ab93450b42415e0ec6faac44e9ed2`, were deployed to the verified linked
Eatova Supabase project at 08:36 UTC. Versions `20260920100000`,
`20260920100500`, and `20260920101000` were applied and registered in one
transaction after an exact live-baseline comparison and disposable rehearsal.

Independent readback verified all 49 migration versions, exact SQL source hashes,
and the full expected application catalog/ACLs: 24 public tables with RLS,
49 functions, 35 policies, and 15 triggers. The project is ACTIVE_HEALTHY.
The [main security workflow](https://github.com/mxritzgit/Eatova/actions/runs/35483775158)
is now successful, including the rerun live migration-drift check (attempt 2).
Ignored local `sync-deploy-result.json` and `sync-deploy-ci-result.json` under
`.agents/offline-sync-2026-09-20/` contain sanitized results.
No production behavioral tests or user test records
were introduced; no Edge Function redeployment was required. The app has not
been installed/released, and the separately hosted privacy notice still needs
its pending update. The 13 auth email templates were already published earlier.
See the [merged sync contract](https://github.com/mxritzgit/Eatova/blob/main/docs/OFFLINE_SYNC.md).

## SQLite rollback, password and background hardening, 2026-09-20

Three isolated implementation agents and independent cross-reviews inspected
commit `01acb77f2d6ab93450b42415e0ec6faac44e9ed2`, the current implementation,
tests, sync/auth contracts, migrations and pinned GoTrue behavior. The existing
dirty root checkout remains preserved. Integration is on
`fix/sync-auth-hardening`; ignored local evidence is under
`.agents/sync-auth-hardening-2026-09-20/`.

**P1 confirmed:** completed SQLite migration skipped importing legacy slots but
still deleted them. An obsolete build could create offline work after cutover
which the next upgrade silently discarded. The supported production policy is
now explicitly forward-only storage protocol 2. An encrypted cleanup receipt
commits atomically with migration and identifies exact imported bytes; unknown or
changed legacy data remains intact beside SQLite. Startup shows an actionable
DE/EN recovery screen before network loading. Retry cannot bypass the conflict
when the key is unavailable. New background acquisitions, including pooled
connections, observe the conflict fence; already-running work is not falsely
claimed to be cancelled. Safe recovery preserves both original stores.

The protected-main release validator rejects the actual pre-SQLite revision,
unmerged revisions and incompatible manifests, and binds an eligibility artifact
to the exact candidate commit/tree. The [release runbook](OPERATIONS.md) requires
this check for signing/upload, including rollbacks. It cannot physically prevent
manual uploads or sideloads. Automatic bidirectional re-import is intentionally
unsupported: arbitrary legacy data has no safe merge order against SQLite
revisions, tombstones and immutable server receipts. SharedPreferences offers no
cross-process compare-and-delete; supported mobile upgrades stop the old process.
See the complete [storage contract](OFFLINE_SYNC.md).

**P2 behavior confirmed, policy retained:** Eatova already accepted Supabase's
recent-session password exception. The UI wrongly promised a code was universally
required. DE/EN copy and API comments now state the 24-hour exception. A stolen
valid recent session can therefore still change a password without fresh mailbox
proof; this accepted residual risk is explicit in the
[Auth contract](../supabase/AUTH_EMAIL_OTP.md). No custom endpoint or backend
policy change was introduced. Account deletion keeps its separate mandatory
fresh, account-bound recovery proof. Live settings were inspected read-only:
secure reauthentication on, current-password requirement off, eight-digit codes,
600-second expiry. No real-account password mutation was attempted.

**P3 confirmed in specific paths:** initial DEK/cache-open failures already
returned `unavailable`. Session-keystore exceptions, runtime DB errors and local
prerequisite timeouts instead reached the generic retry handler. A failed local
ACK could consume an attempt, and a missing local session was conflated with
another worker. These now return `unavailable` without follow-up jobs; transport
failures and real worker contention retain bounded retries. ACKs are separate
from transport failure handling. Operations, frozen payloads and retry budgets
survive prerequisite failure and replay after unlocking/reopening.

Product files: `durable_cache_store.dart`, `local_cache.dart`, `home_store.dart`,
`eatova_home_page.dart`, `background_sync.dart`, `sync_execution_guard.dart`,
`auth_repository.dart` comments, and both ARBs. Other files are regression suites,
local auth probes, the release manifest/validator/workflow and linked guides.
The PR diff provides the exact complete inventory. No SQL migration, Edge
Function, dependency or hosted Auth setting changes are required.

Regression evidence includes the actual old-storage → migrate → old-client
offline write → reopen sequence, cleanup/transaction failures, unavailable-key
retry, real SQLite DE/EN recovery UI, and a historical production-release guard.
Background tests include encrypted SQLite, the real Workmanager callback,
reopening and network/503 retry. The migration regression and seven background
regressions first failed against the original code. Existing atomic mutation,
process-crash/replay, account isolation and receipt checks remain intact.

The real disposable GoTrue/SMTP matrix passes 43 password assertions plus 30
existing template/OTP assertions: recent/no-proof acceptance, old/no-proof
rejection, fresh-proof success and invalid/expired/foreign/replayed proof
rejection. Password logins verify actual effects. Disabling reauthentication
and changing a mail-purpose branch are both detected by negative controls.

An additional full auth probe initially failed a refresh-family assertion, while
an unchanged isolated repeat passed; the original cause is not established.
Inspection confirmed that host sleep did not prove Docker's database grace had
elapsed. A bounded, read-only `clock_timestamp()` barrier now verifies synthetic
token ages. Both HTTP denials remain strict first-attempt assertions, and the
rotation-disabled negative control still fails. Four new deterministic timing
tests and seven transport tests pass; the real probe passes its lifecycle and
47 handler checks. No token rows are backdated for refresh tests.

All 49 migrations, RLS/deletion, provider-budget and receipt/ownership concurrency
checks passed again in disposable PostgreSQL, including the 1,800-recipe upgrade.
Deno lint/type checks and 700 unit/evaluation tests pass. The 137 relevant server
and migration source files still exactly match that verified run. No tests were
run against production user data.

The final integrated Flutter 3.47.2 / Dart 3.13.2 run passes **5,049 tests with no
skips**, strict analysis with fatal infos/warnings, and **94.97% line coverage
(30,123 / 31,718 lines)** excluding generated localization. The unchanged floor
is 88%. All seven release-history guards, four template guards, four timing
regressions and seven transport tests pass. Source comparison confirms the
tested isolated snapshot matches the integration product/test/tooling files;
documentation changes are validated separately. Scoped secret scan and diff
checks are clean.

The Android debug APK builds successfully with the same dummy service defines.
The user authorized push and merge through protected main after successful CI;
the PR checks establish that delivery separately. These fixes require no new
Supabase deployment. The previously deployed migrations and email templates are
unchanged, and no app-store release or device installation was performed.
## Password reauthentication and temporary OTP sessions, 2026-09-20

This supersedes the password-policy decision in the earlier SQLite/background
hardening review, while preserving its storage and background-sync fixes.
The selected native contract requires the current password for ordinary
authenticated password changes, including recent sessions. Older sessions also
need Supabase's reauthentication nonce. The app sends the original password
bytes, distinguishes credential rejection from mail-code rejection and permits
a fresh code after GoTrue consumes a nonce before rejecting the current password.

Signup and password recovery no longer become persistent app logins. A
flow-owned, time-limited, unpersisted recovery capability can set the password;
confirmation/reset returns to normal login. Completion, cancellation and account
changes close the capability and attempt bounded, local-scope revocation.
Email-change confirmation keeps the initiating normal login and updates only its
user profile; the additional OTP session is revoked separately. No flow clears
pending outbox data or replaces a newer login during cleanup. Account deletion
keeps its existing isolated, account/session-bound fresh-proof flow.

Native provider exceptions remain explicit: GoTrue exempts OTP/recovery/signup/
email-change sessions and the first password on a passwordless OAuth account.
A hostile client can retain an OTP bearer; client cleanup is not an unavoidable
server gate. Existing OTP sessions from older builds are not retroactively
revoked by this change. A universal fresh-mail requirement would need a separate
Auth infrastructure decision. Offline revocation can fail; stateless JWT access
can persist until expiry. The app never persists these temporary credentials or
automatically retries an uncertain password mutation.

The read-only live health check reported GoTrue **2.197.0**. Disposable probes now
pin that official image by digest and verify the native contract and its
exceptions through real HTTP and internal SMTP. Native/legacy matrices,
nonce expiry/replay/account binding, email-confirmation session preservation,
local revocation and deliberate disabled-control mutations are covered. Flutter
regressions cover input/wire format, retry UI, normal-login routing, scoped
cleanup, account switching/ABA and late responses. The config audit has offline
failure/secret-redaction tests and runs live only from the protected `main`
`supabase-drift` environment.

Deployment changes only `security_update_password_require_current_password`
to `true`, after the reviewed PR passes CI, with exact configuration readback.
Older clients without the current-password field need an update for the settings
dialog; normal sign-in and mail recovery remain available. The protection must
not be disabled for rollback compatibility. No schema migration or app/device
installation is implied by the source merge. The delivery PR records actual
deployment and CI evidence separately from this implementation contract.

Sources: [current password contract and rollout](../supabase/AUTH_EMAIL_OTP.md),
[temporary credentials](../lib/src/auth/password_recovery.dart),
[session mutations](../lib/src/auth/auth_session_mutation.dart),
[password matrix](../scripts/security/password_change_checks.py),
[Auth probe guide](../scripts/security/README.md),
[production configuration audit](../scripts/security/auth_config_drift.py).

## Social recipe share import, 2026-09-21

Implemented locally on `feat/social-recipe-import`, based on `main` f4aa705,
in `.agents/social-recipe-import-2026-09-21/worktree`. Three requested workstreams
covered extraction, Flutter review UI and native sharing; integration review fixed
idle warm-share frame scheduling and durable account binding before native delivery.
The original older, dirty checkout was preserved. No commit, push or deployment
was performed for this feature.

One complete recipe opens a preview. Multiple recipes and explicit variants remain
separate, unselected choices; users can save several individually from one result.
Only confirmation writes through the existing HomeStore encrypted cache/outbox.
Unavailable or incomplete captions fall back to pasted text. Missing nutrition
stays visibly unknown and cannot enter the diary until supplied. Source attribution
and stable content identity survive persistence. See the [product and security
contract](RECIPE_SHARE_IMPORT.md), [native integration](NATIVE_RECIPE_SHARE.md),
and [Edge Function contract](../supabase/functions/recipe-import/README.md).

Android opens the import sheet in Eatova. The first iOS implementation required
manual app opening after preparing the source. The user clarified that this extra
step does not satisfy the requirement: both platforms must open Eatova directly
from Share, with all recipe UI inside Eatova. See the automatic iOS handoff update
below. App Group provisioning, a signed Xcode build and Apple-device tests remain
required. The backend is not deployed. Live TikTok availability and actual model
extraction quality remain unverified; unit fixtures do not establish them.

Automatic approval review rejected the emulator ACTION_SEND launch with
`blocked by policy`, including an attempt without force-stop. No bypass was used;
on-device cold/warm flow behavior is unverified. The latest separate Android test
APK compiled successfully and was not installed. Only an earlier synthetic fixture
was installed in the emulator; the normal Eatova package/data remained unchanged.

A pre-existing test-seam edge was recorded during review: replacing the entire
AuthGate authRepository with another identity does not dismiss pushed routes,
although save fences reject stale writes. Normal production auth-stream transitions
do dismiss the import. It was not changed as part of this feature.

Final integrated verification (Flutter 3.47.2 / Dart 3.13.2): **5,114 tests passed**,
strict analyzer with fatal warnings/infos passed, **94.95% line coverage
(31,048 / 32,699)** excluding generated localization, above the unchanged 88%
floor. The frozen snapshot matches all 49 changed product/test files byte-for-byte.
Backend verification: 725 function tests plus 11 offline evaluation tests passed,
66 function files and three eval files linted, all four entry points type-checked.
The import test files also pass standalone without network permission. Deliberate
negative controls detected removed auth-context, source-quote, redirect-host,
initial-owner and stale-owner protections. No live database tests were needed;
there are no schema changes.

Visual review passed 16 sheet tests plus four real-font render flows, covering
light/dark themes at 390px/normal text and 320px/double text; 20 screenshots were
inspected. Native receiver tests passed 13/13; iOS XCTest source was added but
cannot be executed on Windows. The final isolated Android test APK SHA256 is
`27B366ED1AD85E98B205A6BB0BC1D03D1B47290CDCDA0367E5F3054FBCCD8330`.
Scoped key-pattern scanning found no credentials; changed-doc links and diff
whitespace checks passed. No dependencies or lockfiles were changed.

Local evidence lives in the ignored task folder
`.agents/social-recipe-import-2026-09-21/`: `flutter-full-owner-final.log`,
`flutter-analyze-owner-final.log`, `integration-freeze-manifest.json`,
`backend-verification/`, `visual-verification/VISUAL_REVIEW.md`, and
`android-share-evidence/VERIFICATION.md`. These are local checks, not a CI run,
backend deployment, signed iOS archive or on-device functional proof.

## Automatic iOS recipe handoff correction, 2026-09-21

The required flow is TikTok -> Share -> Eatova -> main app opens automatically
-> recipe review sheet inside Eatova. The user explicitly rejected manual app
opening as the normal iOS flow and authorized protected-PR push/merge only after
addressing this. A recipe overlay inside TikTok was never required.

The Share Extension now waits for both loaded source and an appeared controller,
atomically enqueues once, and launches the main app using the payload-free
`eatova-share://import` URL. It completes only after a successful launch callback;
false or an eight-second deadline offers retry without duplicating the source.
Late callbacks, repeated appearance/loading and cancellation are fenced. The main
app handles warm delivery through SceneDelegate/RecipeSharePlugin; cold startup
keeps Flutter's engine bootstrap and the owner-bound inbox. Malformed reserved
wake URLs are swallowed, unrelated OAuth URLs are forwarded unchanged, and no
source data or credentials travel in the wake URL.

The typed modern UIApplication.open call uses a responder-chain compatibility
technique; Apple does not support this operation from Share Extensions. The
extension keeps APPLICATION_EXTENSION_API_ONLY=YES. The first PR build rejected
NO; the typed instance method does not use the extension-unavailable shared
accessor. No private API, deprecated openURL selector or dynamic-selector
workaround is used. This limitation is
explicitly documented in the [native guide](NATIVE_RECIPE_SHARE.md). Unit tests and
compilation cannot establish live TikTok behavior, future OS compatibility or
App Store acceptance; a signed device check remains necessary before release.

Nine handoff and five wake XCTest cases join the eight durable-inbox tests. The
iOS workflow now compiles the release app and runs RunnerTests in a simulator,
requiring actual passed cases from all three share suites in xcresult. The CI
helper's nine offline tests and its missing-suite negative control pass locally.
Two new Flutter integration tests cover cold/active wake, route echoes and
notification/resume deduplication; disabling native wake delivery makes the active
case fail. Native XCTest execution is delegated to the macOS PR check, because
this Windows workspace has no Xcode. The delivery PR records its actual outcome;
no production backend deployment or normal-device installation is implied.

## Recipe share CI review and test scheduling fix, 2026-09-22

The iOS implementation in PR #101 compiled with Xcode 26.6 and
APPLICATION_EXTENSION_API_ONLY=YES. The iPhone 17e/iOS 26.5 simulator passed
all 22 new share cases (handoff 9, inbox 8, wake 5), 23 RunnerTests total with
zero failures. The [iOS run](https://github.com/mxritzgit/Eatova/actions/runs/35659311846)
contains the xcresult and logs. This proves compilation and the tested handoff
logic, not a signed TikTok-to-Eatova switch on a physical iPhone.

CI also exposed an existing timing race in the English legacy-storage-conflict
widget test. Its fixed retry wait could leave cache opening unfinished, then
await storageReleased inside runAsync while FakeAsync continuations could no
longer advance. The current feature run passed, but a deliberately delayed retry
reproduced the earlier timeout. The test now pumps until initial load, retry and
storage release actually finish, with bounded waits and explicit retry-start
verification. Production storage and share code are unchanged by this correction.

The [delivery PR](https://github.com/mxritzgit/Eatova/pull/101) records the final
head, CI counts, coverage and merge state. Backend deployment, Apple App Group
provisioning and a signed real-device share check remain release work.

## TikTok caption nutrition and import reliability, 2026-09-22

The reported Hot Pockets video reproduced the original deployed failure: a ready
recipe with all four nutrition fields and yield null, despite explicit caption
values. The source validator missed `pro Stück`, `ca.` and piece yields; the app
also discarded every nutrition field when any macro was missing. The corrected
handler, exercised with real authentication, budget reservations and provider,
returned **358 kcal, 32 g protein, 31 g carbs, 11 g fat per piece, yield 8**.
Repeated quantities in different recipe parts now survive extraction as well.

The [import contract](RECIPE_SHARE_IMPORT.md) and
[function guide](../supabase/functions/recipe-import/README.md) describe v2:
independent source-backed nutrition, proven whole-recipe yield conversion,
explicit confirmation of unclear serving bases, and ingredient-only previews
without invented preparation. Existing clients retain the v1 contract. Persisted
known-field/basis markers preserve partial values through the existing recipe
row, encrypted cache and outbox; no schema migration is needed. Existing saved
recipes are not automatically rewritten.

Source fetching now retries transient oEmbed failures and can read bounded,
inert public-page data for the exact post ID. This fallback was also checked
against the reported public video. Strict JSON output, finish-reason checks,
source verification and one reserved retry address malformed/truncated model
responses. Live provider testing caught a schema compatibility issue with nested
`maxItems`; caps remain enforced by the parser. Private/deleted/restricted videos
can still require pasted text, and the other originally failing videos were not
supplied, so their individual historical failures are not established.

The import preview now uses Eatova typography, a brand-colored recipe header,
four independent nutrient tiles and clearer source/missing-content states.
Real-font light/dark renders were inspected. Local verification: strict analyzer
passed, **5,121 Flutter tests**, **94.95% coverage (31,176 / 32,834)** excluding
generated localization, **738 backend tests** and **11 offline evaluations**
passed. The regression fixtures detected the old trailing-basis, whole-total
and long-caption failures before the fixes. The delivery PR records the final
CI, merge and deployed function version; no updated device installation is
established by these checks.

## Imported nutrition and tracker handoff, 2026-09-22

The follow-up pizza screenshots exposed two linked presentation failures:
complete caption values with an unconfirmed basis still showed the generic
"Nutrition missing" marker, and the tracker action opened a picker whose four
meal buttons were disabled without an actionable way to resolve the basis.
The caption explicitly said `Für eine Pizza`, which the yield validator also
missed. Its matching with-toppings values are 507 kcal / 50 g protein / 61 g
carbs / 6 g fat; the separate without-toppings block must not be mixed in.

New imports recognize that exact written single-dish yield with conservative
source checks. A real provider/authenticated handler call for the screenshot
video returned the four expected values, yield 1 and `per_serving`, with no
warnings or provider diagnostics. Hot Pockets, partial values, recipe totals
and genuinely unspecified bases also retained their expected behavior. The
temporary synthetic account was deleted and deletion verified.

Existing saved recipes now distinguish missing values from an unclear basis.
The tracker action opens a compact serving-basis confirmation for complete
figures, persists it through the existing recipe save/outbox path, then opens
meal selection. Actually missing values lead directly to the prefilled editor.
Cancellation, invalid amounts, failed persistence and stale account sessions
do not create diary entries. No row migration or automatic recipe rewrite is
needed. See the [current import contract](RECIPE_SHARE_IMPORT.md).

Three Flutter regressions and the original two yield regressions failed against
the prior behavior before the fixes. The focused 50-case Flutter suite covers
all four meal slots, offline receipts, scaling, retry, cancellation, single
flight, account switching and large German/English text. The source guards
also reject per-100g, fractional and mixed-block reinterpretations. Real-font
light/dark renders were inspected; strict analysis passes. See the
[tracker regressions](../test/recipe_import_tracker_test.dart) and
[yield/source guards](../supabase/functions/recipe-import/single_yield_test.ts).
An additional real-provider case caught loss of valid numbers when a single-dish
caption omitted the optional nutrition heading; its negative control failed
before the correction and its live rerun retained all four values and basis.

Local verification passed **5,131 Flutter tests**, **94.95% coverage (31,328 /
32,993)** excluding generated localization, **742 backend tests** and **11
offline evaluations**. The delivery PR records CI results, merge and deployed
function version. App changes still require a new device build; backend
deployment alone does not update it.

## Single-Bowl caption nutrition guard, 2026-09-22

The next reported TikTok screenshot showed `Nährwerte (1 Bowl): 425 kcal,
48 g Protein, 39 g Kohlenhydrate, 8 g Fett`, while the preview showed four
dashes. A real provider call using the caption reproduced the failure: the
model returned all four correct numbers and `per_serving`, but the server
source validator rejected the parenthesized Bowl basis and discarded every
number. Recipe ingredients still survived, explaining the misleading preview.

The validator now recognizes source-backed parenthesized one-item nutrition
headings. It chooses that explicit basis even if a model labels it uncertain or
as a recipe total, and still verifies each number against its nutrient label.
`1 Bowl` in the nutrition heading is not treated as proof of the recipe's
overall yield. Fractional, per-100g and multiple conflicting blocks remain
unconfirmed. The before-fix regression failed with all four values null; the
corrected local handler/provider call returned 425/48/39/8 per Bowl with only
the expected missing-preparation warning. The disposable account was deleted.
See [Bowl regressions](../supabase/functions/recipe-import/bowl_basis_test.ts)
and the [import contract](RECIPE_SHARE_IMPORT.md). The delivery PR records
full CI, merge and deployment evidence; no updated app build is implied.

## Separate caption values from serving conversion, 2026-09-22

The Oreo report (`https://vm.tiktok.com/ZGdQqda4h/`, canonical Niall Grehan
video `7356279018955607328`) exposed the limitation of the previous fixes.
The public source fetch returned the complete caption, including `Macros for
whole desert: 326 kcal 31g carbs 7g fat 32g protein`. The source validator still
coupled every number to a small serving-basis vocabulary, so a valid but
unrecognized heading cleared all four figures. The regression reproduces that
loss without requiring a paid provider call.

Version 2 now separates proof of a nutrient value from permission to normalize
it to servings. A single source-backed block survives unfamiliar wording with
its raw values and an unconfirmed basis. No dessert-specific phrase was added
to authorize a serving conversion. Unproven mass/fraction references likewise
stay reviewable without silent scaling. Null model fields can recover unique
source values; missing values, conflicting blocks, swapped numbers and invalid
numeric tokens remain guarded. Reading-order parsing also handles densely
packed label-first values without borrowing the preceding nutrient's number.
Complete values no longer receive the `nutrition_missing` warning solely
because their basis needs confirmation. Legacy clients retain their stricter
contract.

See [the regression matrix](../supabase/functions/recipe-import/nutrition_evidence_test.ts)
and [the Flutter preview/save test](../test/recipe_import_sheet_test.dart).
The shared Oreo response fixture was generated through the actual TypeScript
parser and is consumed by Flutter's JSON model, preview and storage checks.
Delivery evidence must distinguish local verification, protected-main CI/merge,
authenticated provider tests and backend deployment; the delivery PR records
their final status. No device build is implied by a backend rollout.

## Single-letter caption macros, 2026-09-22

Fix on `fix/import-macro-abbreviations`, based on main `5e4fb5c`, in
`.agents/import-macro-abbreviations-2026-09-22/worktree`. The reported
`31g P   13g C  9g F` was rejected because the nutrient-label validator lacked
single-letter aliases. The extraction prompt and source validation now support
`P`/`C`/`F` with gram amounts on either side, case-insensitively. Decimal and
zero values survive; word prefixes and temperatures cannot supply macros.
Reading-order binding also preserves repeated-label conflicts and prevents a
label followed by `:` or `=` from borrowing the preceding nutrient's amount.

The [regressions](../supabase/functions/recipe-import/macro_abbreviations_test.ts)
cover source-verified extraction with both supplied and omitted model values,
format variants, missing/zero values, conflicting/swapped values, false matches,
invalid quantities, serving conversion and legacy behavior. Before the fix,
five of seven tests failed, including the reported caption. After the fix,
all 763 backend tests and 11 offline evaluation tests passed; all Edge Function
entry points type-checked and Deno lint passed. No Flutter code changed.
The user authorized push, merge after CI, and the required backend deployment
on 2026-09-23. The delivery PR records the verified CI, merge and rollout
results separately; no device installation is implied. Existing saved imports
are not rewritten.


## App review and reliability fixes, 2026-09-25

Reviewed current remote main `af69a95` with exactly two subagents plus the
primary reviewer. The [review report](APP-REVIEW-2026-09-25.md) records the
feature matrix, four confirmed findings, source/test links and verification
limits. Fixed foreground and background queue starvation, local ACK failures
incorrectly exhausting server retry attempts, and Coach recipe adoption staying
locked after failed persistence. All four original failures were demonstrated
before correction; five regressions now pass. No confirmed critical backend
security defect or actual data loss was established.

Local result: `fix/app-review-2026-09-25` in the original checkout's
`.agents/app-review-2026-09-25/integration`. Final checks: 5,137 Flutter tests,
fatal analyzer clean, 94.98% coverage (31,343 / 33,001), Android debug APK and
release AAB with R8/AOT and throwaway signing; 763 backend tests, 45 Deno files
independently, 11 offline evals, all 49 migrations/real local RLS and concurrency,
local Auth/password/mail-purpose and backup/restore checks. The report scopes
these counts and links their machine-local evidence. No dependencies, schema
or backend source changed.

The user subsequently authorized push and merge after CI. The delivery pull
request records GitHub verification and merge status separately; the fixes need
no backend deployment. The original dirty checkout remains preserved. No device
installation, local iOS build or live provider/production verification is
established by the local review above.

## Deep functional review with ten specialists, 2026-09-26

The second review started from main `8b8ee122fc8fac04b1ff3221587ec47bfea4a2e6`
(PR #107), with exactly ten GPT-6 Sol/xhigh specialists in isolated worktrees
and independent peer/root review. The full [review and regression evidence](APP-REVIEW-2026-09-25.md#deep-review-with-ten-specialists-2026-09-25-to-2026-09-26)
records the corrected behavior, test oracles and residual boundaries.

- Fixed async auth/Coach navigation and quota feedback, accepted-answer
  reconciliation, immutable import retries, complete bounded meal/history
  paging, selected-day/workout retention, pending counters and weight capping,
  native preference ordering and reminder side effects after durable commits.
- Hardened Edge diagnostics/cancellation/stream cleanup, denied-day provider
  usage retention, and the iOS gate requiring all 22 declared share XCTests.
- Test review corrected a discarded-accepted-reply oracle and replaced timed
  photo assertions with actual cleanup completion. The integrated server/client
  contract caught a missing remote-abort mapping; local cancellation stays silent.
- Final local evidence: **5,194 Flutter tests, 95.02% coverage**,
  strict analyzer clean; **795 offline Deno tests**, four entrypoints checked;
  final Android debug/release builds with R8. Real disposable PostgreSQL checks
  covered all 50 migrations, ownership, concurrency, upgrades and restore.
  Synthetic auth checks included a detected disabled-rotation mutation.

Delivery branch: `fix/deep-app-review-2026-09-25`. Its pull request records
protected CI and merge status; local passes alone do not establish either.
The original dirty checkout was preserved. Migration
`20260925100000_provider_usage_denied_retention.sql` and all four Edge Functions
still need a separately authorized backend deployment. No device build was
installed; real hardware/provider journeys and live production state were not
verified. The main-only drift check can report the unapplied migration until
rollout. Actual Xcode/XCTest execution is delegated to the macOS PR workflow.

## iPhone Health startup recovery, 2026-09-26

An intermittent missing steps card was reproduced from main `6a2da06`
([PR #108](https://github.com/mxritzgit/Eatova/pull/108)) using the actual
[Apple Health service](../lib/src/services/apple_health_service.dart) and
Flutter lifecycle binding with a stubbed native Health plugin. An initial
authorization attempt can finish `unknown` when startup is inactive,
configuration is interrupted, or configuration fails temporarily. The
[home shell](../lib/src/app/eatova_home_page.dart) excluded `unknown` from every
later resume; a resume during an active Health request was also discarded.
Manual Connect Health could therefore recover a session that automatic refresh
never retried. This reproduces a code-level cause consistent with the report;
the historical timing on the user's iPhone and update-versus-reinstall are unknown.

The shell now retries an unfinished iOS connection on resume and coalesces a
resume received while busy into one follow-up. Lifecycle events caused by that
follow-up cannot enqueue another retry, preventing permission-sheet loops.
Android still requires account-scoped Health Connect opt-in. The existing
foreground/account guards, silent re-verification, and same-local-day snapshot
requirement remain; unknown readings do not become measured zero.

[Nine regression tests](../test/health_startup_recovery_test.dart) cover startup,
interruption, temporary failure, busy resume, bounded retries, absent read
evidence, Android opt-in, disposal and sign-out. Five fail against the original
shell; all nine pass with the fix. The adjacent Health/lifecycle run passed
163 tests, and strict analysis passed. Full-suite coverage and protected CI
results are recorded in the delivery PR for `fix/health-startup-recovery`.
Evidence logs are machine-local under `.agents/health-startup-2026-09-26/`.
No backend deployment is needed. A rebuilt iOS app and physical-device check
are separate from automated verification; neither is established by these tests.

## Data export and analysis overlay, 2026-09-26

The export now presents ordered, expandable sections with paged records and
selectable values. Complete output is available as a readable report, indented
JSON, or per-section CSV. Preview limits never truncate copied/shared data;
unknown fields and meaningful nested array order remain intact. CSV escapes
quotes, multiline values and spreadsheet formulas. Completeness still comes
from the export service, including its unknown-count and partial-copy markers.

Photo analysis now uses an integrated photo, a lavender nutrition summary,
pastel macro tiles, open ingredient rows and accessible portion/add actions.
Actions remain visible on ordinary phones and scroll with enlarged text or
short screens. The current meal icon family and asynchronous persistence guards
are retained. Measured toast space is opt-in for the two adapted sheets;
other hosts preserve their existing layout and route visibility rules.

The changes were integrated onto main `1c4862f` in the isolated delivery branch
`design/export-analysis-release`. The original dirty checkout and unrelated
instruction/review edits are preserved. Local verification: strict Flutter
3.47.2 analysis passed; the full suite ran 5,225 tests, with one older export
fixture missing the recipe-history section. After correcting that fixture,
all 67 affected tests passed. Full-run line coverage was **95.12%**. Real-font
renders cover German/English, light/dark and 200% text; final visual inspection
includes the current meal icons. Secret scanning and diff review passed.

Machine-local logs and captures are under `.agents/export-analysis-delivery/`
and `.agents/export-analysis-release/build/export-analysis/`. The delivery PR
records the final complete CI run, Android builds and protected-main merge.
No backend deployment or device installation is part of this UI change.

## Photo preview refinement, 2026-09-27

The user's screenshot identified the **pre-analysis** photo/context dialog
(`MealScanPreviewSheet`), distinct from the result sheet refined in PR #110.
This follow-up replaces its photo-check/ready badges, decorative icons, nested
context card, repeated explanations and character-progress bar with a plain
app header, photo, one optional soft-fill field and compact suggestions. The
upload explanation appears once next to the explicit Start action.

The primary action remains visible on regular phones. Small windows, enlarged
text and the keyboard use a scrollable layout; the input stays in the same
subtree so its focus, selection and draft survive that transition. The close
control is in the header. Invalid/missing previews have an honest fallback,
image decoding is bounded, and the existing 400 UTF-16-unit validation and
cancel-before-upload/account-isolation contracts remain unchanged.

Actual Flutter renders: [dark](scan-preview/dark.png),
[light](scan-preview/light.png). These use a bundled fixture photo, not user
data. Reproduce with `CAPTURE_SCAN_PREVIEW=true` while running
`test/meal_scan_preview_design_test.dart`. Its real-font matrix covers both
languages/themes, 390x844 and 320x568 at 200%, keyboard reflow, focus/selection,
confirmation and unavailable previews; existing flow tests cover the upload
and account guards. Direct diff review and final validation are recorded in
the delivery PR for `design/scan-preview-refinement`. No backend change is
needed; seeing this on a device requires a newly built and installed client.

## Recipe ingredient portions and complete parallel CI, 2026-09-27

Imported recipes previously retained batch ingredient text beside nutrition that
was already normalized per serving. The server now validates ingredient-specific
source evidence independently of nutrition: 800 g for four servings becomes
200 g in the client presentation, while per-piece nutrition stays unchanged.
Whole-recipe nutrition is divided once. Storage and JSON export preserve original
source quantities; readable report/CSV add a derived serving projection.
Detail, import preview, meal-plan shopping and history share that interpretation.
Source edits invalidate ingredient evidence, while title-only edits retain yield.

Unsupported or ambiguous amounts preserve the complete original list with its
context. Written quantities in arbitrary source languages cannot accidentally
be labelled as converted. Older imports without ingredient evidence remain
unconfirmed; nutrition confirmation alone cannot prove their ingredient basis.
See the [import contract](RECIPE_SHARE_IMPORT.md) and the shared
[server/client fixtures](../test/fixtures/recipe_import/portions_contract.json).
The change needs both the updated `recipe-import` function and a rebuilt client;
merging does not establish backend deployment or device installation.

The previous successful Flutter CI job spent 25m15s testing and 49s on setup and
analysis (GitHub job 108573679433). Four complete-file partitions now run in
parallel, starting longer suites first. New test files are discovered automatically.
The existing required `Flutter analyze + test` context verifies strict analysis,
every shard, complete JSON reports and coverage artifacts bound to the checkout.
Coverage unions source/line hits across all shards, excludes generated l10n as
before, and retains the 88% floor. No prior passing result substitutes for a run.
The [CI guide](../CONTRIBUTING.md) describes local reproduction;
[43 integrity regressions](../test/tooling/flutter_ci_test.py) exercise missing,
failed, cancelled, skipped, truncated and incorrectly merged evidence.

Independent local validation: Flutter 3.47.2 strict analysis, **5,315 tests across
525 files**, **95.17%** line coverage; Deno lint/check and **817 tests** including
the evaluation harness. Negative controls reproduced the original portion bug,
unsafe written quantities and CI omission/coverage faults. Exactly two requested
Astra agents implemented and audited the work, followed by parent review and
verification. Hosted timings, Android builds and the protected merge are recorded
in the delivery PR for `fix/recipe-import-portions`. Local evidence is under
`.agents/recipe-portions-2026-09-27/`; the original dirty checkout is preserved.

## TikTok nutrition conflict diagnosis and correction, 2026-09-27

The reported Kaiserschmarrn caption contains two different protein amounts
(`47g Protein`, `68g Protein`) and no carbohydrate label. A fresh fetch through
the production source loader returned the complete caption, including 650 kcal,
20 g fat and a two-serving ingredient yield. That yield does not establish whether
the nutrition describes one serving or the whole recipe. The historic provider
response was not available; the screenshot behavior was independently reproduced
with the current source and parser, without an authenticated or paid AI request.

Two application defects were reproduced before correction: a model quote cropped
to the second protein amount could conceal the earlier conflict, and the client
showed a generic serving-confirmation hint while nutrients were still missing.
The server now checks the bounded containing nutrition section and emits optional
canonical conflict fields. The client preserves known values, distinguishes
conflicts from missing nutrients, and offers a nutrition-only draft correction
before final import save. It never silently relabels the caption's second protein
amount as carbohydrates. Identity, source quantities, account guards and retry
semantics are retained; no database migration or source-caption persistence is added.

Replaying the fetched caption also exposed standalone-line assumptions in the
ingredient-reference validator. Explicit colon-delimited ingredient headers now
work in flattened TikTok captions. Repeated/mixed references, cropped preceding
references and nutrition-only headings remain guarded. Shared fixtures prove
160 g for two servings displays as 80 g without dividing unqualified nutrition;
unsupported quantity lists still retain their complete original batch context.

The [shared server/client regressions](../test/fixtures/recipe_import/nutrition_conflict_contract.json)
cover both original and cropped evidence plus a correctly labelled control.
Both faulty cases fail against the preceding implementation. Additional tests
cover boundaries/hashtags, zero, source variants, persistence/export/logging,
manual correction, cancellation and account changes. A real-font DE/EN,
light/dark, regular/200% text matrix exercises the correction sheet; optional
captures use `CAPTURE_NUTRITION_REVIEW=true` with
`test/recipe_nutrition_review_layout_test.dart`.

Exactly two existing Astra agents implemented backend and client changes;
the parent reviewed the diffs and ran independent integration checks: strict
analysis, **5,346 Flutter tests across 528 files**, **95.19%** line coverage,
**831 Deno tests** both combined and across 50 isolated files, 11 offline
evaluations, lint/type checks and a clean secret scan. Bulleted nutrition rows
after blank lines have a separate failing-before/passing-after regression. Final
validation, protected-main delivery and CI evidence are recorded in the PR for
`fix/recipe-nutrition-conflicts`. Machine-local probes/logs are under
`.agents/recipe-nutrition-2026-09-27/`; the original dirty checkout is untouched.
The fix needs deployment of `recipe-import` and a rebuilt client. A merge alone
does not establish either deployment or installation on the user's iPhone.

## Review fixes and recipe-import v9, 2026-09-27

[PR #114](https://github.com/mxritzgit/Eatova/pull/114) (squash `5255320`) fixed three
review findings on #109–#113. `recipe-import` again accepts yields led by a recipe
subject ("Zutaten für 4 Portionen", "Serves 4 people"), which #112 had rejected.
Scaled ingredient amounts use the locale's decimal separator; shopping ids stay
locale-neutral. The readable session export has the snapshot title.
`recipe-import` v9 is live (JWT on; runtime graph equals merged source), and a
disposable-account canary confirmed the per-serving division. No app build was
installed.

Sharded Flutter CI is not rerun-safe. After a shard fails, "Re-run failed jobs" leaves
the stale `shard-N` artifact next to the new one, and the aggregate fails closed.
Start a fresh run instead, for example by closing and reopening the PR.

## Flutter/Dart skills applied with three agents, 2026-09-28

The user installed the official `flutter/skills` and `dart-lang/skills` packages
(`.agents/skills/` and `.claude/skills/`, both machine-local and ignored). Exactly three
agents applied them in isolated worktrees: test suite, UI/layout/l10n, and Dart
quality/data layer. The coordinator merged the three branches without conflicts,
removed the now-unused outbox-loss ARB keys, and reviewed the combined diff.

- Analysis: `strict-casts`, `strict-inference` and `strict-raw-types` plus
  `avoid_catching_errors` are enabled. New code must avoid untyped empty literals,
  raw generic types and implicit dynamic downcasts.
- Fixed defects, each with a regression test that failed first:
  - a pending weigh-in duplicated on every cold start;
  - an offline cold start showed no planned meals when the slot held only plans or
    checks;
  - planned catalog recipes carried the "self-added" diary note;
  - a JWT `exp` overflow was accepted;
  - sync rethrows lost their stack;
  - `sendTextRequest` bodies are now bounded to 4 MiB;
  - German iOS speech errors reached the English UI;
  - "1 Portionen" and dot decimals appeared under German;
  - the profile streak ignored the frozen clock;
  - a lost Coach recipe photo was masked by the success toast.
- Layout: a sweep test covers 5 tabs and 22 sheets/pages at 320/390 px, 1.0x/2.0x,
  DE/EN, light/dark and tablet/landscape. `ReadableWidth` centres content at
  640 px above that breakpoint; phone geometry was verified unchanged. Widget
  previews exist for four design components (`.widget_preview/` is ignored).
- Tests:
  - removed dead direct-write sync code (unused since #98), `capOutbox` and the loss
    hints, plus their category-(a) tests;
  - removed 12 subsumed or vacuous regression cases, each with a named covering test
    and no line of lost coverage;
  - fixed tests that could not fail (missing PostgREST request, clock-dependent
    lunch default) and a real-time deadline test;
  - two registry tests now guard the live `_mealRow` serializer instead of dead code.
- With the user's approval, the dead `ScanSlotChips` widget (replaced by the compact
  meal-context row in #86/#87) was removed together with its fixed-color allowlist
  entry.
- Result: 5,474 tests, 95.57% line coverage (baseline 5,350 / 95.20%), strict
  analyzer clean. No backend, dependency or lockfile change.
- Evaluated and not adopted, with reasons in the agents' reports:
  - mockito;
  - package:checks;
  - integration_test in CI;
  - go_router;
  - primary constructors (need SDK lower bound `^3.13.0`);
  - package:path as a direct dependency.
- Open items for a user decision:
  - v1 training checkpoints that can never be saved or discarded
    (`training_session.dart:351`);
  - weight cache timestamps without an offset;
  - number fields that turn "3,5" into 35 or "1.000" into 1;
  - German strings persisted in user data;
  - the Android portrait lock versus tablets;
  - larger controller extractions (Coach, add-meal sheet).
- Rare SQLite test flakes remain unexplained:
  - `sync_execution_guard_sqlite_test` once on Linux CI;
  - `sqlite_process_crash_test` twice on Windows under load.
  Adding the SQLite result-code name to `DurableStorageException` would make
  them diagnosable.

## Open findings fixed with five agents, 2026-09-28

This section supersedes the open items and the flake and CI notes in the two
entries above. The user asked for exactly five agents, one per finding. The
coordinator merged their branches (only an import line conflicted), fixed an
additional overflow, reviewed the result and delivered it through one PR.

- Number input:
  - One sealed parser (`models/number_input.dart`) serves every quantity field.
  - "3,5" and "3.5" both parse. A possible thousands group such as "1.000" or
    "2,500" is not guessed: a localized hint asks for clarification.
  - Whole-number fields refuse decimals instead of stripping the separator (for
    example, 7,5 kg used to become 75 kg).
  - Manual macros per 100 g are bounded at 100 g.
  - A source guard keeps `digitsOnly` and ad-hoc decimal parsing out of quantity
    fields.
  - Goal weights stay whole numbers, because `profiles.weight_kg` is an integer
    column (a user decision).
- Training: a #70 v1 checkpoint is upgraded once to v2 and persisted, so resume,
  save and discard work again. The concurrency guard is unchanged.
- Weight: cache rows are UTC instants; legacy offset-less rows migrate on read.
  De-duplication compares instants, and display uses the local day.
- Persisted German fallbacks (meal/product/recipe names, adjustment and recipe
  notes, macro text, import source line) are resolved at display time only.
  Stored bytes, favorite keys and shopping ids are unchanged.
- CI:
  - Shard artifacts are named `shard-N-attempt-K`, and the aggregate takes each
    shard from its newest attempt without falling back. download-artifact picks
    the highest artifact ID per name, and those IDs are not chronological, so
    reruns previously used a stale artifact.
  - "Re-run failed jobs" is now safe.
- SQLite:
  - `DurableStorageException` carries the sanitized result code.
  - A ROLLBACK after SQLite's own rollback no longer masks the original error.
  - The Windows crash-test flake is explained and fixed: the test killed only the
    `dart run` launcher while the child still mapped the `-shm` file, which caused
    `SQLITE_IOERR_TRUNCATE`.
  - The Linux sync-guard flake is unproven but now reports its SQLite category.
- Layout: the expanded search/favorite live preview reflowed poorly at 320 px and
  200 % text, overflowing by 71 px. It now keeps one line when it fits and stacks
  the macros otherwise.

## Dark redesign of the five tabs, 2026-09-28 to 2026-09-30

The user's `Design.html` (not in the repo) redesigns Today, Food, Recipes,
Training and Coach: a dark theme, Figtree for UI text and Bricolage Grotesque
for display text, a floating glass tab bar, and a violet accent. Sheets, detail
pages, settings, auth and onboarding only inherit the tokens and fonts.

- The app is dark-only, and the change is reversible: `kDarkOnly` hides the
  theme row, while `AppTokens.light` and `ThemeModeController` stay in the code.
- Inputs stay borderless soft fills (user preference), although the design draws
  hairlines on them.
- One shared derivation layer (`models/day_nutrition.dart`,
  `home_store_derivations.dart`) feeds all tabs:
  - the logging streak;
  - `nextMealPick`: the same pick on Today, Food and Recipes;
  - the day summary with the activity credit;
  - slot summaries, the next workout, weekly volume and PRs;
  - the coach day brief.
- Planned picks are logged only through `store.eatPlannedMeal`, via
  `widgets/recipes/recipe_pick_actions.dart`. This prevents duplicate diary rows.
- The empty-slot band ("Suggested N–M kcal") is decided by the user's delegated
  choice. It keeps the 20–25/25–33/25–33/7.5–15 % shares, but splits the kcal
  still left over the empty slots, so it never suggests more than what is left.
  It disappears when almost nothing is left.
- A `LocalHourTicker` in the shell (re-synced on resume) moves every tab on at
  meal-slot boundaries.
- Theme text: letter spacing 0, line height 1.2, body styles 1.4. The `≈` glyph
  falls back to Bricolage Grotesque, because Figtree does not have it.
- The status-bar scrim stays (user decision). Content scrolls under the status
  bar in every tab.
- Design elements omitted for lack of data or features: the training energy
  credit card, a fixed weekday plan, quick-start Run/Cycling/Freestyle, and the
  coach mic.
- The steps card on Today moved below the first viewport. This supersedes the
  2026-09-13 request.
- 81 unreferenced ARB keys were removed; 59 of them were already dead on
  `origin/main` (b7cf9cb).
- Process: seven task branches in `.agents/dark-redesign-2026-09-28/`. Each tab
  got one review and a visual comparison; two final reviews and one scoped
  review followed. The full suite passed with 5935 tests and 2 skipped.

## Cleanup, performance and motion polish, 2026-10-01

Seven agents worked in parallel worktrees (`.agents/polish-2026-10-01/`, reports
in `reports/`) and were integrated in one PR.

- Cleanup:
  - Dead `lib/` code was found with a resolved-AST reference scan, not grep
    alone, and is removed (about 1,100 lines). It included old widgets
    (`TickGauge`, `ScreenTitle`, `DottedAddSlot`, `StatusPill`), the never
    scheduled `LocalCache` debounced write-through, `enqueueCoalesced`, six
    unused `AppSymbol` glyphs and `HealthService.readWeightSamples`.
  - Stale tests are cleaned up (about 1,300 lines). Four tests that could not
    fail now can, which was shown by mutation. Duplicates went only where
    another named test covers the same guarantee.
  - Docs and the README describe the dark redesign.
  - The Android launch window is dark (#09090C) instead of white.
  - The light palette, `ThemeModeController` and the parked light-mode tests
    stay, because dark-only is reversible.
- Performance:
  - Scroll content and the coach area have their own repaint layers: about 2–10
    instead of 140–330 render objects repainted per scroll frame.
  - Training week and volume derivations use a time window, about 80× faster at
    2,000 workouts. Recent-workout PRs are memoized per history identity.
  - The workout checkpoint reads history slots read-only, a large cached history
    parses off the UI isolate, and the workout timer notifies once per shown
    second instead of ten times.
- Motion:
  - Tabs fade through: the old tab fades out in 90 ms, the new one fades in over
    40–260 ms with a 10 px directional drift. This is a background-colour
    overlay, not an opacity layer, so the kcal card blur stays valid.
  - The tab-bar pill slides, and a selection click plays on a real change.
  - Values count to their new state over 520 ms, and controls and cards dip
    slightly when pressed.
  - Each tab's sections enter once per session and end together with the
    fade-through. New diary rows grow in.
  - Everything goes through `motionDuration`, so reduced motion is instant, and
    the at-rest captures are pixel-identical.
- Open, deliberately not done:
  - One logged meal round-trips the whole diary twice (the outbox/atomic-commit
    core), the workout checkpoint still decodes the history, and every cold
    start downloads the full history (sync API).
  - The RPC grants `record_training_history` and `delete_training_history` are
    unused by the client; revoking them needs a migration and a deploy.
  - Several sync write methods are only called by tests
    (`MealPlansSync.save/check/convert`, `ProfileSync.save`,
    `LifetimeStatsSync.increment`, …).
  - `BackgroundSyncScheduler.cancel()` is never called. That is harmless,
    because the runner re-checks the persisted session, but it costs an empty
    wake-up after sign-out.
  - The light palette's `arcEnd` on `arcTrack` is 1.77:1 and fails WCAG 1.4.11
    if light mode returns.
  - The blur on docked tabs is unchanged, because the capture tests cannot
    render blur.

## Remaining findings, 2026-10-01

A read-only check against `91ad800` showed that most of the 2026-09-01 auth
backlog was already closed. That includes the outbox replay across accounts,
`same_password`, the AuthScreen classifier, recovery without a password change,
GoTrue 5xx/429 handling and the `delete_account` amr tests. Five agents fixed
what remained, each in its own worktree. Agent reports and the evidence are in
the git-ignored `.agents/remaining-fixes-2026-10-01/reports/`.

- Security:
  - The chat-session RPCs (`rename_chat_session`, `delete_chat_session`,
    `list_chat_sessions`) now have real cross-user Postgres tests.
  - A new static rule requires every definer UPDATE/DELETE to filter on the
    caller.
  - The live drift job checks the Auth config against
    `supabase/auth_config.expected.json`. That covers 17 settings, the
    redirect allow-list and the 13 templates, including the magic-link
    takeover path and the project-wide mail quota.
  - The auth-fail gate answers a token that was rejected twice within 60 s
    before the GoTrue lookup and the DB write (P7-02). The memory is bounded
    and per isolate. A valid token from the same IP is still always checked.
  - A Keychain session that survives an iOS uninstall is discarded on a fresh
    install. An update keeps its session.
  - Reminders and the background-sync request are cancelled on every session
    end.
- Performance and cleanup:
  - Acknowledging a meal no longer decodes the diary (1,000 meals: 29 ms →
    0.7 ms).
  - A cold start loads training history incrementally: a manifest of `id` and
    `finished_at`, then only new rows. At 2,000 workouts that is about 174 kB
    instead of about 21 MB. This relies on history rows never changing after
    insert. A future in-place rewrite must add a revision to the manifest.
  - Sync write methods that only tests called are removed.
  - `record_training_history` and `delete_training_history` lose their
    `authenticated` grant (migration `20261001100000`).
  - The light `arcEnd` reaches 3.21:1.
  - Dependency updates: `flutter_local_notifications` 22.3.0 and `image`
    4.9.1.
- Still open:
  - `package_info_plus` 10 needs a Mac/iOS build check, because it pulls in
    several majors.
  - Meals and weight still load in full (meals have no revision column).
  - `TrainingPlansSync.upsert` is still a direct table write.
  - The legacy RPC grants for older builds stay on purpose (`OFFLINE_SYNC.md`).
  - The Android backup rules let `eatova-cache.sqlite` move to another device
    without its key. The existing recovery clears it after three starts.
  - The drift contract does not pin `external_google_client_id`, SMTP or the
    hooks yet.
- Rollout, completed 2026-10-01 with the user's approval:
  1. The live drift check first found two unused redirect allow-list entries:
     `eatova://login-callback` without the slash, and the project's own
     `/auth/v1/verify` URL. Both were removed and read back. The check now
     matches: 17 settings, 3 allow-list entries, 13 templates.
  2. Migration `20261001100000` is applied and registered (51 = 51).
     `authenticated` has no EXECUTE on the two training-history RPCs, while
     `apply_sync_operation` still works. The handoff records no device
     installation between #77 and #98.
  3. `analyze-meal` v34, `coach-chat` v51 and `search-key` v12 are deployed
     from `581d67a`. Each booted and answered with its own 401/405, so P7-02
     is live.
  4. Open: the client-side fixes reach users with the next device build.
     Check P3-01 on an iPhone: uninstall while signed in, reinstall, and the
     app must show the login screen.

## Design polish, 2026-10-02

The user found that surfaces outside the five redesigned tabs still looked generic.
Seven agents brought them into the dark redesign language, each on its own branch
in `.agents/design-polish-2026-10-02/` (git-ignored: `progress.md` ledger, agent
reports, before/after captures). The orchestrator reviewed every branch visually and
in code, and integrated them by cherry-pick. Behaviour, data flow and store APIs are
unchanged.

- My Profile:
  - The hero card has an avatar ring, goal and routine pills, and streak and record
    as display numbers.
  - Lifetime tiles count up.
  - The plan card shows current → target weight.
  - The weight card has a chart with an area fill and a dashed grid, and goal progress.
  - The body card has a BMI scale.
  - Daily goals sit in one card with bars.
- Settings:
  - The page uses the prominent tab header (`PageHeader(prominent:)`). Goals uses it too.
  - Each group is one card with icon tiles, and values are right-aligned.
  - The account card has an identity row.
  - Sign-out and delete are separated.
  - The plan hero is styled like Today.
  - Number fields are soft capsules with a focus fill.
  - Pickers show the selection.
- Adding a meal:
  - The sheet header is in the display face, and the search capsule matches the
    Food tab.
  - The AI scan is a hero card. Gallery, barcode and manual entry share one card.
  - Favourites, recents and search hits are diary-style rows grouped in one card
    (`SavedMealCollection`).
  - The add action is a soft gram capsule, a slider and one round accent "+" with a
    check confirmation.
  - The favourites sheet was restyled to match.
- Slot choice:
  - One inline segmented control with the `SlotIconTile` glyphs is used in the add,
    barcode, camera, manual and edit sheets.
  - **It supersedes the 2026-09-13 compact row with its separate choice sheet**: one
    tap instead of two. Favourites now start about 80 pt lower.
- Login and sign-up:
  - A soft accent glow sits behind the wordmark.
  - The selected mode is a quiet outlined segment, so only the primary button is
    solid accent.
  - Google uses its real mark, drawn from vector paths.
  - Inputs are borderless capsules with a focus disc.
  - The 8-digit code shows as two groups of four cells.
- Launch:
  - The welcome animation is built from the focus ring only: it holds, makes a
    quarter-turn focus pull while loading, then locks into the wordmark. On a fast
    restore it takes about 620–650 ms from data-ready to home (was 736 ms).
  - The native splash (Android launch background, Android 12+ `values-v31` styles,
    iOS storyboard and LaunchImage, generated by `tool/launch_mark.py`) shows the
    same ring on the same `#09090C` ground, so the colour flash to `forest` is gone.
- Fixes found on the way:
  - Adding from the sheet on a phone with a home indicator raised "Floating SnackBar
    presented off screen". `SnackHost(measureToast: true)` fixes it, with a
    regression test.
  - Sheet grab handles were nearly invisible (1.11:1). They now use `inkDisabled`
    (3.02:1).
- Tests:
  - A read-only audit of about 177 test files kept the old Settings suites, because
    they test behaviour.
  - It deleted 8 vacuous or duplicate cases and rewrote 20 items that had silently
    stopped guarding anything: the streak clock, `Text.rich` macro colours, the
    snackbar tolerance, the code cells, large-text welcome, the expanded settings
    pill and the heart target.
  - Each rewrite was shown to fail against a deliberate regression.
- Open:
  - Device check of a cold start on Android 12+, Android ≤ 11 (3-button navigation)
    and iPhone, for the native-splash hand-off.
  - With reduced motion, the welcome greeting is visible for only one frame. This
    is unchanged behaviour.
  - Dead code:
    - the compact `_SettingsChoicePill` branch, which two tests still pin;
    - unused colour parameters on `SettingsStudioGroup`/`Row`, `SettingsGroup`
      and `MealKcalValue`;
    - the old `AppToggle` look.
  - The analysis sheet and the recipe slot picker still use the old slot icons.
  - The two profile sheets keep their own grab handle.

## Secret scan, design leftovers and calorie review, 2026-10-03

- Device builds: the user installs a build on their own phone after every
  merge. A merged client change is therefore on their device. A delivery note
  no longer needs to list "device build pending". Specific device checks (cold
  start, iPhone reinstall) are asked for separately.
- Secret scan ([PR #124](https://github.com/mxritzgit/Eatova/pull/124),
  `caca16c`):
  - The `security` workflow on main was red after PR #123. gitleaks flagged a
    widget-key comparison in a test as `generic-api-key`. That was the only
    finding in the history.
  - The PR check missed it. `gitleaks-action` lists a PR's commits without
    paging and scans only the first 30. #123 had 45.
  - CI now runs the pinned gitleaks 8.30.1 CLI (checksum checked):
    - PRs: `base..head`;
    - pushes: `before..after`;
    - schedule: all refs.
  - gitleaks exits 0 on a range git cannot resolve, so `rev-list` resolves
    the range first.
  - `.gitleaksignore` allowlists exactly that one historical finding by
    fingerprint.
  - A reviewed false positive goes there. Do not quote matched text in that
    file: it is scanned too.
- Design leftovers of 2026-10-02 (branch `design/redesign-leftovers`; its PR
  records CI and merge). These supersede the "Open" list of the previous
  section, except the device cold-start check.
  - Slot marks: the analysis sheet and the recipe slot picker use
    `SlotIconTile`. The old slot glyphs (`AppSymbol.breakfast…snack`,
    `MealSlotStyle.symbol`, `diarySurface`) are removed.
  - Toggle: `AppToggle` follows `SelectionTone`.
    - ON: a solid `selectedFill` track with an `onSelected` knob.
    - OFF: an ink2@35 % track with a solid ink2 knob.
  - Sheet handle: `SheetHandle(onDismiss:)` carries the screen-reader dismiss
    action. The weight and BMI profile sheets and the weight-adjust sheet use
    it instead of private grabbers.
  - Reminders: on the goals screen, the blocked-reminder note and its "Open
    system settings" button form one group child, with no hairline between.
  - Welcome: the 1 s greeting after a fresh login also holds under reduced
    motion. `motionDelay` is removed.
  - Removed as dead code:
    - the compact `_SettingsChoicePill` branch and `expanded`;
    - `SegmentedPill`;
    - unused colour parameters;
    - `MealKcalValue.unit`/`size`.
  - Still open by choice: collapsed add-sheet rows reveal their add action
    only when expanded. That is the accepted 2026-10-02 design.
- Calorie model review (read-only, decisions pending with the user):
  - Weight logs never update `profile.weightKg`, an int set at onboarding or
    on the goals screen. Live-mode goals, the plan card ("current → target"),
    the forecast, the step kcal and the Coach context therefore stay on that
    weight.
  - The weight and BMI cards already use the latest log, so the profile shows
    two different "current" weights.
  - Measured with the calculator (male, 182 cm, light, −0.5 kg/week), the
    daily goal moves only from 2100 kcal at 84 kg to 2000 at 76 kg. The
    visible error is the forecast and the plan card.
  - The manual-mode misdetection named in `REVIEW-KCAL-2026-08-21.md` §4.1
    is already fixed by the explicit `manualEnergy` flag (PR #54).

### Weight trend, stage 1, 2026-10-03

The user decided the calorie-model questions in the chat:
- the current weight is a smoothed trend;
- a changed daily goal gets a short notice;
- stage 2 is an adaptive weekly check with confirmation.

[WEIGHT-TREND.md](WEIGHT-TREND.md) holds the rules. The branch
`feat/weight-trend` implements stage 1, and its PR records CI and merge.

- The trend:
  - takes the last weigh-in per local day, smoothed 10 %/day and time-aware;
  - holds an outlier (more than 5 % off the trend) until the next day
    confirms it;
  - starts afresh after a break of more than 28 days;
  - counts as the plan weight only while fresh and inside `ProfileLimits`.
- The store re-anchors `profile.weightKg` (live goals recomputed) after a
  weigh-in, a Health import and the boot.
  - The weigh-in and the profile update are one local commit.
  - It needs a server-answered profile AND weight log in this session.
  - A cache re-hydration with different rows closes that gate.
  - The boot re-anchor runs after the cache snapshot.
- The UI shows one current weight: plan card, weight-card trend line and
  progress, BMI. The goals screen shows the weight read-only when a plan
  weight exists.
- Three review rounds found 10 issues, all fixed with tests that fail on
  the previous code: stale-cache writes, typo handling, stale weigh-ins,
  the break, gate closing, and the sync hint versus the notice.
- Verification: 6116 Flutter tests, 96.60 % coverage, strict analysis.
- Stage 2 needs a profile column (migration, column grants,
  `apply_sync_operation`, RLS tests). It is a separate PR, and its live
  migration needs the user's approval.

### Weekly energy check, stage 2, 2026-10-03

Branch `feat/energy-check`; its PR records CI and merge. The user approved
the live migration and any function deploy in the chat. No function reads
the new columns, so none was deployed.

- The check (pure `EnergyCheck`, rules in [WEIGHT-TREND.md](WEIGHT-TREND.md)):
  - window: 21 local days ending yesterday; at least 14 logged days (intake
    of at least 50 % of the goal) and 4 weigh-in days spanning 14 days;
  - observed expenditure = mean intake − weight slope × 7700; modelled =
    maintenance with the current offset + mean step kcal;
  - proposes only above 100 kcal AND two standard errors of the slope
    (noise floor 0.5 kg per weigh-in, so daily weigh-ins need about
    280 kcal); step rounded to 50, capped at ±150, offset at ±500;
  - with a step source, only days with their own step value count.
- Store: a proposal only on data the server answered in this session
  (profile, weight log, the meal window without a row cap) and after the
  window's step values were refreshed once. "Adjust" adds the step to the
  current offset; both answers record `energy_checked_on`.
- UI: a card on Today (Adjust / Not now) and, in live mode, the calibration
  with a reset on the goals screen.
- Data: `profiles.energy_adjustment_kcal` (smallint, ±1000 check) and
  `energy_checked_on` (date), written only through `apply_sync_operation`.
  A payload without the keys keeps the stored values, so older builds do
  not reset them. No client column grants.
- Rollout order: the live migration must precede the client, because
  `ProfileSync.load` selects both columns.
- Live, 2026-10-03, before the merge: `20261003100000` applied and registered
  in one transaction through the Management API (52 registered migrations).
  Read back: both columns with their defaults, the range check,
  `apply_sync_operation` writing both (SECURITY DEFINER,
  `search_path=pg_catalog`, EXECUTE only for `authenticated` and
  `service_role`), no client column grants, existing rows at the defaults.
- Verification before the PR: PostgreSQL 17.6 replay of all migrations plus
  `rls_cross_user.sql`; an independent review (5 findings, all fixed with
  tests that fail on the previous code); strict analysis; 6184 Flutter
  tests, 96.61 % coverage.

### Stuck check status and the PR gate, 2026-10-03

- Symptom: the merge of PR #127 waited about 20 minutes on green CI.
- Cause on GitHub's side: the `Secret scanning (gitleaks)` job finished in
  8 s (conclusion `success`, `completed_at` set, every step completed), but
  its status stayed `in_progress` for good. Its workflow run read
  `completed/success`, and GitHub reported the PR as `clean`. There was no
  incident on githubstatus.com. It was 1 of 694 jobs in the 60 latest runs,
  and nothing in the job could cause it: no API calls, no `checks`
  permission.
- Cause on our side: the session's ad-hoc wait and merge scripts required
  `status == completed` for every check, so they never returned. They also
  polled without a token, and the 60 requests per hour for anonymous calls
  ran out.
- Fix: [`scripts/operations/pr_gate.py`](../scripts/operations/pr_gate.py)
  (`wait`, `merge`) with offline tests in `test/operations/pr_gate_test.py`,
  which CI runs.
  - A check counts as finished by its conclusion; a lagging status is
    named, not waited for.
  - It fails fast on the first red check.
  - It is authenticated, and backs off until the rate-limit reset.
  - `merge` takes only the reviewed head, with every check green and GitHub
    reporting it mergeable.
  - Mutations (status decides, anonymous calls, rate limit as a plain
    retry, ignored mergeability) each fail the tests.
  - Usage: [DEVELOPMENT.md](DEVELOPMENT.md#checks-and-delivery).

## Training flow, Coach /log and dictation, 2026-10-03

Branch `feat/training-flow-coach-log`, one PR for server and app
([#129](https://github.com/mxritzgit/Eatova/pull/129)); its description
holds the review evidence and the decisions taken. Design:
[spec](superpowers/specs/2026-10-03-training-flow-and-coach-log-design.md),
[plan](superpowers/plans/2026-10-03-training-flow-coach-log.md). Player
rules and what they supersede: [TRAINING-DESIGN.md](TRAINING-DESIGN.md#workout-player-list-2026-10-03).

- Workout player: a list of exercise cards with one tap per set (✓; timed
  sets ▶ with a 3 s lead). Weights carry forward within an exercise or come
  from Last time; undo, skip and "complete as planned" sit on the row and
  card menu. Rests and timed sets run on wall-clock deadlines, also while the
  phone is locked, with one generic local alert per phase and keep-awake
  only around timed sets. A finish sheet saves the done sets or logs the
  rest as shown.
- Logging: `HomeStore.logCompletedWorkout` adds a finished workout without
  touching the active session; a plan-attached log is refused while a
  workout is saved. Training offers "Log workout" and "Log as done"; the
  shared log editor writes nothing before Add, and each opening carries one
  history ID through every retry. Today shows "In progress · Resume" while a
  checkpoint exists.
- Coach `/log`: mode `log` in `coach-chat` (mode allowlist, `local_date`,
  strict validator, refusal enum, refunds as for `/plan`, evals E1–E22) and
  `chat_messages.workout_log` (migration `20261004090000`). The card's
  "Add to history" opens the log editor prefilled; its Add is the only
  write. The card reads Added or Removed from the live history.
- Dictation (iOS): the plugin overwrote the transcript with every partial
  result, and iOS restarts its hypothesis after a pause, so only the last
  utterance survived; `stop()` also cancelled the final result. The fix is a
  native accumulator (`SpeechTranscriptAccumulator.swift`, 15 XCTests written
  first against the old overwrite strategy; Swift runs only in the PR's iOS
  workflow), a graceful stop, live partials appended to the
  draft and a DE/EN switch. Mixed German and English in one
  recording stays out of reach of Apple's recognizer (decision D2: no audio
  goes to Eatova's servers or an AI model; Apple may use its servers where
  no on-device model exists).
- Coach fixes: the plan brief no longer drops or wipes a draft and says why
  it cannot open; 429 texts follow the app language (the client sends
  `Accept-Language`); errors, "thinking" and answers reach screen readers; a
  photo survives typing during compression; the plan card lists its first
  exercises.
- Shell wiring (the last step): the Training callbacks, the Coach's save
  adapter and live history, and rest-alert taps (also the launch tap) are
  connected in `eatova_home_page.dart`. One adapter writes for Training and
  the Coach; it re-checks the owner store and flags plan-backed entries
  itself. The local preview offers no logging.
- Delivery order: CI green → apply migration `20261004090000`
  → deploy `coach-chat` from the PR head → verify ACTIVE, boot and a smoke
  request → merge → the owner installs build `1.1.0+4`. Reasons: the app's
  Coach history select reads `workout_log`, so an app without the live
  migration fails every Coach history load; the old function answers `/log`
  with 400. A change to the PR after the deploy needs a redeploy. Rollback:
  the old function is safe; a device rollback drops an in-progress workout
  checkpoint with the new keys.
- Verification for the wiring step (its worktree on Windows, Flutter
  3.47.2, before the parallel minor-fix batch was integrated): strict
  analysis clean; 6678 Flutter tests passed; line coverage of `lib/`
  without generated l10n 96.76 % (computed as `tool/flutter_ci.py` does);
  `deno check coach-chat/index.ts`. The wiring tests
  (`test/flows/training_coach_wiring_flow_test.dart`) fail on the unwired
  shell and on each mutated guard: owner checks, the R15 flag, the tap's
  payload, owner and preview checks, the subscription cancel, the single
  editor, and the Coach and Today selector inputs.
- Open:
  - On-device checks: a minute of dictation (Console, subsystem
    `com.eatova.app`, category `speech`, never a transcript), rest alerts on
    a locked phone and under an iOS Focus (no Time-Sensitive entitlement),
    keep-awake during timed sets, the alert tap and a cold start from it.
  - Website privacy text (separate repository `Desktop/EatovaTest21st`)
    must mention `/log` and the rest alerts, as [PRIVACY.md](../PRIVACY.md)
    now does.
  - The iOS workflow now also requires the dictation XCTest suite
    (`SpeechTranscriptAccumulatorTests`) besides the share tests; earlier
    dated notes that count only the share XCTests describe their own
    checkpoint.
  - The paid real-model `/log` evaluation
    (`coach_eval.ts --live --log --budget-usd=2.60`) has not run; it needs
    an explicitly approved provider budget (`supabase/eval/README.md`).
    Offline, E16, E19 and E22 pass; whether the real model sets the pain flag
    and resists the injection case is unverified.

### Rollout, 2026-10-03

The owner authorised merge, migration and function deploy for after the
work. Final head `36f9844`: 6736 Flutter tests, 96.78 % line coverage of
`lib/` without generated l10n, 922 Deno tests (`deno test --allow-env` as in
CI), and all 17 PR checks green, including the iOS build with the new
XCTests.

1. Migration `20261004090000_chat_message_workout_log` applied live and
   registered in one Management API transaction (53 registered). Read back:
   `chat_messages.workout_log jsonb`, the CHECK as in the repository,
   `is_valid_coach_workout_log` immutable, invoker, `search_path=pg_catalog`,
   EXECUTE only for `authenticated` and `service_role`, a valid and an
   invalid sample judged correctly, no rows with a log yet.
2. `coach-chat` deployed from `36f9844`: version 52, `ACTIVE`,
   `verify_jwt=true`. Boot checks: CORS preflight 204, no auth 401, the
   public anon JWT reached the handler's own 401. No authenticated
   end-to-end request was made.
3. #129 squash-merged as `46f956e`. Main CI on `46f956e`: 16 of 16 green,
   including RLS against PostgreSQL and both live migration drift checks.
4. Device build `1.1.0+4` is the owner's step.

## Weekly volume follows the selected week, 2026-10-03

Owner report after a `/log` workout: the Training card read "0.0 tonnes last
week" although this week's bar had the volume, and "Now" did nothing on tap.
Cause: the card was built to show only the last full week
(`weeks.length - 2`), and the bars carried no tap target. Now the running
week is shown first ("tonnes this week", with "50% of last week so far"
instead of a drop while the week is partial), and each bar selects its
week, with a target over its bar, label and half of each gap. A picked week
is remembered by its start date, so it stays picked across the Monday
rollover and falls back to the running week once it leaves the chart.
`TrainingVolumeTrend.changePercentAt(index)` replaces `lastFullWeek` and
`changePercent`. App-only change, no backend step. Regression tests:
`test/training/training_volume_card_test.dart`. They fail on the old card,
and on five mutations (every bar selected, no tap handler, a lost
selection, the share shown as a drop, a share for an empty week).

Follow-up the same day: the owner's workout (3 × 12 × 25 kg and
3 × 3 × 120 kg, read back read-only from `training_history`) is 1,980 kg,
and the card said "2.0 tonnes". The sum was right; the display in tonnes with
one decimal rounded to 100 kg. The card now shows exact kilograms, grouped
("1,980 kg this week"), with up to two decimals only when the total has any
(weights carry two). The figure above the selected bar shrinks to fit its
column instead of being cut off. `TrainingVolumeWeek.tonnes` is gone. The
design scenario's weeks read 6,798 to 8,625 kg where the reference shot shows
6.8 to 8.6.

## Favorites keep their photo; lively favorites list, 2026-10-03

Owner request: a product hearted from the search showed only its first
letter in the favorites, and the favorites menu should be livelier. Design
approved in chat ("lebendige Liste");
[spec](superpowers/specs/2026-10-03-favorites-photos-and-lively-list-design.md),
[plan](superpowers/plans/2026-10-03-favorites-photos-lively-list.md),
[FAVORITES-DESIGN.md](FAVORITES-DESIGN.md#lively-list-and-product-photos-2026-10-03).

- Cause: the search row knew the photo URL, but the heart passed on only the
  `MealAnalysisResult`, which had no photo field.
- `MealAnalysisResult.imageUrl` comes from the Open Food Facts product
  (search hit and barcode scan) and travels in the existing meal payloads of
  `favorite_meals` and `logged_meals`. No migration, no function deploy.
  Only https addresses on `images.openfoodfacts.org` and
  `static.openfoodfacts.org` are accepted, also when a synced payload is
  read. A read-only scan of 10,200 index products found only
  `https://images.openfoodfacts.org` addresses.
- `FavoriteMeal.keepImage`: a rewrite never drops a stored photo, and an old
  photo-less favorite takes the photo of a hit with the same barcode. Name-keyed
  entries never trade photos.
- Pinned rows: a 48 px photo tile, "Brand · 60 g · 212 kcal", macro dots, the
  heart over a tinted one-tap "+" for the saved portion. After an add the inline
  rows keep their order while the check shows, and the sheet scrolls by the
  height the "already added" list grew, so a second tap adds the same food.
- The favorites sheet sorts by Recent, Frequent (store logs of 35 days) and
  A–Z. `PRIVACY.md` names the image servers.
- A fresh reviewer found 1 medium and 4 low issues: the moving row, the fade
  on fast chip changes, name-keyed photo transfer, and the privacy wording.
  All are fixed with tests. The chips keep the app's 42 px `FilterChipPill`.
- Open: the website privacy text (separate repository) should mention the
  product photos; the device check is the owner's build.

## Old sheets in the dark-redesign language, 2026-10-03

Owner request: the edit-meal sheet (day choice, Save and Delete), the recipe
import ("From your feed"), the "Your recipe" card in recipe creation, and
every other leftover old-design card should follow the current design
system. The add sheet should drop the inline top 3 favorites and keep only
the entry into the favorites menu. Design A–E approved in chat.

- Shared pieces: `SoftPillButton` (accent, neutral, danger; 48 px) and
  `SourcePill` in `lib/src/widgets/design/soft_actions.dart`.
  `showFoodDatePicker` takes `lastDate`, `confirmLabel` and `contextLabel`,
  so the meal plan, the training log and the edit sheet open the same
  calendar sheet.
- Add sheet: one "Favorites · N saved" row opens the favorites sheet.
  `kInlineFavoritesCount` and the inline "+" order hold are gone. The scroll
  anchor after an add stays and is tested on recents. This supersedes the
  inline top 3 of the favorites section above.
- Edit sheet:
  - The Today tab's `TodayDayStrip`, bounded by `firstDate` to the
    calendar's two years.
  - A calendar pill, the `PrimaryActionButton` Save, a danger pill Delete.
  - The app sheet shell, and macro dots in the summary.
  - Its own day picker and `recentDaysDescending` are gone.
- Recipes:
  - Import: a three-step strip, a Paste pill, a source pill, and icon cards
    for portion, ingredients and steps.
  - Create: a fixed-height live preview card and `AppToggle` rows.
  - The batch per-portion result is a card.
  - Recipe tiles read "Carbs" instead of "C".
- Five worktree agents moved the remaining sheets onto the same chips,
  pills, cards and `showEatovaSheet` shell, each with a capture suite under
  `test/design/`. The sheets are meal widgets, manual entry, recipe detail,
  meal plan, recipe history, training editors and history, data export, the
  onboarding review and the scan fallbacks.
- A fresh reviewer found six issues. All are fixed with tests in
  `test/design/soft_controls_test.dart`, `test/recipe_import_sheet_test.dart`
  and `test/edit_meal_sheet_test.dart`:
  - an edit-sheet test that failed on the 15th of a month (it hit the
    calendar header);
  - 42 px chips;
  - disabled chips announced as live buttons;
  - strip paging past the calendar's first date;
  - the source pill not saying whether it was open;
  - a paste that overwrote text typed while the clipboard was read.
- `FilterChipPill` is now 44 px app-wide. This supersedes the 42 px note in
  the favorites section.
- Left as is: the icon placement of `PrimaryActionButton` at 2x text, and the
  manual sheet's "per 100 g" label.
- App-only change, no backend step. Verification on Windows with Flutter
  3.47.2: the analyzer is clean. In the full suite 6,830 tests passed and 2
  failed, both expecting the old 42 px chip or a live chip without `onTap`.
  Their expectations were updated, and their files then passed 103 of 103.
  Local line coverage without the generated l10n is 96.8 %.

## In-depth review with twelve agents, 2026-10-04

Owner request: twelve subagents review Eatova in depth (auth, logic,
functionality), fix what they find, and remove dead code and superfluous
tests; merge after CI. Each reviewer worked in its own worktree on one area:
1. client auth
2. backend security
3. sync and outbox
4. food logging
5. energy and targets
6. scan and search
7. Coach
8. recipes and meal plan
9. training and health
10. app shell, settings and export
11. repo-wide dead code
12. test audit

Every fix came with a regression test shown to fail without it. The
orchestrator read every diff before cherry-picking it onto
`review/indepth-2026-10-04`, resolved four test-file conflicts by keeping
both intents, and added its own fixes where a finding crossed areas.

**Fixed (medium):**
- **Coach:**
  - A connection lost during `/recipe`, `/plan` or `/log` now checks the
    transcript before saying "No connection". A retry no longer buys a
    second daily slot.
  - An auth-stream error replayed to the per-request identity fence
    blocked `/plan` and `/log` for up to an hour. The fence now uses the
    sync stream.
- **Food:**
  - The add sheet mirrored a meal the store had already re-fed. It was
    listed twice, and an X on the copy deleted the real meal.
  - A manual portion that rounded to 0 kcal could not be logged.
- **Sync:**
  - A dead claim lease left no retry armed.
  - A lease lost mid-pass left no retry armed.
  - The orchestrator added a 5-minute clock-correction slack to the
    orphaned-lease bound (`ac0fe11`), so an NTP correction of a second
    cannot release a live lease.
- **Energy:** the weekly check re-reads the ended day's full step total after
  a day rollover.
- **Scan:**
  - Android gallery picks left a full-size GPS-tagged copy in the app cache.
    It is now deleted.
  - Impossible Open Food Facts macros (250 g protein per 100 g) are dropped
    instead of scaled up.
- **Auth:**
  - GoTrue exchanges (sign-in, sign-up, Google, password and email change)
    and the mail requests had no timeout. They now end after 20 s with the
    offline message.
- **Recipes:** an import after a long background period sent an expired
  token and asked the user to sign in again.
- **Shell:**
  - GoTrue 5xx from sync paths now reaches Sentry, throttled to one report
    per 10 minutes.
  - A failed "copy all" export is now shown.

**Fixed (low), with tests:**
- **Coach:** "Send again" at 2x text; the quota refreshes after failures.
- **Sync:** the boot no longer reloads twice after a delivery.
- **Energy and goals:** wrong pace texts.
- **Scan:**
  - bidi and control characters in model labels;
  - confidence case;
  - item fallback 'Zutat';
  - scan retry after an account change;
  - early barcode errors in both the Food tab and the add sheet;
  - unnamed camera controls.
- **Meal plan:** week navigation now covers the editor's window.
- **Recipes:**
  - recipe search on hidden import markers;
  - goal matches on incomplete nutrition;
  - import tile contrast;
  - control characters in the import author;
  - the known-bad-token cache in recipe-import.
- **Training:**
  - the player kept the display on under a sheet;
  - Health Connect still said "install" after installing.
- **Auth:** dismiss race and code-field labels in the account-change sheets.
- **App shell:**
  - localized boot error;
  - emoji avatar initial;
  - double pushes of profile, goals and settings;
  - the quadratic export.

**Removed:**
- **Dead code:**
  - the legacy prefs-plaintext path of `EncryptedKeyValueStore` (`create`,
    `migrateAllLegacySlots`, the probe, the accepting read branch);
    production builds the store only through `migrateDurableCache`;
  - MacroBar, MealAvatar and DotGridBackground;
  - TrainingActualFields, `renameSession`, `RecipeImageStore.deleteFor`, the
    portion-hint plumbing, the export session-snapshot mode, unused sync
    and cache writers, and test-only clamps and serializers.
- **Tests:** 83 Flutter and 9 Deno tests that a named stronger test already
  covers or that could not fail.
- **Fragile tests:** three were fixed: a DST time bomb in the day-load and
  edit tests (red locally in Germany for up to 40 days after the spring
  switch), an order-dependent Supabase wiring test, and a midnight race in
  the lifecycle flow.

**Deployed 2026-10-04 (owner OK):** these went live from `c61c115`, with
`verify_jwt` on. The boot probe got each function's own 401 or 405, with no
BOOT_ERROR.
- search-key v13 (stalled-body classification)
- recipe-import v10 (author filter, known-bad-token cache)
- analyze-meal v35 (label sanitizing, confidence case, item fallback)

No migration is part of this change.

**Report-only, decisions for the owner:**
- **D1, per-account byte budget (medium).** Row caps limit rows, not bytes:
  one confirmed account can store about 13 GB through normal writes. On the
  Free plan, 500 MB puts the whole project into read-only mode. The backend
  reviewer verified a 64 MiB draft migration (PT507) against a local replay:
  [proposal](STORAGE-BUDGET-PROPOSAL-2026-10-04.md). The size is
  the owner's call.
- **R10-04 (medium).** Large exports cannot leave an Android device: copying
  hits the binder limit, and there is no share path. Fixing it needs a share
  plugin, which is a dependency change.
- **R10-09 (medium a11y).** Undo toasts auto-dismiss after 2.6 s even with a
  screen reader on.
- **Smaller decisions:**
  - shopping-list check ids that include grams;
  - 5xx responses that count against the outbox's eight-attempt budget;
  - the classifier `content_filter` that keeps the slot;
  - RPC grants with no client caller (`rename_chat_session`,
    `eat_planned_meal`, ...);
  - the legacy `refund_chat_quota(uuid)`;
  - the PRIVACY.md barcode wording;
  - about 14 legacy `LocalCache` writers used only as test seeding;
  - the default sentinel and probe seams of `CacheKeyProvider.obtain`, which
    production no longer uses.
- **Remaining mixed-clock tests.** The test audit lists the tests that can
  still race midnight by milliseconds.

Verification on Windows with Flutter 3.47.2, final head: the analyzer is
clean; the full suite passed 6,810 of 6,810 with 96.9 % local line coverage
(generated l10n excluded); Deno lint, check and 922 tests are green; the CI
shard plan and tooling tests pass.

## Profile, goals, onboarding and light mode, 2026-10-04

The owner asked for four changes, approved the plan in advance and authorized
the merge after CI:
- bring the profile page and "Profile & Goals" up to the current design;
- rethink and redesign the onboarding;
- explain why the plan card showed 119.1 kg after a 117 kg weigh-in;
- add a complete light mode, using three subagents and doing it last.

Plan: [2026-10-04-profile-onboarding-light-mode](superpowers/plans/2026-10-04-profile-onboarding-light-mode.md).
The work ran in two phases. Workers W1 and W2 ran first, in parallel. L1 ran
next, then L2 and L3 in parallel. Each worked in its own worktree; the
orchestrator read every diff and visual capture before cherry-picking.

- **Weight label (W1).** It was not a calculation bug. Since stage 1 of the
  weight trend, the plan card's left pole shows the smoothed trend, while the
  weight card shows the last weigh-in. The pole is now labelled "Trend", with
  "Last weigh-in 117 kg" under it when the two differ. The goals screen's
  read-only row is "Weight trend" and names the last weigh-in.
  docs/WEIGHT-TREND.md is updated.
- **My Profile and Profile & Goals (W1).**
  - The header matches Settings.
  - Stat tiles and the plan card now use icon tiles and value capsules.
  - The goals groups follow the Settings page style, with 40 px icon tiles and
    calmer footnotes.
  - Duplicated labels are gone ("Reminders" is now "Streak reminder").
  - Sex values are capitalized and localized ("Male", "Männlich").
  - The pickers have glyphs and a level meter.
  - All keys and behaviour are kept.
- **Onboarding (W2).** The decision table is in
  [ONBOARDING-2026-10-04.md](ONBOARDING-2026-10-04.md).
  - **New order:** goal → about you (sex, age) → body (height, weight) →
    activity → target → pace → diet (optional) → plan.
  - **Target and pace** are asked only for lose or gain. That gives 6
    questions for maintain and 8 for lose or gain.
  - **Target default:** an untouched target follows the current weight in the
    goal's direction; the old default made a one-kilo plan.
  - **Plan step:** shows the target BMI hint and the forecast, in the Goals
    hero style.
  - **Code:** the 1,744-line screen is split into lib/src/screens/onboarding/.
  - **Unchanged:** the profile fields, persistence and the calorie rules.
  - **Proof:** 10 old behaviours were put back one at a time, and each turned
    its test red.
- **Light mode.**
  - **L1, foundation:**
    - `kDarkOnly` is gone. The app follows System, Light or Dark (default
      System), and the Settings Appearance row is back.
    - New `AppTokens.light` mirrors every dark role with AA contrast (all
      pairs are checked in `app_tokens_test`).
    - System bars are styled per brightness; this fixes navigation-bar icons
      that would have vanished on a light bar.
    - The stored mode is loaded before `runApp`.
    - The Android launch window follows the OS mode. iOS keeps its dark launch
      screen (an Xcode change is open).
    - `--dart-define=DESIGN_CAPTURE_BRIGHTNESS=light` renders every capture
      suite in light, written to build/light-redesign/.
  - **L2, Today, Food, profile, settings, onboarding, auth:**
    - new tokens `knob`, `knobRing` and `glowStrength`;
    - a white arc and BMI knob with an accent ring;
    - softer violet glows in light;
    - the camera viewfinder stays dark in both modes;
    - trend bars use `progressAccent`;
    - settings captures include the Appearance row, and there is a new trends
      capture suite.
  - **L3, Coach, Recipes, Training:**
    - new token `orbBody`, so the orb stays a lit sphere;
    - the recipe hero bookmark is ink;
    - the dark night-studio photo is toned as a lavender duotone on light
      cards (same asset);
    - new capture suites for Coach cards, the training player and recipe
      lists.
  - **Dark parity:** dark captures stayed pixel-identical, except where a
    change was intended: the Appearance row in the settings shots, and the
    bookmark glyph tone.
- **Orchestrator fix.** The trends chart's goal label now sits on a
  card-coloured pill; bars used to cover it in both modes.

**Open:**
- the iOS light launch screen (needs Xcode);
- the device check of hold-to-repeat and the transitions in the onboarding;
- small light-mode polish candidates L3 listed: the grey "My recipes"
  empty well, grey field capsules on the active set row, and the white
  label on disabled accent pills.

Verification on Windows with Flutter 3.47.2, final head: the analyzer is
clean; the full suite passed 6,911 of 6,911 with 96.96 % local line coverage
(generated l10n excluded); the CI shard plan and tooling tests pass.

## Sentry triage, 2026-10-04

Three unresolved issues in Sentry (org eatova, project flutter) were read in
the owner's Chrome. All came from the owner's iPhone 16 Pro, iOS 27.0.

- **PostgrestException 401, context "Konto-Löschung", 1.1.0 (4).**
  - Stack: `runAccountDeletionCode`, then the `delete_account` RPC.
  - Cause: the RPC runs with the token the recovery code minted a moment
    earlier. This is the fresh-token rejection that `StaleAuthRetry` documents
    for the boot reads: PGRST303 or a bare gateway 401, per the edge logs of
    2026-08-26.
  - Why a retry is safe: a 401 means PostgREST never ran the function.
    `delete_account` refuses on its own only with 28000 (HTTP 403).
  - Effect before the fix: the code was spent, so the user had to request a
    new one.
  - Fix (`auth_session_mutation.dart`): one retry after 1 s on a stale-auth
    rejection only. A second rejection, the 28000 refusal and every other
    error still reach the caller. Tests:
    `test/delete_account_fresh_token_retry_test.dart`.
  - Not checked live: the Supabase logs API moved from `logs.all` to `logs`
    with a new schema and answered with backend errors, so the edge-log
    reading of this event is not done.
- **PlatformException STEPS_ERROR, `health.readSteps`, 1.1.0 (4), 04:24.**
  - What happened: the step query failed 27 ms after the app came to the
    foreground.
  - Why it is a transient: the plugin wraps every HealthKit error in
    STEPS_ERROR and keeps the reason only in the message, which Sentry strips.
    Right after an unlock the protected store is briefly not readable.
  - Fix (`apple_health_service.dart`):
    - Required queries (configure, write grant, steps, day backfill) hold
      their first generic HealthKit error back, wait 1 s and try once more.
    - Only a failure that persists is reported.
    - The optional weight query and non-HealthKit errors report at once.
  - Tests: `test/services/apple_health_transient_error_test.dart`.
- **WatchdogTermination FLUTTER-C.**
  - Events: 2, on 1.1.0 (2) and 1.1.0 (3). The last was 2026-10-01 23:49,
    between the merges of #121 and #122.
  - Cause: the known false positive. Sentry's iOS SDK reports a watchdog kill
    when the previous run ended in the foreground without a crash and the
    release name stayed the same. The pubspec build number stayed the same
    across dozens of merges and device installs (build 3 from 2026-08-29 to
    2026-10-03).
  - Fix: `scripts/operations/device_build.py` builds with `--build-number` =
    the commit count of HEAD (`iphone`, `android`, `ipa`, `apk`,
    `appbundle`), so each
    merged build is its own release. Documented in docs/DEVELOPMENT.md and
    covered by `test/operations/device_build_test.py`. It only helps when
    device builds go through the script.

All three are app-side: no migration, no function deploy. They reach users
with the next device build.

Verification on Windows with Flutter 3.47.2: the analyzer is clean; the full
suite passed 6,920 of 6,920 with 96.96 % local line coverage; the
test/operations suite passed 60 of 60.

Follow-up the same day: `flutter run` accepts no `--build-number` (the first
version of the helper failed with "Could not find an option"). The device
targets now run `flutter build` with the build number followed by
`flutter install`. `iphone` needs macOS; `--dry-run` prints the commands. This
was verified on Windows against the real flutter CLI (dry run, and the build
flags with `--help`).

## Meal plan, shopping list and training brief, 2026-10-04

The owner found the meal plan and the shopping list too generic ("AI slop")
and asked for a simpler, clearer training brief ("Ask Coach" → "Your
training brief"). The work was planned without a confirmation round, at
the owner's request, and the merge after CI was authorized. Plan:
[2026-10-04-mealplan-shopping-brief](superpowers/plans/2026-10-04-mealplan-shopping-brief.md).
Two workers did the work in their own worktrees; the orchestrator reviewed
the dark and light captures and integrated it.

- **Meal plan.**
  - Header: a large page header, and Week / Shopping list as the app's
    segmented control.
  - The week card holds the range, round arrows, a factual summary ("3 meals
    planned · 1 eaten") and a 7-day strip. Each day shows one slot-coloured
    dot per meal; tapping a day scrolls to it.
  - Days are compact sections. Each meal row shows the photo with a slot
    badge, then "Lunch · 1 serving · 723 kcal". The kcal is exactly what the
    eaten toggle logs.
  - The eaten toggle is a tinted disc that becomes a check with "Logged on
    …".
  - An empty day is a dashed "Plan a meal" row, disabled outside the planning
    window.
  - The slogan hero is gone, and the diary rule is a footnote.
- **Shopping list.**
  - Progress (count and bar) sits in the week card.
  - Weighed items are one grouped card with round checks and amount
    capsules. Checked rows dim in place.
  - Free-text recipes are cards with photo, servings and clean ingredient
    lines; the "- " markers are stripped for display only.
  - A designed empty state has "Plan a meal".
  - `ShoppingItem.planId` is new and optional (for the photo); the check ids
    are unchanged.
- **Training brief.**
  - "Plan with Coach", with one lead line and a compact privacy row.
  - The selected plan is a row that expands to the preview. Adapt and
    Discuss are option cards with a consequence line.
  - Goal: quick chips plus "Own goal".
  - Experience and equipment are segmented choices with icons. Sessions and
    minutes are steppers.
  - A pinned bar holds the summary, the action (its label follows the
    intent) and "Uses 1 Coach request".
  - `CoachTrainingContext`, validation, quota and the confirm-before-write
    rule are unchanged.
- **Structure (orchestrator).**
  - The option card, glyph tile and radio moved from the onboarding folder to
    `lib/src/widgets/design/option_card.dart`, shared by onboarding and the
    brief.
  - `meal_plan_screen.dart` (about 1,580 lines after the redesign) is split
    into the `meal_plan_week.dart` and `meal_plan_shopping.dart` parts.
- **Tests.**
  - New: `test/meal_plan/meal_plan_week_view_test.dart` (5 tests) and
    `test/coach_training_brief_test.dart` (16 tests). Each fails against the
    old code.
  - Capture suites cover both modes.

Verification on Windows with Flutter 3.47.2: the analyzer is clean; the full
suite passed 6,944 of 6,944 with 96.99 % local line coverage.

### STEPS_ERROR again, 2026-10-04 evening

Sentry FLUTTER-K, 12 events on 1.1.0 (383), the first build made with
`device_build.py`.
- **What failed:** twelve past days of the energy-check backfill
  (`readStepsOnDay`), one per second, 22 s after a cold start in the
  foreground. The newer days of the 21-day window read fine.
- **Revised diagnosis:** an interval without step samples. HealthKit's
  statistics query reports that as an error, not as a zero sum. This also
  explains the 04:24 event (FLUTTER-H): no steps since midnight. The
  locked-store explanation above did not fit the backfill, and the retry
  wait cost a second per day.
- **Fix in `apple_health_service.dart`:**
  - A generic HealthKit error is reported only when a sample query finds step
    samples in the same interval.
  - Past days get no retry; the backfill keeps the stored value and reads the
    day again next session.
  - Today keeps its one retry.
- **Tests:** `test/services/apple_health_transient_error_test.dart`. The
  twelve-day case failed with 24 queries before the fix.

## Claude Sonnet 5.5 for text and vision AI, 2026-10-08

The owner received free Anthropic API credits and asked to move every AI call
except image generation from OpenRouter/Gemini to the Claude API with
Sonnet 5.5 at effort "high", provided it stays fast enough, plus a review of
the Coach by three Opus 5.5 subagents (parsing, storage, creation). The key is
the Infisical secret `ClaudeAPI` (env `CLAUDEAPI` under `infisical run`).
Branch `feat/claude-sonnet-provider`; the PR records CI and merge state.

- **Provider.** `_shared/claude.ts` holds the Messages API contract (raw
  `fetch`, no SDK: functions stay dependency-free, bodies byte-bounded, own
  deadlines/refunds). Coach (classifier, JSON and SSE answers, `/recipe`,
  `/plan`, `/log`), `analyze-meal` and `recipe-import` use
  `claude-sonnet-5-5` with adaptive thinking, structured outputs for every
  JSON route and the system prompt as a cached prefix. Recipe pictures stay on
  OpenRouter; `OPENROUTER_API_KEY` is now optional (no key = recipe without
  picture). Secrets: `ANTHROPIC_API_KEY` (required), `CLAUDE_MODEL`,
  `COACH_EFFORT`, `COACH_PLAN_EFFORT`, `ANALYZE_MEAL_EFFORT`,
  `RECIPE_IMPORT_EFFORT`. The old `OPENROUTER_MODEL`/`COACH_MODEL_*` secrets
  that production still has are no longer read.
- **Effort, decided from live measurements** (see
  [Backend](BACKEND.md#ai-configuration)): Coach answers, classifier
  (capped at high), recipes and `/log` at `high`; plans, meal scan and recipe
  import at `medium`, because `high` doubled their time (plans hit the token
  cap near the 45 s deadline, the scan took 10-12 s instead of 4-5 s, a
  three-recipe import 20-32 s instead of ~10 s) without better results.
  Effort secrets change behavior without a redeploy.
- **Review findings fixed** (all three Opus reviews reproduced issues with
  probes; the orchestrator verified each live or in tests): a cut emoji (lone
  surrogate) made every request invalid JSON; text-only 4xx were charged to
  the user; a classifier declined by the provider returned a bare 502 (now a
  signposting refusal with the helpline); a truncated classifier charged
  structured modes; 5-7 session plans could not finish (prompt now caps four
  rotated workouts, 4,500 tokens, `medium`); long imports timed out and paid
  for a hopeless retry (one 40 s attempt, no retry after timeout, refusal or
  cut-off); schema-valid `/log` and plan answers the validators rejected
  (stricter schemas); recipe mode with a photo. Measured: the API accepts
  5.1 MB images (the 5 MB fear did not hold) but rejects edges above
  8,000 px, which are now refused before quota.
- **Not changed (low):** an assistant reply above the 16 KB row limit is
  delivered but not stored (needs ~4,000 tokens of multi-byte text); the meal
  explanation can mention an ignored hint; one 14.5 s classifier latency spike
  was observed once (retests 1-2 s; a timeout refunds).
- **Verification:** 970 Deno tests green, also file by file (the CI isolation
  check), lint and all entrypoint checks; eval harness tests 19/19; operations
  tests 66/66; strict Flutter analyzer clean (full Flutter suite: see PR).
  Every new guarantee was shown to fail against its reverted fix. A live end-to-end run of the real handlers
  against Claude (Supabase stubbed) passed chat JSON/SSE, history, photo-only,
  refusals, recipe, 2- and 7-session plans, `/log`, meal scan and import; the
  eval harness was migrated but no paid evaluation was run.
- **Open, needs the owner:** set `ANTHROPIC_API_KEY` as a function secret,
  deploy `coach-chat`, `analyze-meal` and `recipe-import` from the merged
  source, then remove the unused model secrets. Update the published privacy
  policy at eatova.de (Anthropic as recipient) with the rollout. The
  OpenRouter account behind the Infisical dev key had about $0.79 of $5 left
  and answered image requests with 402; production uses a different key whose
  balance was not checked. The app build only changes the Coach disclosure
  text.

### Rollout, 2026-10-08 (owner: "Freigabe für alles")

- [PR #141](https://github.com/mxritzgit/Eatova/pull/141) squash-merged as
  `a0d7bfd` after 17/17 green checks; the merged tree equals the reviewed head.
  The full Flutter suite also passed locally (6,947/6,947).
- `ANTHROPIC_API_KEY` set on the verified project (ref as in earlier
  rollouts, dashboard name "Shiftfit"); its SHA-256 digest matches the
  Infisical `ClaudeAPI` value.
- Deployed from `a0d7bfd` with Supabase CLI 2.120.0 (`--use-api`):
  `coach-chat` v53 -> **v54**, `analyze-meal` v36 -> **v37**,
  `recipe-import` v11 -> **v12**; all ACTIVE with `verify_jwt=true`.
  Boot probe: without a token the gateway answers 401; with the service
  bearer each handler answers its own 401, so all three passed their
  configuration check and see the new key. No authenticated user request
  was made against production.
- Removed the unused secrets `COACH_MODEL_ANSWER`, `COACH_MODEL_CLASSIFIER`
  and `OPENROUTER_MODEL`; `ANTHROPIC_API_KEY` and `OPENROUTER_API_KEY`
  remain, and the probes still pass afterwards.
- Website: the live privacy page is built from `Desktop/EatovaTestCodex`
  (not a Git repository), not from `EatovaTest21st`, whose copy is older than
  the live page. An Anthropic version of that page was prepared but not
  published; publishing it is the remaining step, after which the
  "Pending publication" note in `PRIVACY.md` can go.

## Shopping receipt and TikTok photo posts, 2026-10-10

- **Shopping list as a receipt:** [PR #144](https://github.com/mxritzgit/Eatova/pull/144)
  was squash-merged as `2ddf1e0` after all checks passed, including iOS
  (pubspec changed). Every free-text ingredient line now has its own check.
  Before, a recipe was one check. Line ids are `<week>:<sha256>` of the
  locale-neutral line plus its occurrence. A recipe checked as a whole by
  the old version keeps its lines checked (`shoppingLineChecked`). DM Mono
  (OFL) is bundled for the receipt. There is no schema or sync change: the
  server cap of 2000 checks per account with 35-day retention is unchanged,
  and free-text recipes now use it like weighed ingredients. Locally: full
  suite 6,955/6,955, coverage excluding l10n 97.00%. A test catches each
  reverted guarantee (one line per tap, legacy fallback).
- **TikTok photo posts:** [PR #143](https://github.com/mxritzgit/Eatova/pull/143)
  was squash-merged as `ec240a2`. Share links of slideshow posts redirect to
  `/@user/photo/<id>`, which `supportedTikTokUrl` rejected, so imports ended
  as `needs_text` ("TikTok is not making this caption available"). oEmbed
  answers 400 for `/photo/` URLs, and the photo page carries no caption
  data. The live `/video/<id>` form of the same id returns the full caption
  through both paths. The fix accepts `/photo/` and looks it up through
  `/video/`; video posts send the same requests as before. Deno suite
  976/976. The new tests fail on the old code.
- **recipe-import deploy:** before deploying, the live source of v13
  (redeployed 2026-10-08 23:28, after the rollout entry above recorded v12)
  was downloaded and is byte-identical to `a0d7bfd`. With the owner's
  explicit approval, `recipe-import` was then deployed from main `2ddf1e0`
  with Supabase CLI 2.120.0 (`--use-api`): v13 -> **v14**,
  ACTIVE, `verify_jwt=true`. The downloaded live source equals main byte for
  byte. Boot probe: preflight 204, no token 401 from the gateway, public
  anon key 401 from the handler itself (configuration check passed). No
  authenticated import was run; the owner's photo-post link still needs a
  real import on the device. The receipt needs a new device build.
- **Workflow:** the owner gave standing approval to commit, push, open PRs,
  wait for CI and merge when green. The auto-mode classifier still requires
  the local permission rule `Bash(infisical run:*)` for GitHub token use,
  and an explicit chat line for each merge and each production deploy.

## Feature-gap review with five agents, 2026-10-10

The owner asked for a five-agent review of missing features. See
[FEATURE-REVIEW-2026-10-10.md](FEATURE-REVIEW-2026-10-10.md), based on
`e59f812`. Five read-only agents covered food logging, recipes and planning,
training and health, Coach and insights, and growth and release readiness;
the main session spot-checked the load-bearing claims in code. Strongest
candidates: Sign in with Apple and AI-data consent before a store release;
copying meals, text logging and history search; a weekly check-in, a wider
Coach context and food preferences; exercise records and Health weight with
measurement times. Still open from 2026-09-10: F6, F8 and F9. A short list
of small gaps reads like bugs to users (export file button never shown,
unknown barcode not kept, Health weight stored with import time). This is a
recommendation, not an approved roadmap; only documentation changed.
