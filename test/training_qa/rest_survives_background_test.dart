import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/screens/training/training_player_screen.dart';
import 'package:eatova/src/services/rest_alerts.dart';
import 'package:eatova/src/services/screen_awake.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import '../training/training_timer_fixtures.dart';

// Review focus 1 (spec A4/A5): the phone is locked for longer than the rest,
// then unlocked. The next set is active, the rest did not freeze, and the
// one alert planned at rest start was the only one. Before 2026-10-03 any
// background paused the rest and nothing resumed it.

TrainingPlan _plan() => TrainingPlan(
  id: 'background_plan',
  proposal: CoachTrainingProposal(
    title: 'Strength',
    workouts: [
      TrainingWorkout(
        title: 'Day A',
        exercises: [
          TrainingExercise(name: 'Squat', sets: 3, reps: 5, restSeconds: 90),
        ],
      ),
    ],
  ),
);

/// The brief's case: a 45 s plank with a 60 s rest after each set.
TrainingPlan _planks() => TrainingPlan(
  id: 'background_planks',
  proposal: CoachTrainingProposal(
    title: 'Core',
    workouts: [
      TrainingWorkout(
        title: 'Day B',
        exercises: [
          TrainingExercise(
            name: 'Plank',
            sets: 2,
            durationSeconds: 45,
            restSeconds: 60,
          ),
        ],
      ),
    ],
  ),
);

final class _Alerts implements RestAlertScheduler {
  final log = <(String, DateTime?)>[];
  final scheduled = <({int id, DateTime at, String title, String body})>[];

  @override
  Future<void> scheduleRestAlert({
    required int id,
    required DateTime at,
    required String title,
    required String body,
  }) async {
    log.add(('schedule', at));
    scheduled.add((id: id, at: at, title: title, body: body));
  }

  @override
  Future<void> cancelRestAlert(int id) async => log.add(('cancel', null));
}

Future<void> _openPlayer(
  WidgetTester tester, {
  required TrainingPlan plan,
  required TimerTestClock time,
  required _Alerts alerts,
  required List<TrainingSessionSnapshot?> checkpoints,
}) async {
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => TrainingPlayerScreen(
              plan: plan,
              monotonicNow: time.now,
              restAlerts: alerts,
              screenAwake: const NoopScreenAwake(),
              onPersist: (value) async {
                checkpoints.add(value);
                return true;
              },
            ),
          ),
        ),
        child: const Text('Open'),
      ),
    ),
    locale: const Locale('en'),
    surfaceSize: const Size(393, 852),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void _lock(WidgetTester tester) {
  for (final state in const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void _unlock(WidgetTester tester) {
  for (final state in const [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void main() {
  testWidgets('a lock longer than the rest leaves the next set active, no '
      'Resume button and exactly one alert', (tester) async {
    final time = TimerTestClock();
    final alerts = _Alerts();
    final checkpoints = <TrainingSessionSnapshot?>[];
    await _openPlayer(
      tester,
      plan: _plan(),
      time: time,
      alerts: alerts,
      checkpoints: checkpoints,
    );

    await tester.tap(find.byKey(const ValueKey('training-set-check-0-0')));
    await tester.pump();
    final deadline = checkpoints.last!.phaseEndsAt!;
    expect(alerts.log.last, ('schedule', deadline));

    // Lock the phone: the app leaves the foreground.
    _lock(tester);
    await tester.pump();
    final whileLocked = List.of(alerts.log);
    expect(checkpoints.last!.phaseEndsAt, deadline, reason: 'not frozen');

    time.elapse(const Duration(seconds: 150));
    await tester.pump(const Duration(milliseconds: 300));
    expect(alerts.log, whileLocked, reason: 'nothing replanned while locked');

    _unlock(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('training-rest-bar')), findsNothing);
    expect(
      find.byKey(const ValueKey('training-timer-rest-resume')),
      findsNothing,
    );
    expect(checkpoints.last!.phase, TrainingSessionPhase.exercise);
    expect(checkpoints.last!.setIndex, 1);
    expect(checkpoints.last!.completedSets, hasLength(1));
    expect(
      tester.getSemantics(find.byKey(const ValueKey('training-set-check-0-1'))),
      matchesSemantics(
        label: 'Complete set 2',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    final schedules = alerts.log.where((entry) => entry.$1 == 'schedule');
    expect(schedules, [('schedule', deadline)], reason: 'exactly one alert');
    final scheduledAt = alerts.log.indexOf(('schedule', deadline));
    expect(alerts.log.sublist(scheduledAt, whileLocked.length), [
      ('schedule', deadline),
    ], reason: 'the alert was not cancelled before it fired');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // Final review P-1: the rest after a timed set starts only once the app
  // sees the interval end, so its alert must be planned at ▶ already.
  testWidgets('a lock during a timed set still alerts when the rest after it '
      'ends', (tester) async {
    final time = TimerTestClock();
    final alerts = _Alerts();
    final checkpoints = <TrainingSessionSnapshot?>[];
    await _openPlayer(
      tester,
      plan: _planks(),
      time: time,
      alerts: alerts,
      checkpoints: checkpoints,
    );

    await tester.tap(find.byKey(const ValueKey('training-set-check-0-0')));
    await tester.pump();
    final intervalEnds = checkpoints.last!.phaseEndsAt!;
    final restEnds = intervalEnds.add(const Duration(seconds: 60));

    _lock(tester);
    await tester.pump();
    final whileLocked = List.of(alerts.log);
    final planned = {for (final alert in alerts.scheduled) alert.at: alert};
    expect(planned.keys, unorderedEquals([intervalEnds, restEnds]));
    expect(
      (planned[intervalEnds]!.title, planned[intervalEnds]!.body),
      ("Time's up", 'Rest starts now.'),
    );
    expect(
      (planned[restEnds]!.title, planned[restEnds]!.body),
      ('Rest over', 'Time for your next set.'),
      reason: 'generic texts (D5)',
    );
    expect(
      planned[restEnds]!.id,
      isNot(planned[intervalEnds]!.id),
      reason: 'one alert never replaces the other',
    );
    expect(isRestAlertId(planned[restEnds]!.id), isTrue);
    final firstPlan = alerts.log.indexOf(('schedule', intervalEnds));
    expect(
      alerts.log.sublist(firstPlan).where((entry) => entry.$1 == 'cancel'),
      isEmpty,
      reason: 'neither alert is cancelled before it fires',
    );

    // Locked through the interval and the whole rest.
    time.elapse(const Duration(seconds: 3 + 45 + 60 + 5));
    await tester.pump(const Duration(milliseconds: 300));
    expect(alerts.log, whileLocked, reason: 'nothing replanned while locked');

    _unlock(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(checkpoints.last!.completedSets, hasLength(1));
    expect(checkpoints.last!.phase, TrainingSessionPhase.exercise);
    expect(checkpoints.last!.setIndex, 1, reason: 'waits for ▶');
    expect(checkpoints.last!.phaseEndsAt, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
