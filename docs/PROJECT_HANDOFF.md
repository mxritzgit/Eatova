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
2. **Remaining auth-review findings:** Claude's 2026-09-01 review lists outbox
   replay across account changes, a consumed password-change nonce after
   `same_password`, GoTrue 5xx/429 misclassified as invalid authentication,
   auth-failure gate amplification, inconsistent AuthScreen error handling,
   leaving password recovery without changing the password, missing Postgres
   checks for reauthentication/session ownership, and missing live auth-config
   drift checks. Treat these as an inherited backlog requiring targeted
   reproduction, not as newly proven findings or a reliable numeric count.
   Spot reads still show the relevant replay loop, password-change error path,
   and Coach non-OK auth-response classification. Timeout handling already has
   a distinct outage path; do not conflate timeout fixes with HTTP 5xx/429 handling.
3. **Release/website follow-ups:** older notes mention real-device Google login,
   privacy text synchronization, and store/legal-page finishing work. These need
   current verification before being scheduled. The marketing site is a separate
   repository (`Desktop/EatovaTest21st` per Claude), not this Flutter repository.

## Decisions and useful constraints

- Preserve the selected calorie model unless asked to revisit it. Its rationale
  is in `docs/REVIEW-KCAL-2026-08-21.md` and Claude's calorie-review note.
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
