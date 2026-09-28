import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_insights.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';

// Training derivations of the dark redesign (Task 7): rotation-based next
// workout, the Mon–Sun week, weekly volume and personal records. All dates
// are LOCAL; the history stores UTC, so the rules must convert.

TrainingExercise _lift(String id, {int sets = 3, int reps = 8}) =>
    TrainingExercise(
      id: id,
      name: 'Exercise $id',
      sets: sets,
      reps: reps,
      restSeconds: 90,
    );

final _push = TrainingWorkout(
  title: 'Upper Body Push',
  exercises: [
    _lift('bench', sets: 4),
    _lift('ohp'),
    TrainingExercise(
      id: 'plank',
      name: 'Plank',
      sets: 2,
      durationSeconds: 45,
      restSeconds: 30,
    ),
  ],
);
final _pull = TrainingWorkout(
  title: 'Upper Body Pull',
  exercises: [_lift('row'), _lift('pullup')],
);
final _legs = TrainingWorkout(
  title: 'Lower Body',
  exercises: [_lift('squat'), _lift('rdl')],
);

final _plan = TrainingPlan(
  id: 'ppl',
  proposal: CoachTrainingProposal(
    title: 'Strength plan',
    workouts: [_push, _pull, _legs],
  ),
);

/// One exercise, one set: a session's load is exactly weight x reps.
final _volumePlan = TrainingPlan(
  id: 'volume',
  proposal: CoachTrainingProposal(
    title: 'Volume',
    workouts: [
      TrainingWorkout(title: 'Lift', exercises: [_lift('lift', sets: 1)]),
    ],
  ),
);

var _sessionCounter = 0;

/// A completed session of [plan]'s workout [workoutIndex]. [sets] maps an
/// exercise id to (weight, reps) per set, cycled over the planned sets;
/// unlisted exercises are performed without weight at the planned reps.
TrainingHistoryEntry _session(
  TrainingPlan plan,
  int workoutIndex, {
  required DateTime start,
  Duration length = const Duration(minutes: 50),
  Map<String, List<(double?, int?)>> sets = const {},
}) {
  final workout = plan.workouts[workoutIndex];
  final completed = <TrainingSetReference>[];
  final actuals = <TrainingSetActual>[];
  final doneAt = start.add(const Duration(seconds: 30));
  for (var e = 0; e < workout.exercises.length; e++) {
    final exercise = workout.exercises[e];
    final values = sets[exercise.id];
    for (var s = 0; s < exercise.sets; s++) {
      final reference = TrainingSetReference(exerciseIndex: e, setIndex: s);
      final value = values?[s % values.length];
      completed.add(reference);
      actuals.add(
        TrainingSetActual(
          reference: reference,
          completedAt: doneAt,
          weightKg: value?.$1,
          reps: exercise.isTimed ? null : (value?.$2 ?? exercise.reps),
        ),
      );
    }
  }
  final last = workout.exercises.length - 1;
  _sessionCounter++;
  return TrainingHistoryEntry(
    snapshot: TrainingSessionSnapshot(
      plan: plan,
      sessionId:
          '00000000-0000-4000-8000-${_sessionCounter.toString().padLeft(12, '0')}',
      startedAt: start,
      actualSets: actuals,
      workoutIndex: workoutIndex,
      exerciseIndex: last,
      setIndex: workout.exercises[last].sets - 1,
      phase: TrainingSessionPhase.review,
      remainingMilliseconds: 0,
      completedSets: completed,
    ),
    finishedAt: start.add(length),
  );
}

TrainingHistoryEntry _lifted(DateTime start, double kg, int reps) => _session(
  _volumePlan,
  0,
  start: start,
  sets: {
    'lift': [(kg, reps)],
  },
);

void main() {
  // Monday of the design week.
  final monday = DateTime(2026, 9, 28, 18, 30);

  group('startOfLocalWeek', () {
    test('Monday to Sunday map to the same Monday', () {
      for (var day = 28; day <= 30; day++) {
        expect(
          startOfLocalWeek(DateTime(2026, 9, day, 23, 59)),
          DateTime(2026, 9, 28),
        );
      }
      expect(
        startOfLocalWeek(DateTime(2026, 10, 4, 23, 59)),
        DateTime(2026, 9, 28),
      );
      expect(startOfLocalWeek(DateTime(2026, 10, 5)), DateTime(2026, 10, 5));
    });

    test('across the October DST switch and from a UTC instant', () {
      // Sunday 2026-10-25 is 25 h long in Europe; the week still starts on
      // the Monday before at local midnight.
      expect(
        startOfLocalWeek(DateTime(2026, 10, 25, 12)),
        DateTime(2026, 10, 19),
      );
      final utc = DateTime(2026, 10, 4, 12).toUtc();
      expect(startOfLocalWeek(utc), DateTime(2026, 9, 28));
    });
  });

  group('topTrainingSet', () {
    TrainingSetActual set(int index, double? kg, int? reps) =>
        TrainingSetActual(
          reference: TrainingSetReference(exerciseIndex: 0, setIndex: index),
          completedAt: DateTime.utc(2026, 9, 1),
          weightKg: kg,
          reps: reps,
        );

    test('heaviest, then most reps, then the earlier set', () {
      final top = topTrainingSet([
        set(0, 70, 8),
        set(1, 75, 6),
        set(2, 75, 5),
        set(3, 75, 6),
      ])!;
      expect((top.weightKg, top.reps, top.reference.setIndex), (75, 6, 1));
    });

    test('bodyweight ranks by reps; nothing gives null', () {
      final top = topTrainingSet([set(0, null, 8), set(1, null, 10)])!;
      expect(top.reps, 10);
      expect(topTrainingSet(const []), isNull);
    });
  });

  group('nextTrainingWorkout', () {
    test('no plan -> null; never trained -> first workout', () {
      expect(
        nextTrainingWorkout(plan: null, history: const [], now: monday),
        isNull,
      );
      final next = nextTrainingWorkout(
        plan: _plan,
        history: const [],
        now: monday,
      )!;
      expect(next.workoutIndex, 0);
      expect(next.title, 'Upper Body Push');
      expect(next.completedToday, isFalse);
      expect(next.exerciseCount, 3);
      expect(next.exercises.map((e) => e.exercise.id), [
        'bench',
        'ohp',
        'plank',
      ]);
      expect(next.exercises.every((e) => e.lastTopSet == null), isTrue);
      // 4x8 reps (96 s + 3x90 s) + 3x8 (72 s + 2x90 s) + 2x45 s (+30 s).
      expect(next.estimatedMinutes, 12);
    });

    test('rotates after the last session of this plan and wraps', () {
      final push = _session(_plan, 0, start: DateTime(2026, 9, 21, 18));
      final pull = _session(_plan, 1, start: DateTime(2026, 9, 23, 18));
      final legs = _session(_plan, 2, start: DateTime(2026, 9, 25, 18));
      expect(
        nextTrainingWorkout(
          plan: _plan,
          history: [push],
          now: monday,
        )!.workoutIndex,
        1,
      );
      // Order of the history list does not matter.
      expect(
        nextTrainingWorkout(
          plan: _plan,
          history: [legs, push, pull],
          now: monday,
        )!.workoutIndex,
        0,
      );
    });

    test('a session finished today keeps that workout, marked done', () {
      final pullToday = _session(_plan, 1, start: DateTime(2026, 9, 28, 7));
      final next = nextTrainingWorkout(
        plan: _plan,
        history: [pullToday],
        now: monday,
      )!;
      expect(next.workoutIndex, 1);
      expect(next.completedToday, isTrue);
    });

    test('another plan\'s sessions do not move the rotation', () {
      final other = TrainingPlan(id: 'other', proposal: _plan.proposal);
      final foreign = _session(other, 1, start: DateTime(2026, 9, 27, 18));
      final next = nextTrainingWorkout(
        plan: _plan,
        history: [foreign],
        now: monday,
      )!;
      expect(next.workoutIndex, 0);
      // "Last time" is plan-scoped too: the foreign bench never counts.
      expect(next.exercises.first.lastTopSet, isNull);
    });

    test('an edited, reordered plan maps by exercise identity', () {
      final push = _session(_plan, 0, start: DateTime(2026, 9, 25, 18));
      final reordered = TrainingPlan(
        id: 'ppl',
        proposal: _plan.proposal.copyWith(workouts: [_pull, _legs, _push]),
      );
      final next = nextTrainingWorkout(
        plan: reordered,
        history: [push],
        now: monday,
      )!;
      // Push now sits at index 2, so the next workout wraps to Pull (0).
      expect(next.workoutIndex, 0);
      expect(next.title, 'Upper Body Pull');
    });

    test('an unmappable session restarts the rotation', () {
      final older = TrainingPlan(
        id: 'ppl',
        proposal: CoachTrainingProposal(
          title: 'Old',
          workouts: [
            TrainingWorkout(title: 'A', exercises: [_lift('a1')]),
            TrainingWorkout(title: 'B', exercises: [_lift('b1')]),
            TrainingWorkout(title: 'C', exercises: [_lift('c1')]),
            TrainingWorkout(title: 'D', exercises: [_lift('d1')]),
          ],
        ),
      );
      final gone = _session(older, 3, start: DateTime(2026, 9, 27, 18));
      final next = nextTrainingWorkout(
        plan: _plan,
        history: [gone],
        now: monday,
      )!;
      expect(next.workoutIndex, 0);
      expect(next.completedToday, isFalse);
    });

    test('previews carry the top set of the last performance', () {
      final older = _session(
        _plan,
        0,
        start: DateTime(2026, 9, 14, 18),
        sets: {
          'bench': [(80, 3)],
        },
      );
      final last = _session(
        _plan,
        0,
        start: DateTime(2026, 9, 21, 18),
        sets: {
          'bench': [(70, 8), (75, 8), (75, 6), (70, 8)],
          'ohp': [(45, 8)],
        },
      );
      final pull = _session(_plan, 1, start: DateTime(2026, 9, 23, 18));
      final legs = _session(_plan, 2, start: DateTime(2026, 9, 25, 18));
      final next = nextTrainingWorkout(
        plan: _plan,
        history: [older, last, pull, legs],
        now: monday,
      )!;
      expect(next.workoutIndex, 0);
      final bench = next.exercises[0].lastTopSet!;
      // The LAST session counts, not the all-time heaviest (80 kg x 3).
      expect((bench.weightKg, bench.reps), (75, 8));
      expect(next.exercises[1].lastTopSet!.weightKg, 45);
      // Timed plank: performed, no weight, no reps.
      final plank = next.exercises[2].lastTopSet!;
      expect((plank.weightKg, plank.reps), (null, null));
    });
  });

  group('trainingWeekOf', () {
    final thursday = DateTime(2026, 10, 1, 12);
    final history = [
      _session(_plan, 0, start: DateTime(2026, 9, 27, 18)), // last week
      _session(_plan, 1, start: DateTime(2026, 9, 28, 7)),
      _session(_plan, 2, start: DateTime(2026, 9, 30, 20)),
      _session(_plan, 0, start: DateTime(2026, 9, 30, 7)),
      _session(_plan, 1, start: DateTime(2026, 10, 5, 7)), // next week
    ];

    test('seven local days from Monday with the sessions of each day', () {
      final week = trainingWeekOf(now: thursday, history: history, plan: _plan);
      expect(week.start, DateTime(2026, 9, 28));
      expect(week.end, DateTime(2026, 10, 4));
      expect(week.days.map((d) => d.date.day), [28, 29, 30, 1, 2, 3, 4]);
      expect(week.days.map((d) => d.done), [
        true,
        false,
        true,
        false,
        false,
        false,
        false,
      ]);
      expect(week.days.map((d) => d.isToday), [
        false,
        false,
        false,
        true,
        false,
        false,
        false,
      ]);
      // Two sessions on Wednesday, oldest first.
      expect(week.days[2].sessions.map((e) => e.snapshot.workoutIndex), [0, 2]);
      expect(week.doneSessions, 3);
      expect(week.plannedSessions, 3);
    });

    test('without a plan nothing is planned; an empty history is a week', () {
      final week = trainingWeekOf(now: thursday, history: const []);
      expect(week.plannedSessions, isNull);
      expect(week.doneSessions, 0);
      expect(week.days, hasLength(7));
    });

    test('a session is filed under the local day it finished', () {
      // Started Sunday 23:30, finished Monday 00:20.
      final late = _session(
        _plan,
        0,
        start: DateTime(2026, 9, 27, 23, 30),
        length: const Duration(minutes: 50),
      );
      final week = trainingWeekOf(now: thursday, history: [late]);
      expect(week.days.first.done, isTrue);
    });
  });

  group('trainingLoadKg', () {
    test('weight x reps over weighted sets only', () {
      final entry = _session(
        _plan,
        0,
        start: DateTime(2026, 9, 21, 18),
        sets: {
          'bench': [(70, 8), (75, 6), (0, 10), (80, 0)],
          'ohp': [(null, 8)],
          'plank': [(10, null)],
        },
      );
      // 560 + 450; zero weight, zero reps, bodyweight and timed sets add 0.
      expect(trainingLoadKg(entry), 1010);
    });
  });

  group('trainingVolumeTrend', () {
    test('design scenario: 8.6 t last week, +9 % vs the week before', () {
      final history = [
        _lifted(DateTime(2026, 9, 22, 18), 100, 43),
        _lifted(DateTime(2026, 9, 25, 18), 100, 43),
        _lifted(DateTime(2026, 9, 15, 18), 789, 10),
        _lifted(DateTime(2026, 8, 24, 18), 500, 10),
        _lifted(DateTime(2026, 8, 17, 18), 999, 10), // before the window
        _lifted(DateTime(2026, 9, 28, 7), 25, 10), // current week
      ];
      final trend = trainingVolumeTrend(history: history, now: monday);
      expect(trend.weeks.map((w) => w.start), [
        DateTime(2026, 8, 24),
        DateTime(2026, 8, 31),
        DateTime(2026, 9, 7),
        DateTime(2026, 9, 14),
        DateTime(2026, 9, 21),
        DateTime(2026, 9, 28),
      ]);
      expect(trend.weeks.map((w) => w.volumeKg), [5000, 0, 0, 7890, 8600, 250]);
      expect(trend.weeks.map((w) => w.isCurrent), [
        false,
        false,
        false,
        false,
        false,
        true,
      ]);
      expect(trend.lastFullWeek!.tonnes, closeTo(8.6, 1e-9));
      expect(trend.currentWeek.volumeKg, 250);
      expect(trend.changePercent!.round(), 9);
    });

    test('no earlier volume -> no percentage; empty history -> zeros', () {
      final trend = trainingVolumeTrend(
        history: [_lifted(DateTime(2026, 9, 22, 18), 100, 10)],
        now: monday,
      );
      expect(trend.lastFullWeek!.volumeKg, 1000);
      expect(trend.changePercent, isNull);
      final empty = trainingVolumeTrend(history: const [], now: monday);
      expect(empty.weeks, hasLength(6));
      expect(empty.weeks.every((w) => w.volumeKg == 0), isTrue);
      expect(empty.changePercent, isNull);
      // A shorter window still works; one full week has no comparison.
      final short = trainingVolumeTrend(
        history: const [],
        now: monday,
        fullWeeks: 1,
      );
      expect(short.weeks, hasLength(2));
      expect(short.changePercent, isNull);
    });

    test('weeks follow local days across the DST switch', () {
      final history = [
        // Sunday of the 25-hour day belongs to the week of Oct 19.
        _lifted(DateTime(2026, 10, 25, 23), 100, 10),
        _lifted(DateTime(2026, 10, 26, 0, 30), 50, 10),
      ];
      final trend = trainingVolumeTrend(
        history: history,
        now: DateTime(2026, 10, 27),
        fullWeeks: 1,
      );
      expect(trend.weeks.map((w) => w.start), [
        DateTime(2026, 10, 19),
        DateTime(2026, 10, 26),
      ]);
      expect(trend.weeks.map((w) => w.volumeKg), [1000, 500]);
    });
  });

  group('personal records', () {
    final s1 = _session(
      _plan,
      0,
      start: DateTime(2026, 9, 1, 18),
      sets: {
        'bench': [(70, 8)],
      },
    );
    final s2 = _session(
      _plan,
      0,
      start: DateTime(2026, 9, 8, 18),
      sets: {
        'bench': [(72.5, 8)], // better estimate
        'ohp': [(40, 8)], // first time: baseline only
      },
    );
    final s3 = _session(
      _plan,
      0,
      start: DateTime(2026, 9, 15, 18),
      sets: {
        'bench': [(75, 5)], // lower estimate, heavier weight
        'ohp': [(45, 8)], // better estimate
      },
    );
    final s4 = _session(
      _plan,
      0,
      start: DateTime(2026, 9, 22, 18),
      sets: {
        'bench': [(72.5, 8)], // ties the best estimate: no record
        'ohp': [(45, 8)],
      },
    );

    test('first time is a baseline; estimate or weight beats earlier', () {
      final counts = personalRecordCounts([s4, s2, s1, s3]);
      expect(counts[s1.id], 0);
      expect(counts[s2.id], 1);
      expect(counts[s3.id], 2);
      expect(counts[s4.id], 0);
    });

    test('records are plan-scoped and skip unweighted sets', () {
      final copy = TrainingPlan(id: 'ppl_copy', proposal: _plan.proposal);
      final heavierInCopy = _session(
        copy,
        0,
        start: DateTime(2026, 9, 29, 18),
        sets: {
          'bench': [(100, 8)],
        },
      );
      final bodyweight = _session(
        _plan,
        1,
        start: DateTime(2026, 9, 2, 18),
        sets: {
          'pullup': [(null, 8)],
        },
      );
      final moreReps = _session(
        _plan,
        1,
        start: DateTime(2026, 9, 9, 18),
        sets: {
          'pullup': [(null, 12)],
        },
      );
      final counts = personalRecordCounts([
        s1,
        s2,
        heavierInCopy,
        bodyweight,
        moreReps,
      ]);
      expect(counts[heavierInCopy.id], 0);
      expect(counts[moreReps.id], 0);
    });

    test('estimatedOneRepMaxKg is Epley, a single rep is the weight', () {
      expect(estimatedOneRepMaxKg(100, 1), 100);
      expect(estimatedOneRepMaxKg(100, 10), closeTo(133.33, 0.01));
      expect(estimatedOneRepMaxKg(75, 5), closeTo(87.5, 1e-9));
    });

    test('recentTrainingWorkouts: newest first, limited, with PRs', () {
      final recent = recentTrainingWorkouts([s1, s3, s2, s4], limit: 3);
      expect(recent.map((r) => r.entry.id), [s4.id, s3.id, s2.id]);
      expect(recent.map((r) => r.personalRecords), [0, 2, 1]);
      expect(recent.first.title, 'Upper Body Push');
      expect(recent.first.duration, const Duration(minutes: 50));
      expect(recent.first.finishedAt, s4.finishedAt);
      // Bench 4 x 72.5 x 8 + ohp 3 x 45 x 8.
      expect(recent.first.volumeKg, 2320 + 1080);
      expect(recentTrainingWorkouts(const []), isEmpty);
      expect(recentTrainingWorkouts([s1], limit: 0), isEmpty);
    });
  });
}
