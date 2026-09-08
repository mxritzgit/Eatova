import 'package:clock/clock.dart';
import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
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
          TrainingWorkout(title: 'Einheit A', exercises: [
            TrainingExercise(
              name: 'Unterarmstütz',
              sets: 2,
              durationSeconds: 30,
              restSeconds: 10,
            ),
          ]),
        ],
      ),
    );

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<HomeStore> _mount(WidgetTester tester, LocalCache cache,
    {bool connected = false}) async {
  final server = FixlaufServer()
    ..profileRow = serverProfileRow(completedProfile);
  final client = connected
      ? SupabaseClient('https://example.supabase.co', 'test-anon-key',
          httpClient: server.client(),
          authOptions: const AuthClientOptions(autoRefreshToken: false))
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
  await pumpUntil(tester,
      () => find.byKey(const ValueKey('screen-welcome')).evaluate().isEmpty,
      'the mock account is ready');
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
  testWidgets('Training opens /plan on first and cached Coach mount without sending',
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
        expect(input.controller!.text, '/plan ');
        expect(store.trainingPlans, isEmpty);
        expect(find.byKey(const ValueKey('coach-plan-card')), findsNothing);
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
