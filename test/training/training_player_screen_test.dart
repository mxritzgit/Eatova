import 'dart:async';

import 'package:clock/clock.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/screens/training/player/player_set_row.dart';
import 'package:eatova/src/screens/training/training_player_screen.dart';
import 'package:eatova/src/services/rest_alerts.dart';
import 'package:eatova/src/services/screen_awake.dart';
import 'package:eatova/src/services/training_session_controller.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'training_timer_fixtures.dart';

// The list player (spec A1–A7, Option L, decision D1). Supersedes the hero
// player's tests: Start gate for repetitions, pause on background/cover, no
// auto-resume, no notifications (spec §4).

TrainingPlan _strength() => TrainingPlan(
  id: 'player_strength',
  proposal: CoachTrainingProposal(
    title: 'Strength',
    workouts: [
      TrainingWorkout(
        title: 'Day A',
        exercises: [
          for (final name in ['Squat', 'Bench', 'Row', 'Press'])
            TrainingExercise(name: name, sets: 3, reps: 8, restSeconds: 60),
        ],
      ),
    ],
  ),
);

/// Two exercises; the first one has a single set.
TrainingPlan _pair({int secondSets = 1}) => TrainingPlan(
  id: 'player_pair',
  proposal: CoachTrainingProposal(
    title: 'Pair',
    workouts: [
      TrainingWorkout(
        title: 'Day B',
        exercises: [
          TrainingExercise(name: 'Squat', sets: 1, reps: 8, restSeconds: 60),
          TrainingExercise(
            name: 'Bench',
            sets: secondSets,
            reps: 8,
            restSeconds: 60,
          ),
        ],
      ),
    ],
  ),
);

/// A repetition set whose rest leads into a timed set.
TrainingPlan _restIntoTimed() => TrainingPlan(
  id: 'player_rest_timed',
  proposal: CoachTrainingProposal(
    title: 'Mixed',
    workouts: [
      TrainingWorkout(
        title: 'Day C',
        exercises: [
          TrainingExercise(name: 'Squat', sets: 1, reps: 8, restSeconds: 10),
          TrainingExercise(
            name: 'Plank',
            sets: 1,
            durationSeconds: 20,
            restSeconds: 0,
          ),
        ],
      ),
    ],
  ),
);

/// Last time for [_strength]'s Squat: 60, 70 and 80 kg × 8.
TrainingHistoryEntry _squatHistory(TrainingPlan plan) {
  final previous = TrainingSessionController(plan: plan, autoTick: false);
  for (final weight in [60.0, 70.0, 80.0]) {
    previous.setCurrentActual(reps: 8, weightKg: weight);
    previous.completeActiveSet();
  }
  final entry = previous.completion();
  previous.dispose();
  return entry;
}

final class _Alerts implements RestAlertScheduler, RestAlertCue {
  final log = <String>[];
  final scheduled = <({int id, DateTime at, String title, String body})>[];
  final cancelled = <int>[];
  final cues = <({int id, String title, String body})>[];

  @override
  Future<void> cueRestAlert({
    required int id,
    required String title,
    required String body,
  }) async => cues.add((id: id, title: title, body: body));

  @override
  Future<void> scheduleRestAlert({
    required int id,
    required DateTime at,
    required String title,
    required String body,
  }) async {
    log.add('schedule');
    scheduled.add((id: id, at: at, title: title, body: body));
  }

  @override
  Future<void> cancelRestAlert(int id) async {
    log.add('cancel');
    cancelled.add(id);
  }
}

/// The original two-member gate, as other branches' fakes implement it: no
/// memory of a shown explainer.
class _PlainGate implements RestAlertPermissionGate {
  _PlainGate(this.value, {this.grant = true});
  RestAlertPermission value;
  final bool grant;
  int requests = 0;

  @override
  Future<RestAlertPermission> state() async => value;

  @override
  Future<bool> request() async {
    requests++;
    value = grant ? RestAlertPermission.granted : RestAlertPermission.denied;
    return grant;
  }
}

/// The device as [LocalNotificationService] keeps it: "explainer shown" and
/// "system prompt requested" are separate facts.
final class _Gate extends _PlainGate implements RestAlertExplainerMemory {
  _Gate(super.value, {super.grant});
  bool shown = false;
  int marks = 0;

  @override
  Future<bool> explainerShown() async => shown;

  @override
  Future<void> markExplainerShown() async {
    marks++;
    shown = true;
  }
}

/// A gate whose silent read fails.
final class _BrokenGate implements RestAlertPermissionGate {
  @override
  Future<RestAlertPermission> state() => Future.error(StateError('gate'));

  @override
  Future<bool> request() async => false;
}

final class _Awake implements ScreenAwake {
  final calls = <(bool, String)>[];
  bool get on => calls.isNotEmpty && calls.last.$1;

  @override
  Future<void> setKeepAwake(bool on, {String owner = 'default'}) async =>
      calls.add((on, owner));
}

final class _Host {
  final writes = <TrainingSessionSnapshot?>[];
  final completed = <TrainingHistoryEntry>[];
  final alerts = _Alerts();
  final awake = _Awake();
  final clock = TimerTestClock();
  var taps = 0;
  var settings = 0;
}

Future<_Host> _open(
  WidgetTester tester, {
  TrainingPlan? plan,
  TrainingSessionSnapshot? snapshot,
  List<TrainingHistoryEntry> history = const [],
  Future<bool> Function(TrainingSessionSnapshot?)? persist,
  Future<void> Function(TrainingHistoryEntry)? complete,
  RestAlertPermissionGate? gate,
  TimerTestClock? clock,
  bool wallClock = false,
  Size size = const Size(393, 852),
  double scale = 1,
  String locale = 'en',
}) async {
  final host = _Host();
  final time = clock ?? host.clock;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      locale: Locale(locale),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => TrainingPlayerScreen(
                  plan: snapshot == null ? plan ?? _strength() : null,
                  initialSnapshot: snapshot,
                  history: history,
                  monotonicNow: wallClock ? null : time.now,
                  restAlerts: host.alerts,
                  alertPermission: gate,
                  screenAwake: host.awake,
                  openAlertSettings: () async => host.settings++,
                  onPersist:
                      persist ??
                      (value) async {
                        host.writes.add(value);
                        return true;
                      },
                  onComplete: (entry) async {
                    await complete?.call(entry);
                    host.completed.add(entry);
                    host.writes.add(null);
                  },
                ),
              ),
            ),
            child: const Text('Open fixture'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open fixture'));
  host.taps++;
  await tester.pumpAndSettle();
  return host;
}

Finder _key(String id) => find.byKey(ValueKey(id));

Future<void> _tap(WidgetTester tester, String id, [_Host? host]) async {
  await tester.ensureVisible(_key(id));
  await tester.pump();
  await tester.tap(_key(id));
  if (host != null) host.taps++;
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _menu(WidgetTester tester, String item) async {
  await _tap(tester, 'training-timer-menu');
  await tester.pumpAndSettle();
  await tester.tap(_key(item));
  await tester.pumpAndSettle();
}

Future<void> _exerciseMenu(
  WidgetTester tester,
  int exercise,
  String item,
) async {
  await _tap(tester, 'training-exercise-menu-$exercise');
  await tester.pumpAndSettle();
  await tester.tap(_key(item));
  await tester.pumpAndSettle();
}

Future<void> _elapse(WidgetTester tester, _Host host, Duration duration) async {
  host.clock.elapse(duration);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump();
}

void _lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
  for (final state in states) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

const _background = [
  AppLifecycleState.inactive,
  AppLifecycleState.hidden,
  AppLifecycleState.paused,
];
const _foreground = [
  AppLifecycleState.hidden,
  AppLifecycleState.inactive,
  AppLifecycleState.resumed,
];

_SetButton _check(WidgetTester tester, String id) =>
    _SetButton(tester, _key('training-set-check-$id'));

/// A row's ✓ / ▶: its spoken label and whether it reacts.
final class _SetButton {
  _SetButton(this.tester, this.finder);
  final WidgetTester tester;
  final Finder finder;
  String get label => tester.getSemantics(finder).label;
  bool get enabled => tester.widget<PlayerSetButton>(finder).onPressed != null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('one tap per set', () {
    testWidgets('a 4 × 3 workout takes 14 taps, open and save included', (
      tester,
    ) async {
      final host = await _open(tester);
      for (var e = 0; e < 4; e++) {
        for (var s = 0; s < 3; s++) {
          expect(_check(tester, '$e-$s').enabled, isTrue, reason: '$e-$s');
          await _tap(tester, 'training-set-check-$e-$s', host);
        }
      }
      await tester.pumpAndSettle();
      expect(host.alerts.log.last, 'cancel', reason: 'no rest after the last');
      expect(
        _key('training-finish-sheet'),
        findsOneWidget,
        reason: 'the finish sheet opens by itself after the last set',
      );
      await _tap(tester, 'training-finish-save', host);
      await tester.pumpAndSettle();
      expect(host.taps, 14);
      expect(host.completed.single.snapshot.completedSets, hasLength(12));
      expect(host.completed.single.snapshot.skippedSets, isEmpty);
      expect(find.text('Open fixture'), findsOneWidget);
    });

    testWidgets('only the active set can be checked; the others are visibly '
        'locked and ✓ is at least 56 dp', (tester) async {
      await _open(tester);
      expect(
        tester.getSize(_key('training-set-check-0-0')).width,
        greaterThanOrEqualTo(56),
      );
      expect(
        tester.getSize(_key('training-set-check-0-0')).height,
        greaterThanOrEqualTo(56),
      );
      expect(_check(tester, '0-1').enabled, isFalse);
      expect(_check(tester, '0-1').label, 'Set 2, not yet');
      expect(_check(tester, '0-0').label, 'Complete set 1');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('weights carry Last time into the rows and the ✓', (
      tester,
    ) async {
      final plan = _strength();
      final host = await _open(
        tester,
        plan: plan,
        history: [_squatHistory(plan)],
      );
      expect(
        tester
            .widget<TextField>(_key('training-set-weight-0-0'))
            .controller!
            .text,
        '60',
      );
      expect(find.text('70'), findsOneWidget, reason: 'upcoming prefill');
      await _tap(tester, 'training-set-check-0-0');
      await _tap(tester, 'training-set-check-0-1');
      expect(host.writes.last!.actualSets.map((a) => a.weightKg), [60, 70]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('copying Last time into a focused field shows what ✓ saves', (
      tester,
    ) async {
      final plan = _strength();
      final host = await _open(
        tester,
        plan: plan,
        history: [_squatHistory(plan)],
      );
      String weight() => tester
          .widget<TextField>(_key('training-set-weight-0-0'))
          .controller!
          .text;
      await tester.showKeyboard(_key('training-set-weight-0-0'));
      await tester.enterText(_key('training-set-weight-0-0'), '85');
      await tester.pump();
      expect(weight(), '85');
      await _tap(tester, 'training-set-last-0-0');
      expect(weight(), '60', reason: 'the copied weight is the one shown');
      await _tap(tester, 'training-set-check-0-0');
      expect(host.writes.last!.actualSets.single.weightKg, 60);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a weight corrected during its rest carries to the next set', (
      tester,
    ) async {
      final host = await _open(tester);
      String weight(String id) => tester
          .widget<TextField>(_key('training-set-weight-$id'))
          .controller!
          .text;
      await tester.enterText(_key('training-set-weight-0-0'), '80');
      await _tap(tester, 'training-set-check-0-0');
      expect(weight('0-1'), '80');
      // The finished row stays open through its rest: correct it there.
      await tester.enterText(_key('training-set-weight-0-0'), '85');
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(weight('0-1'), '85', reason: 'the next set follows');
      await _tap(tester, 'training-set-check-0-1');
      expect(host.writes.last!.actualSets.map((a) => a.weightKg), [85, 85]);
      expect(weight('0-2'), '85');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('editing a value never pauses a running rest or set', (
      tester,
    ) async {
      final host = await _open(tester);
      await _tap(tester, 'training-set-check-0-0');
      final ends = host.writes.last!.phaseEndsAt;
      expect(ends, isNotNull);
      await tester.enterText(_key('training-set-weight-0-1'), '42.5');
      await tester.pump();
      await _elapse(tester, host, const Duration(seconds: 5));
      expect(_key('training-timer-rest-resume'), findsNothing);
      await tester.pump(const Duration(milliseconds: 700));
      expect(host.writes.last!.phaseEndsAt, ends);
      expect(host.writes.last!.draftWeightKg, 42.5);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('✓ and a drag on the list dismiss the keyboard', (
      tester,
    ) async {
      await _open(tester, size: const Size(393, 560));
      await tester.showKeyboard(_key('training-set-weight-0-0'));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      await _tap(tester, 'training-set-check-0-0');
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.showKeyboard(_key('training-set-weight-0-1'));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.drag(_key('training-player-list'), const Offset(0, -200));
      await tester.pump();
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('time keeps running (spec A4)', () {
    // A lock longer than the rest: training_qa/rest_survives_background_test.

    testWidgets('a covering page never pauses the rest', (tester) async {
      final host = await _open(tester);
      await _tap(tester, 'training-set-check-0-0');
      final ends = host.writes.last!.phaseEndsAt;
      final context = tester.element(find.byType(TrainingPlayerScreen));
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Covered fixture')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _elapse(tester, host, const Duration(seconds: 20));
      Navigator.of(tester.element(find.text('Covered fixture'))).pop();
      await tester.pumpAndSettle();
      expect(host.writes.last!.phaseEndsAt, ends);
      expect(
        tester.widget<Text>(_key('training-timer-rest-time')).data,
        '00:40',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a recovered running rest continues; a timed set past its '
        'deadline waits at zero for ✓', (tester) async {
      var now = DateTime.utc(2026, 10, 3, 18);
      await withClock(Clock(() => now), () async {
        final session = TrainingSessionController(
          plan: _strength(),
          autoTick: false,
        )..completeActiveSet();
        final snapshot = session.snapshot();
        session.dispose();
        now = now.add(const Duration(seconds: 15));
        await _open(tester, snapshot: snapshot, wallClock: true);
        expect(
          tester.widget<Text>(_key('training-timer-rest-time')).data,
          '00:45',
        );
        await tester.pumpWidget(const SizedBox());

        final timed = TrainingSessionController(
          plan: timerPlan(),
          autoTick: false,
        )..startActiveSet();
        final running = timed.snapshot();
        timed.dispose();
        now = now.add(const Duration(hours: 1));
        final host = await _open(tester, snapshot: running, wallClock: true);
        expect(host.writes.last!.completedSets, isEmpty, reason: 'no phantom');
        expect(find.text('Time is up. Tap ✓ to log the set.'), findsOneWidget);
        expect(_check(tester, '0-0').label, 'Complete set 1');
        await _tap(tester, 'training-set-check-0-0');
        expect(host.writes.last!.completedSets, hasLength(1));
        await tester.pumpWidget(const SizedBox());
      });
    });

    testWidgets('a timed set: ▶ with a 3 s lead, Done early, and the chain '
        'into its rest', (tester) async {
      final host = await _open(tester, plan: timerPlan());
      expect(_check(tester, '0-0').label, 'Start set 1');
      await _tap(tester, 'training-set-check-0-0');
      expect(find.text('Get ready · 3'), findsOneWidget);
      await _elapse(tester, host, const Duration(seconds: 13));
      expect(find.text('00:20'), findsOneWidget);
      await _tap(tester, 'training-timer-done-early');
      expect(host.writes.last!.completedSets, hasLength(1));
      expect(host.writes.last!.phase, TrainingSessionPhase.rest);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a double tap on ▶ never logs a timed set that did not run', (
      tester,
    ) async {
      final host = await _open(tester, plan: timerPlan());
      final button = _key('training-set-check-0-0');
      await tester.tap(button);
      await tester.pump();
      host.clock.elapse(const Duration(milliseconds: 250));
      // ▶ turned into ✓ at the same spot; the second tap lands on it.
      await tester.tap(button);
      await tester.pump();
      expect(host.writes.last!.completedSets, isEmpty);
      expect(host.writes.last!.phase, TrainingSessionPhase.exercise);
      expect(find.text('Get ready · 3'), findsOneWidget);
      expect(_check(tester, '0-0').enabled, isFalse, reason: 'get-ready');
      await _elapse(tester, host, const Duration(seconds: 3));
      expect(
        tester.getSemantics(_key('training-timer-readout')).label,
        '30 seconds remaining',
        reason: 'the countdown runs',
      );
      expect(_check(tester, '0-0').enabled, isTrue, reason: 'Done early');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('±15 s moves the deadline; Skip ends the rest', (tester) async {
      final host = await _open(tester);
      await _tap(tester, 'training-set-check-0-0');
      final ends = host.writes.last!.phaseEndsAt!;
      await _elapse(tester, host, const Duration(seconds: 30));
      await _tap(tester, 'training-timer-rest-plus');
      expect(
        host.writes.last!.phaseEndsAt,
        ends.add(const Duration(seconds: 15)),
      );
      await _tap(tester, 'training-timer-rest-minus');
      expect(host.writes.last!.phaseEndsAt, ends);
      await _tap(tester, 'training-timer-skip-rest');
      expect(host.writes.last!.phase, TrainingSessionPhase.exercise);
      expect(host.writes.last!.setIndex, 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('+15 s is off while it would pass the planned rest; a tap '
        'there stores nothing', (tester) async {
      final semantics = tester.ensureSemantics();
      final host = await _open(tester);
      await _tap(tester, 'training-set-check-0-0');
      final ends = host.writes.last!.phaseEndsAt!;
      final writes = host.writes.length;
      final plus = _key('training-timer-rest-plus');
      bool enabled() => tester.widget<FilledButton>(plus).onPressed != null;
      expect(enabled(), isFalse, reason: 'the full 60 s rest is left');
      expect(
        tester.getSemantics(plus),
        isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
      );
      await _tap(tester, 'training-timer-rest-plus');
      expect(host.writes, hasLength(writes), reason: 'no checkpoint');
      await _elapse(tester, host, const Duration(seconds: 14));
      expect(enabled(), isFalse, reason: '46 s + 15 s > 60 s');
      await _elapse(tester, host, const Duration(seconds: 1));
      expect(enabled(), isTrue, reason: '45 s + 15 s fits');
      await _tap(tester, 'training-timer-rest-plus');
      expect(
        host.writes.last!.phaseEndsAt,
        ends.add(const Duration(seconds: 15)),
      );
      expect(enabled(), isFalse);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the rest bar expands to a full-screen rest view', (
      tester,
    ) async {
      await _open(tester);
      await _tap(tester, 'training-set-check-0-0');
      await _tap(tester, 'training-timer-rest-expand');
      expect(_key('training-rest-view'), findsOneWidget);
      expect(find.text('01:00'), findsOneWidget);
      await _tap(tester, 'training-timer-rest-collapse');
      expect(_key('training-rest-view'), findsNothing);
      expect(_key('training-rest-bar'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('alerts and the display (spec A5/A6)', () {
    testWidgets('one alert per phase under the session id, cancelled by ✓, '
        'Skip, Undo and Discard', (tester) async {
      final host = await _open(tester);
      final session = host.writes.last!.sessionId;
      final id = restAlertIdForSession(session);
      expect(host.alerts.cancelled, [
        id,
        restAlertFollowUpIdForSession(session),
      ], reason: 'open clears stale alerts');
      await _tap(tester, 'training-set-check-0-0');
      final rest = host.alerts.scheduled.single;
      expect(rest.id, id);
      expect(rest.at, host.writes.last!.phaseEndsAt);
      expect(rest.title, 'Rest over');
      expect(rest.body, 'Time for your next set.');

      await _elapse(tester, host, const Duration(seconds: 20));
      await _tap(tester, 'training-set-check-0-1');
      expect(host.alerts.log.sublist(3), [
        'schedule',
      ], reason: 'the next rest replaces the alert under the same id');
      expect(host.alerts.scheduled.last.at, host.writes.last!.phaseEndsAt);
      await _tap(tester, 'training-set-check-0-1');
      expect(host.alerts.log.last, 'cancel', reason: 'undo ends its rest');
      await _elapse(tester, host, const Duration(seconds: 5));
      await _tap(tester, 'training-set-check-0-1');
      expect(host.alerts.log.last, 'schedule');
      await _tap(tester, 'training-timer-skip-rest');
      expect(host.alerts.log.last, 'cancel', reason: 'skip');
      await _tap(tester, 'training-set-check-0-2');
      expect(host.alerts.log.last, 'schedule');
      await _menu(tester, 'training-timer-discard');
      await _tap(tester, 'training-timer-confirm-exit');
      await tester.pumpAndSettle();
      expect(host.alerts.log.last, 'cancel', reason: 'discard');
      expect(host.alerts.scheduled.map((a) => a.id).toSet(), {id});
    });

    testWidgets('▶ also plans the rest that follows the timed set; Done '
        'early, Pause and Undo drop that plan', (tester) async {
      final host = await _open(tester, plan: timerPlan());
      final id = restAlertIdForSession(host.writes.last!.sessionId);
      await _tap(tester, 'training-set-check-0-0');
      final ends = host.writes.last!.phaseEndsAt!;
      final planned = {for (final a in host.alerts.scheduled) a.id: a};
      expect(planned.keys, hasLength(2));
      expect(planned[id]!.at, ends);
      expect(planned[id]!.body, 'Rest starts now.');
      final followUp = planned.keys.singleWhere((other) => other != id);
      expect(isRestAlertId(followUp), isTrue);
      expect(planned[followUp]!.at, ends.add(const Duration(seconds: 15)));
      expect(planned[followUp]!.title, 'Rest over');

      // Done early: the rest runs from now under the phase alert.
      await _elapse(tester, host, const Duration(seconds: 10));
      await _tap(tester, 'training-timer-done-early');
      expect(host.alerts.cancelled.last, followUp);
      expect(host.alerts.scheduled.last.id, id);
      expect(host.alerts.scheduled.last.at, host.writes.last!.phaseEndsAt);

      // Undo reopens the timed set; ▶ plans both again, Pause drops both.
      await _tap(tester, 'training-set-check-0-0');
      expect(host.alerts.cancelled.sublist(host.alerts.cancelled.length - 1), [
        id,
      ]);
      await _tap(tester, 'training-set-check-0-0');
      expect(host.alerts.scheduled.map((a) => a.id).skip(3), [id, followUp]);
      await _menu(tester, 'training-timer-pause');
      expect(host.alerts.cancelled.skip(host.alerts.cancelled.length - 2), [
        id,
        followUp,
      ]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('alerts off: nothing is scheduled; back from the settings '
        'with alerts on, the running rest is planned', (tester) async {
      final gate = _Gate(RestAlertPermission.denied);
      final host = await _open(tester, gate: gate);
      await _tap(tester, 'training-set-check-0-0');
      await tester.pumpAndSettle();
      expect(
        host.alerts.scheduled,
        isEmpty,
        reason: 'iOS rejects a request without a grant (a Sentry event each)',
      );
      await _tap(tester, 'training-timer-alerts-off');
      await tester.pumpAndSettle();
      expect(host.settings, 1);
      gate.value = RestAlertPermission.granted;
      _lifecycle(tester, _background);
      await tester.pump();
      _lifecycle(tester, _foreground);
      await tester.pumpAndSettle();
      expect(_key('training-timer-alerts-off'), findsNothing);
      expect(host.alerts.scheduled.single.at, host.writes.last!.phaseEndsAt);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a timed set with alerts off schedules nothing either', (
      tester,
    ) async {
      final gate = _Gate(RestAlertPermission.notAsked)..shown = true;
      final host = await _open(tester, plan: timerPlan(), gate: gate);
      await _tap(tester, 'training-set-check-0-0');
      await tester.pumpAndSettle();
      expect(host.writes.last!.phaseEndsAt, isNotNull);
      expect(host.alerts.scheduled, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a gate that cannot answer leaves the alerts to the OS', (
      tester,
    ) async {
      final host = await _open(tester, gate: _BrokenGate());
      await _tap(tester, 'training-set-check-0-0');
      await tester.pumpAndSettle();
      expect(host.alerts.scheduled.single.at, host.writes.last!.phaseEndsAt);
      expect(_key('training-timer-alerts-off'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Finish cancels a running alert', (tester) async {
      final host = await _open(tester);
      await _tap(tester, 'training-set-check-0-0');
      expect(host.alerts.log.last, 'schedule');
      await _tap(tester, 'training-timer-finish');
      await tester.pumpAndSettle();
      await _tap(tester, 'training-finish-save');
      await tester.pumpAndSettle();
      expect(host.alerts.log.last, 'cancel');
      expect(host.completed.single.snapshot.completedSets, hasLength(1));
    });

    testWidgets('the rest end in the foreground vibrates once', (tester) async {
      var haptics = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') haptics++;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final host = await _open(tester);
      await _tap(tester, 'training-set-check-0-0');
      await _elapse(tester, host, const Duration(seconds: 59));
      expect(haptics, 0);
      await _elapse(tester, host, const Duration(seconds: 1));
      expect(haptics, 1);
      await tester.pumpWidget(const SizedBox());
    });

    // Final review P-4: Android delivers the planned alert late and the
    // player cancels it at the deadline, so a seen end posts the cue.
    testWidgets('a rest end seen in the foreground cues once with the generic '
        'text; one passed in the background does not', (tester) async {
      final host = await _open(tester);
      final cueId = restAlertCueIdForSession(host.writes.last!.sessionId);
      await _tap(tester, 'training-set-check-0-0');
      await _elapse(tester, host, const Duration(seconds: 59));
      expect(host.alerts.cues, isEmpty);
      await _elapse(tester, host, const Duration(seconds: 1));
      expect(host.alerts.cues, [
        (id: cueId, title: 'Rest over', body: 'Time for your next set.'),
      ]);
      expect(cueId, isNot(restAlertIdForSession(host.writes.last!.sessionId)));

      await _tap(tester, 'training-set-check-0-1');
      _lifecycle(tester, _background);
      await tester.pump();
      host.clock.elapse(const Duration(seconds: 70));
      await tester.pump(const Duration(milliseconds: 300));
      _lifecycle(tester, _foreground);
      await tester.pump();
      expect(host.writes.last!.setIndex, 2, reason: 'the rest passed');
      expect(host.alerts.cues, hasLength(1), reason: 'the alert came instead');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a timed set ending in the foreground cues "Time\'s up"', (
      tester,
    ) async {
      final host = await _open(tester, plan: timerPlan());
      await _tap(tester, 'training-set-check-0-0');
      await _elapse(tester, host, const Duration(seconds: 33));
      expect(host.writes.last!.phase, TrainingSessionPhase.rest);
      expect(host.alerts.cues.single.title, "Time's up");
      expect(host.alerts.cues.single.body, 'Rest starts now.');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with alerts off a seen end only vibrates', (tester) async {
      final host = await _open(tester, gate: _Gate(RestAlertPermission.denied));
      await _tap(tester, 'training-set-check-0-0');
      await tester.pumpAndSettle();
      await _elapse(tester, host, const Duration(seconds: 60));
      expect(host.writes.last!.phase, TrainingSessionPhase.exercise);
      expect(host.alerts.cues, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the first workout explains alerts once before asking', (
      tester,
    ) async {
      final gate = _Gate(RestAlertPermission.notAsked);
      await _open(tester, gate: gate);
      expect(_key('training-alerts-allow'), findsNothing);
      await _tap(tester, 'training-set-check-0-0');
      await tester.pumpAndSettle();
      expect(find.text('Alert when the rest is over?'), findsOneWidget);
      expect(gate.requests, 0);
      await tester.tap(_key('training-alerts-allow'));
      await tester.pumpAndSettle();
      expect(gate.requests, 1);
      expect(_key('training-timer-alerts-off'), findsNothing);
      await _tap(tester, 'training-set-check-0-1');
      await tester.pumpAndSettle();
      expect(find.text('Alert when the rest is over?'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a system prompt answered with no leaves the quiet chip', (
      tester,
    ) async {
      final gate = _Gate(RestAlertPermission.notAsked, grant: false);
      await _open(tester, gate: gate);
      await _tap(tester, 'training-set-check-0-0');
      await tester.pumpAndSettle();
      await tester.tap(_key('training-alerts-allow'));
      await tester.pumpAndSettle();
      expect(gate.requests, 1);
      expect(_key('training-timer-alerts-off'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('"Not now" is remembered: the next workout shows no '
        'explainer, only the quiet chip', (tester) async {
      final gate = _Gate(RestAlertPermission.notAsked);
      await _open(tester, gate: gate);
      await _tap(tester, 'training-set-check-0-0');
      await tester.pumpAndSettle();
      expect(find.text('Alert when the rest is over?'), findsOneWidget);
      await tester.tap(_key('training-alerts-later'));
      await tester.pumpAndSettle();
      expect(_key('training-timer-alerts-off'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());

      // The next workout on this device.
      await _open(tester, gate: gate);
      await _tap(tester, 'training-set-check-0-0');
      await tester.pumpAndSettle();
      expect(find.text('Alert when the rest is over?'), findsNothing);
      expect(_key('training-timer-alerts-off'), findsOneWidget);
      expect(gate.requests, 0, reason: 'no system prompt without consent');
      expect(gate.marks, 1, reason: 'the device remembers the explainer');
      expect(
        gate.value,
        RestAlertPermission.notAsked,
        reason: '"Not now" is no system prompt: the chip may still ask',
      );
      await tester.pumpWidget(const SizedBox());
    });

    for (final grant in [true, false]) {
      testWidgets('after "Not now" the chip asks the system once '
          '(${grant ? 'allowed' : 'denied'}), then opens the settings', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        final gate = _Gate(RestAlertPermission.notAsked, grant: grant)
          ..shown = true;
        final host = await _open(tester, gate: gate);
        await _tap(tester, 'training-set-check-0-0');
        await tester.pumpAndSettle();
        expect(find.text('Alert when the rest is over?'), findsNothing);
        expect(
          find.bySemanticsLabel('Rest alerts are off. Turn on alerts.'),
          findsOneWidget,
        );
        final schedules = host.alerts.scheduled.length;

        // iOS lists the notification switch only after a request: the
        // first tap is the system prompt, not a dead end in Settings.
        await _tap(tester, 'training-timer-alerts-off');
        await tester.pumpAndSettle();
        expect(gate.requests, 1);
        expect(host.settings, 0);
        if (grant) {
          expect(_key('training-timer-alerts-off'), findsNothing);
          expect(
            host.alerts.scheduled,
            hasLength(schedules + 1),
            reason: 'the running rest is planned again once granted',
          );
        } else {
          expect(
            find.bySemanticsLabel(
              'Rest alerts are off. Open notification settings.',
            ),
            findsOneWidget,
          );
          await _tap(tester, 'training-timer-alerts-off');
          await tester.pumpAndSettle();
          expect(host.settings, 1, reason: 'asked once: now the settings');
          expect(gate.requests, 1);
        }
        await tester.pumpWidget(const SizedBox());
        semantics.dispose();
      });
    }

    testWidgets('with alerts off the rest bar shows a quiet chip; after a '
        'denial it opens the notification settings', (tester) async {
      final gate = _Gate(RestAlertPermission.denied);
      final host = await _open(tester, gate: gate);
      await _tap(tester, 'training-set-check-0-0');
      await tester.pumpAndSettle();
      expect(find.text('Alert when the rest is over?'), findsNothing);
      expect(_key('training-timer-alerts-off'), findsOneWidget);
      await _tap(tester, 'training-timer-alerts-off');
      await tester.pumpAndSettle();
      expect(host.settings, 1);
      expect(gate.requests, 0, reason: 'the system asks only once anyway');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('alerts turned on elsewhere meanwhile: the chip goes and the '
        'rest is planned with the grant', (tester) async {
      final gate = _Gate(RestAlertPermission.denied);
      final host = await _open(tester, gate: gate);
      await _tap(tester, 'training-set-check-0-0');
      await tester.pumpAndSettle();
      final schedules = host.alerts.scheduled.length;
      gate.value = RestAlertPermission.granted;
      await _tap(tester, 'training-timer-alerts-off');
      await tester.pumpAndSettle();
      expect(_key('training-timer-alerts-off'), findsNothing);
      expect(host.alerts.scheduled, hasLength(schedules + 1));
      expect((host.settings, gate.requests), (0, 0));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a gate without the explainer memory keeps the original '
        'contract: the explainer returns until answered', (tester) async {
      final gate = _PlainGate(RestAlertPermission.notAsked);
      for (var workout = 0; workout < 2; workout++) {
        await _open(tester, gate: gate);
        await _tap(tester, 'training-set-check-0-0');
        await tester.pumpAndSettle();
        expect(
          find.text('Alert when the rest is over?'),
          findsOneWidget,
          reason: 'workout $workout',
        );
        await tester.tap(_key('training-alerts-later'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      }
      expect(gate.requests, 0);
    });

    testWidgets('the display stays awake only for a timed set or the rest '
        'leading into one', (tester) async {
      final host = await _open(tester, plan: timerPlan());
      expect(host.awake.on, isFalse);
      await _tap(tester, 'training-set-check-0-0');
      expect(host.awake.calls.last, (true, trainingPlayerAwakeOwner));
      await _elapse(tester, host, const Duration(seconds: 33));
      expect(host.writes.last!.phase, TrainingSessionPhase.rest);
      expect(host.awake.on, isTrue, reason: 'rest leads into a timed set');
      _lifecycle(tester, _background);
      await tester.pump();
      expect(host.awake.on, isFalse);
      _lifecycle(tester, _foreground);
      await tester.pump();
      expect(host.awake.on, isTrue);
      await _menu(tester, 'training-timer-pause');
      expect(host.awake.on, isFalse);
      await tester.pumpWidget(const SizedBox());
      expect(host.awake.on, isFalse);
    });

    testWidgets('a sheet or menu over a running interval releases the display '
        'until the player is on top again', (tester) async {
      final host = await _open(tester, plan: timerPlan());
      await _tap(tester, 'training-set-check-0-0');
      await _elapse(tester, host, const Duration(seconds: 4));
      expect(host.awake.on, isTrue);
      // A finish sheet left open must not keep the phone lit, also not
      // after the interval behind it has ended.
      await _tap(tester, 'training-timer-finish');
      await tester.pumpAndSettle();
      expect(_key('training-finish-sheet'), findsOneWidget);
      expect(host.awake.on, isFalse, reason: 'the sheet is on top');
      await _elapse(tester, host, const Duration(seconds: 5));
      expect(host.awake.on, isFalse);
      await _tap(tester, 'training-finish-keep');
      await tester.pumpAndSettle();
      expect(host.awake.on, isTrue, reason: 'the interval still runs');
      await _tap(tester, 'training-timer-menu');
      await tester.pumpAndSettle();
      expect(host.awake.on, isFalse, reason: 'the menu is on top');
      await tester.tapAt(const Offset(8, 840));
      await tester.pumpAndSettle();
      expect(host.awake.on, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(host.awake.on, isFalse);
    });

    testWidgets('a repetition workout never holds the display', (tester) async {
      final host = await _open(tester);
      await _tap(tester, 'training-set-check-0-0');
      expect(host.awake.calls, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('set done, rest start and rest over are announced', (
      tester,
    ) async {
      final announcements = <String>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (
            message,
          ) async {
            final map = message as Map;
            if (map['type'] == 'announce') {
              announcements.add((map['data'] as Map)['message'] as String);
            }
            return null;
          });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler<dynamic>(
              SystemChannels.accessibility,
              null,
            ),
      );
      final host = await _open(tester);
      await _tap(tester, 'training-set-check-0-0');
      expect(announcements, ['Squat, set 1 done. Rest, 60 seconds.']);
      await _elapse(tester, host, const Duration(seconds: 60));
      expect(announcements.last, 'Rest over. Next: Squat, set 2.');
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('finishing (spec A7)', () {
    testWidgets('with open sets the honest primary saves only what was done', (
      tester,
    ) async {
      final host = await _open(tester);
      await _tap(tester, 'training-set-check-0-0');
      await _exerciseMenu(tester, 0, 'training-timer-skip-set');
      await _tap(tester, 'training-timer-finish');
      await tester.pumpAndSettle();
      // In English "rest" is the pause between sets: the remaining sets are
      // named as such, and open ones are not counted as skipped yet.
      expect(
        tester.widget<Text>(_key('training-finish-summary')).data,
        '1 of 12 sets completed · 1 set skipped · 10 open',
      );
      expect(find.text('Save 1 set, skip the remaining ones'), findsOneWidget);
      expect(
        find.text('I did the remaining sets — log as shown'),
        findsOneWidget,
      );
      expect(find.text('Keep training'), findsOneWidget);
      await _tap(tester, 'training-finish-keep');
      await tester.pumpAndSettle();
      expect(host.completed, isEmpty);
      await _tap(tester, 'training-timer-finish');
      await tester.pumpAndSettle();
      await _tap(tester, 'training-finish-save');
      await tester.pumpAndSettle();
      final entry = host.completed.single;
      expect(entry.snapshot.completedSets, hasLength(1));
      expect(entry.snapshot.skippedSets, hasLength(11));
    });

    testWidgets('German: the open sets read as "offen" before the choice', (
      tester,
    ) async {
      await _open(tester, locale: 'de');
      await _tap(tester, 'training-set-check-0-0');
      await _tap(tester, 'training-timer-finish');
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(_key('training-finish-summary')).data,
        '1 von 12 Sätzen geschafft · 11 offen',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('"I did the rest" logs the open sets as shown', (tester) async {
      final host = await _open(tester);
      await _tap(tester, 'training-set-check-0-0');
      await _tap(tester, 'training-timer-finish');
      await tester.pumpAndSettle();
      await _tap(tester, 'training-finish-log-rest');
      await tester.pumpAndSettle();
      final entry = host.completed.single;
      expect(entry.snapshot.completedSets, hasLength(12));
      expect(entry.snapshot.actualSets.map((a) => a.reps).toSet(), {8});
    });

    testWidgets('with no completed set only Discard and Keep training', (
      tester,
    ) async {
      final host = await _open(tester);
      await _tap(tester, 'training-timer-finish');
      await tester.pumpAndSettle();
      expect(_key('training-finish-save'), findsNothing);
      expect(_key('training-finish-log-rest'), findsNothing);
      await _tap(tester, 'training-finish-discard');
      await tester.pumpAndSettle();
      expect(find.text('Discard this workout?'), findsOneWidget);
      await _tap(tester, 'training-timer-confirm-exit');
      await tester.pumpAndSettle();
      expect(host.writes.last, isNull);
      expect(host.completed, isEmpty);
    });

    testWidgets('skipping to the end opens the sheet; Keep training reopens '
        'the skipped sets', (tester) async {
      final host = await _open(tester, plan: timerPlan());
      await _exerciseMenu(tester, 0, 'training-timer-skip-exercise');
      await _exerciseMenu(tester, 1, 'training-timer-skip-exercise');
      await tester.pumpAndSettle();
      expect(_key('training-finish-sheet'), findsOneWidget);
      await _tap(tester, 'training-finish-keep');
      await tester.pumpAndSettle();
      expect(host.writes.last!.phase, TrainingSessionPhase.exercise);
      expect(host.writes.last!.skippedSets, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a refused checkpoint shows "not stored" and Finish still '
        'saves the frozen plan copy', (tester) async {
      var refuse = false;
      final writes = <TrainingSessionSnapshot?>[];
      final host = await _open(
        tester,
        persist: (value) async {
          writes.add(value);
          return !refuse;
        },
      );
      expect(find.text('Recovery checkpoint saved'), findsOneWidget);
      refuse = true;
      await _tap(tester, 'training-set-check-0-0');
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Not stored: your plan changed. Finish still saves this workout.',
        ),
        findsOneWidget,
      );
      expect(find.text('Recovery checkpoint saved'), findsNothing);
      await _tap(tester, 'training-timer-finish');
      await tester.pumpAndSettle();
      await _tap(tester, 'training-finish-save');
      await tester.pumpAndSettle();
      expect(host.completed.single.snapshot.plan.id, 'player_strength');
    });

    testWidgets('complete remaining as planned and undo from the list', (
      tester,
    ) async {
      final host = await _open(tester);
      await _exerciseMenu(tester, 0, 'training-timer-complete-remaining');
      expect(host.writes.last!.completedSets, hasLength(3));
      expect(_check(tester, '0-2').label, 'Undo set 3');
      await _tap(tester, 'training-set-check-0-2');
      expect(host.writes.last!.completedSets, hasLength(2));
      expect(host.writes.last!.phase, TrainingSessionPhase.exercise);
      await _exerciseMenu(tester, 0, 'training-timer-skip-set');
      expect(host.writes.last!.skippedSets, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('invalid values never outlive their field', () {
    const missing =
        'Enter the actual repetitions for completed sets before saving the '
        'workout.';

    bool saveEnabled(WidgetTester tester) =>
        tester
            .widget<PrimaryActionButton>(_key('training-finish-save'))
            .onTap !=
        null;

    testWidgets('a card collapsing with a cleared value keeps Save enabled; '
        're-expanded it edits again', (tester) async {
      final host = await _open(tester, plan: _pair());
      await _tap(tester, 'training-set-check-0-0');
      // The finished card stays open through its rest: clear its reps.
      await tester.enterText(_key('training-set-reps-0-0'), '');
      await tester.pump();
      expect(find.text(missing), findsOneWidget);
      // The final set collapses card 1 and opens the finish sheet.
      await _tap(tester, 'training-set-check-1-0');
      await tester.pumpAndSettle();
      expect(_key('training-set-reps-0-0'), findsNothing);
      expect(find.text(missing), findsNothing);
      expect(saveEnabled(tester), isTrue);
      expect(
        tester.widget<SoftPillButton>(_key('training-finish-keep')).onTap,
        isNotNull,
      );
      await _tap(tester, 'training-finish-keep');
      await tester.pumpAndSettle();
      await _tap(tester, 'training-exercise-expand-0');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(_key('training-set-reps-0-0'))
            .controller!
            .text,
        '8',
      );
      await tester.enterText(_key('training-set-reps-0-0'), '7');
      await tester.pump();
      await _tap(tester, 'training-timer-finish');
      await tester.pumpAndSettle();
      expect(saveEnabled(tester), isTrue);
      await _tap(tester, 'training-finish-save');
      await tester.pumpAndSettle();
      expect(host.completed.single.snapshot.actualSets.first.reps, 7);
    });

    testWidgets('Hide sets drops the invalid value of the hidden rows', (
      tester,
    ) async {
      final host = await _open(tester, plan: _pair(secondSets: 2));
      await _tap(tester, 'training-set-check-0-0');
      await _tap(tester, 'training-timer-skip-rest');
      await _tap(tester, 'training-exercise-expand-0');
      await tester.enterText(_key('training-set-reps-0-0'), '');
      await tester.pump();
      expect(find.text(missing), findsOneWidget);
      await _tap(tester, 'training-exercise-expand-0');
      await tester.pumpAndSettle();
      expect(find.text(missing), findsNothing);
      await _tap(tester, 'training-timer-finish');
      await tester.pumpAndSettle();
      expect(saveEnabled(tester), isTrue);
      await _tap(tester, 'training-finish-save');
      await tester.pumpAndSettle();
      expect(host.completed.single.snapshot.actualSets.single.reps, 8);
    });
  });

  group('durable writes', () {
    testWidgets('the initial checkpoint does not claim saved before its '
        'callback', (tester) async {
      final gate = Completer<void>();
      final writes = <TrainingSessionSnapshot?>[];
      await _open(
        tester,
        persist: (value) async {
          writes.add(value);
          await gate.future;
          return true;
        },
      );
      expect(writes, hasLength(1));
      expect(find.text('Saving your place…'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Recovery checkpoint saved'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the save status speaks up only when the place is not kept', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      var refuse = false;
      Completer<void>? hold;
      await _open(
        tester,
        persist: (_) async {
          await hold?.future;
          return !refuse;
        },
      );
      final status = _key('training-timer-save-status');
      expect(find.text('Recovery checkpoint saved'), findsOneWidget);
      expect(tester.getSemantics(status), isSemantics(isLiveRegion: false));
      final saving = Completer<void>();
      hold = saving;
      await tester.tap(_key('training-set-check-0-0'));
      await tester.pump();
      expect(find.text('Saving your place…'), findsOneWidget);
      expect(
        tester.getSemantics(status),
        isSemantics(isLiveRegion: false),
        reason: 'never on top of "set done" and "rest"',
      );
      saving.complete();
      hold = null;
      await tester.pumpAndSettle();
      expect(tester.getSemantics(status), isSemantics(isLiveRegion: false));
      refuse = true;
      await _tap(tester, 'training-set-check-0-1');
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Not stored: your plan changed. Finish still saves this workout.',
        ),
        findsOneWidget,
      );
      expect(tester.getSemantics(status), isSemantics(isLiveRegion: true));
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('field edits are debounced and flushed by the background', (
      tester,
    ) async {
      final host = await _open(tester);
      final before = host.writes.length;
      await tester.enterText(_key('training-set-weight-0-0'), '5');
      await tester.enterText(_key('training-set-weight-0-0'), '50');
      await tester.pump(const Duration(milliseconds: 200));
      expect(host.writes.length, before, reason: 'no write per keystroke');
      _lifecycle(tester, [AppLifecycleState.inactive]);
      await tester.pump();
      expect(host.writes.length, before + 1);
      expect(host.writes.last!.draftWeightKg, 50);
      _lifecycle(tester, [AppLifecycleState.resumed]);
      await tester.pump(const Duration(seconds: 1));
      expect(host.writes.length, before + 1, reason: 'the debounce was spent');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('save failure is sanitized and retried', (tester) async {
      var fail = false;
      final writes = <TrainingSessionSnapshot?>[];
      await _open(
        tester,
        persist: (value) async {
          if (fail) throw StateError('private-account-path');
          writes.add(value);
          return true;
        },
      );
      fail = true;
      await _tap(tester, 'training-set-check-0-0');
      expect(_key('training-timer-save-error'), findsOneWidget);
      expect(find.textContaining('private-account-path'), findsNothing);
      expect(_key('training-rest-bar'), findsOneWidget, reason: 'still runs');
      fail = false;
      await _tap(tester, 'training-timer-retry');
      expect(_key('training-timer-save-error'), findsNothing);
      expect(writes.last!.completedSets, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Stay here keeps the rest running; Save & leave pauses it', (
      tester,
    ) async {
      final host = await _open(tester);
      await _tap(tester, 'training-set-check-0-0');
      await _tap(tester, 'training-timer-back');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stay here'));
      await tester.pumpAndSettle();
      expect(host.writes.last!.phaseEndsAt, isNotNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Pause and leave?'), findsOneWidget);
      await _tap(tester, 'training-timer-confirm-exit');
      await tester.pumpAndSettle();
      expect(find.text('Open fixture'), findsOneWidget);
      expect(host.writes.last!.phase, TrainingSessionPhase.rest);
      expect(host.writes.last!.phaseEndsAt, isNull);
      expect(host.alerts.log.last, 'cancel');
    });

    testWidgets('failed save and leave keeps the route; retry waits for the '
        'durable callback', (tester) async {
      var fail = false;
      var block = false;
      final gate = Completer<void>();
      final writes = <TrainingSessionSnapshot?>[];
      await _open(
        tester,
        persist: (value) async {
          writes.add(value);
          if (fail) throw StateError('save failed');
          if (block) await gate.future;
          return true;
        },
      );
      await _tap(tester, 'training-timer-back');
      await tester.pumpAndSettle();
      fail = true;
      await _tap(tester, 'training-timer-confirm-exit');
      await tester.pumpAndSettle();
      expect(_key('training-timer-save-error'), findsOneWidget);
      fail = false;
      block = true;
      await _tap(tester, 'training-timer-retry');
      await tester.pumpAndSettle();
      expect(find.byType(TrainingPlayerScreen), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Open fixture'), findsOneWidget);
      expect(writes.every((s) => s != null), isTrue);
    });

    testWidgets('a refused Save & leave never closes as saved; Finish still '
        'saves the workout', (tester) async {
      var refuse = false;
      final host = await _open(tester, persist: (_) async => !refuse);
      await _tap(tester, 'training-set-check-0-0');
      expect(find.text('Recovery checkpoint saved'), findsOneWidget);
      refuse = true;
      await _tap(tester, 'training-timer-back');
      await tester.pumpAndSettle();
      expect(find.text('Pause and leave?'), findsOneWidget);
      await _tap(tester, 'training-timer-confirm-exit');
      await tester.pumpAndSettle();
      expect(find.text('Open fixture'), findsNothing);
      expect(find.byType(TrainingPlayerScreen), findsOneWidget);
      expect(find.text('Leave without saving?'), findsOneWidget);
      expect(
        find.text(
          'Not stored: your plan changed. Finish still saves this workout.',
        ),
        findsOneWidget,
      );
      await _tap(tester, 'training-timer-unstored-finish');
      await tester.pumpAndSettle();
      await _tap(tester, 'training-finish-save');
      await tester.pumpAndSettle();
      expect(find.text('Open fixture'), findsOneWidget);
      expect(host.completed.single.snapshot.completedSets, hasLength(1));
    });

    testWidgets('a known refusal warns before leaving; Leave without saving '
        'writes nothing', (tester) async {
      final writes = <TrainingSessionSnapshot?>[];
      var refuse = false;
      final host = await _open(
        tester,
        persist: (value) async {
          writes.add(value);
          return !refuse;
        },
      );
      refuse = true;
      await _tap(tester, 'training-set-check-0-0');
      await tester.pumpAndSettle();
      final before = writes.length;
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Pause and leave?'), findsNothing);
      expect(find.text('Leave without saving?'), findsOneWidget);
      await _tap(tester, 'training-timer-unstored-stay');
      await tester.pumpAndSettle();
      expect(find.byType(TrainingPlayerScreen), findsOneWidget);
      expect(writes, hasLength(before));
      await _tap(tester, 'training-timer-back');
      await tester.pumpAndSettle();
      await _tap(tester, 'training-timer-unstored-leave');
      await tester.pumpAndSettle();
      expect(find.text('Open fixture'), findsOneWidget);
      expect(writes, hasLength(before), reason: 'nothing claims a save');
      expect(host.completed, isEmpty);
      expect(host.alerts.log.last, 'cancel');
    });

    // A failed completion locks the workout; a refused place must still
    // leave a visible way out (Retry, Finish or Leave without saving).
    for (final exit in ['unstored-finish', 'retry', 'unstored-leave']) {
      testWidgets('a refused Save & leave after a failed completion keeps an '
          'exit: $exit', (tester) async {
        final writes = <TrainingSessionSnapshot?>[];
        var completions = 0;
        var refuse = false;
        final host = await _open(
          tester,
          persist: (value) async {
            writes.add(value);
            return !refuse;
          },
          complete: (_) async {
            if (completions++ == 0) throw StateError('completion failed');
          },
        );
        await _tap(tester, 'training-set-check-0-0');
        await _tap(tester, 'training-timer-finish');
        await tester.pumpAndSettle();
        await _tap(tester, 'training-finish-save');
        await tester.pumpAndSettle();
        expect(_key('training-timer-retry'), findsOneWidget);
        refuse = true;
        await _tap(tester, 'training-timer-back');
        await tester.pumpAndSettle();
        expect(find.text('Pause and leave?'), findsOneWidget);
        await _tap(tester, 'training-timer-confirm-exit');
        await tester.pumpAndSettle();
        final refusedAt = writes.length;
        expect(find.byType(TrainingPlayerScreen), findsOneWidget);
        expect(find.text('Leave without saving?'), findsOneWidget);
        expect(_key('training-timer-unstored-finish'), findsOneWidget);
        await _tap(tester, 'training-timer-unstored-stay');
        await tester.pumpAndSettle();
        expect(_key('training-timer-retry'), findsOneWidget);
        // Back no longer loops through "Pause and leave?".
        await _tap(tester, 'training-timer-back');
        await tester.pumpAndSettle();
        expect(find.text('Pause and leave?'), findsNothing);
        expect(find.text('Leave without saving?'), findsOneWidget);
        if (exit == 'retry') {
          await _tap(tester, 'training-timer-unstored-stay');
          await tester.pumpAndSettle();
        }
        await _tap(tester, 'training-timer-$exit');
        await tester.pumpAndSettle();
        expect(find.text('Open fixture'), findsOneWidget);
        expect(writes, hasLength(refusedAt), reason: 'no write after refusal');
        if (exit == 'unstored-leave') {
          expect(completions, 1);
          expect(host.completed, isEmpty);
        } else {
          expect(completions, 2);
          expect(host.completed.single.snapshot.completedSets, hasLength(1));
        }
      });
    }

    testWidgets('a failed Finish pauses the workout: no rest or timed set '
        'runs on until Retry resolves', (tester) async {
      var completions = 0;
      final host = await _open(
        tester,
        plan: _restIntoTimed(),
        complete: (_) async {
          if (completions++ == 0) throw StateError('completion failed');
        },
      );
      await _tap(tester, 'training-set-check-0-0');
      await _tap(tester, 'training-timer-finish');
      await tester.pumpAndSettle();
      await _tap(tester, 'training-finish-save');
      await tester.pumpAndSettle();
      expect(_key('training-timer-retry'), findsOneWidget);
      // Long past the rest and the timed set it would chain into.
      for (var i = 0; i < 4; i++) {
        await _elapse(tester, host, const Duration(seconds: 10));
      }
      expect(find.text('1/2 sets'), findsOneWidget);
      expect(
        tester.widget<Text>(_key('training-timer-rest-time')).data,
        '00:10',
        reason: 'the rest froze at Finish',
      );
      expect(host.alerts.log.last, 'cancel');
      await _tap(tester, 'training-timer-retry');
      await tester.pumpAndSettle();
      expect(find.text('Open fixture'), findsOneWidget);
      expect(completions, 2);
      expect(host.completed.single.snapshot.completedSets, hasLength(1));
    });

    testWidgets('the background cannot hide a failed clear or replace its '
        'retry intent', (tester) async {
      var failClear = true;
      final writes = <TrainingSessionSnapshot?>[];
      await _open(
        tester,
        persist: (value) async {
          writes.add(value);
          if (value == null && failClear) throw StateError('clear failed');
          return true;
        },
      );
      await _menu(tester, 'training-timer-discard');
      await _tap(tester, 'training-timer-confirm-exit');
      await tester.pumpAndSettle();
      final count = writes.length;
      _lifecycle(tester, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      await tester.pumpAndSettle();
      expect(writes.length, count);
      expect(_key('training-timer-save-error'), findsOneWidget);
      failClear = false;
      await _tap(tester, 'training-timer-retry');
      await tester.pumpAndSettle();
      expect(writes.last, isNull);
      expect(writes.where((s) => s == null), hasLength(2));
      expect(find.text('Open fixture'), findsOneWidget);
    });

    for (final terminal in ['discard', 'finish']) {
      testWidgets('$terminal clears only after older checkpoints finish', (
        tester,
      ) async {
        final gate = Completer<void>();
        final writes = <TrainingSessionSnapshot?>[];
        var active = 0;
        var maxActive = 0;
        final host = await _open(
          tester,
          persist: (value) async {
            active++;
            if (active > maxActive) maxActive = active;
            writes.add(value);
            if (writes.length == 1) await gate.future;
            active--;
            return true;
          },
        );
        if (terminal == 'discard') {
          await _menu(tester, 'training-timer-discard');
          await _tap(tester, 'training-timer-confirm-exit');
        } else {
          await _tap(tester, 'training-set-check-0-0');
          await _tap(tester, 'training-timer-finish');
          await tester.pumpAndSettle();
          await _tap(tester, 'training-finish-save');
        }
        await tester.pumpAndSettle();
        _lifecycle(tester, [AppLifecycleState.inactive]);
        await tester.pump();
        expect(find.byType(TrainingPlayerScreen), findsOneWidget);
        expect(host.completed, isEmpty);
        gate.complete();
        await tester.pumpAndSettle();
        expect(maxActive, 1);
        expect(find.text('Open fixture'), findsOneWidget);
        if (terminal == 'discard') {
          expect(writes.last, isNull);
          expect(writes.where((s) => s == null), hasLength(1));
        } else {
          expect(host.completed, hasLength(1));
        }
        _lifecycle(tester, [AppLifecycleState.resumed]);
        await tester.pump();
      });
    }

    testWidgets('an older failed checkpoint cannot unlock a queued clear', (
      tester,
    ) async {
      final checkpoint = Completer<void>();
      final clear = Completer<void>();
      final writes = <TrainingSessionSnapshot?>[];
      await _open(
        tester,
        persist: (value) async {
          writes.add(value);
          if (writes.length == 1) await checkpoint.future;
          if (value == null) await clear.future;
          return true;
        },
      );
      await _menu(tester, 'training-timer-discard');
      await _tap(tester, 'training-timer-confirm-exit');
      await tester.pumpAndSettle();
      checkpoint.completeError(StateError('old checkpoint failed'));
      await tester.pumpAndSettle();
      expect(writes.last, isNull);
      _lifecycle(tester, [AppLifecycleState.inactive]);
      await tester.pump();
      clear.complete();
      await tester.pumpAndSettle();
      expect(
        writes.last,
        isNull,
        reason: 'No checkpoint may be queued after a terminal clear',
      );
      expect(find.text('Open fixture'), findsOneWidget);
      _lifecycle(tester, [AppLifecycleState.resumed]);
      await tester.pump();
    });

    testWidgets('external route removal queues a final checkpoint that keeps '
        'the running deadline', (tester) async {
      final host = await _open(tester);
      await _tap(tester, 'training-set-check-0-0');
      final ends = host.writes.last!.phaseEndsAt;
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(host.writes.last!.phaseEndsAt, ends);
      expect(host.alerts.log.last, 'cancel');
    });
  });

  group('layout', () {
    for (final locale in ['de', 'en']) {
      testWidgets('320 px, 2.0 text, $locale: no overflow, reachable '
          'controls', (tester) async {
        final host = await _open(
          tester,
          plan: timerPlan(longText: true, duration: 3600),
          size: const Size(320, 568),
          scale: 2,
          locale: locale,
        );
        expect(tester.takeException(), isNull);
        for (final id in [
          'training-timer-back',
          'training-timer-finish',
          'training-timer-menu',
          'training-set-check-0-0',
          'training-set-weight-0-0',
        ]) {
          await tester.ensureVisible(_key(id));
          await tester.pump();
          final rect = tester.getRect(_key(id));
          expect(rect.left, greaterThanOrEqualTo(0), reason: id);
          expect(rect.right, lessThanOrEqualTo(320), reason: id);
          expect(rect.height, greaterThanOrEqualTo(48), reason: id);
          expect(_key(id).hitTestable(), findsOneWidget, reason: id);
        }
        await _tap(tester, 'training-set-check-0-0');
        await _elapse(tester, host, const Duration(seconds: 3604));
        expect(_key('training-rest-bar'), findsOneWidget);
        for (final id in [
          'training-timer-rest-minus',
          'training-timer-rest-plus',
          'training-timer-skip-rest',
        ]) {
          // At 2.0 text the bar scrolls within its 40 % of the screen.
          await tester.ensureVisible(_key(id));
          await tester.pump();
          final rect = tester.getRect(_key(id));
          expect(rect.right, lessThanOrEqualTo(320), reason: id);
          expect(rect.bottom, lessThanOrEqualTo(568), reason: id);
          expect(rect.height, greaterThanOrEqualTo(48), reason: id);
        }
        expect(tester.takeException(), isNull);
        await _tap(tester, 'training-timer-finish');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }

    // Typing the next set's weight during a rest is the core flow: the
    // keyboard shrinks the body, and the rest bar must never take the row
    // being typed in. Only where not even one control row is left (320 px
    // high text) does the bar wait for the keyboard to close.
    for (final (size, scale, keyboard, barWhileTyping) in const [
      (Size(320, 568), 1.0, 260.0, true),
      (Size(320, 568), 2.0, 260.0, false),
      (Size(360, 640), 1.0, 280.0, true),
      (Size(375, 667), 1.3, 300.0, true),
      (Size(375, 667), 2.0, 300.0, true),
    ]) {
      testWidgets('${size.width.toInt()}×${size.height.toInt()} at ${scale}x '
          'with a ${keyboard.toInt()} px keyboard during a rest: no overflow, '
          'the field and its ✓ stay visible, Skip stays reachable', (
        tester,
      ) async {
        final host = await _open(tester, size: size, scale: scale);
        await _tap(tester, 'training-set-check-0-0');
        expect(_key('training-rest-bar'), findsOneWidget);
        await tester.showKeyboard(_key('training-set-weight-0-1'));
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final list = tester.getRect(_key('training-player-list'));
        for (final id in [
          'training-set-weight-0-1',
          'training-set-check-0-1',
        ]) {
          await tester.ensureVisible(_key(id));
          await tester.pumpAndSettle();
          final rect = tester.getRect(_key(id));
          expect(rect.top, greaterThanOrEqualTo(list.top - 0.5), reason: id);
          expect(rect.bottom, lessThanOrEqualTo(list.bottom + 0.5), reason: id);
          expect(_key(id).hitTestable(), findsOneWidget, reason: id);
        }
        expect(tester.testTextInput.isVisible, isTrue, reason: 'still typing');
        expect(
          _key('training-rest-bar'),
          barWhileTyping ? findsOneWidget : findsNothing,
        );
        var visibleBottom = size.height - keyboard;
        if (!barWhileTyping) {
          FocusManager.instance.primaryFocus?.unfocus();
          tester.view.resetViewInsets();
          await tester.pumpAndSettle();
          expect(_key('training-rest-bar'), findsOneWidget, reason: 'back');
          visibleBottom = size.height;
        }
        final skip = _key('training-timer-skip-rest');
        await tester.ensureVisible(skip);
        await tester.pumpAndSettle();
        expect(
          tester.getRect(skip).bottom,
          lessThanOrEqualTo(visibleBottom + 0.5),
        );
        expect(skip.hitTestable(), findsOneWidget);
        await tester.tap(skip);
        await tester.pumpAndSettle();
        expect(host.writes.last!.phase, TrainingSessionPhase.exercise);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('German: the header menu is "Trainingsoptionen"', (
      tester,
    ) async {
      await _open(tester, locale: 'de');
      expect(find.byTooltip('Trainingsoptionen'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
