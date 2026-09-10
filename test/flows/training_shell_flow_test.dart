import 'dart:async';

import 'package:clock/clock.dart';
import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/screens/training/training_player_screen.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import '../fixlauf_a_helpers.dart';
import '../support/harness.dart';
import 'flow_test_helpers.dart' show pumpUntil;

final _now = DateTime(2026, 9, 8, 12);

TrainingPlan _plan() => TrainingPlan(
  id: 'coach_shell-plan',
  proposal: CoachTrainingProposal(
    title: 'Mein Trainingsplan',
    workouts: [
      TrainingWorkout(
        title: 'Einheit A',
        exercises: [
          TrainingExercise(
            name: 'Unterarmstütz',
            sets: 2,
            durationSeconds: 30,
            restSeconds: 10,
          ),
        ],
      ),
    ],
  ),
);

class _FailSessionCache extends LocalCache {
  _FailSessionCache() : super(InMemoryKeyValueStore(), kFixlaufUser);
  bool fail = false;

  @override
  Future<bool> writeTrainingSession(TrainingSessionSnapshot? snapshot) async =>
      fail ? false : super.writeTrainingSession(snapshot);
}

class _FailRecoveryReadCache extends LocalCache {
  _FailRecoveryReadCache() : super(InMemoryKeyValueStore(), kFixlaufUser);

  bool failDeletionReads = true;
  Completer<void>? repairGate;
  int deletionReads = 0;
  int sessionWrites = 0;

  @override
  Future<Set<String>> readTrainingHistoryDeletions() async {
    deletionReads++;
    if (failDeletionReads) throw StateError('Simulated encrypted storage error');
    await repairGate?.future;
    return super.readTrainingHistoryDeletions();
  }

  @override
  Future<bool> writeTrainingSession(TrainingSessionSnapshot? snapshot) {
    sessionWrites++;
    return super.writeTrainingSession(snapshot);
  }
}

TrainingSessionSnapshot _savedRecovery(TrainingPlan plan) =>
    TrainingSessionSnapshot(
      plan: plan,
      sessionId: '44f8625f-7f4b-4ffc-b6b0-ec94fcae1f39',
      startedAt: _now.subtract(const Duration(minutes: 3)),
      workoutIndex: 0,
      exerciseIndex: 0,
      setIndex: 1,
      phase: TrainingSessionPhase.exercise,
      remainingMilliseconds: 12000,
      completedSets: const [
        TrainingSetReference(exerciseIndex: 0, setIndex: 0),
      ],
      actualSets: [
        TrainingSetActual(
          reference: const TrainingSetReference(exerciseIndex: 0, setIndex: 0),
          completedAt: _now.subtract(const Duration(minutes: 1)),
        ),
      ],
      recoveryNote: 'Keep my saved progress',
    );

Future<HomeStore> _mountHiddenRecovery(
  WidgetTester tester,
  _FailRecoveryReadCache cache,
  TrainingSessionSnapshot snapshot,
) async {
  await cache.writeProfile(completedProfile);
  await cache.writeTrainingPlans([snapshot.plan]);
  await cache.writeTrainingSession(snapshot);
  final server = FixlaufServer();
  server.trainingRows[snapshot.plan.id] = snapshot.plan.toRow();
  final store = await _mount(
    tester,
    cache,
    connected: true,
    serverOverride: server,
  );
  await pumpUntil(tester, () => !store.bootLoadInFlight,
      'cached recovery and server plans are loaded');
  expect(cache.deletionReads, greaterThan(0));
  expect(store.trainingSession, isNull);
  expect((await cache.readTrainingSession())?.toJson(), snapshot.toJson());
  store.setTab(3);
  await _frames(tester);
  expect(find.byKey(const ValueKey('training-resume')), findsNothing);
  return store;
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<HomeStore> _mount(
  WidgetTester tester,
  LocalCache cache, {
  bool connected = false,
  FixlaufServer? serverOverride,
}) async {
  final server = serverOverride ?? FixlaufServer()
    ..profileRow = serverProfileRow(completedProfile);
  final client = connected
      ? SupabaseClient(
          'https://example.supabase.co',
          'test-anon-key',
          httpClient: server.client(),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        )
      : null;
  await pumpLocalized(
    tester,
    EatovaHomePage(
      debugCache: cache,
      sync: client == null ? null : EatovaSync.forUser(client, kFixlaufUser),
    ),
    surfaceSize: const Size(390, 844),
    scaffold: false,
    safeArea: false,
  );
  await pumpUntil(
    tester,
    () => find.byKey(const ValueKey('screen-welcome')).evaluate().isEmpty,
    'the mock account is ready',
  );
  await _frames(tester);
  return (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
      .debugStore;
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await _frames(tester);
}

void main() {
  testWidgets('start repairs a hidden recovery before creating a player', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final cache = _FailRecoveryReadCache();
      final snapshot = _savedRecovery(_plan());
      final store = await _mountHiddenRecovery(tester, cache, snapshot);
      cache.failDeletionReads = false;

      await _tap(tester, 'training-start');

      final player = tester.widget<TrainingPlayerScreen>(
        find.byType(TrainingPlayerScreen),
      );
      expect(player.initialSnapshot?.toJson(), snapshot.toJson());
      expect(store.trainingSession?.toJson(), snapshot.toJson());
      expect((await cache.readTrainingSession())?.toJson(), snapshot.toJson());
      await tester.pumpWidget(const SizedBox.shrink());
      await _frames(tester);
    });
  });

  testWidgets('unavailable recovery blocks start and allows a safe retry', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final cache = _FailRecoveryReadCache();
      final snapshot = _savedRecovery(_plan());
      await _mountHiddenRecovery(tester, cache, snapshot);
      final writesBeforeStart = cache.sessionWrites;
      final message = tester.element(find.byType(EatovaHomePage))
          .l10n.commonGenericRetryError;

      await _tap(tester, 'training-start');

      expect(find.byType(TrainingPlayerScreen), findsNothing);
      expect(find.text(message), findsOneWidget);
      expect(cache.sessionWrites, writesBeforeStart);
      expect((await cache.readTrainingSession())?.toJson(), snapshot.toJson());

      cache.failDeletionReads = false;
      await _tap(tester, 'training-start');
      expect(tester.widget<TrainingPlayerScreen>(
        find.byType(TrainingPlayerScreen),
      ).initialSnapshot?.sessionId, snapshot.sessionId);
      await tester.pumpWidget(const SizedBox.shrink());
      await _frames(tester);
    });
  });

  testWidgets('repeated starts share one pending repair and one player route', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final cache = _FailRecoveryReadCache();
      final snapshot = _savedRecovery(_plan());
      await _mountHiddenRecovery(tester, cache, snapshot);
      final previousReads = cache.deletionReads;
      cache.failDeletionReads = false;
      final repair = cache.repairGate = Completer<void>();

      await _tap(tester, 'training-start');
      await _tap(tester, 'training-start');
      expect(find.byType(TrainingPlayerScreen), findsNothing);
      expect(cache.deletionReads, previousReads + 1);

      repair.complete();
      await _frames(tester);
      expect(find.byType(TrainingPlayerScreen, skipOffstage: false),
          findsOneWidget);
      expect((await cache.readTrainingSession())?.toJson(), snapshot.toJson());
      await tester.pumpWidget(const SizedBox.shrink());
      await _frames(tester);
    });
  });

  testWidgets('sign out during recovery repair cannot open a player', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final cache = _FailRecoveryReadCache();
      final snapshot = _savedRecovery(_plan());
      final store = await _mountHiddenRecovery(tester, cache, snapshot);
      cache.failDeletionReads = false;
      final repair = cache.repairGate = Completer<void>();
      await _tap(tester, 'training-start');
      expect(find.byType(TrainingPlayerScreen), findsNothing);
      final writesBeforeSignOut = cache.sessionWrites;

      await tester.runAsync(() async {
        final signOut = store.signOutCleanup();
        repair.complete();
        await signOut;
      });
      await _frames(tester);

      expect(find.byType(TrainingPlayerScreen, skipOffstage: false), findsNothing);
      expect(cache.sessionWrites, writesBeforeSignOut);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _frames(tester);
    });
  });

  for (final sourceChange in ['removed', 'changed']) {
    for (final exit in ['save', 'discard', 'finish']) {
      testWidgets('retired player can $exit after boot source is $sourceChange', (
        tester,
      ) async {
        await withClock(Clock.fixed(_now), () async {
          final storage = InMemoryKeyValueStore();
          final cache = LocalCache(storage, kFixlaufUser);
          final source = _plan();
          final snapshot = TrainingSessionSnapshot(
            plan: source,
            workoutIndex: 0,
            exerciseIndex: 0,
            setIndex: exit == 'finish' ? 1 : 0,
            phase: exit == 'finish'
                ? TrainingSessionPhase.review
                : TrainingSessionPhase.exercise,
            remainingMilliseconds: exit == 'finish' ? 0 : 30000,
            completedSets: exit == 'finish'
                ? const [
                    TrainingSetReference(exerciseIndex: 0, setIndex: 0),
                    TrainingSetReference(exerciseIndex: 0, setIndex: 1),
                  ]
                : const [],
            actualSets: exit == 'finish'
                ? [
                    TrainingSetActual(
                      reference: const TrainingSetReference(exerciseIndex: 0, setIndex: 0),
                      completedAt: _now,
                    ),
                    TrainingSetActual(
                      reference: const TrainingSetReference(exerciseIndex: 0, setIndex: 1),
                      completedAt: _now,
                    ),
                  ]
                : const [],
          );
          await cache.writeProfile(completedProfile);
          await cache.writeTrainingPlans([source]);
          await cache.writeTrainingSession(snapshot);
          final server = FixlaufServer()..holdReads = true;
          if (sourceChange == 'changed') {
            server.trainingRows[source.id] = source
                .copyWith(
                  proposal: CoachTrainingProposal(
                    title: source.title,
                    workouts: [
                      source.workouts.single.copyWith(title: 'Changed source'),
                    ],
                  ),
                )
                .toRow();
          }
          final store = await _mount(
            tester,
            cache,
            connected: true,
            serverOverride: server,
          );
          expect(store.bootLoadInFlight, isTrue);
          store.setTab(3);
          await _frames(tester);
          await _tap(tester, 'training-resume');
          final stalePersist = tester
              .widget<TrainingPlayerScreen>(find.byType(TrainingPlayerScreen))
              .onPersist;
          server.holdReads = false;
          server.releaseReads();
          await pumpUntil(
            tester,
            () => !store.bootLoadInFlight,
            'authoritative source removal finishes',
          );
          expect(store.trainingSession, isNull);
          // A replacement session may belong to the same re-adopted source
          // or a different plan; an obsolete player must touch neither.
          final replacement = TrainingPlan(
            id: exit == 'finish' ? source.id : 'new-session-plan',
            proposal: source.proposal,
          );
          await store.saveTrainingPlan(replacement);
          final replacementSnapshot = TrainingSessionSnapshot(
            plan: replacement,
            workoutIndex: 0,
            exerciseIndex: 0,
            setIndex: 0,
            phase: TrainingSessionPhase.exercise,
            remainingMilliseconds: 12000,
          );
          await store.saveTrainingSession(replacementSnapshot);
          const checkpointKey = 'eatova.v1.training_session.$kFixlaufUser';
          final savedBytes = storage.snapshot[checkpointKey];
          await _tap(
            tester,
            exit == 'save'
                ? 'training-timer-back'
                : exit == 'discard'
                ? 'training-timer-discard'
                : 'training-timer-primary',
          );
          await _tap(tester, 'training-timer-confirm-exit');
          await pumpUntil(
            tester,
            () => find.byType(TrainingPlayerScreen).evaluate().isEmpty,
            'retired player closes without saving',
          );
          expect(
            find.byType(TrainingPlayerScreen),
            findsNothing,
            reason:
                'Retired recovery must not trap the player in a save-error loop',
          );
          await stalePersist(snapshot);
          await stalePersist(null);
          expect(storage.snapshot[checkpointKey], savedBytes);
          expect(store.trainingSession?.toJson(), replacementSnapshot.toJson());
          await tester.pumpWidget(const SizedBox.shrink());
          await _frames(tester);
        });
      });
    }
  }

  testWidgets('failed save can retry leaving after source retirement', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final cache = _FailSessionCache();
      final source = _plan();
      final snapshot = TrainingSessionSnapshot(
        plan: source,
        workoutIndex: 0,
        exerciseIndex: 0,
        setIndex: 0,
        phase: TrainingSessionPhase.exercise,
        remainingMilliseconds: 30000,
      );
      await cache.writeProfile(completedProfile);
      await cache.writeTrainingPlans([source]);
      await cache.writeTrainingSession(snapshot);
      final server = FixlaufServer()..holdReads = true;
      final store = await _mount(
        tester,
        cache,
        connected: true,
        serverOverride: server,
      );
      store.setTab(3);
      await _frames(tester);
      await _tap(tester, 'training-resume');
      cache.fail = true;
      await _tap(tester, 'training-timer-back');
      await _tap(tester, 'training-timer-confirm-exit');
      await pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey('training-timer-save-error'))
            .evaluate()
            .isNotEmpty,
        'ordinary storage failure remains retryable',
      );
      expect(find.byType(TrainingPlayerScreen), findsOneWidget);
      server.holdReads = false;
      server.releaseReads();
      await pumpUntil(
        tester,
        () => !store.bootLoadInFlight,
        'source retirement completes despite failed cleanup',
      );
      expect(store.trainingSession, isNull);
      await _tap(tester, 'training-timer-retry');
      await pumpUntil(
        tester,
        () => find.byType(TrainingPlayerScreen).evaluate().isEmpty,
        'retry leaves the retired source without writing',
      );
      expect((await cache.readTrainingSession())?.toJson(), snapshot.toJson());
      await tester.pumpWidget(const SizedBox.shrink());
      await _frames(tester);
    });
  });

  testWidgets('saved workout disappears from resume after confirmed plan deletion',
      (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final cache = LocalCache(InMemoryKeyValueStore(), kFixlaufUser);
      final store = await _mount(tester, cache, connected: true);
      await store.saveTrainingPlan(_plan());
      store.setTab(3);
      await _frames(tester);
      await _tap(tester, 'training-start');
      await _tap(tester, 'training-timer-back');
      await _tap(tester, 'training-timer-confirm-exit');
      await pumpUntil(tester,
          () => find.byType(TrainingPlayerScreen).evaluate().isEmpty,
          'save and leave finishes');
      expect(find.byKey(const ValueKey('training-resume')), findsOneWidget);
      await _tap(tester, 'training-plan-menu');
      await tester.tap(find.byWidgetPredicate((widget) =>
          widget is PopupMenuItem<String> && widget.value == 'delete'));
      await _frames(tester);
      await _tap(tester, 'training-delete-confirm');
      await pumpUntil(tester, () => store.trainingPlans.isEmpty,
          'confirmed plan deletion finishes');
      expect(find.byKey(const ValueKey('training-resume')), findsNothing);
      expect(await cache.readTrainingSession(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _frames(tester);
    });
  });

  testWidgets('Training opens its brief on first and cached Coach mount without sending',
      (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final cache = LocalCache(InMemoryKeyValueStore(), kFixlaufUser);
      final store = await _mount(tester, cache);
      expect(find.byType(CoachChatScreen, skipOffstage: false), findsNothing);

      for (var visit = 0; visit < 2; visit++) {
        store.setTab(3);
        await _frames(tester);
        await _tap(tester, 'training-empty-coach');
        expect(store.selectedTab, 4);
        final input = tester.widget<TextField>(
          find.byKey(const ValueKey('coach-input')),
        );
        expect(input.controller!.text, isEmpty);
        expect(find.byKey(const ValueKey('coach-brief-scroll')), findsOneWidget);
        expect(find.byKey(const ValueKey('coach-brief-submit')), findsOneWidget);
        expect(store.trainingPlans, isEmpty);
        expect(find.byKey(const ValueKey('coach-plan-card')), findsNothing);
        await _tap(tester, 'coach-brief-close');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await _frames(tester);
    });
  });

  testWidgets('shell adoption updates both tabs and paused player survives route exit',
      (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final cache = LocalCache(InMemoryKeyValueStore(), kFixlaufUser);
      final store = await _mount(tester, cache, connected: true);
      store.setTab(4);
      await _frames(tester);
      var coach = tester.widget<CoachChatScreen>(find.byType(CoachChatScreen));
      final plan = _plan();
      await coach.onCreateTrainingPlan!(plan);
      await _frames(tester);
      coach = tester.widget<CoachChatScreen>(find.byType(CoachChatScreen));
      expect(coach.userTrainingPlanIds, {plan.id});
      coach.onOpenTraining!();
      await _frames(tester);
      expect(store.selectedTab, 3);
      expect(find.text(plan.title), findsOneWidget);

      await _tap(tester, 'training-start');
      expect(find.byType(TrainingPlayerScreen), findsOneWidget);
      expect(store.trainingSession?.plan.id, plan.id);
      await _tap(tester, 'training-timer-forward');
      expect(store.trainingSession?.remainingMilliseconds, 20000);
      await _tap(tester, 'training-timer-rewind');
      expect(store.trainingSession?.remainingMilliseconds, 30000);
      await _tap(tester, 'training-timer-back');
      await _tap(tester, 'training-timer-confirm-exit');
      await pumpUntil(tester,
          () => find.byType(TrainingPlayerScreen).evaluate().isEmpty,
          'the paused checkpoint is durable before route exit');
      expect(find.byType(TrainingPlayerScreen), findsNothing);
      expect((await cache.readTrainingSession())?.remainingMilliseconds, 30000);
      expect(find.byKey(const ValueKey('training-resume')), findsOneWidget);

      await _tap(tester, 'training-resume');
      expect(find.text('Pausiert'), findsOneWidget);
      await _tap(tester, 'training-timer-discard');
      await _tap(tester, 'training-timer-confirm-exit');
      await pumpUntil(tester,
          () => find.byType(TrainingPlayerScreen).evaluate().isEmpty,
          'the discarded checkpoint is cleared before route exit');
      expect(find.byType(TrainingPlayerScreen), findsNothing);
      expect(store.trainingSession, isNull);
      expect(await cache.readTrainingSession(), isNull);
      expect(store.trainingPlans.single.id, plan.id);

      await store.deleteTrainingPlan(plan.id);
      await _frames(tester);
      store.setTab(4);
      await _frames(tester);
      coach = tester.widget<CoachChatScreen>(find.byType(CoachChatScreen));
      expect(coach.userTrainingPlanIds, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await _frames(tester);
    });
  });
}
