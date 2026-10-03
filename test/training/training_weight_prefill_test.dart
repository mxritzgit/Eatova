import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_insights.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:flutter_test/flutter_test.dart';

// Spec A2: the player's weight prefill reads "Last time", but a session
// logged without any weight (what the old blank-weight player produced) must
// not blank it. The Last-time display itself keeps showing that session.

final _start = DateTime.utc(2026, 9, 1, 18);

TrainingPlan _plan(String id, {String name = 'Bench press'}) => TrainingPlan(
  id: id,
  proposal: CoachTrainingProposal(
    title: 'Strength',
    workouts: [
      TrainingWorkout(
        title: 'Day A',
        exercises: [
          TrainingExercise(name: name, sets: 3, reps: 8, restSeconds: 90),
        ],
      ),
    ],
  ),
);

TrainingHistoryEntry _session(
  TrainingPlan plan,
  int day,
  List<double?> weights,
) {
  final startedAt = _start.add(Duration(days: day));
  final sets = [
    for (var s = 0; s < weights.length; s++)
      TrainingSetReference(exerciseIndex: 0, setIndex: s),
  ];
  return TrainingHistoryEntry(
    snapshot: TrainingSessionSnapshot(
      plan: plan,
      startedAt: startedAt,
      workoutIndex: 0,
      exerciseIndex: 0,
      setIndex: 2,
      phase: TrainingSessionPhase.review,
      remainingMilliseconds: 0,
      completedSets: sets,
      skippedSets: [
        for (var s = weights.length; s < 3; s++)
          TrainingSetReference(exerciseIndex: 0, setIndex: s),
      ],
      actualSets: [
        for (var s = 0; s < weights.length; s++)
          TrainingSetActual(
            reference: sets[s],
            completedAt: startedAt.add(Duration(minutes: s)),
            reps: 8,
            weightKg: weights[s],
          ),
      ],
    ),
    finishedAt: startedAt.add(const Duration(minutes: 30)),
  );
}

void main() {
  final plan = _plan('coach_strength');
  final bench = plan.workouts.single.exercises.single;

  List<double?> weights(List<TrainingHistoryEntry> history) => [
    for (final set in lastWeightedTrainingPerformanceFor(
      history,
      planId: plan.id,
      exercise: bench,
    ))
      set.weightKg,
  ];

  test('skips a newer session whose weights are all empty', () {
    final history = [
      _session(plan, 0, [60, 70, 80]),
      _session(plan, 2, [null, null, null]),
    ];
    expect(
      lastTrainingPerformanceFor(history, planId: plan.id, exercise: bench)
          .map((s) => s.weightKg),
      [null, null, null],
      reason: 'the Last-time display still shows the newest session',
    );
    expect(weights(history), [60, 70, 80]);
  });

  test('a partly weighted session still counts', () {
    final history = [
      _session(plan, 0, [60, 70, 80]),
      _session(plan, 2, [null, 75]),
    ];
    expect(weights(history), [null, 75]);
  });

  test('falls back to the same name in another plan, also past empty '
      'sessions', () {
    final other = _plan('manual_other', name: '  bench   PRESS ');
    final history = [
      _session(other, 0, [50, 55]),
      _session(other, 1, [null, null]),
      _session(plan, 3, [null, null, null]),
    ];
    expect(weights(history), [50, 55]);
  });

  test('without any weighted session there is nothing to prefill', () {
    expect(weights([_session(plan, 0, [null])]), isEmpty);
    expect(weights(const []), isEmpty);
  });

  test('Last time set k, or its last set beyond it', () {
    final sets = _session(plan, 0, [60, 70]).snapshot.actualSets;
    expect(lastTimeWeightForSet(sets, 0), 60);
    expect(lastTimeWeightForSet(sets, 1), 70);
    expect(lastTimeWeightForSet(sets, 2), 70);
    expect(lastTimeWeightForSet(const [], 0), isNull);
  });
}
