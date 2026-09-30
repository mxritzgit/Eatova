import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_insights.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/services/local_day.dart';

// Perf polish 2026-10-01: the week strip, the volume chart and "Last time"
// no longer convert every history entry to a local day (30-60 ms for 2000
// workouts) or copy and sort the whole history per exercise. These tests pin
// the new code to the previous, straightforward rules (the reference copies
// below) over randomised histories dense around week and day boundaries.

TrainingExercise _lift(String id, {bool timed = false}) => TrainingExercise(
  id: id,
  name: 'Exercise $id',
  sets: 3,
  reps: timed ? null : 8,
  durationSeconds: timed ? 30 : null,
  restSeconds: 60,
);

TrainingPlan _plan(String id) => TrainingPlan(
  id: id,
  proposal: CoachTrainingProposal(
    title: 'Plan $id',
    workouts: [
      TrainingWorkout(title: 'A', exercises: [_lift('a1'), _lift('a2')]),
      TrainingWorkout(
        title: 'B',
        exercises: [_lift('b1'), _lift('plank', timed: true)],
      ),
    ],
  ),
);

final _plans = [_plan('p1'), _plan('p2')];

TrainingHistoryEntry _entry(Random random, int i, DateTime finishedAt) {
  final plan = _plans[random.nextInt(_plans.length)];
  final workoutIndex = random.nextInt(plan.workouts.length);
  final workout = plan.workouts[workoutIndex];
  final start = finishedAt.subtract(const Duration(minutes: 40));
  final completed = <TrainingSetReference>[];
  final skipped = <TrainingSetReference>[];
  final actuals = <TrainingSetActual>[];
  for (var e = 0; e < workout.exercises.length; e++) {
    final exercise = workout.exercises[e];
    for (var s = 0; s < exercise.sets; s++) {
      final reference = TrainingSetReference(exerciseIndex: e, setIndex: s);
      // Some sets were skipped (no actual values).
      if (random.nextInt(5) == 0) {
        skipped.add(reference);
        continue;
      }
      completed.add(reference);
      actuals.add(
        TrainingSetActual(
          reference: reference,
          completedAt: start,
          weightKg: random.nextBool() ? 20.0 + random.nextInt(60) : null,
          reps: exercise.isTimed ? null : 1 + random.nextInt(12),
        ),
      );
    }
  }
  return TrainingHistoryEntry(
    snapshot: TrainingSessionSnapshot(
      plan: plan,
      sessionId: '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
      startedAt: start,
      actualSets: actuals,
      workoutIndex: workoutIndex,
      exerciseIndex: workout.exercises.length - 1,
      setIndex: workout.exercises.last.sets - 1,
      phase: TrainingSessionPhase.review,
      remainingMilliseconds: 0,
      completedSets: completed,
      skippedSets: skipped,
    ),
    finishedAt: finishedAt,
  );
}

/// A history of [count] workouts, newest first like the store keeps it.
/// Finish times cluster within four hours of local midnights, so the day and
/// week edges are exercised (entries store UTC instants).
List<TrainingHistoryEntry> _history(int seed, DateTime now, int count) {
  final random = Random(seed);
  final used = <DateTime>{};
  final entries = <TrainingHistoryEntry>[];
  for (var i = 0; i < count; i++) {
    DateTime at;
    do {
      final day = addDays(startOfDay(now), 14 - random.nextInt(80));
      at = day.add(Duration(minutes: random.nextInt(8 * 60) - 4 * 60));
      // Distinct instants: ties are pinned separately below.
    } while (!used.add(at.toUtc()));
    entries.add(_entry(random, i, at));
  }
  return entries..sort((a, b) => b.finishedAt.compareTo(a.finishedAt));
}

// --- Reference rules (the implementation before 2026-10-01) ---------------

DateTime _refLocalDay(DateTime instant) => startOfDay(instant.toLocal());

List<List<String>> _refWeek(DateTime now, List<TrainingHistoryEntry> history) {
  final start = startOfLocalWeek(now);
  final byDay = <String, List<TrainingHistoryEntry>>{};
  for (final entry in history) {
    byDay
        .putIfAbsent(localDayKey(_refLocalDay(entry.finishedAt)), () => [])
        .add(entry);
  }
  return [
    for (var i = 0; i < 7; i++)
      [
        for (final entry
            in [...?byDay[localDayKey(addDays(start, i))]]..sort((a, b) {
              final byTime = a.finishedAt.compareTo(b.finishedAt);
              return byTime != 0 ? byTime : a.id.compareTo(b.id);
            }))
          entry.id,
      ],
  ];
}

List<double> _refVolume(DateTime now, List<TrainingHistoryEntry> history) {
  final current = startOfLocalWeek(now);
  final starts = [for (var i = 5; i >= 0; i--) addDays(current, -7 * i)];
  final totals = <String, double>{
    for (final start in starts) localDayKey(start): 0,
  };
  for (final entry in history) {
    final key = localDayKey(startOfLocalWeek(entry.finishedAt));
    final sum = totals[key];
    if (sum != null) totals[key] = sum + trainingLoadKg(entry);
  }
  return [for (final start in starts) totals[localDayKey(start)]!];
}

List<TrainingSetActual> _refLast(
  List<TrainingHistoryEntry> history,
  String planId,
  String exerciseId, {
  required bool isTimed,
}) {
  final sorted = [...history]
    ..sort((a, b) => b.finishedAt.compareTo(a.finishedAt));
  for (final entry in sorted) {
    if (entry.snapshot.plan.id != planId) continue;
    final exercises = entry.snapshot.workout.exercises;
    final index = exercises.indexWhere(
      (e) => e.id == exerciseId && e.isTimed == isTimed,
    );
    if (index < 0) continue;
    final sets =
        entry.snapshot.actualSets
            .where((a) => a.reference.exerciseIndex == index)
            .toList()
          ..sort(
            (a, b) => a.reference.setIndex.compareTo(b.reference.setIndex),
          );
    if (sets.isNotEmpty) return sets;
  }
  return const [];
}

String _sets(List<TrainingSetActual> sets) => [
  for (final set in sets)
    '${set.reference.exerciseIndex}/${set.reference.setIndex}:'
        '${set.weightKg}x${set.reps}',
].join(',');

void main() {
  // Mondays, a Sunday night and the Europe DST weeks (end of March/October).
  final nows = [
    DateTime(2026, 9, 28, 0, 5),
    DateTime(2026, 10, 1, 18, 30),
    DateTime(2026, 10, 4, 23, 55),
    DateTime(2026, 10, 26, 9),
    DateTime(2027, 3, 29, 0, 30),
  ];

  test('trainingWeekOf matches the full-history rule', () {
    for (var seed = 0; seed < 12; seed++) {
      for (final now in nows) {
        final history = _history(seed, now, 120);
        final week = trainingWeekOf(now: now, history: history);
        expect(
          [
            for (final day in week.days)
              [for (final entry in day.sessions) entry.id],
          ],
          _refWeek(now, history),
          reason: 'seed $seed, now $now',
        );
      }
    }
  });

  test('trainingVolumeTrend matches the full-history rule', () {
    for (var seed = 0; seed < 12; seed++) {
      for (final now in nows) {
        final history = _history(seed, now, 120);
        expect(
          [
            for (final week in trainingVolumeTrend(
              history: history,
              now: now,
            ).weeks)
              week.volumeKg,
          ],
          _refVolume(now, history),
          reason: 'seed $seed, now $now',
        );
      }
    }
  });

  test('lastTrainingPerformance matches the sort-then-scan rule', () {
    final ids = [
      for (final plan in _plans)
        for (final workout in plan.workouts)
          for (final exercise in workout.exercises)
            (plan.id, exercise.id!, exercise.isTimed),
    ];
    for (var seed = 0; seed < 12; seed++) {
      final history = _history(seed, nows[1], 60);
      // The store keeps newest first; any other order must not matter.
      final shuffled = [...history]..shuffle(Random(seed));
      for (final (planId, exerciseId, timed) in ids) {
        for (final isTimed in [timed, !timed]) {
          final expected = _sets(
            _refLast(history, planId, exerciseId, isTimed: isTimed),
          );
          for (final input in [history, shuffled]) {
            expect(
              _sets(
                lastTrainingPerformance(
                  input,
                  planId,
                  exerciseId,
                  isTimed: isTimed,
                ),
              ),
              expected,
              reason: 'seed $seed, $planId/$exerciseId timed $isTimed',
            );
          }
        }
      }
    }
  });

  test('lastTrainingPerformance: a later session without sets is skipped; '
      'at equal finish times the first listed wins', () {
    final at = DateTime.utc(2026, 9, 30, 18);
    TrainingHistoryEntry performed(int i, double kg, DateTime finished) {
      final started = finished.subtract(const Duration(minutes: 40));
      return TrainingHistoryEntry(
        snapshot: TrainingSessionSnapshot(
          plan: _plans.first,
          sessionId: '00000000-0000-4000-8000-${'$i'.padLeft(12, '0')}',
          startedAt: started,
          actualSets: [
            TrainingSetActual(
              reference: const TrainingSetReference(
                exerciseIndex: 0,
                setIndex: 0,
              ),
              completedAt: started,
              weightKg: kg,
              reps: 5,
            ),
          ],
          workoutIndex: 0,
          exerciseIndex: 1,
          setIndex: 2,
          phase: TrainingSessionPhase.review,
          remainingMilliseconds: 0,
          completedSets: const [
            TrainingSetReference(exerciseIndex: 0, setIndex: 0),
          ],
          skippedSets: [
            for (var e = 0; e < 2; e++)
              for (var s = 0; s < 3; s++)
                if (e != 0 || s != 0)
                  TrainingSetReference(exerciseIndex: e, setIndex: s),
          ],
        ),
        finishedAt: finished,
      );
    }

    final first = performed(1, 60, at);
    final tie = performed(2, 70, at);
    final older = performed(3, 50, at.subtract(const Duration(days: 2)));
    final skipped = TrainingHistoryEntry(
      snapshot: TrainingSessionSnapshot(
        plan: _plans.first,
        sessionId: '00000000-0000-4000-8000-000000000099',
        startedAt: at,
        workoutIndex: 0,
        exerciseIndex: 1,
        setIndex: 2,
        phase: TrainingSessionPhase.review,
        remainingMilliseconds: 0,
        skippedSets: [
          for (var e = 0; e < 2; e++)
            for (var s = 0; s < 3; s++)
              TrainingSetReference(exerciseIndex: e, setIndex: s),
        ],
      ),
      finishedAt: at.add(const Duration(days: 1)),
    );
    double? kg(List<TrainingHistoryEntry> history) => lastTrainingPerformance(
      history,
      'p1',
      'a1',
      isTimed: false,
    ).single.weightKg;

    expect(kg([skipped, first, tie, older]), 60);
    expect(kg([skipped, tie, first, older]), 70);
    expect(kg([older, skipped]), 50);
  });
}
