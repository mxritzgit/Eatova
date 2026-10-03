// Shell wiring of the training flow (spec §5 A5, §6, §7 C1), mounted as the
// real home page against the fake backend: Training's log entries open the
// shared editor and write through one owner-checked adapter, the Coach gets
// that adapter plus the live history and the `/log` draft request, and a
// tapped rest alert or Today's "In progress" row resumes the saved workout.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_log.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/screens/training/training_log_editor.dart';
import 'package:eatova/src/screens/training/training_player_screen.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/rest_alerts.dart';
import 'package:eatova/src/services/uuid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import '../fixlauf_a_helpers.dart';
import '../support/harness.dart';
import 'flow_test_helpers.dart' show pumpUntil;

/// Saturday 2026-10-03, 18:00 local.
final _now = DateTime(2026, 10, 3, 18);

const _sessionId = '44f8625f-7f4b-4ffc-b6b0-ec94fcae1f39';

TrainingPlan _plan() => TrainingPlan(
  id: 'wiring-plan',
  proposal: CoachTrainingProposal(
    title: 'Core plan',
    workouts: [
      TrainingWorkout(
        title: 'Core',
        exercises: [
          TrainingExercise(
            name: 'Plank',
            sets: 2,
            durationSeconds: 30,
            restSeconds: 10,
          ),
        ],
      ),
    ],
  ),
);

/// One plank done, the second one waiting: a paused workout checkpoint.
TrainingSessionSnapshot _checkpoint(TrainingPlan plan) =>
    TrainingSessionSnapshot(
      plan: plan,
      sessionId: _sessionId,
      startedAt: _now.subtract(const Duration(minutes: 3)),
      workoutIndex: 0,
      exerciseIndex: 0,
      setIndex: 1,
      phase: TrainingSessionPhase.exercise,
      remainingMilliseconds: 30000,
      completedSets: const [
        TrainingSetReference(exerciseIndex: 0, setIndex: 0),
      ],
      actualSets: [
        TrainingSetActual(
          reference: const TrainingSetReference(exerciseIndex: 0, setIndex: 0),
          completedAt: _now.subtract(const Duration(minutes: 1)),
        ),
      ],
    );

TrainingHistoryEntry _freeLog(String id) => buildLoggedWorkout(
  historyId: id,
  draft: LoggedWorkoutDraft(
    title: 'Back day',
    performedOn: DateTime(2026, 10, 3),
    exercises: const [
      LoggedExercise(
        name: 'Row',
        timed: false,
        sets: [LoggedSet(reps: 10, weightKg: 50)],
      ),
    ],
  ),
  now: _now,
  fallbackTitle: 'Workout',
);

/// The plan's workout done without the player: attached to the plan.
TrainingHistoryEntry _plannedLog(TrainingPlan plan, String id) =>
    buildPlanAttachedLog(
      historyId: id,
      plan: plan,
      workoutIndex: 0,
      sets: const [
        [PlanAttachedSet(done: true), PlanAttachedSet(done: true)],
      ],
      performedOn: DateTime(2026, 10, 3),
      now: _now,
    );

/// Notifications whose taps the test fires by hand.
class _TapNotifications extends NoopNotificationService
    implements NotificationTapSource {
  _TapNotifications({this.launch});

  final String? launch;
  final StreamController<String> controller =
      StreamController<String>.broadcast();
  int launchReads = 0;

  @override
  Stream<String> get taps => controller.stream;

  @override
  Future<String?> launchPayload() async {
    launchReads++;
    return launch;
  }
}

EatovaSync _sync(FixlaufServer server, {String user = kFixlaufUser}) =>
    EatovaSync.forUser(
      SupabaseClient(
        'https://example.supabase.co',
        'test-anon-key',
        httpClient: server.client(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      ),
      user,
    );

FixlaufServer _server({TrainingPlan? plan}) {
  final server = FixlaufServer()
    ..profileRow = serverProfileRow(completedProfile)
    ..coachSessionId = 'coach-session';
  if (plan != null) server.trainingRows[plan.id] = plan.toRow();
  return server;
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required EatovaSync? sync,
  required LocalCache cache,
  NotificationService notifications = const NoopNotificationService(),
}) => pumpLocalized(
  tester,
  EatovaHomePage(
    sync: sync,
    debugCache: cache,
    notificationService: notifications,
  ),
  locale: const Locale('en'),
  surfaceSize: const Size(390, 844),
  scaffold: false,
  safeArea: false,
);

/// The signed-in shell (or the local preview without [server]), booted.
Future<HomeStore> _mount(
  WidgetTester tester, {
  FixlaufServer? server,
  LocalCache? cache,
  NotificationService notifications = const NoopNotificationService(),
}) async {
  await _pumpHome(
    tester,
    sync: server == null ? null : _sync(server),
    cache: cache ?? LocalCache(InMemoryKeyValueStore(), kFixlaufUser),
    notifications: notifications,
  );
  await pumpUntil(
    tester,
    () => find.byKey(const ValueKey('screen-welcome')).evaluate().isEmpty,
    'the account is ready',
  );
  // Offstage too: a resumed player may already cover the shell.
  final store =
      (tester.state(find.byType(EatovaHomePage, skipOffstage: false))
              as HomePageDebugAccess)
          .debugStore;
  await pumpUntil(tester, () => !store.bootLoadInFlight, 'the boot load');
  return store;
}

/// A paused workout of [plan], saved through the store.
Future<void> _saveCheckpoint(
  WidgetTester tester,
  HomeStore store,
  TrainingPlan plan,
) async {
  await pumpUntil(
    tester,
    () => store.trainingPlans.any((p) => p.id == plan.id),
    'the plan is loaded',
  );
  expect(await store.saveTrainingSession(_checkpoint(plan)), isTrue);
  await _frames(tester);
  expect(store.trainingSession?.sessionId, _sessionId);
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await _frames(tester);
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.enterText(target, text);
  await tester.pump();
}

Future<void> _leave(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _frames(tester);
}

CoachChatScreen _coach(WidgetTester tester) =>
    tester.widget<CoachChatScreen>(find.byType(CoachChatScreen));

TrainingPlayerScreen? _player(WidgetTester tester) {
  final player = find.byType(TrainingPlayerScreen);
  return player.evaluate().isEmpty
      ? null
      : tester.widget<TrainingPlayerScreen>(player);
}

bool _editorOpen() =>
    find.byKey(const ValueKey('training-log-save')).evaluate().isNotEmpty;

void main() {
  group('Training log', () {
    testWidgets('Log workout opens the editor; each opening adds one free '
        'log under its own ID', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final plan = _plan();
        final server = _server(plan: plan);
        final store = await _mount(tester, server: server);
        store.setTab(3);
        await _frames(tester);

        for (final (index, name) in ['Row', 'Curl'].indexed) {
          await _tap(tester, 'training-quick-log');
          expect(_editorOpen(), isTrue, reason: 'the log editor opens');
          await _type(tester, 'training-log-exercise-0-name', name);
          await _type(tester, 'training-log-exercise-0-set-0-reps', '10');
          await _tap(tester, 'training-log-save');
          await pumpUntil(
            tester,
            () => store.trainingHistory.length == index + 1,
            'log ${index + 1} reaches the history',
          );
          expect(_editorOpen(), isFalse, reason: 'Add closes the editor');
        }

        final ids = [for (final entry in store.trainingHistory) entry.id];
        expect(ids.toSet(), hasLength(2), reason: 'one ID per opening');
        for (final entry in store.trainingHistory) {
          expect(isLoggedTrainingEntry(entry), isTrue);
          expect(isUuidShape(entry.id), isTrue);
          expect(entry.id, entry.id.toLowerCase());
          expect(server.trainingHistoryRows, contains(entry.id));
        }
        expect(store.trainingPlans.single.id, plan.id, reason: 'no plan');
        await _leave(tester);
      });
    });

    testWidgets('Log as done adds the shown workout attached to its plan', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final plan = _plan();
        final server = _server(plan: plan);
        final store = await _mount(tester, server: server);
        store.setTab(3);
        await _frames(tester);

        await _tap(tester, 'training-log-done');
        expect(_editorOpen(), isTrue);
        expect(store.trainingHistory, isEmpty, reason: 'nothing before Add');
        await _tap(tester, 'training-log-save');
        await pumpUntil(
          tester,
          () => store.trainingHistory.length == 1,
          'the planned workout reaches the history',
        );

        final entry = store.trainingHistory.single;
        expect(isLoggedTrainingEntry(entry), isFalse);
        expect(entry.snapshot.plan.id, plan.id);
        expect(entry.snapshot.workoutIndex, 0);
        expect(entry.snapshot.completedSets, hasLength(2));
        expect(server.trainingHistoryRows, contains(entry.id));
        await _leave(tester);
      });
    });

    testWidgets('"Tell the Coach instead" prepares /log in the Coach, on the '
        'first and on a cached visit, without sending', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final server = _server();
        final store = await _mount(tester, server: server);
        expect(find.byType(CoachChatScreen, skipOffstage: false), findsNothing);

        for (var visit = 0; visit < 2; visit++) {
          store.setTab(3);
          await _frames(tester);
          await _tap(tester, 'training-empty-log-coach');
          expect(store.selectedTab, 4);
          await pumpUntil(
            tester,
            () =>
                tester
                    .widget<TextField>(find.byKey(const ValueKey('coach-input')))
                    .controller!
                    .text ==
                '/log ',
            'the composer holds /log',
          );
          await tester.enterText(
            find.byKey(const ValueKey('coach-input')),
            '',
          );
          await tester.pump();
        }
        expect(
          server.requests.where((r) => r.url.path.contains('/functions/v1/')),
          isEmpty,
          reason: 'preparing /log books nothing',
        );
        await _leave(tester);
      });
    });

    testWidgets('a failed history load is said on Training; Retry reloads it', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final cache = LocalCache(InMemoryKeyValueStore(), kFixlaufUser);
        await cache.writeProfile(completedProfile);
        final server = _server()..offline = true;
        final store = await _mount(tester, server: server, cache: cache);
        expect(store.trainingHistoryLoadFailed, isTrue);
        store.setTab(3);
        await _frames(tester);
        expect(
          find.byKey(const ValueKey('training-history-retry')),
          findsOneWidget,
        );

        server.offline = false;
        await _tap(tester, 'training-history-retry');
        await pumpUntil(
          tester,
          () => !store.bootLoadInFlight && !store.trainingHistoryLoadFailed,
          'the retry loads the history',
        );
        expect(
          find.byKey(const ValueKey('training-history-retry')),
          findsNothing,
        );
        await _leave(tester);
      });
    });

    testWidgets('the local preview offers no logging at all', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final store = await _mount(tester);
        store.setTab(3);
        await _frames(tester);
        expect(find.byKey(const ValueKey('training-empty-log')), findsNothing);
        expect(
          find.byKey(const ValueKey('training-empty-log-coach')),
          findsNothing,
        );
        store.setTab(4);
        await _frames(tester);
        expect(_coach(tester).onLogWorkout, isNull);
        await _leave(tester);
      });
    });
  });

  group('Coach /log', () {
    testWidgets('the card inputs follow the store live: added, removed', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final server = _server();
        final store = await _mount(tester, server: server);
        store.setTab(4);
        await _frames(tester);
        var coach = _coach(tester);
        expect(coach.trainingHistoryAuthoritative, isTrue);
        expect(coach.trainingHistoryIds, isEmpty);

        const id = '0b6f2a9e-1c3d-4e5f-8a7b-6c5d4e3f2a1b';
        final outcome = await coach.onLogWorkout!(_freeLog(id));
        expect(outcome, TrainingLogSaveOutcome.saved);
        await _frames(tester);
        coach = _coach(tester);
        expect(coach.trainingHistoryIds, {id});
        expect(coach.trainingHistory.single.id, id);
        expect(server.trainingHistoryRows, contains(id));

        await store.deleteTrainingHistory(id);
        await _frames(tester);
        coach = _coach(tester);
        expect(coach.trainingHistoryIds, isEmpty);
        expect(coach.trainingHistoryDeletedIds, {id});
        await _leave(tester);
      });
    });

    testWidgets('the adapter flags a plan-backed entry itself: blocked while '
        'a workout is saved, a free log is not', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final plan = _plan();
        final store = await _mount(tester, server: _server(plan: plan));
        await _saveCheckpoint(tester, store, plan);
        store.setTab(4);
        await _frames(tester);
        final save = _coach(tester).onLogWorkout!;

        const planned = '5d4c3b2a-1f0e-4d9c-8b7a-6f5e4d3c2b1a';
        expect(
          await save(_plannedLog(plan, planned)),
          TrainingLogSaveOutcome.blocked,
          reason: 'one session at a time: never counted twice',
        );
        expect(store.trainingHistory, isEmpty);

        const free = '3f2b8c1e-4d5a-4b6c-8d7e-9f0a1b2c3d4e';
        expect(await save(_freeLog(free)), TrainingLogSaveOutcome.saved);
        expect([for (final e in store.trainingHistory) e.id], [free]);
        expect(store.trainingSession?.sessionId, _sessionId);
        await _leave(tester);
      });
    });

    testWidgets('a save after an account change writes nothing', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final server = _server();
        final cache = LocalCache(InMemoryKeyValueStore(), kFixlaufUser);
        final store = await _mount(tester, server: server, cache: cache);
        store.setTab(4);
        await _frames(tester);
        final save = _coach(tester).onLogWorkout!;

        // AuthGate hands the page another account's session.
        await _pumpHome(
          tester,
          sync: _sync(_server(), user: 'user-fixlauf-b'),
          cache: cache,
        );
        await _frames(tester);

        const id = '0b6f2a9e-1c3d-4e5f-8a7b-6c5d4e3f2a1b';
        expect(await save(_freeLog(id)), TrainingLogSaveOutcome.failed);
        await _frames(tester);
        expect(store.trainingHistory, isEmpty);
        expect(server.trainingHistoryRows, isEmpty);
        await _leave(tester);
      });
    });
  });

  group('rest alert taps', () {
    testWidgets('a tap opens Training and resumes the saved workout', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final plan = _plan();
        final notifications = _TapNotifications();
        final store = await _mount(
          tester,
          server: _server(plan: plan),
          notifications: notifications,
        );
        await _saveCheckpoint(tester, store, plan);
        expect(store.selectedTab, 0);

        notifications.controller.add(trainingRestNotificationPayload);
        await pumpUntil(
          tester,
          () => _player(tester) != null,
          'the player opens',
        );
        expect(store.selectedTab, 3);
        expect(_player(tester)!.initialSnapshot?.sessionId, _sessionId);
        expect(find.byType(TrainingPlayerScreen), findsOneWidget);
        await _leave(tester);
      });
    });

    testWidgets('without a saved workout a tap only opens Training', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final notifications = _TapNotifications();
        final store = await _mount(
          tester,
          server: _server(plan: _plan()),
          notifications: notifications,
        );
        notifications.controller.add(trainingRestNotificationPayload);
        await _frames(tester);
        expect(store.selectedTab, 3);
        expect(_player(tester), isNull);
        await _leave(tester);
      });
    });

    testWidgets('another payload, the local preview and another account are '
        'ignored', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final plan = _plan();
        final notifications = _TapNotifications();
        final cache = LocalCache(InMemoryKeyValueStore(), kFixlaufUser);
        final store = await _mount(
          tester,
          server: _server(plan: plan),
          cache: cache,
          notifications: notifications,
        );
        await _saveCheckpoint(tester, store, plan);
        notifications.controller.add('meal-reminder');
        await _frames(tester);
        expect(store.selectedTab, 0);

        await _pumpHome(
          tester,
          sync: _sync(_server(), user: 'user-fixlauf-b'),
          cache: cache,
          notifications: notifications,
        );
        await _frames(tester);
        notifications.controller.add(trainingRestNotificationPayload);
        await _frames(tester);
        expect(store.selectedTab, 0, reason: 'not this account\'s alert');
        expect(_player(tester), isNull);
        await _leave(tester);

        final preview = await _mount(tester, notifications: notifications);
        notifications.controller.add(trainingRestNotificationPayload);
        await _frames(tester);
        expect(preview.selectedTab, 0, reason: 'signed out');
        await _leave(tester);
      });
    });

    testWidgets('the alert that launched the app resumes the cached workout '
        'once the welcome is done', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final plan = _plan();
        final cache = LocalCache(InMemoryKeyValueStore(), kFixlaufUser);
        await cache.writeProfile(completedProfile);
        await cache.writeTrainingPlans([plan]);
        await cache.writeTrainingSession(_checkpoint(plan));
        final notifications = _TapNotifications(
          launch: trainingRestNotificationPayload,
        );
        final store = await _mount(
          tester,
          server: _server(plan: plan),
          cache: cache,
          notifications: notifications,
        );
        await pumpUntil(
          tester,
          () => _player(tester) != null,
          'the player opens',
        );
        expect(store.selectedTab, 3);
        expect(_player(tester)!.initialSnapshot?.sessionId, _sessionId);
        expect(notifications.launchReads, 1);
        await _leave(tester);
      });
    });

    testWidgets('leaving the shell ends the tap subscription', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final notifications = _TapNotifications();
        await _mount(
          tester,
          server: _server(),
          notifications: notifications,
        );
        expect(notifications.controller.hasListener, isTrue);
        await _leave(tester);
        expect(notifications.controller.hasListener, isFalse);
      });
    });
  });

  group('Today', () {
    testWidgets('a saved workout shows "In progress · Resume" and resumes', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final plan = _plan();
        final store = await _mount(tester, server: _server(plan: plan));
        await _saveCheckpoint(tester, store, plan);
        final sub = find.byKey(const ValueKey('today-workout-sub'));
        await tester.scrollUntilVisible(
          sub,
          220,
          scrollable: find.byType(Scrollable).first,
        );
        await _frames(tester);
        expect(tester.widget<Text>(sub).data, 'In progress · Resume');

        await _tap(tester, 'today-workout-row');
        expect(_player(tester)?.initialSnapshot?.sessionId, _sessionId);
        expect(store.selectedTab, 0, reason: 'the player opens over Today');
        await _leave(tester);
      });
    });
  });
}
