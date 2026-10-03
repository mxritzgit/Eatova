// The shared log editor (spec B): a free log or a planned workout done
// outside the player. Nothing is written before Add; Add is single-flight and
// every attempt carries the caller's history ID.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_log.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/screens/training/training_log_editor.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/kcal/food_date_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const _id = '3f2b8c1e-4d5a-4b6c-8d7e-9f0a1b2c3d4e';
const _otherId = '0b6f2a9e-1c3d-4e5f-8a7b-6c5d4e3f2a1b';
const _id2 = '5d4c3b2a-1f0e-4d9c-8b7a-6f5e4d3c2b1a';

/// Saturday 2026-10-03, 18:30 local.
final _now = DateTime(2026, 10, 3, 18, 30);

class _Recorder {
  final saved = <TrainingHistoryEntry>[];
  TrainingLogSaveOutcome? result;
  bool closed = false;
}

Future<_Recorder> _open(
  WidgetTester tester, {
  TrainingLogEditorRequest request = const FreeLogRequest(historyId: _id),
  List<TrainingHistoryEntry> history = const [],
  List<TrainingLogSaveOutcome> outcomes = const [],
  Future<TrainingLogSaveOutcome> Function(TrainingHistoryEntry)? onSave,
  Locale locale = const Locale('en'),
  Size size = const Size(390, 844),
  double scale = 1,
}) async {
  final recorder = _Recorder();
  var calls = 0;
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => TextButton(
        key: const ValueKey('open-log'),
        onPressed: () async {
          recorder.result = await showTrainingLogEditor(
            context,
            request: request,
            history: history,
            onSave:
                onSave ??
                (entry) async {
                  recorder.saved.add(entry);
                  final i = calls++;
                  return i < outcomes.length
                      ? outcomes[i]
                      : TrainingLogSaveOutcome.saved;
                },
          );
          recorder.closed = true;
        },
        child: const Text('Open'),
      ),
    ),
    locale: locale,
    surfaceSize: size,
    textScale: scale,
  );
  await tester.tap(find.byKey(const ValueKey('open-log')));
  await tester.pumpAndSettle();
  return recorder;
}

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.pumpAndSettle();
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(_key(key));
  await tester.pumpAndSettle();
  await tester.enterText(_key(key), text);
  await tester.pumpAndSettle();
}

String _text(WidgetTester tester, String key) =>
    tester.widget<TextField>(_key(key)).controller!.text;

bool _saveEnabled(WidgetTester tester) =>
    tester.widget<PrimaryActionButton>(_key('training-log-save')).onTap != null;

TrainingHistoryEntry _expectedFree(LoggedWorkoutDraft draft) =>
    buildLoggedWorkout(
      historyId: _id,
      draft: draft,
      now: _now,
      fallbackTitle: 'Workout',
    );

/// Bench press 80 × 8, 80 × 8, 75 × 6 two days ago, as a free log.
TrainingHistoryEntry _benchLog() => buildLoggedWorkout(
  historyId: _otherId,
  draft: LoggedWorkoutDraft(
    title: 'Push',
    performedOn: DateTime(2026, 10, 1),
    exercises: const [
      LoggedExercise(
        name: 'Bench press',
        timed: false,
        sets: [
          LoggedSet(reps: 8, weightKg: 80),
          LoggedSet(reps: 8, weightKg: 80),
          LoggedSet(reps: 6, weightKg: 75),
        ],
      ),
    ],
  ),
  now: _now,
  fallbackTitle: 'Workout',
);

TrainingPlan _plan() => TrainingPlan(
  id: 'plan-a',
  proposal: CoachTrainingProposal(
    title: 'Strength',
    workouts: [
      TrainingWorkout(
        title: 'Day A',
        exercises: [
          TrainingExercise(
            id: 'bench',
            name: 'Bench press',
            sets: 3,
            reps: 8,
            restSeconds: 90,
          ),
          TrainingExercise(
            id: 'plank',
            name: 'Plank',
            sets: 2,
            durationSeconds: 45,
            restSeconds: 30,
          ),
        ],
      ),
    ],
  ),
);

/// A played-looking Day A of [_plan] with bench weights [kg] (null = none).
TrainingHistoryEntry _planSession(String id, DateTime day, List<double?> kg) =>
    buildPlanAttachedLog(
      historyId: id,
      plan: _plan(),
      workoutIndex: 0,
      sets: [
        [for (final w in kg) PlanAttachedSet(done: true, reps: 8, weightKg: w)],
        const [PlanAttachedSet(done: true), PlanAttachedSet(done: true)],
      ],
      performedOn: day,
      durationMinutes: 40,
      now: _now,
    );

void main() {
  group('free log', () {
    testWidgets('Add stays disabled until the draft is valid', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final recorder = await _open(tester);
        expect(find.text('Log workout'), findsOneWidget);
        expect(_saveEnabled(tester), isFalse);
        expect(
          find.text('Give every exercise a name and at least one set.'),
          findsOneWidget,
        );
        await _type(tester, 'training-log-exercise-0-name', 'Bench press');
        expect(_saveEnabled(tester), isFalse, reason: 'reps missing');
        expect(find.text('Enter the reps for every set.'), findsOneWidget);
        await _type(tester, 'training-log-exercise-0-set-0-reps', '8');
        expect(_saveEnabled(tester), isTrue);
        await _type(tester, 'training-log-exercise-0-set-0-reps', '3,5');
        expect(_saveEnabled(tester), isFalse, reason: 'not a whole number');
        await _type(tester, 'training-log-exercise-0-set-0-reps', '1001');
        expect(_saveEnabled(tester), isFalse, reason: 'over 1000');
        expect(recorder.saved, isEmpty);
      });
    });

    testWidgets(
      'Add calls onSave once with buildLoggedWorkout and the request ID',
      (tester) async {
        await withClock(Clock.fixed(_now), () async {
          final recorder = await _open(tester);
          await _type(tester, 'training-log-exercise-0-name', 'Bench press');
          await _type(tester, 'training-log-exercise-0-set-0-reps', '8');
          await _type(tester, 'training-log-exercise-0-set-0-weight', '82,5');
          await _type(tester, 'training-log-duration', '45');
          await _type(tester, 'training-log-note', 'Felt strong');
          await _tap(tester, 'training-log-save');
          final expected = _expectedFree(
            LoggedWorkoutDraft(
              title: '',
              performedOn: DateTime(2026, 10, 3),
              durationMinutes: 45,
              note: 'Felt strong',
              exercises: const [
                LoggedExercise(
                  name: 'Bench press',
                  timed: false,
                  sets: [LoggedSet(reps: 8, weightKg: 82.5)],
                ),
              ],
            ),
          );
          expect(recorder.saved.single.id, _id);
          expect(recorder.saved.single.toRow(), expected.toRow());
          expect(recorder.saved.single.snapshot.workout.title, 'Workout');
          expect(recorder.result, TrainingLogSaveOutcome.saved);
          expect(find.text('Workout added to your history.'), findsOneWidget);
        });
      },
    );

    testWidgets('Yesterday and a picked day (≤ 30 days, never future)', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final recorder = await _open(tester);
        await _type(tester, 'training-log-exercise-0-name', 'Squat');
        await _type(tester, 'training-log-exercise-0-set-0-reps', '5');
        await _tap(tester, 'training-log-day-yesterday');
        expect(
          tester
              .widget<FilterChipPill>(_key('training-log-day-yesterday'))
              .selected,
          isTrue,
        );
        await _tap(tester, 'training-log-day-pick');
        final picker = tester.widget<FoodDatePicker>(
          find.byType(FoodDatePicker),
        );
        expect(picker.firstDate, DateTime(2026, 9, 3));
        expect(picker.lastDate, DateTime(2026, 10, 3));
        expect(picker.confirmLabel, 'Use this day');
        await tester.tap(
          find.descendant(
            of: find.byType(CalendarDatePicker),
            matching: find.text('1'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('food-date-confirm')));
        await tester.pumpAndSettle();
        expect(find.text('Thu, Oct 1'), findsOneWidget);
        await _tap(tester, 'training-log-save');
        expect(
          recorder.saved.single.toRow(),
          _expectedFree(
            LoggedWorkoutDraft(
              title: '',
              performedOn: DateTime(2026, 10, 1),
              exercises: const [
                LoggedExercise(
                  name: 'Squat',
                  timed: false,
                  sets: [LoggedSet(reps: 5)],
                ),
              ],
            ),
          ).toRow(),
        );
      });
    });

    testWidgets('a known name prefills Last time; Add set copies the last', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        await _open(tester, history: [_benchLog()]);
        await _type(tester, 'training-log-exercise-0-name', 'ben');
        await _tap(tester, 'training-log-exercise-0-suggestion-0');
        expect(_text(tester, 'training-log-exercise-0-name'), 'Bench press');
        expect(
          _key('training-log-exercise-0-suggestion-0'),
          findsNothing,
          reason: 'an exact name needs no suggestion',
        );
        for (final (set, reps, kg) in const [
          (0, '8', '80'),
          (1, '8', '80'),
          (2, '6', '75'),
        ]) {
          expect(_text(tester, 'training-log-exercise-0-set-$set-reps'), reps);
          expect(_text(tester, 'training-log-exercise-0-set-$set-weight'), kg);
        }
        await _type(tester, 'training-log-exercise-0-set-2-weight', '77,5');
        await _tap(tester, 'training-log-exercise-0-add-set');
        expect(_text(tester, 'training-log-exercise-0-set-3-reps'), '6');
        expect(_text(tester, 'training-log-exercise-0-set-3-weight'), '77,5');

        await _type(tester, 'training-log-exercise-0-name', 'xyz');
        expect(_key('training-log-exercise-0-suggestion-0'), findsNothing);
      });
    });

    testWidgets('timed exercise: duration instead of reps', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final recorder = await _open(tester);
        await _type(tester, 'training-log-exercise-0-name', 'Plank');
        await _tap(tester, 'training-log-exercise-0-timed');
        expect(_key('training-log-exercise-0-set-0-reps'), findsNothing);
        expect(_saveEnabled(tester), isFalse);
        expect(
          find.text('Enter a duration for every timed exercise.'),
          findsOneWidget,
        );
        await _type(tester, 'training-log-exercise-0-minutes', '1');
        await _type(tester, 'training-log-exercise-0-seconds', '30');
        await _tap(tester, 'training-log-exercise-0-add-set');
        await _tap(tester, 'training-log-save');
        expect(
          recorder.saved.single.toRow(),
          _expectedFree(
            LoggedWorkoutDraft(
              title: '',
              performedOn: DateTime(2026, 10, 3),
              exercises: const [
                LoggedExercise(
                  name: 'Plank',
                  timed: true,
                  durationSeconds: 90,
                  sets: [LoggedSet(), LoggedSet()],
                ),
              ],
            ),
          ).toRow(),
        );
      });
    });

    testWidgets('remove keeps the other exercise and set values', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final recorder = await _open(tester);
        expect(_key('training-log-exercise-0-remove'), findsNothing);
        await _type(tester, 'training-log-exercise-0-name', 'Row');
        await _type(tester, 'training-log-exercise-0-set-0-reps', '10');
        await _tap(tester, 'training-log-add-exercise');
        await _type(tester, 'training-log-exercise-1-name', 'Curl');
        await _type(tester, 'training-log-exercise-1-set-0-reps', '12');
        await _tap(tester, 'training-log-exercise-1-add-set');
        await _type(tester, 'training-log-exercise-1-set-1-reps', '9');
        await _tap(tester, 'training-log-exercise-1-set-0-remove');
        await _tap(tester, 'training-log-exercise-0-remove');
        expect(_text(tester, 'training-log-exercise-0-name'), 'Curl');
        expect(_text(tester, 'training-log-exercise-0-set-0-reps'), '9');
        await _tap(tester, 'training-log-save');
        expect(
          recorder.saved.single.snapshot.workout.exercises.single.name,
          'Curl',
        );
        expect(recorder.saved.single.snapshot.actualSets.single.reps, 9);
      });
    });

    testWidgets('a double tap saves once; a retry reuses the ID', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final pending = Completer<TrainingLogSaveOutcome>();
        final calls = <TrainingHistoryEntry>[];
        final recorder = await _open(
          tester,
          onSave: (entry) {
            calls.add(entry);
            return calls.length == 1
                ? Future.value(TrainingLogSaveOutcome.failed)
                : pending.future;
          },
        );
        await _type(tester, 'training-log-exercise-0-name', 'Dips');
        await _type(tester, 'training-log-exercise-0-set-0-reps', '12');
        await _tap(tester, 'training-log-save');
        expect(calls, hasLength(1));
        expect(
          find.text('The workout could not be added. Try again.'),
          findsOneWidget,
        );
        expect(recorder.closed, isFalse);

        final save = _key('training-log-save');
        await tester.tap(save);
        await tester.tap(save, warnIfMissed: false);
        await tester.pump();
        expect(calls, hasLength(2), reason: 'single-flight');
        expect(calls.map((entry) => entry.id), [_id, _id]);
        pending.complete(TrainingLogSaveOutcome.queued);
        await tester.pumpAndSettle();
        expect(recorder.result, TrainingLogSaveOutcome.queued);
        expect(
          find.text(
            'Workout added to your history — the transfer will be retried '
            'automatically.',
          ),
          findsOneWidget,
        );
      });
    });

    testWidgets('an offline Add says it syncs once back online', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final recorder = await _open(
          tester,
          outcomes: const [TrainingLogSaveOutcome.queuedOffline],
        );
        await _type(tester, 'training-log-exercise-0-name', 'Dips');
        await _type(tester, 'training-log-exercise-0-set-0-reps', '12');
        await _tap(tester, 'training-log-save');
        expect(recorder.result, TrainingLogSaveOutcome.queuedOffline);
        expect(
          find.text(
            "Workout added to your history — will sync once you're back "
            'online.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('retried automatically'), findsNothing);
      });
    });

    testWidgets('deleted closes with "Removed from history"', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final recorder = await _open(
          tester,
          outcomes: const [TrainingLogSaveOutcome.deleted],
        );
        await _type(tester, 'training-log-exercise-0-name', 'Dips');
        await _type(tester, 'training-log-exercise-0-set-0-reps', '12');
        await _tap(tester, 'training-log-save');
        expect(recorder.result, TrainingLogSaveOutcome.deleted);
        expect(
          find.text("Removed from history. This workout can't be added again."),
          findsOneWidget,
        );
      });
    });

    testWidgets('dirty close asks first; Keep editing keeps the values', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final recorder = await _open(tester);
        await _tap(tester, 'training-log-close');
        expect(recorder.closed, isTrue, reason: 'nothing typed: just closes');

        await tester.tap(_key('open-log'));
        await tester.pumpAndSettle();
        await _type(tester, 'training-log-exercise-0-name', 'Dips');
        await _tap(tester, 'training-log-close');
        expect(_key('training-log-discard-dialog'), findsOneWidget);
        await tester.tap(find.text('Keep editing'));
        await tester.pumpAndSettle();
        expect(_text(tester, 'training-log-exercise-0-name'), 'Dips');
        await _tap(tester, 'training-log-close');
        await _tap(tester, 'training-log-discard-confirm');
        expect(_key('training-log-save'), findsNothing);
        expect(recorder.saved, isEmpty);
      });
    });

    testWidgets('a Coach draft opens prefilled for review', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final draft = LoggedWorkoutDraft(
          title: 'Push day',
          performedOn: DateTime(2026, 10, 1),
          durationMinutes: 50,
          note: 'Knee was fine',
          otherDaysOmitted: true,
          exercises: const [
            LoggedExercise(
              name: 'Bench press',
              timed: false,
              sets: [
                LoggedSet(reps: 8, weightKg: 80),
                LoggedSet(reps: 6, weightKg: 82.5),
              ],
            ),
            LoggedExercise(
              name: 'Plank',
              timed: true,
              durationSeconds: 75,
              sets: [LoggedSet()],
            ),
          ],
        );
        final recorder = await _open(
          tester,
          request: FreeLogRequest(
            historyId: _id,
            initial: draft,
            fromCoach: true,
          ),
        );
        expect(find.text('Review workout'), findsOneWidget);
        expect(
          find.text(
            'Check the values. Nothing is saved until you add the workout to '
            'your history.',
          ),
          findsOneWidget,
        );
        expect(_text(tester, 'training-log-title'), 'Push day');
        expect(find.text('Thu, Oct 1'), findsOneWidget);
        expect(_text(tester, 'training-log-exercise-0-set-1-weight'), '82.5');
        expect(_text(tester, 'training-log-exercise-1-minutes'), '1');
        expect(_text(tester, 'training-log-exercise-1-seconds'), '15');
        await _tap(tester, 'training-log-save');
        expect(recorder.saved.single.toRow(), _expectedFree(draft).toRow());
      });
    });

    testWidgets('a Coach draft without a date waits for one', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final recorder = await _open(
          tester,
          request: const FreeLogRequest(
            historyId: _id,
            fromCoach: true,
            initial: LoggedWorkoutDraft(
              title: 'Run',
              exercises: [
                LoggedExercise(
                  name: 'Run',
                  timed: true,
                  durationSeconds: 1800,
                  sets: [LoggedSet()],
                ),
              ],
            ),
          ),
        );
        expect(_saveEnabled(tester), isFalse);
        expect(
          find.text('Pick a day within the last 30 days.'),
          findsOneWidget,
        );
        await _tap(tester, 'training-log-day-today');
        expect(_saveEnabled(tester), isTrue);
        await _tap(tester, 'training-log-save');
        expect(recorder.saved, hasLength(1));
      });
    });

    testWidgets('a draft exercise without sets opens with one empty set', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final recorder = await _open(
          tester,
          request: FreeLogRequest(
            historyId: _id,
            fromCoach: true,
            initial: LoggedWorkoutDraft(
              title: 'Push',
              performedOn: DateTime(2026, 10, 3),
              exercises: const [
                LoggedExercise(name: 'Bench press', timed: false, sets: []),
              ],
            ),
          ),
        );
        expect(_text(tester, 'training-log-exercise-0-set-0-reps'), '');
        await _tap(tester, 'training-log-exercise-0-add-set');
        expect(_key('training-log-exercise-0-set-1-reps'), findsOneWidget);
        await _type(tester, 'training-log-exercise-0-set-0-reps', '8');
        await _type(tester, 'training-log-exercise-0-set-1-reps', '6');
        await _tap(tester, 'training-log-save');
        expect(
          recorder.saved.single.snapshot.actualSets.map((set) => set.reps),
          [8, 6],
        );
      });
    });

    testWidgets('a build failure stays in the sheet with Add usable', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        // Not a lowercase UUID: building the entry throws.
        final recorder = await _open(
          tester,
          request: const FreeLogRequest(historyId: 'Not-A-History-Id'),
        );
        await _type(tester, 'training-log-exercise-0-name', 'Dips');
        await _type(tester, 'training-log-exercise-0-set-0-reps', '12');
        await _tap(tester, 'training-log-save');
        expect(recorder.saved, isEmpty);
        expect(recorder.closed, isFalse);
        expect(
          find.text('The workout could not be added. Try again.'),
          findsOneWidget,
        );
        expect(_saveEnabled(tester), isTrue);
      });
    });
  });

  group('planned workout', () {
    PlanAttachedLogRequest request() =>
        PlanAttachedLogRequest(historyId: _id, plan: _plan(), workoutIndex: 0);

    testWidgets('fixed structure, prefilled values, one done set required', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final recorder = await _open(
          tester,
          request: request(),
          history: [
            _planSession(_otherId, DateTime(2026, 10, 1), [80, 80, 75]),
          ],
        );
        expect(find.text('Day A'), findsWidgets);
        expect(_key('training-log-add-exercise'), findsNothing);
        expect(_key('training-log-exercise-0-name'), findsNothing);
        for (final (set, kg) in const [(0, '80'), (1, '80'), (2, '75')]) {
          expect(_text(tester, 'training-log-planned-0-$set-reps'), '8');
          expect(_text(tester, 'training-log-planned-0-$set-weight'), kg);
        }
        expect(_key('training-log-planned-1-0-reps'), findsNothing);
        expect(_text(tester, 'training-log-planned-1-0-weight'), isEmpty);
        expect(_saveEnabled(tester), isTrue, reason: 'all sets start done');

        for (final key in [
          'training-log-planned-0-0-done',
          'training-log-planned-0-1-done',
          'training-log-planned-0-2-done',
          'training-log-planned-1-0-done',
          'training-log-planned-1-1-done',
        ]) {
          await _tap(tester, key);
        }
        expect(_saveEnabled(tester), isFalse);
        expect(find.text('Tick at least one set you did.'), findsOneWidget);
        await _tap(tester, 'training-log-planned-0-0-done');
        await _type(tester, 'training-log-planned-0-0-reps', '10');
        await _tap(tester, 'training-log-day-yesterday');
        await _tap(tester, 'training-log-save');

        final expected = buildPlanAttachedLog(
          historyId: _id,
          plan: _plan(),
          workoutIndex: 0,
          sets: const [
            [
              PlanAttachedSet(done: true, reps: 10, weightKg: 80),
              PlanAttachedSet(done: false, reps: 8, weightKg: 80),
              PlanAttachedSet(done: false, reps: 8, weightKg: 75),
            ],
            [PlanAttachedSet(done: false), PlanAttachedSet(done: false)],
          ],
          performedOn: DateTime(2026, 10, 2),
          now: _now,
        );
        expect(recorder.saved.single.toRow(), expected.toRow());
      });
    });

    testWidgets('a later weight follows an edited one until set by hand', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        await _open(tester, request: request());
        for (final set in [0, 1, 2]) {
          expect(_text(tester, 'training-log-planned-0-$set-weight'), isEmpty);
        }
        await _type(tester, 'training-log-planned-0-0-weight', '60');
        expect(_text(tester, 'training-log-planned-0-1-weight'), '60');
        expect(_text(tester, 'training-log-planned-0-2-weight'), '60');
        await _type(tester, 'training-log-planned-0-2-weight', '65');
        await _type(tester, 'training-log-planned-0-0-weight', '62,5');
        expect(_text(tester, 'training-log-planned-0-1-weight'), '62,5');
        expect(_text(tester, 'training-log-planned-0-2-weight'), '65');
      });
    });

    testWidgets('Last time skips a newer session without weights', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        await _open(
          tester,
          request: request(),
          history: [
            _planSession(_otherId, DateTime(2026, 9, 30), [80, 80, 75]),
            _planSession(_id2, DateTime(2026, 10, 2), [null, null, null]),
          ],
        );
        for (final (set, kg) in const [(0, '80'), (1, '80'), (2, '75')]) {
          expect(_text(tester, 'training-log-planned-0-$set-weight'), kg);
        }
      });
    });

    testWidgets('Last time set k by its set number, else its last set', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        // Set 1 skipped last time: it takes the last set's weight (set 3),
        // as the player does; not the first recorded one.
        await _open(
          tester,
          request: request(),
          history: [
            buildPlanAttachedLog(
              historyId: _otherId,
              plan: _plan(),
              workoutIndex: 0,
              sets: const [
                [
                  PlanAttachedSet(done: false),
                  PlanAttachedSet(done: true, reps: 8, weightKg: 60),
                  PlanAttachedSet(done: true, reps: 8, weightKg: 70),
                ],
                [PlanAttachedSet(done: true), PlanAttachedSet(done: true)],
              ],
              performedOn: DateTime(2026, 10, 1),
              now: _now,
            ),
          ],
        );
        for (final (set, kg) in const [(0, '70'), (1, '60'), (2, '70')]) {
          expect(_text(tester, 'training-log-planned-0-$set-weight'), kg);
        }
      });
    });

    testWidgets('without weight history nothing is prefilled', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        await _open(
          tester,
          request: request(),
          history: [
            _planSession(_otherId, DateTime(2026, 10, 2), [null, null, null]),
          ],
        );
        for (final set in [0, 1, 2]) {
          expect(_text(tester, 'training-log-planned-0-$set-weight'), isEmpty);
        }
      });
    });

    testWidgets('blocked shows the resume hint and keeps the sheet', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final recorder = await _open(
          tester,
          request: request(),
          outcomes: const [TrainingLogSaveOutcome.blocked],
        );
        await _tap(tester, 'training-log-save');
        expect(
          find.text(
            'A workout is in progress. Finish or discard it first, then log '
            'this one.',
          ),
          findsOneWidget,
        );
        expect(recorder.closed, isFalse);
        expect(recorder.saved.single.id, _id);
      });
    });
  });

  group('layout', () {
    for (final locale in ['de', 'en']) {
      for (final planned in [false, true]) {
        testWidgets(
          '${planned ? 'planned' : 'free'} editor reflows at 320 px and 2x '
          '($locale)',
          (tester) async {
            await withClock(Clock.fixed(_now), () async {
              await _open(
                tester,
                request: planned
                    ? PlanAttachedLogRequest(
                        historyId: _id,
                        plan: _plan(),
                        workoutIndex: 0,
                      )
                    : const FreeLogRequest(historyId: _id),
                history: [_benchLog()],
                locale: Locale(locale),
                size: const Size(320, 568),
                scale: 2,
              );
              if (!planned) {
                await _tap(tester, 'training-log-exercise-0-timed');
                await _tap(tester, 'training-log-add-exercise');
              }
              final scrollable = find.descendant(
                of: _key('training-log-scroll'),
                matching: find.byType(Scrollable),
              );
              for (var i = 0; i < 8; i++) {
                await tester.drag(scrollable.first, const Offset(0, -300));
                await tester.pumpAndSettle();
              }
              expect(tester.takeException(), isNull);
            });
          },
        );
      }
    }

    for (final planned in [false, true]) {
      testWidgets('the keyboard keeps the focused field '
          '(${planned ? 'planned' : 'free'})', (tester) async {
        await withClock(Clock.fixed(_now), () async {
          // 375 × 667: 655 px pinned without the keyboard, 395 px (whole
          // sheet scrolls) with a 260 px one.
          await _open(
            tester,
            request: planned
                ? PlanAttachedLogRequest(
                    historyId: _id,
                    plan: _plan(),
                    workoutIndex: 0,
                  )
                : const FreeLogRequest(historyId: _id),
            size: const Size(375, 667),
          );
          addTearDown(tester.view.resetViewInsets);
          final key = planned
              ? 'training-log-planned-0-0-weight'
              : 'training-log-exercise-0-name';
          final field = _key(key);
          final editable = find.descendant(
            of: field,
            matching: find.byType(EditableText),
          );
          await tester.showKeyboard(field);
          tester.testTextInput.enterText('62');
          await tester.pump();
          final state = tester.state<EditableTextState>(editable);
          bool headerScrolls() => find
              .descendant(
                of: _key('training-log-scroll'),
                matching: _key('training-log-close'),
              )
              .evaluate()
              .isNotEmpty;

          for (final (inset, compact) in const [
            (200.0, false),
            (260.0, true),
            (0.0, false),
          ]) {
            tester.view.viewInsets = FakeViewPadding(
              bottom: inset * tester.view.devicePixelRatio,
            );
            await tester.pumpAndSettle();
            expect(headerScrolls(), compact, reason: 'keyboard $inset');
            expect(
              tester.state<EditableTextState>(editable),
              same(state),
              reason: 'keyboard $inset',
            );
            expect(state.widget.focusNode.hasFocus, isTrue);
            expect(tester.testTextInput.hasAnyClients, isTrue);
            expect(_text(tester, key), '62');
            expect(
              tester.getRect(editable).bottom,
              lessThanOrEqualTo(667 - inset),
              reason: 'the focused field stays above the keyboard',
            );
          }
        });
      });
    }
  });

  group('trainingLogSaveOutcome', () {
    test('maps deliveries and store refusals', () async {
      expect(
        await trainingLogSaveOutcome(() async => SyncDelivery.delivered),
        TrainingLogSaveOutcome.saved,
      );
      // Review TUI-2: offline keeps its own outcome for the snack text.
      expect(
        await trainingLogSaveOutcome(() async => SyncDelivery.queuedOffline),
        TrainingLogSaveOutcome.queuedOffline,
      );
      expect(
        await trainingLogSaveOutcome(() async => SyncDelivery.queuedRetry),
        TrainingLogSaveOutcome.queued,
      );
      expect(
        await trainingLogSaveOutcome(
          () async => throw const TrainingCompletionDeleted(),
        ),
        TrainingLogSaveOutcome.deleted,
      );
      expect(
        await trainingLogSaveOutcome(
          () async => throw const TrainingLogBlockedBySession(),
        ),
        TrainingLogSaveOutcome.blocked,
      );
      expect(
        await trainingLogSaveOutcome(
          () async => throw StateError('Training history limit reached'),
        ),
        TrainingLogSaveOutcome.failed,
      );
    });
  });
}
