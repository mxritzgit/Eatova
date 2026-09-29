// The dark redesign's Training scenario (design/training/template.html) as
// real models: a three-workout "Strength plan" and five weeks of finished
// workouts before Monday 2026-09-28, so the store derives what the design
// shows — "Upper Body Push" next with "Last time 75 kg × 8", 0 of 3 done this
// week, 6.8 / 7.4 / 7.1 / 7.9 / 8.6 tonnes per week (↑ 9 %), and Lower Body
// (Fri, 52 min, 2 PRs), Upper Body Pull (Wed, 47 min), Upper Body Push (Mon,
// 49 min) as the recent workouts.

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import '../fixlauf_a_helpers.dart';
import '../flows/flow_test_helpers.dart' show settleFrames, storeOf;
import '../support/design_capture.dart';
import '../support/harness.dart';

/// The design's "today": Monday of the week Sep 28 – Oct 4, 19:00 local.
final DateTime kTrainingDesignNow = DateTime(2026, 9, 28, 19);

const String kTrainingDesignPlanId = 'strength-plan';

TrainingExercise _exercise(
  String id,
  String name,
  int sets,
  int reps,
  int rest,
) => TrainingExercise(
  id: id,
  name: name,
  sets: sets,
  reps: reps,
  restSeconds: rest,
);

/// Push (six exercises, ≈ 50 min), Pull and Lower Body.
TrainingPlan trainingDesignPlan() => TrainingPlan(
  id: kTrainingDesignPlanId,
  proposal: CoachTrainingProposal(
    title: 'Strength plan',
    workouts: [
      TrainingWorkout(
        title: 'Upper Body Push',
        exercises: [
          _exercise('bench', 'Bench press', 4, 8, 240),
          _exercise('ohp', 'Overhead press', 3, 8, 180),
          _exercise('incline', 'Incline dumbbell press', 3, 10, 180),
          _exercise('fly', 'Cable fly', 3, 12, 150),
          _exercise('lateral', 'Lateral raise', 3, 15, 150),
          _exercise('pushdown', 'Triceps pushdown', 3, 12, 180),
        ],
      ),
      TrainingWorkout(
        title: 'Upper Body Pull',
        exercises: [
          _exercise('row', 'Barbell row', 3, 8, 120),
          _exercise('pulldown', 'Lat pulldown', 3, 10, 120),
          _exercise('facepull', 'Face pull', 3, 15, 90),
          _exercise('curl', 'Biceps curl', 3, 12, 90),
        ],
      ),
      TrainingWorkout(
        title: 'Lower Body',
        exercises: [
          _exercise('squat', 'Back squat', 3, 5, 180),
          _exercise('rdl', 'Romanian deadlift', 3, 8, 150),
          _exercise('legcurl', 'Leg curl', 3, 12, 90),
          _exercise('calf', 'Calf raise', 3, 15, 60),
        ],
      ),
    ],
  ),
);

var _sessionSerial = 0;

/// A finished workout of [plan]: every planned set done, the first set of
/// each exercise at `topKg[i]` (the best set) and the rest at [backOff] of
/// it, reps as planned.
TrainingHistoryEntry trainingDesignEntry(
  TrainingPlan plan,
  int workoutIndex, {
  required DateTime finishedAt,
  required int minutes,
  required List<double> topKg,
  double backOff = 0.8,
}) {
  final workout = plan.workouts[workoutIndex];
  final startedAt = finishedAt.subtract(Duration(minutes: minutes));
  final done = <TrainingSetReference>[];
  final actual = <TrainingSetActual>[];
  var minute = 1;
  for (var e = 0; e < workout.exercises.length; e++) {
    final exercise = workout.exercises[e];
    for (var s = 0; s < exercise.sets; s++) {
      final reference = TrainingSetReference(exerciseIndex: e, setIndex: s);
      done.add(reference);
      actual.add(
        TrainingSetActual(
          reference: reference,
          completedAt: startedAt.add(Duration(minutes: minute++)),
          reps: exercise.reps,
          weightKg: s == 0
              ? topKg[e]
              : (topKg[e] * backOff * 2).roundToDouble() / 2,
        ),
      );
    }
  }
  _sessionSerial++;
  final last = workout.exercises.length - 1;
  return TrainingHistoryEntry(
    snapshot: TrainingSessionSnapshot(
      plan: plan,
      sessionId:
          '00000000-0000-4000-8000-${_sessionSerial.toString().padLeft(12, '0')}',
      startedAt: startedAt,
      actualSets: actual,
      workoutIndex: workoutIndex,
      exerciseIndex: last,
      setIndex: workout.exercises[last].sets - 1,
      phase: TrainingSessionPhase.review,
      remainingMilliseconds: 0,
      completedSets: done,
    ),
    finishedAt: finishedAt,
  );
}

/// Five full weeks (Mon push, Wed pull, Fri legs) before [kTrainingDesignNow],
/// newest last. The back-off factor per week sets the design's tonnage; the
/// top sets stay flat except the last Lower Body (squat 95, RDL 85: 2 PRs).
List<TrainingHistoryEntry> trainingDesignHistory(TrainingPlan plan) {
  const push = [75.0, 45.0, 26.0, 10.0, 6.0, 15.0];
  const pull = [60.0, 50.0, 15.0, 12.0];
  const legs = [90.0, 80.0, 35.0, 40.0];
  const legsRecord = [95.0, 85.0, 35.0, 40.0];
  // Back-off share per week for 6.8, 7.4, 7.1, 7.9 and 8.6 t.
  const backOff = [0.1612, 0.2171, 0.1891, 0.2636, 0.3189];
  const minutes = [
    (50, 48, 51),
    (51, 46, 50),
    (48, 49, 53),
    (50, 47, 51),
    (49, 47, 52),
  ];
  final entries = <TrainingHistoryEntry>[];
  for (var w = 0; w < 5; w++) {
    final monday = DateTime(2026, 8, 24 + 7 * w);
    final (pushMin, pullMin, legsMin) = minutes[w];
    entries
      ..add(
        trainingDesignEntry(
          plan,
          0,
          finishedAt: monday.add(const Duration(hours: 18, minutes: 30)),
          minutes: pushMin,
          topKg: push,
          backOff: backOff[w],
        ),
      )
      ..add(
        trainingDesignEntry(
          plan,
          1,
          finishedAt: monday.add(
            const Duration(days: 2, hours: 18, minutes: 30),
          ),
          minutes: pullMin,
          topKg: pull,
          backOff: backOff[w],
        ),
      )
      ..add(
        trainingDesignEntry(
          plan,
          2,
          finishedAt: monday.add(
            const Duration(days: 4, hours: 18, minutes: 30),
          ),
          minutes: legsMin,
          topKg: w == 4 ? legsRecord : legs,
          backOff: backOff[w],
        ),
      );
  }
  return entries;
}

/// Signs the real home page in against a fake backend that holds [plans]
/// and [history], at the design's reference geometry (390x844, iPhone safe
/// areas), and waits until the boot load has adopted both.
///
/// The history response exceeds postgrest's 10 kB isolate threshold, so the
/// wait lets real time pass (`runAsync`) for the JSON isolate to answer.
Future<({HomeStore store, FixlaufServer server})> pumpTrainingDesignHome(
  WidgetTester tester, {
  List<TrainingPlan>? plans,
  List<TrainingHistoryEntry>? history,
  Locale locale = const Locale('en'),
}) async {
  pinDesignViewport(tester);
  final plan = trainingDesignPlan();
  final server = FixlaufServer()
    ..profileRow = serverProfileRow(completedProfile);
  for (final p in plans ?? [plan]) {
    server.trainingRows[p.id] = p.toRow();
  }
  final entries = history ?? trainingDesignHistory(plan);
  for (final entry in entries) {
    server.trainingHistoryRows[entry.id] = entry.toRow();
  }
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: server.client(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        EatovaHomePage(
          sync: EatovaSync.forUser(client, kFixlaufUser),
          debugCache: LocalCache(InMemoryKeyValueStore(), kFixlaufUser),
        ),
        locale: locale,
        safeArea: false,
        scaffold: false,
      ),
    ),
  );
  await pumpRealUntil(
    tester,
    () => find.byKey(const ValueKey('screen-welcome')).evaluate().isEmpty,
    'the account is ready',
  );
  final store = storeOf(tester);
  await pumpRealUntil(
    tester,
    () =>
        !store.bootLoadInFlight &&
        store.trainingHistory.length == entries.length,
    'plans and history are loaded',
  );
  return (store: store, server: server);
}

/// [pumpUntil] with real time between frames, for isolate-backed work.
Future<void> pumpRealUntil(
  WidgetTester tester,
  bool Function() done,
  String what,
) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(done(), isTrue, reason: '$what did not happen');
  await settleFrames(tester);
}
