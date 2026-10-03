# Training flow, Coach `/log` and dictation — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One-tap, lock-proof workouts; logging finished workouts (Training tab
and Coach `/log` with explicit confirmation); dictation that keeps every word.

**Architecture:** Pure models first (snapshot deadline key, log builders, wire
model), then store/cache (non-destructive history insert), then UI (list
player, log editor, Coach card). Server mode `log` ships separately (PR 1) and
goes live before the app (PR 2). Native iOS speech is rewritten around a pure,
XCTest-covered accumulator.

**Tech Stack:** Flutter 3.47.2 / Dart 3.13.2, Supabase Edge Functions (Deno),
Postgres migrations, Swift (iOS runner), flutter_local_notifications.

**Spec:** `docs/superpowers/specs/2026-10-03-training-flow-and-coach-log-design.md`
(read it first; section numbers below refer to it).

## Global Constraints

- Flutter `C:/Users/morit/Desktop/Flutter/flutter/bin/flutter.bat` (3.47.2), never another SDK; no `pubspec.lock` changes; **no new packages** (`package:clock`, `crypto`, `flutter_local_notifications`, `shared_preferences` are already dependencies — verify with `grep` in `pubspec.yaml` before use).
- `flutter analyze --no-pub --fatal-infos --fatal-warnings` must be clean; coverage floor 88 %.
- Localized UI only via `lib/l10n/app_de.arb` **and** `app_en.arb` (same keys), then `flutter gen-l10n`. Add keys **next to your domain's existing keys** (anchors below), never at the end of the file. No German literals in `lib/src/screens/coach/**`.
- Comments concise English; existing German test names are fine. No `dart format` on whole existing files (format only lines you touch).
- Inputs: borderless soft fills, focus = fill change, no hairline borders/focus rings (owner preference); keep accessible focus.
- Never log transcripts, workout text, tokens, or user data (os_log, print, Sentry, Edge logs).
- Coach proposals never write user data before the user's explicit confirmation.
- Account isolation: every async write path re-checks the owner store/session as the existing code does (`_isStoreSessionCurrent`, `_ensureTrainingSessionActive`, `isCurrentDraft`).
- Tests: freeze time (`withClock`, `TimerTestClock`, `fake_async`), dummy defines, stub all network; demonstrate red-before/green-after for every critical guarantee marked **(R/G)**.
- Do not touch the root checkout `C:/Users/morit/Desktop/Bridgespace/Projects/Eatova` (another session works there). Work only in your assigned worktree.

## Review Focus

1. Phone locked for longer than the rest, then unlocked → the next set is active, the rest is not frozen, exactly one alert fired. (Task A1 `rest_survives_background_test`.)
2. A checkpoint written in a new shape (rest between exercises, `phase_ends_at`) survives a foreign history insert and app restart. (Tasks M1 + B1, **R/G**.)
3. Confirming the same Coach card twice / on a second device / after deleting the entry never creates two rows and never resurrects a deleted one. (Task C2 flow tests.)
4. A one-minute dictation with pauses arrives complete; stopping keeps the last words; a typed `/log ` prefix survives. (Tasks D1 XCTest **R/G**, D2 widget tests.)
5. English UI with German speech/text: `/log` card texts and chat answers are in English; rate-limit and error texts are English. (Tasks S1 evals, C3.)

---

## Shared contracts (all packages code against these exact names)

### Models (Task M1–M3)
```dart
// lib/src/models/training_session.dart
//   TrainingSessionSnapshot gains: final DateTime? phaseEndsAt;  // JSON 'phase_ends_at', UTC, optional
//   valid only when phase == rest, or phase == exercise && current exercise isTimed;
//   forbidden with pendingCompletionAt; forbidden in review.
//   Rest is valid after any completed set except the final set of the final exercise.

// lib/src/models/training_history.dart
//   TrainingHistoryEntry(...) additionally throws FormatException when:
//   draft reps/weight non-null, sessionId not lowercase UUID, snapshot.phaseEndsAt != null.
final class TrainingLogBlockedBySession implements Exception { const TrainingLogBlockedBySession(); }
List<TrainingSetActual> lastTrainingPerformanceByName(
  List<TrainingHistoryEntry> history, {
  required String excludePlanId,
  required String exerciseName,
  required bool isTimed,
});

// lib/src/models/training_log.dart (new)
String normalizeExerciseName(String name);            // trim, collapse whitespace, lowercase
String trainingLogExerciseId(String name, int occurrence); // 'n_' + sha256(normalized)[0..32) + (occurrence > 1 ? '_$occurrence' : '')
const String trainingLogPlanPrefix = 'log_';
bool isLoggedTrainingEntry(TrainingHistoryEntry entry);  // plan id starts with 'log_'
bool trainingEntryHasDuration(TrainingHistoryEntry entry); // startedAt != finishedAt
final class LoggedSet { const LoggedSet({this.reps, this.weightKg}); final int? reps; final double? weightKg; }
final class LoggedExercise {
  const LoggedExercise({required this.name, required this.timed, this.durationSeconds, required this.sets});
  final String name; final bool timed; final int? durationSeconds; final List<LoggedSet> sets;
}
final class LoggedWorkoutDraft {
  const LoggedWorkoutDraft({required this.title, this.performedOn, this.durationMinutes, this.note = '', this.otherDaysOmitted = false, required this.exercises});
  final String title; final DateTime? performedOn; // local calendar day (y,m,d), time ignored
  final int? durationMinutes; final String note; final bool otherDaysOmitted; final List<LoggedExercise> exercises;
}
enum LoggedWorkoutProblem { empty, missingDate, dateOutOfRange, missingReps, missingDuration, tooLarge }
List<LoggedWorkoutProblem> validateLoggedWorkout(LoggedWorkoutDraft draft, {required DateTime now});
({DateTime startedAt, DateTime finishedAt}) loggedWorkoutTimes({required DateTime performedOn, int? durationMinutes, required DateTime now});
TrainingHistoryEntry buildLoggedWorkout({required String historyId, required LoggedWorkoutDraft draft, required DateTime now, required String fallbackTitle});
final class PlanAttachedSet { const PlanAttachedSet({required this.done, this.reps, this.weightKg}); final bool done; final int? reps; final double? weightKg; }
TrainingHistoryEntry buildPlanAttachedLog({required String historyId, required TrainingPlan plan, required int workoutIndex,
  required List<List<PlanAttachedSet>> sets, required DateTime performedOn, int? durationMinutes, String note = '', required DateTime now});

// lib/src/models/coach_workout_log.dart (new) — wire/stored schema v1 (spec C3)
enum CoachWorkoutLogKind { reps, timed }
final class CoachWorkoutLogSet { final int? reps; final double? weightKg; }
final class CoachWorkoutLogExercise { final String name; final CoachWorkoutLogKind kind; final int? durationSeconds; final List<CoachWorkoutLogSet> sets; }
final class CoachWorkoutLog {
  final String title; final String? performedOn; // 'YYYY-MM-DD'
  final int? durationMinutes; final bool otherDaysOmitted; final String note; final List<CoachWorkoutLogExercise> exercises;
  static CoachWorkoutLog? fromJson(Map<dynamic, dynamic> json); // null on ANY violation, format-only date check
  Map<String, dynamic> toJson();
  LoggedWorkoutDraft toDraft();
}

// lib/src/services/uuid.dart
String? deriveCoachWorkoutLogId(String messageId); // XOR with ASCII 'eatova-workoutlg', lowercase; null unless isUuidShape
```

### Store (Task B1)
```dart
// HomeStore (lib/src/app/home_store_training_history.dart / home_store.dart)
Future<SyncDelivery> logCompletedWorkout(TrainingHistoryEntry entry, {bool planAttached = false});
  // throws TrainingCompletionDeleted, TrainingLogBlockedBySession (planAttached && a session/recovery exists),
  // StateError on cap / account change. Never clears/retires the active session or plan sources.
Set<String> get trainingHistoryDeletedIds;      // unmodifiable
bool get trainingHistoryAuthoritative;          // known, not loading, not failed, receipts readable
Future<bool> saveTrainingSession(...same params as today...); // true only when the checkpoint was stored
// completeTrainingSession: keeps account checks, receipt repair, protected-recovery and pending-equality;
// drops source/generation fences; publish clears _trainingSession only if its sessionId == entry.id.
```

### Alerts and screen (Tasks A2, D1)
```dart
// lib/src/services/rest_alerts.dart (new)
abstract class RestAlertScheduler {
  Future<void> scheduleRestAlert({required int id, required DateTime at, required String title, required String body});
  Future<void> cancelRestAlert(int id);
}
final class NoopRestAlertScheduler implements RestAlertScheduler { const NoopRestAlertScheduler(); ... }
int restAlertIdForSession(String sessionId); // deterministic, in reserved range [2000000000, 2000999999], outside nudge ids
enum RestAlertPermission { granted, notAsked, denied }
abstract class RestAlertPermissionGate { Future<RestAlertPermission> state(); Future<bool> request(); }
const String trainingRestNotificationPayload = 'training-rest';
abstract class NotificationTapSource { Stream<String> get taps; Future<String?> launchPayload(); }

// lib/src/services/screen_awake.dart (new) — channel 'eatova/screen', method 'setKeepAwake', args {'on': bool}
abstract class ScreenAwake { Future<void> setKeepAwake(bool on); }
final class MethodChannelScreenAwake implements ScreenAwake { const MethodChannelScreenAwake(); }
final class NoopScreenAwake implements ScreenAwake { const NoopScreenAwake(); }
```

### Dictation channel `eatova/speech` (Tasks D1 native, D2 Dart)
- `listen` args `{localeId: String, token: int}` → success value `{text: String, reason: 'stop'|'final'|'limit'|'length'|'cancel'}`; errors keep today's codes (`permission_denied`, `unavailable`, `busy`, `recognition_failed`).
- Native → Dart `invokeMethod('partial', {token: int, text: String})` (accumulated text so far, only when changed).
- `stop` = graceful (end audio, ≤ 1.5 s for the final, then complete `listen` with reason `stop`/`final`); `cancel` = immediate (complete with reason `cancel`).
- Dart API (fakes keep compiling — all new params optional):
```dart
Future<String?> listen({String localeId = 'de_DE', required AppLocalizations l10n,
  int token = 0, ValueChanged<String>? onPartial, ValueChanged<CoachSpeechEnd>? onEnd});
Future<void> stop();   // graceful
Future<void> cancel(); // immediate
enum CoachSpeechEnd { stopped, limit, length }
```

### Server `/log` (Task S1) — spec C2/C3 exactly
Request `{message, mode:"log", local_date, locale, session_id}`; success
`{reply, workout_log, remaining?, daily_limit, session_id, assistant_message_id?}`;
refusal `{reply, refusal:true, refusal_reason, remaining?, daily_limit, session_id}`.
Shared fixture `supabase/functions/coach-chat/fixtures/workout_log_cases.json`
(`{"valid":[...], "invalid":[{"reason":..., "value":...}]}`) used by TS, SQL and Dart tests.

### Log editor (Task L1) and Coach screen params (Task C2)
```dart
// lib/src/screens/training/training_log_editor.dart (new)
sealed class TrainingLogEditorRequest { const TrainingLogEditorRequest({required this.historyId}); final String historyId; }
final class FreeLogRequest extends TrainingLogEditorRequest { const FreeLogRequest({required super.historyId, this.initial, this.fromCoach = false}); final LoggedWorkoutDraft? initial; final bool fromCoach; }
final class PlanAttachedLogRequest extends TrainingLogEditorRequest { const PlanAttachedLogRequest({required super.historyId, required this.plan, required this.workoutIndex}); final TrainingPlan plan; final int workoutIndex; }
enum TrainingLogSaveOutcome { saved, queued, queuedOffline, deleted, blocked, failed }
Future<TrainingLogSaveOutcome?> showTrainingLogEditor(BuildContext context, {
  required TrainingLogEditorRequest request,
  required Future<TrainingLogSaveOutcome> Function(TrainingHistoryEntry entry) onSave,
  List<TrainingHistoryEntry> history = const [], // for name autocomplete + Last time
});
// CoachChatScreen new params
final Future<TrainingLogSaveOutcome> Function(TrainingHistoryEntry entry)? onLogWorkout;
final Set<String> trainingHistoryIds; final Set<String> trainingHistoryDeletedIds;
final bool trainingHistoryAuthoritative; final List<TrainingHistoryEntry> trainingHistory;
final int logDraftRequest; // bump -> composer prefilled with '/log ' and focused (like planDraftRequest)
```

### ARB anchors
A1: after the last `trainingTimer*` key · A2: next to `notification*` keys ·
L1: after `trainingHistory*` keys · I1: after `trainingWeek*` keys ·
C2/C3: after `coachPlan*` keys (prefix `coachWorkoutLog*`, never `coachLog*`) ·
D2: after `coachSpeech*` keys (prefix `coachDictation*`).

---

## Execution topology

Each task runs in its own worktree `…/main/.agents/wp-<task>` on branch
`wp/<task>` created from the integration branch at phase start; the integrator
cherry-picks finished commits into `feat/training-flow-coach-log`
(PR 2) — except S1, which goes to `feat/coach-log-server` from `main` (PR 1).

| Phase | Tasks (parallel) | Needs |
|---|---|---|
| 1 | S1, M1, A2, D1 | — |
| 2 | I1, B1, D2 | M1 (I1, B1), A2 (D2) |
| 3 | A1, L1 | M1, I1, B1, A2 |
| 4 | C2 (+C3) | M1, B1, L1, D2, S1 contract |
| 5 | W1 (integrator) | all |

Per task: implement with TDD → fresh reviewer (spec + plan + diff) → fixer →
focused tests + analyzer green → commit. Full suite once per phase on the
integration branch.

---

### Task S1: Server — `/log` mode, migration, allowlist, locale (PR 1)

**Files:**
- Create: `supabase/functions/coach-chat/workout_log.ts`, `workout_log_test.ts`, `handler_workout_log_test.ts`, `fixtures/workout_log_cases.json`, `supabase/migrations/20261004090000_chat_message_workout_log.sql`, `test/migrations/coach_workout_log_rls.sql`
- Modify: `supabase/functions/coach-chat/handler.ts` (REQUEST_FIELDS ≈2258, mode dispatch ≈2427-2440, classifier ≈2578-2617, branch after plan ≈2647, answer prompt ≈248-251), `guardrails.ts`, mode loops in `handler_test.ts`, `handler_boundary_test.ts`, `handler_stream_test.ts`, `training_qa_integration_test.ts`, `_shared/request_fields_test.ts` (if present), `supabase/eval/coach_cases.ts` (+ runner expectations), `test/migrations/rls_cross_user.sql` (`\ir` new file), `test/migrations/rls_invariants_test.dart`, `supabase/SCHEMA_STATE.md` (regenerate), `docs/BACKEND.md`
- Test: Deno per file; `flutter test test/migrations/` (needs local Postgres only in CI — run the Dart parts that don't need it)

**Interfaces:** Produces the wire contract above and the fixture file.

- [ ] **Step 1: Fixture + pure module tests first.** Write `fixtures/workout_log_cases.json` with ≥ 12 valid logs (E1–E21 shapes from spec/PR, after server transform) and ≥ 20 invalid ones, each with a `reason` (extra key, missing key, title blank, 21 exercises, 11 sets, reps 1001, weight 2000.001, weight 102.055 (3 decimals), timed with reps, reps exercise with duration, timed 3 sets × 7200 s (exceeds build cap), bad date `2026-02-30`, control char in name, lone surrogate, total text > 6000, `schema_version` 2). Write `workout_log_test.ts`: `parseWorkoutLog` accepts every valid, rejects every invalid; `parseWorkoutLogCommand` (`/log x` → `x`, `/LOG` → `''`, `/logbook` → null); `transformExtraction` (lb → kg `225 lb` → `102.06`; `performed_on` outside `[local_date-30, local_date]` → null; refusal enum mapping); `workoutLogSummary` DE/EN; prompt contains locale + calendar.
- [ ] **Step 2: Run** `cd supabase/functions && deno test --allow-env coach-chat/workout_log_test.ts` → FAIL (module missing).
- [ ] **Step 3: Implement `workout_log.ts`** (pure: no fetch/env): exact-key validator mirroring spec C3 (`Number(x.toFixed(2)) === x`, code-point counts, TrainingJson text rules incl. no C0 except `\t\n\r`), extraction schema per PR contract (`status`, `refuse_reason`, `workout{..., weight_unit}`), `transformExtraction(raw, localDate)`, system prompt with the 19 rules from the PR description and a server-built 8-day calendar (`today = local_date (weekday)`, previous 7 days).
- [ ] **Step 4: Run** the test → PASS.
- [ ] **Step 5: Handler tests first** (`handler_workout_log_test.ts`, clone the `handler_plan_test.ts` harness): one slot claimed before classifier; buffered JSON even with SSE Accept; no history GET; persisted assistant row has exactly `{session_id, role:'assistant', content: summary, workout_log}`; `mode:"foo"` → 400 `invalid_mode` with no session/quota call; `mode:"log"` + image / training_context / user_context → 400 before session; `local_date` missing / malformed / ±2 days → 400 `invalid_local_date`; `local_date` with mode plan → 400; `mode:"log"` + text `/plan legs` → log path; mode absent + `/log x` → 400 (`/log` requires explicit mode; text parsing only for `/plan`); empty wish → 400; classifier `self_harm`/`eating_disorder`/`injection` → refusal, slot kept, no extraction; `medical_risk` → extraction runs and summary ends with the fixed safety line; unusable classifier output in log mode → `classifier_unusable` refusal, no extraction; invalid draft / `finish_reason:length` / provider 500 → 502 + one refund to the claim day; content_filter → refusal kept; assistant store failure → 200 without `assistant_message_id`; lb conversion persisted 102.06; logs never contain the user text (assert on captured console). Mode loops in existing tests gain `log` where they enumerate modes; `mode:"chat"` (brief discuss) and absent mode stay 200.
- [ ] **Step 6: Implement handler changes**: dispatch (explicit mode wins; allowlist `{absent, chat, recipe, plan, log}`), `local_date` in REQUEST_FIELDS with validation before `ensureSession`, `LOG_REFUSAL_CATEGORIES = {self_harm, eating_disorder, injection}` in `guardrails.ts` (pinned in `guardrails_test.ts`), `isLogMode` in both the parseFailed exclusion and `refuseOnUnusableOutput`, `handleWorkoutLogMode` (copy of `handlePlanMode` structure: store user row → `budget("coach_plan")` → extraction call `{model: MODEL_ANSWER (env COACH_MODEL_LOG overrides), temperature: 0, response_format: json_object, reasoning: {effort:'low', exclude:true}, provider: {require_parameters: true}, max_tokens: 4096}` with the 45 s answer deadline and 512 KiB body cap → transform → validate → `storeWorkoutLogMessage` → buffered JSON). Chat answer prompt: "answer in the app language (`locale`) when the message mixes languages; if the user reports a completed workout, suggest `/log`". Shared classifier prompt gains gym-slang examples ("I'm dead after leg day" is fitness).
- [ ] **Step 7: Run** every `coach-chat/*_test.ts` and `_shared/*_test.ts` individually (`deno test --allow-env <file>`), plus `deno lint` and `deno check coach-chat/index.ts` → PASS.
- [ ] **Step 8: Migration** `20261004090000_chat_message_workout_log.sql`: `create or replace function public.is_valid_coach_workout_log(jsonb) returns boolean language sql immutable set search_path = pg_catalog` mirroring the TS validator (format-only date check with `to_date` round-trip, `round(n,2) = n`, exact key sets via `jsonb_object_keys`, octet cap 32768); revoke/grant like `is_valid_training_plan` (20260908130000:129-131); `alter table public.chat_messages add column if not exists workout_log jsonb`; constraint `chat_messages_workout_log_check check (workout_log is null or (role = 'assistant' and not coalesce(refusal,false) and recipe is null and training_plan is null and public.is_valid_coach_workout_log(workout_log)))` (match the real column names in `chat_messages`). Do NOT touch `apply_sync_operation` or `reserve_ai_provider_call`.
- [ ] **Step 9: DB tests** `test/migrations/coach_workout_log_rls.sql` (every fixture case through `is_valid_coach_workout_log`; user-role insert with workout_log fails 23514; refusal + workout_log fails; recipe + workout_log fails; client INSERT denied), `\ir` from `rls_cross_user.sql`, expectation in `rls_invariants_test.dart`. Regenerate `SCHEMA_STATE.md` per its header instructions (`SCHEMA_STATE_SCHREIBEN=1 flutter test test/migrations/schema_state_doc_test.dart`) if it can run locally; otherwise leave the exact regeneration to CI output and say so.
- [ ] **Step 10: Evals** add E1–E22 (PR description list) to `supabase/eval/coach_cases.ts` with expected mode `log`.
- [ ] **Step 11: Docs** `docs/BACKEND.md` mode list, request fields, quota/refund rule for `/log`.
- [ ] **Step 12: Commit** (`feat(coach): /log mode extracts a completed workout as a confirmable proposal`), one commit per logical unit is fine.

### Task M1: Snapshot deadline key, rest rule, history mirror

**Files:** Modify `lib/src/models/training_session.dart`, `lib/src/models/training_history.dart` (constructor + `lastTrainingPerformanceByName` + `TrainingLogBlockedBySession`); Test `test/training/training_session_snapshot_test.dart`, `test/training/training_history_test.dart`, `test/training/training_legacy_checkpoint_test.dart`.

**Interfaces:** Produces `phaseEndsAt`, relaxed rest rule, stricter history constructor, `lastTrainingPerformanceByName`, `TrainingLogBlockedBySession` (see contracts).

- [ ] **Step 1: Failing tests:** (a) a rest-phase snapshot after the last set of exercise 0 (not the final exercise) round-trips; a rest after the final set of the final exercise is still rejected (update the existing assertion at `training_session_snapshot_test.dart:82` deliberately); (b) `phase_ends_at` round-trips byte-identically (`jsonEncode(fromJson(j).toJson()) == jsonEncode(j)`) incl. microseconds; old checkpoints without the key decode unchanged; key rejected in review / with pending completion / in a rep exercise phase; decoding under two different frozen clocks yields equal objects; (c) `TrainingHistoryEntry` rejects a snapshot with draft values, an uppercase session id, or `phaseEndsAt`; existing cached rows/fixtures still decode; (d) `lastTrainingPerformanceByName` returns the newest entry from another plan with the same normalized name and `isTimed`, ignores the excluded plan, ignores entries whose sets have no actuals for that exercise.
- [ ] **Step 2: Run** `flutter test test/training/training_session_snapshot_test.dart test/training/training_history_test.dart` → new tests FAIL.
- [ ] **Step 3: Implement**: optional key handled like `recovery_note` (training_session.dart ≈224-225, 288-289, 366-371, 424); `fromRecovery`/history construction strips it; rest validator at ≈210-215; `normalizeExerciseName` is imported from `training_log.dart` (create that file with just this function and the id helper if M2 has not landed — M2 owns the rest of it).
- [ ] **Step 4: Run** the focused files + `test/training/training_legacy_checkpoint_test.dart` → PASS.
- [ ] **Step 5: Commit.**

### Task M2: Log builders (`training_log.dart`) and Coach wire model (`coach_workout_log.dart`), id derivation

**Files:** Create `lib/src/models/training_log.dart`, `lib/src/models/coach_workout_log.dart`; Modify `lib/src/services/uuid.dart`; Test create `test/models/training_log_test.dart`, `test/models/coach_workout_log_test.dart`, extend the uuid test file (find with `grep -rl deriveStatsRequestId test`).

(M2 runs in the same worktree/agent as M1, after M1.)

- [ ] **Step 1: Failing tests:** `buildLoggedWorkout` → `TrainingHistoryEntry.fromRow(entry.toRow())` equals; bodyweight (weight null), weighted, timed (reps null), 150 reps kept as actual while plan reps = 100, same name twice → ids `n_<h>` and `n_<h>_2`, 20 exercises × 10 sets, timed 7200 s → 2 rows of 3600 s per set with copied weight, `performedOn` today → finishedAt = now; yesterday → yesterday at now's local time-of-day (test across a DST boundary with a frozen clock in `Europe/Berlin` semantics using local DateTime ctor), `durationMinutes` → startedAt = finishedAt − d, none → equal, all completed_at = finishedAt, plan id `log_<historyId>`, `isLoggedTrainingEntry` true. `validateLoggedWorkout`: future date / 31 days ago → `dateOutOfRange`; missing reps → `missingReps`; timed without duration → `missingDuration`. `buildPlanAttachedLog`: real plan id/exercise ids/workoutIndex, undone sets skipped, at least one done set required (else throws `ArgumentError`), round-trip. `CoachWorkoutLog.fromJson`: accepts the canonical example, rejects extra key / wrong type / 11 sets / 3 decimals; `toDraft()` maps kinds/durations; date `'2026-02-30'` → null. `deriveCoachWorkoutLogId`: golden vector for a fixed UUID, lowercase, null for `local-r-1`, differs from `deriveStatsRequestId` of the same input.
- [ ] **Step 2: Run** `flutter test test/models/training_log_test.dart test/models/coach_workout_log_test.dart` → FAIL.
- [ ] **Step 3: Implement** per contracts (sha256 from `package:crypto`; `TrainingJson` helpers for text limits; plan title fallback = `fallbackTitle`; prescription `reps = clamp(max non-null actual, 1, 100)`, `restSeconds 0`; snapshot `phase review`, cursor at last exercise/last set, `remainingMilliseconds 0`, drafts null, `completedSets` all refs, `skippedSets` empty (plan-attached: undone refs), `actualSets` one per completed set).
- [ ] **Step 4: Run** → PASS. **Step 5: Commit.**

### Task A2: Rest alerts, permission gate, notification taps, screen-awake (Dart + Android)

**Files:** Create `lib/src/services/rest_alerts.dart`, `lib/src/services/screen_awake.dart`, `test/services/rest_alerts_test.dart`, `test/services/screen_awake_test.dart`; Modify `lib/src/services/notification_service.dart` (gateway `cancel(id)`, `scheduleAll` cancels only nudge ids, dedicated Android channel `eatova_training`, `RestAlertScheduler`/`NotificationTapSource`/permission state on `LocalNotificationService`, rest alerts through `_enqueueMutation` and refused after session end), `lib/src/app/home_store_profile.dart` (reminders-off path cancels nudge ids only), `android/app/src/main/kotlin/**/MainActivity.kt` (`eatova/screen` → `window.addFlags/clearFlags(FLAG_KEEP_SCREEN_ON)` on the UI thread); update the existing notification test doubles (`grep -rln "implements NotificationService\|NotificationPluginGateway" test`).

- [ ] **Step 1: Failing tests:** scheduling a rest alert calls the gateway `zonedSchedule` with the reserved id, channel `eatova_training`, payload `training-rest`, iOS details `presentSound: true, presentBanner: false, presentList: false` for foreground; `cancelRestAlert` calls `cancel(id)` only; `scheduleAll(nudges)` no longer cancels the rest id (**R/G**: fails on today's cancel-all); reminders-off keeps a pending rest alert; session end (`cancelAll` via auth gate) still removes it; a rest alert requested after session end is ignored; `restAlertIdForSession` deterministic and in range; permission gate returns `notAsked` before the device flag is set, `request()` sets the flag; tap stream emits `training-rest` from `onDidReceiveNotificationResponse`, `launchPayload()` from `getNotificationAppLaunchDetails`; `MethodChannelScreenAwake` sends `setKeepAwake {on: true}` (mock channel); manifest test still green (no new permission).
- [ ] **Step 2: Run** `flutter test test/services/rest_alerts_test.dart test/services/screen_awake_test.dart test/fixlauf_g_notification_tz_test.dart test/services/notification_concurrency_test.dart test/wiring_android_manifest_test.dart` → FAIL.
- [ ] **Step 3: Implement.** ARB keys (anchor next to `notification*`): `trainingRestAlertTitle` ("Rest over" / "Pause vorbei"), `trainingRestAlertBody` ("Time for your next set." / "Zeit für den nächsten Satz."), `trainingIntervalAlertTitle` ("Time's up" / "Zeit um"), `trainingIntervalAlertBody` ("Rest starts now." / "Jetzt Pause."), `trainingRestChannelName`, `trainingRestChannelDescription`.
- [ ] **Step 4: Run** → PASS (+ `flutter gen-l10n`, analyzer). **Step 5: Commit.**

### Task D1: iOS speech accumulator, graceful stop, partials, screen channel (Swift)

**Files:** Create `ios/Runner/SpeechTranscriptAccumulator.swift`, `ios/RunnerTests/SpeechTranscriptAccumulatorTests.swift`; Modify `ios/Runner/AppDelegate.swift` (EatovaSpeechPlugin + `eatova/screen` handler using `UIApplication.shared.isIdleTimerDisabled`), `ios/Runner.xcodeproj/project.pbxproj` (add both files to the right targets with fixed hex ids following the existing EA21-style precedent), `scripts/ci/ios_test_support.py` (+ its unit test) to require the new suite.

- [ ] **Step 1: Accumulator test first** (`SpeechTranscriptAccumulatorTests`): the forum reset trace (hypotheses growing to 114 segments then collapsing to 1 with new text and later timestamp) keeps both utterances; punctuation/capitalisation revisions of the same utterance do not duplicate ("i did 20 reps" → "I did 20 reps." stays one); `speechRecognitionMetadata` commit; duplicate final after commit ignored; empty partials ignored. Commit this together with an `OverwriteAccumulator` strategy used by a parametrised test that is expected to fail, so the first iOS CI run is red for the old behaviour; then switch the tests to the real accumulator (keep the overwrite case as an explicit `XCTAssertNotEqual` documenting the bug).
- [ ] **Step 2: Implement** the accumulator (pure struct: inputs = formatted string, first-segment timestamp, segment count, `utteranceEnded`), plugin per contract: token from args, partial `invokeMethod('partial', ...)` on main thread only when changed, graceful `stop` (stop engine, remove tap, `endAudio()`, wait ≤ 1.5 s for `isFinal`, then finish with `acc.text`), separate `cancel`, reason `limit` when the task ends by itself after ≥ 55 s, reason `length` + graceful stop when `acc.text.utf16.count >= 1000`, `addsPunctuation` (iOS 16+), `taskHint = .dictation`, `contextualStrings` (gym terms DE/EN), recognizer kept as a property, a busy `listen` while a previous one is stopping force-finishes the old one. Never log text.
- [ ] **Step 3: Verify without a Mac:** `python -m unittest discover -s scripts/ci -p "test_*.py"`; review the pbxproj diff by hand (every new id unique, file in Runner sources / RunnerTests sources). The iOS workflow runs on the PR (paths filter) — record that native execution is unverified locally.
- [ ] **Step 4: Commit.**

### Task I1: Insights — up-next after done-today, name fallback for Last time

**Files:** Modify `lib/src/models/training_insights.dart`, `lib/src/screens/today/today_sections.dart` (only if needed to keep showing the done workout); Test `test/models/training_insights_test.dart`, `test/models/training_insights_equivalence_test.dart`, Today tests (`grep -rl todayWorkoutDone test`), `test/home_store_derivations_test.dart`.

- [ ] **Step 1: Failing tests:** `TrainingNextWorkout.upNextWorkoutIndex` == rotation successor when `completedToday`, == `workoutIndex` otherwise; Today tab still shows the done workout; preview `lastTopSet` falls back to `lastTrainingPerformanceByName` when the plan-scoped lookup is empty; logs (`log_` plans) never affect a plan's rotation; week strip counts a backdated log on its local day (frozen clock).
- [ ] **Step 2–4:** run → FAIL, implement, run → PASS. ARB (anchor `trainingWeek*`) only if a label is needed (e.g. `trainingDoneTodayLine`: "Done today: {title}" / "Heute erledigt: {title}").
- [ ] **Step 5: Commit.**

### Task B1: Store and cache — non-destructive insert, `logCompletedWorkout`, relaxed completion

**Files:** Modify `lib/src/services/local_cache_mutations.dart` (≈1393-1412), `lib/src/app/home_store.dart`, `home_store_training.dart`, `home_store_training_history.dart`, `lib/src/models/training_history.dart` (only the exception class at the top, if M1 has not added it); Test `test/training/training_history_store_test.dart`, `training_store_test.dart`, `training_checkpoint_concurrency_test.dart`, `test/services/local_cache_test.dart`, `test/services/training_deletion_receipt_security_test.dart`.

- [ ] **Step 1: Failing tests (each R/G):** a paused checkpoint survives a history insert with a different id (cache projection) and survives app restart; `logCompletedWorkout` publishes the entry, enqueues exactly one `trainingHistoryInsert`, leaves `trainingSession` and source generations untouched; idempotent (second call → no new op, returns delivered/queuedRetry); deleted id → `TrainingCompletionDeleted`; cap 2000 → `StateError` without writing; account switch mid-call → throws, nothing written; offline → `queuedOffline`, durable after restart; plan-attached with an existing session/recovery → `TrainingLogBlockedBySession`; `completeTrainingSession` after the source plan was edited (generation bumped) now saves (previous behaviour: `TrainingCompletionSourceRetired`) while a protected recovery with another id still blocks; publish keeps an unrelated session; `saveTrainingSession` returns false when the source is retired and true when stored; `trainingHistoryAuthoritative` false while receipts are unreadable.
- [ ] **Step 2: Run** `flutter test test/training/ test/services/local_cache_test.dart test/services/training_deletion_receipt_security_test.dart` → new tests FAIL.
- [ ] **Step 3: Implement** in the order from spec §6 Store; remove the source fences only from completion; projection clears the checkpoint only when `recovery['session_id'] == entry.id` (mirror `_deleteHistory`).
- [ ] **Step 4: Run** → PASS (whole `test/training/` dir). **Step 5: Commit.**

### Task D2: Dictation client

**Files:** Modify `lib/src/screens/coach/coach_speech.dart`, `lib/src/screens/coach/coach_composer.dart` (mic gating, language pill, read-only field while listening), the dictation region of `lib/src/screens/coach/coach_chat_screen.dart` (`_cancelSpeechInput`/`_toggleSpeechInput` ≈1941-2002, lifecycle hooks ≈318-321/355-363/375, one guarded call at the top of `_send`); Create `lib/src/services/dictation_language.dart` (per-device DE/EN preference using the app's existing key-value/shared-preferences mechanism — find it with `grep -rn SharedPreferences lib/src`), `test/coach_dictation_test.dart`; update the five `CoachSpeechInput` fakes only if needed.

- [ ] **Step 1: Failing widget tests** (drive native calls via `TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger` on `eatova/speech`): partials appear live in the field; final text appended after an existing `/log ` draft with one space; stale-token partial ignored after a tab switch; tab switch keeps already-shown text, dispose/account change discards; Send while listening → `stop` called, final text in field, nothing sent until a second tap; mic stop works while a request is in flight; `limit`/`length` end shows the localized hint; language pill toggles `de_DE`/`en_US`, restarts recognition and replaces only the current dictation's text, persists per device; screen awake on while listening (fake `ScreenAwake`), off after; nothing from the transcript reaches `debugPrint`/reporters.
- [ ] **Step 2–4:** FAIL → implement → PASS (`flutter test test/coach_dictation_test.dart test/coach_design_test.dart test/coach_quota_unbekannt_test.dart test/fixlauf_e_coach_client_test.dart test/fixlauf_p5_coach_test.dart test/review_2026_09_08_coach_lifecycle_test.dart test/coach_speech_localized_error_test.dart`). Update the lifecycle test that locked "hide discards" deliberately. ARB (anchor `coachSpeech*`, prefix `coachDictation*`): language pill labels + semantics, limit hint, length hint.
- [ ] **Step 5: Commit.**

### Task A1: Controller and list player

**Files:** Modify `lib/src/services/training_session_controller.dart`, `lib/src/screens/training/training_player_screen.dart`, `lib/src/screens/training/training_actual_fields.dart`, `lib/src/app/eatova_home_page.dart` (only `_openTrainingPlayer` ≈1118-1218: permission ask, rest alerts, screen awake, onPersist bool); Create widget files under `lib/src/screens/training/player/` (set row, exercise card, rest bar, finish sheet); Tests: rewrite deliberately `test/training/training_session_controller_test.dart`, `training_player_screen_test.dart`, `training_automatic_flow_test.dart`, `training_account_route_test.dart`, `test/training_qa/player_lifecycle_test.dart`, `timer_recovery_test.dart`, `test/flows/training_shell_flow_test.dart`, `core_feature_shell_flow_test.dart` (tap counts ≈140-143), `training_legacy_recovery_flow_test.dart`, `test/responsive/app_layout_sweep_test.dart` (player entries); keep fixture-only users green (`training_history_*`, `training_legacy_checkpoint_test`, `training_deletion_receipt_security_test`).

- [ ] **Step 1: Controller tests first:** ✓ completes a rep set without `start()`; `start()` + `completeCurrentSet()` still work (fixtures); weight carry-forward rule (spec A2, incl. Last time set *k*, ignoring all-empty last sessions); rest after an exercise's last set (not after the workout's final set); `phaseEndsAt` set on rest/timed start, `remaining` derived from `clock.now()`, clamped on backwards clock; `catchUp(now)`: timed past deadline → completed at deadline, rest from deadline, next timed waits; recovery: running rest continues, timed past deadline waits at zero for ✓; undo of the last completed set cancels rest; ±15 s moves the deadline; "complete remaining as planned" completes the active exercise's remaining sets with shown values; `startedAt` = first ✓/▶; finish > 5 min after last completion uses last completion; completedAt ≥ startedAt under a backwards clock (**R/G**).
- [ ] **Step 2: Player tests first:** one tap per set end-to-end (4 × 3 plan: 14 taps incl. start and save); editing never pauses; a background → resume gap longer than the rest leaves the next set active and no Resume button (**R/G** vs today's freeze); rest alert scheduled at rest start with `restAlertIdForSession`, cancelled on Skip/✓/Undo/Finish/Discard; foreground haptic at rest end; finish sheet opens after the last set; partial finish options and 0-set case; plan edited while open → Finish still saves; save indicator false → "not stored" text; keyboard dismissed by ✓ and drag; ✓ ≥ 56 dp; announcements via live regions/`sendAnnouncement` (no deprecated API); screen awake only during timed interval/rest-before-timed; large text (2.0) and 320 px width without overflow.
- [ ] **Step 3: Implement**: controller on `package:clock` deadlines (keep the monotonic seam for tests), list UI per spec A3 in new widget files, debounced durable writes flushed on lifecycle/cover/terminal/dispose (remove the 5 s timer), notification permission explainer at first workout via `RestAlertPermissionGate`, `onPersist` → bool. ARB (anchor after `trainingTimer*`): row/column labels, rest bar, finish sheet options, menu items, "Alerts off" chip, "not stored", explainer.
- [ ] **Step 4: Run** `flutter test test/training/ test/training_qa/ test/flows/ test/responsive/app_layout_sweep_test.dart` → PASS; update `docs/TRAINING-DESIGN.md` (player section + "Supersedes" table from spec §4).
- [ ] **Step 5: Commit** (several commits fine: controller, UI, tests).

### Task L1: Log editor and Training root

**Files:** Create `lib/src/screens/training/training_log_editor.dart`, `test/training/training_log_editor_test.dart`; Modify `lib/src/screens/training/training_screen.dart`, `training_overview_widgets.dart`, `training_history_screen.dart`; Tests `test/training/training_overview_wiring_test.dart` (`training-quick-create` ≈347/553), `test/training_page_test.dart`, `test/training_page_geometry_test.dart`, `test/training/training_history_screen_test.dart`.

- [ ] **Step 1: Failing tests:** free editor: date chips (today/yesterday/picker limited to 30 days, no future), add exercise with name autocomplete from history (prefills Last time), "Add set" copies previous, timed toggle with duration, remove, note; Save disabled until `validateLoggedWorkout` is empty; Save calls `onSave` once with an entry built by `buildLoggedWorkout` using the request's `historyId` (same id on retry), double tap → one call; outcome `deleted` → "Removed from history" message, `blocked` → resume hint; plan-attached editor shows fixed structure, toggles, prefilled values, needs ≥ 1 done set; Training root: "Log workout" tile replaces the duplicate create tile, "Log as done" hidden while a session exists, "Done today: X" + Start for `upNextWorkoutIndex`, history load failure notice, history rows of logs show "Logged" and hide duration/"recorded from" when `!trainingEntryHasDuration`, delete copy for logs; a "Tell the Coach instead" link calls `onOpenCoachLog`.
- [ ] **Step 2–4:** FAIL → implement (borderless soft inputs, `showEatovaSheet`, Safe-Area/keyboard-aware sheet height as existing sheets) → PASS (`flutter test test/training/ test/training_page_test.dart test/training_page_geometry_test.dart`). New `TrainingScreen` callbacks: `onLogWorkout`, `onLogPlannedWorkout(TrainingPlan plan, int workoutIndex)`, `onOpenCoachLog`, plus `historyLoadFailed`. ARB anchor after `trainingHistory*`.
- [ ] **Step 5: Commit.**

### Task C2: Coach `/log` client

**Files:** Create `lib/src/screens/coach/coach_workout_log.dart` (part: card + review glue), `test/coach_workout_log_flow_test.dart`, `test/services/coach_workout_log_service_test.dart`, `test/models/coach_workout_log_parity_test.dart` (reads the S1 fixture); Modify `lib/src/services/coach_chat_service.dart` (`requestWorkoutLog`, `_workoutLogFromPayload`, straggler, history select adds `workout_log`, `Accept-Language` on every request), `lib/src/models/chat_message.dart` (`workoutLogProposal`, exactly-one-proposal rule), `lib/src/screens/coach/coach_chat_screen.dart` (command registry incl. `/log`, `_send`, `_sendWorkoutLogRequest`, `_hydrateProposalImages`, `_sameCompletedAnswer`, new params, `logDraftRequest`), `coach_message_list.dart`, `coach_recipe.dart` (command menu), `coach_hero.dart` (third chip).

- [ ] **Step 1: Failing tests:** service: request body exactly `{message, mode:'log', local_date, locale, session_id}`; JSON and SSE-`done` bodies parsed; malformed payload → invalid response error tagged `coach.workoutLog.invalidResponse` without content; refusal suppresses the proposal; 400 `invalid_mode`/`invalid_local_date` → "not available yet" error; deadline straggler finds the persisted row; account switch mid-request → dropped. Flow: `/log …` sends once; empty `/log` and photo + `/log` send nothing; card shows title/date/lines and, when `otherDaysOmitted`, the "Only <day> was taken" hint; **no write before confirm**; Add opens the editor prefilled; editor Add calls `onLogWorkout` once with id `deriveCoachWorkoutLogId(messageId)`; cancel writes nothing; card flips to "Added ✓ · Open training" when the id appears in `trainingHistoryIds`; deleted → "Removed from history" and no Add; not authoritative → disabled; local-only message → uuid kept on the message (same id on retry); reload rebuilds the card from history rows; English UI keeps English card texts; double tap → one sheet. Parity: every fixture `valid` parses with `CoachWorkoutLog.fromJson`, every `invalid` returns null.
- [ ] **Step 2–4:** FAIL → implement → PASS (`flutter test test/coach_*_test.dart test/services/coach_*_test.dart test/models/ test/flows/coach_rezept_flow_test.dart test/repo_rules_test.dart`). ARB anchor after `coachPlan*`, prefix `coachWorkoutLog*`; update `coachPlanUnknownCommandHint` to list `/log` in both languages.
- [ ] **Step 5: Commit.**

### Task C3: Coach fixes (spec §9)

**Files:** `coach_chat_screen.dart`, `coach_message_list.dart`, `coach_sessions.dart`, `coach_training_brief.dart`, `coach_recipe.dart`, `coach_plan.dart`, `coach_chat_service.dart`; tests: one regression per item in the matching existing test file or `test/coach_review_fixes_2026_10_03_test.dart`.

- [ ] **Step 1: Failing regressions (each R/G):** brief requested while `_sending` is queued and opens after the reply; brief submission restores an unrelated draft; brief does not open when quota is exhausted/composer locked and shows the reason; 429 with German `serverReply` in an English UI shows the English local text; error banner / unsent notice are live regions and the thinking row has a semantics label; recipe "added" is a live region; session delete target ≥ 48 dp; failed history load keeps the sessions list in the sheet and unlocks the composer after retry; failed "New conversation" shows a snack; a photo is not dropped when typing during compression (send goes ahead with the text at pick time, or the field is locked during compression — pick one and test it); recipe add lock set before the sheet opens (double tap → one sheet); plan card lists up to three exercises with "+N more".
- [ ] **Step 2–4:** FAIL → fix → PASS. **Step 5: Commit** per fix group.

### Task W1: Shell wiring, notification taps, docs (integrator)

**Files:** `lib/src/app/eatova_home_page.dart` (`_trainingTab` and `_coachTab` builders, notification tap → Training + player, Today "In progress · Resume" if missing), `lib/src/app/home_store*.dart` only if a getter is missing, docs (`docs/FEATURES.md`, `docs/TRAINING-DESIGN.md`, `docs/BACKEND.md`, `PRIVACY.md` (workout text in `chat_messages` and sent to the AI provider), `CHANGELOG.md`, `docs/PROJECT_HANDOFF.md`), version bump in `pubspec.yaml` build number.

- [ ] **Step 1: Failing wiring tests** in `test/training/training_overview_wiring_test.dart` / `test/coach_start_wiring_test.dart`: Coach selector rebuilds when history/deletions change (card flips to Added); `onLogWorkout` null without sync; "Tell the Coach" switches tab and prefills `/log `; notification tap payload opens Training with the player for the owner only.
- [ ] **Step 2–4:** FAIL → wire → PASS; then `flutter gen-l10n`, `flutter analyze --no-pub --fatal-infos --fatal-warnings`, `flutter test --coverage` (≥ 88 %), Deno suite.
- [ ] **Step 5: Commit**; push branches; open PR 1 and PR 2 (bodies carry evidence, root causes, rollout order); ask the owner for migration/deploy/merge approval.

---

## Self-review notes

- Spec coverage: A1–A7 → A1/A2/D1(screen iOS)/M1/B1; B → M2/B1/L1/I1; C → S1/M2/C2; D → D1/D2; E → C3/S1; Delivery → W1. Spec §11 items have no task by design.
- Type consistency checked against the contracts block; `TrainingLogSaveOutcome` is produced by L1 and consumed by C2/W1; `logCompletedWorkout` by B1 → W1 adapters map exceptions to outcomes (`TrainingCompletionDeleted` → `deleted`, `TrainingLogBlockedBySession` → `blocked`, other → `failed`, `SyncDelivery.delivered` → `saved`, `queuedRetry` → `queued`, `queuedOffline` → `queuedOffline`).
- Review Focus items 1–5 each have a test step (A1 step 2, M1/B1 step 1, C2 step 1, D1/D2 step 1, S1 step 5 + C3).
