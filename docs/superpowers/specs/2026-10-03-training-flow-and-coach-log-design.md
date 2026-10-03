# Training flow, Coach `/log` and dictation — design (v2)

Date: 2026-10-03 · Branch: `feat/training-flow-coach-log` (from main `07b0791`)
v2 folds in four adversarial reviews (gym user, data safety, feasibility,
`/log` contract). Their evidence lists live in the PR description.

## 1. What the owner asked for

- The Training tab's look is fine; its **logic** is not. Running a Coach plan
  means tapping Next → rest timer → Next again, with the phone open next to you
  the whole time. Make the workout experience genuinely good, in the existing
  design language.
- A new Coach command: type or dictate "today I did 20 reps barbell 100 kg" and
  get a **proposal card** that adds an already-completed workout to the history,
  only after the user confirms, exactly like recipes.
- Review the Coach tab for anything that is wrong.
- Dictation: app in English, ~1 minute of mixed German/English, only the last
  ~3 words arrived. Code or model?
- Scope: Training and Coach; real bugs found elsewhere are fixed too.

Assumptions (open to correction): the owner trains with an iPhone; rep-based
strength plans are the main use; calories are not affected.

Success criteria:
1. A 4 × 3 rep workout takes ~1 tap per set (today 2 per set plus re-typing the
   weight every set — ≈35 taps without weights, ≈95 with), and rests keep
   running and alert while the phone is locked.
2. `/log …` turns a spoken or typed description into a card; confirming it puts
   the workout into This week, Recent and History.
3. A minute of dictation keeps all its words, is visible while speaking, and is
   appended to what is already in the field.

## 2. Root causes (evidence in the PR description)

- Player: rep sets need Start then Complete set
  (`training_session_controller.dart:283-294`); typing pauses
  (`training_player_screen.dart:717-720`); weight blank every set (drafts reset
  `:303-304, 332-333`); any non-foreground state pauses, nothing resumes
  (`training_player_screen.dart:151-159, 192-198`); no alert at rest end; no
  rest between exercises.
- History: the only writer (`completeTrainingSession`) requires the player's
  source plan and clears/retires the active session; the insert projection
  wipes any checkpoint (`local_cache_mutations.dart:1412`).
- Dictation: the plugin overwrites the transcript with each partial result
  (`ios/Runner/AppDelegate.swift:304`); iOS restarts the hypothesis after a
  pause, so only the last utterance survives; `stop()` cancels the final result;
  Dart replaces the draft and shows nothing while listening. Mixed
  German/English is beyond any Apple recognizer (one locale each).

## 3. Decisions

| # | Decision | Recommendation | Owner |
|---|---|---|---|
| D1 | Player layout: list (L) or focused hero (F) | **L**, with the gym conditions in A3 | **L** (2026-10-03) |
| D2 | Mixed DE/EN dictation via a server model (audio leaves the device) | **Not now**: fix the bug on-device + visible DE/EN switch | **on-device only** (2026-10-03) |
| D3 | `/log` quota | **1 of the shared daily Coach requests**; manual logging in Training is free | **1 shared slot** (2026-10-03) |
| D4 | Pain mentioned in a log ("knee hurt") | Log it, never copy the symptom, add a fixed "if pain persists, see a doctor/physio" line | default |
| D5 | Lock-screen alert text | Generic, no exercise names or weights | default |
| D6 | Keep the screen awake | Only while a timed interval (or the rest leading into one) runs, and while dictating | default |

## 4. Superseded rules (docs updated in the same PR)

| Old rule (source) | New rule |
|---|---|
| Background/covered routes pause; nothing resumes (TRAINING-DESIGN-2026-09-08.md:150-152, handoff:345-347) | Rest and timed intervals run on wall-clock deadlines; only an explicit pause or process death stops them |
| Pause/resume is the dominant control; Next/Previous visible (TRAINING-DESIGN-2026-09-08.md:146-148) | ✓ per set is dominant; pause, skip and undo live on the row / exercise menu |
| No notifications (handoff:345-349) | One rest/interval alert per phase, generic text |
| Recovery always paused | Recovery continues a still-running rest; a timed interval whose deadline passed during process death waits at zero for ✓ |
| No rest after an exercise's last set (training_session.dart:210-215) | Rest after every completed set except the workout's final set |
| Rep sets need Start (tests) | ✓ completes a rep set directly |

Tests that encode the old rules are rewritten deliberately and renamed
(`training_player_screen_test.dart:227-290`, `training_automatic_flow_test.dart`,
`training_qa/player_lifecycle_test.dart`, `timer_recovery_test.dart`,
`training_session_controller_test.dart:111-150`, `training_session_snapshot_test.dart:82`).

## 5. Part A — workout player

### A1 Interaction and ledger
- **One tap per set.** A rep set completes with ✓. A timed set has ▶ (3 s
  get-ready), counts down, completes at zero, and offers "Done early".
- **Order stays sequential this round** (prefix ledger as today). Only the
  active set's ✓ is enabled; other rows show a visibly disabled ✓. Supersets /
  out-of-order are out of scope.
- **Undo** = uncheck the most recent completed set: rewinds to it, cancels its
  rest and alert, keeps its values as the row draft.
- **Completed rows** stay editable (values only); a recorded pending completion
  freezes all values until Retry resolves (as today).
- **Per exercise** (active only): "Complete remaining as planned" (names the
  count; explicit), "Skip exercise". Per active set: "Skip set". Pause is in
  the header menu.

### A2 Prefill
- Reps: planned reps.
- Weight for set *k*: if the user changed a weight earlier in this exercise
  this session → carry it forward; else "Last time" set *k* (or its last set);
  else empty. Last-time sessions whose weights are all empty are ignored.
- "Last time" = same plan + exercise id; if empty, the newest entry from
  **another** plan with the same normalized name (keeps the existing
  same-plan test). Computed once per player route. PRs stay plan-scoped.
- Prefilled values are styled as unconfirmed until the set's ✓; the Last-time
  cell is tap-to-copy. Never prefill weight for an exercise without weight
  history.

### A3 Layout (Option L)
Same tokens, fonts, dark studio look, borderless soft inputs:
- Header: title, sets done/total, elapsed active time, **Finish**, menu
  (Pause, Discard).
- Exercise cards in order; the active one expanded with rows
  `#  ·  last time  ·  kg  ·  reps  ·  ✓`; completed exercises collapse
  ("3 sets · 10/8/8 · 80–90 kg ✓"); upcoming show the plan; notes expand.
- The active row is dominant: ✓ ≥ 56 dp; it auto-scrolls above the rest bar and
  keyboard on activation and on resume. ✓ commits field values and dismisses
  the keyboard; the list dismisses the keyboard on drag; fields use Done.
- Timed sets show a large countdown inside the active card.
- **Rest bar** pinned at the bottom: mm:ss ≥ 34 pt, −15 s, +15 s, Skip; tap
  expands to a full-screen rest view. ✓ on the next set ends the rest early.

### A4 Time keeps running
- Rest and timed intervals carry `phase_ends_at` (local-only optional
  checkpoint key, UTC `Z`; allowed only in rest or a running timed exercise,
  never with pending completion, never in review; stripped from history, which
  rejects it). Presence means running. `remaining = clamp(ends − now, 0,
  phaseDuration)`; a backwards clock step can no longer break validation.
- Pure `catchUp(now)` applied on resume: a timed interval past its deadline is
  completed at `completed_at = deadline` (the user started it); the following
  rest runs from that deadline; after a rest that ended unseen, a following
  timed interval waits for ▶. At most one unseen completion.
- **Process death** (recovery from checkpoint): a still-running rest continues;
  a timed interval whose deadline passed waits at zero for ✓ (no phantom
  completion).
- Completion times are clamped ≥ start; `finishedAt` ≥ last completion.
- Controller moves from Stopwatch to `package:clock` deadlines; test seams kept.
  `start()` and `completeCurrentSet()` keep their signatures so fixture-only
  tests stay green.

### A5 Alerts
- At phase start (rest start, ▶) one local notification is scheduled for the
  deadline with a deterministic id from the session id; ±15 s reschedules;
  ✓/Skip/Undo/Finish/Discard/sign-out/account switch cancel. Foreground
  presentation = sound only (no banner) plus a haptic from the app; background =
  normal alert. Texts: "Time's up — rest" / "Rest over — next set" (generic).
- New `RestAlertScheduler` interface (Noop default, probed like the existing
  permission probe) through the NotificationService FIFO and its session fence;
  dedicated Android channel; reserved id outside the reminder range. Reminder
  paths (`scheduleAll`, reminders off) cancel only reminder ids; session end and
  the cold-start backstop keep `cancelAll`.
- Permission: one in-context explainer + system prompt at the first workout if
  never asked (device flag); if alerts are off, a quiet "Alerts off" chip in the
  rest bar links to settings. Not tied to the reminder toggle.
- Tapping the alert opens Training and the active set (after the owner check).
  Today shows "In progress · Resume" while a checkpoint exists.
- Honest limits: Android alerts can be late (inexact scheduling by policy);
  an iOS Focus can silence them (no Time-Sensitive entitlement this round).

### A6 Keep awake (D6)
Small `eatova/screen` channel (`UIApplication.isIdleTimerDisabled` /
`FLAG_KEEP_SCREEN_ON`, no package, no permission): on while a timed interval or
the rest leading into one runs with the player on top, and while dictating; off
on pause, finish, pop and background.

### A7 Finishing
- Finish at any time; after the last set the finish sheet opens itself:
  summary, note, **Save workout**.
- With open sets: primary "Save N sets (skip the rest)", secondary "I did the
  rest — log as shown", "Keep training". With 0 completed sets only "Discard"
  and "Keep training".
- Time: `startedAt` = first ✓ or ▶; if Save comes > 5 min after the last
  completion, `finishedAt` = last completion.
- Plan edited/deleted while the player is **open**: Finish still saves the
  workout with its frozen plan copy (completion drops only the source fences;
  account checks, receipt repair, protected-recovery and pending-equality stay;
  publish clears the session only if its id matches). The save indicator is
  truthful ("not stored" when a checkpoint write was refused). A kill after a
  plan edit still loses the checkpoint (unchanged, rare, stated).
- Field edits push into the controller immediately; the durable write is
  debounced (≈600 ms) and flushed on any lifecycle change, cover, terminal
  intent and dispose. The 5 s timer goes away.
- Announcements via `SemanticsService.sendAnnouncement` / live regions for set
  done, rest start, rest over.

## 6. Part B — logging a finished workout

- **Store** `logCompletedWorkout(entry, {planAttached})` in this order:
  serialize → ensure session active → repair deletion receipts → deleted id ⇒
  `TrainingCompletionDeleted` → already present ⇒ delivered/queued (no write) →
  2000 cap → `fromRow(toRow())` → commit `trainingHistoryInsert` (publish never
  touches the active session or source generations). Plan-attached logs are
  rejected while a session/recovery exists (one session at a time) and need ≥ 1
  completed set.
- **Cache:** the insert projection clears the checkpoint only when its
  `session_id` equals the entry id (red-before/green-after test).
- **History model** rejects non-null drafts, non-lowercase ids and
  `phase_ends_at` (Dart now mirrors the SQL CHECK; parity fixtures).
- **Free logs:** plan id `log_<historyId>`; exercise id `n_` + 32 hex of
  sha256(normalized name), `_k` for the k-th repeat; prescription reps =
  clamp(max actual, 1, 100), actuals unchanged; timed > 1 h split
  deterministically (k = ⌈d/3600⌉).
- **Times:** today → `finishedAt = now`; past day → that local date at the
  current local time of day (≤ now). `startedAt = finishedAt − duration`, or
  equal (= "no duration": history hides duration and "recorded from"). Every
  `completed_at = finishedAt`.
- **Log editor sheet** (shared with Coach): date chips Today / Yesterday /
  pick (≤ 30 days, never future), optional duration, exercises with sets (reps,
  kg) or timed (duration), add/remove, note. Exercise names autocomplete from
  known exercises (prefilling Last time); "Add set" copies the previous set.
  Plan-attached mode: structure fixed, sets toggle done/skipped, values prefilled
  by A2. The id is allocated once when the editor opens; Add is single-flight.
- **Training root:** "Log workout" replaces the duplicate "Create plan" tile;
  the next-workout card gets "Log as done" (hidden while a session exists —
  Resume instead); after a workout today the card shows "Done today: X" and
  offers the next workout (Today tab keeps showing the done one — split
  `doneToday` and `next` semantics); history load failure is shown; delete and
  empty copy fixed for logs.

## 7. Part C — Coach `/log`

### C1 Client
- `/log` in a command registry (menu, hero chip, unknown-command hint). Typed or
  dictated. Photo + `/log` and empty `/log` are handled locally (no request).
- Request `{message, mode:"log", local_date, locale, session_id}`; client sends
  `Accept-Language` on every Coach request.
- `ChatMessage.workoutLogProposal`; `fromRow` keeps a proposal only if exactly
  one of recipe / training_plan / workout_log is set; history select adds
  `workout_log` (after the migration is live); `_hydrateProposalImages` and
  `_sameCompletedAnswer` handle it.
- **Card:** "Workout · draft", title, resolved date, one line per exercise,
  "Only <day> was taken" hint when other days were omitted. **Add to history**
  opens the review sheet (log editor, prefilled, editable); its **Add** is the
  confirmation. Required gaps (reps, duration, date) must be filled first.
- **State** derived: history id = `deriveCoachWorkoutLogId(messageId)` (XOR with
  ASCII `eatova-workoutlg`, lowercase, golden vector) for server ids; for a
  local-only message a uuid is allocated once and kept on the message. Present
  in history → "Added ✓ · Open training" (no second edit); deleted (local
  receipt or `entity_deleted`) → "Removed from history"; history not
  authoritative → neutral disabled state. The Coach selector includes history,
  deleted ids and load state. Lock taken before the sheet opens; draft identity
  re-checked before and after the write.

### C2 Server (`coach-chat`)
- Dispatch: explicit `mode` wins; text command parsing only when mode is absent;
  allowlist {absent, chat, recipe, plan, log}, else 400 `invalid_mode`;
  `log` + image / training_context / user_context → 400; `local_date` required
  for log, forbidden otherwise, real date within server UTC ±1 day; empty wish →
  400. All before session/quota.
- Flow: prefilter → claim slot (D3) → classifier (log refuses self_harm,
  eating_disorder, injection; medical_risk handled per D4; unusable output →
  refusal, no extraction; slang examples in the shared prompt) → extraction
  (MODEL_ANSWER default, temperature 0, JSON, low excluded reasoning,
  require_parameters, max_tokens 4096, 45 s, 512 KiB, accept only
  `finish_reason: stop`) → server transform (performed_on window, lb → kg,
  round to 0.01) → strict validator → store user + assistant rows → buffered
  JSON. Refusals use a reason enum mapped to fixed localized texts.
- Refunds as for `/plan`: outage, invalid draft, store failure refund once;
  refusals keep the slot. Budget op reuses `coach_plan` (no change to
  `reserve_ai_provider_call`).
- Diagnostics: status, lengths, digests only; never workout text.
- Chat answers follow the app language for mixed input and suggest `/log` when
  someone reports a completed workout.

### C3 Wire / stored schema v1 (`chat_messages.workout_log`)
```
{ schema_version: 1, title: 1..120, performed_on: "YYYY-MM-DD"|null,
  duration_minutes: 1..600|null, other_days_omitted: bool, note: 0..500,
  exercises: [1..20] { name: 1..120, kind: "reps"|"timed",
    duration_seconds: 5..36000|null,       // null for reps; timed null = not said
    sets: [1..10] { reps: 0..1000|null,    // null when timed; reps null = not said
                    weight_kg: 0..2000 (≤ 2 decimals)|null } } }
```
Exact keys; timed: `len(sets)·⌈d/3600⌉ ≤ 10`; text rules as TrainingJson, ≤ 6000
code points, ≤ 32 KiB. SQL `is_valid_coach_workout_log` (immutable, format only,
no `now()`) + CHECK (assistant, not refusal, no recipe/plan in the same row).
One shared fixture file drives TS, Dart and SQL tests. The extraction prompt
rules and 22 eval cases are in the PR (`supabase/eval/coach_cases.ts`).

## 8. Part D — dictation (iOS)

1. Native accumulator: a new utterance starts when segment metadata says so
   (`speechRecognitionMetadata`, first-segment timestamp moves forward, segment
   count collapses); text compared case/punctuation-folded. XCTest with the
   reset trace, punctuation revisions and duplicate finals; first pushed against
   an overwrite strategy for a red run.
2. Graceful stop (end audio, ≤ 1.5 s for the final) vs immediate cancel
   (lifecycle, dispose).
3. Partials stream into the field (`{token, text}`); field read-only while
   listening; stale tokens dropped.
4. Append to the existing draft (keeps `/log `).
5. Language pill next to the mic while listening (tap = switch DE/EN, restarts
   only the current dictation); default app language; remembered per device;
   VoiceOver action.
6. Punctuation, dictation task hint, gym vocabulary.
7. Apple's server path ends at ~1 min: text kept + hint; stop at the 1000-char
   limit with a hint.
8. Send while listening stops dictation and leaves the final text in the field
   (a second tap sends — never sends unseen text). Stop is never blocked by a
   running request. Tab switch / background keep the text so far; dispose and
   account change discard it. Screen stays awake while listening (A6).
9. No transcript in any log (native or Dart).

## 9. Part E — further Coach fixes

Brief no longer dropped while a request runs and no longer wipes a draft; it
does not open when nothing can be sent (reason shown). English users no longer
get German rate-limit texts. Errors, "thinking" and answers are announced to
screen readers; recipe "added" is a live region; session delete target ≥ 48 dp.
Sessions sheet keeps its list after a failed history load; failed "New
conversation" shows a message. A photo is not dropped when typing during
compression. Recipe add takes its lock before the sheet. The plan card lists
its first exercises.

## 10. Delivery

> Ruling R23 merged both PRs into one; its delivery order is in the
> [handoff](../../PROJECT_HANDOFF.md#training-flow-coach-log-and-dictation-2026-10-03).

- **PR 1 — server:** migration + `coach-chat` log mode, mode allowlist, locale
  fix, evals. After green CI and the owner's approval: apply the migration
  (after the energy-check migration 20261003100000, which is on the unmerged
  `feat/energy-check`; timestamp ours later), deploy `coach-chat`, verify ACTIVE
  + boot + smoke. Merge.
- **PR 2 — app:** Training (A, B), Coach client (C1, E), dictation (D, incl.
  Swift + XCTest, iOS workflow green). Merge after PR 1 is live; then device
  build (build number bumped).
- Docs in the PRs: TRAINING-DESIGN (supersedes), FEATURES, BACKEND, PRIVACY
  (workout text in `chat_messages`, sent to the AI provider), handoff, CHANGELOG.
- Rollback: redeploying the old function is safe (`/log` → 400). A device
  rollback discards an in-progress workout checkpoint with new keys.

## 11. Not in this round

Android dictation, Live Activities / lock-screen controls, Time-Sensitive
alerts, supersets/out-of-order sets, Apple Health write-back, per-set actual
duration or distance (history schema), editing saved history entries,
server-side multilingual transcription (unless D2 says otherwise), "Adapt
plan" replacing instead of duplicating.
