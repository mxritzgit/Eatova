# Eatova project handoff

Snapshot: 2026-09-06. This is a context handoff from Claude Code to Codex, not a
new security clearance or a full test run. Existing documentation remains shared.

## Current position

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
- The classifier staying on grok-4.3 was a user decision in the performance run.
  Streaming does not eliminate the preceding classifier's latency.
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
