import 'package:clock/clock.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/screens/training/training_history_screen.dart';
import 'package:eatova/src/screens/training/training_player_screen.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fixlauf_a_helpers.dart';
import 'flow_test_helpers.dart';

final _now = DateTime(2026, 9, 10, 12);

TrainingPlan _plan() => TrainingPlan(
  id: 'core-feature-plan',
  proposal: CoachTrainingProposal(
    title: 'Strength at home',
    workouts: [
      TrainingWorkout(title: 'Session A', exercises: [
        TrainingExercise(name: 'Squat', sets: 1, reps: 8, restSeconds: 0),
      ]),
    ],
  ),
);

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await settleFrames(tester);
}

void main() {
  testWidgets('recipes open the meal planner bound to the same signed-in store', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final server = FixlaufServer()..profileRow = serverProfileRow(completedProfile);
      final store = await pumpSignedIn(tester, server);
      store.setTab(2);
      await settleFrames(tester);
      await _tap(tester, 'recipe-meal-plan-button');
      final planner = tester.widget<MealPlanScreen>(find.byType(MealPlanScreen));
      expect(identical(planner.store, store), isTrue);
      expect(store.selectedTab, 2);
      expect(store.dailyConsumedKcal, 0);
      await tester.pageBack();
      await settleFrames(tester);
      expect(find.byKey(const ValueKey('screen-recipes')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleFrames(tester);
    });
  });

  testWidgets('discuss plan opens its saved snapshot without booking a request', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final server = FixlaufServer()..profileRow = serverProfileRow(completedProfile);
      final store = await pumpSignedIn(tester, server);
      final plan = _plan();
      await store.saveTrainingPlan(plan);
      store.setTab(3);
      await settleFrames(tester);
      await _tap(tester, 'training-discuss-plan');
      expect(store.selectedTab, 4);
      expect(find.byKey(const ValueKey('coach-brief-scroll')), findsOneWidget);
      final coach = tester.widget<CoachChatScreen>(find.byType(CoachChatScreen));
      expect(coach.selectedPlanForCoach?.id, plan.id);
      expect(coach.selectedPlanForCoach?.workouts.single.exercises.single.reps, 8);
      expect(server.requests.where((r) => r.url.path.contains('/functions/v1/')), isEmpty);
      await _tap(tester, 'coach-brief-close');
      expect(store.trainingPlans.single.id, plan.id);
      expect(store.trainingHistory, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleFrames(tester);
    });
  });

  testWidgets('actual workout reaches history and Last time through shell callbacks', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final server = FixlaufServer()..profileRow = serverProfileRow(completedProfile);
      final raw = InMemoryKeyValueStore();
      final store = await pumpSignedIn(tester, server, store: raw);
      final plan = _plan();
      await store.saveTrainingPlan(plan);
      store.setTab(3);
      await settleFrames(tester);
      await _tap(tester, 'training-start');
      await tester.enterText(find.byKey(const ValueKey('training-actual-reps')), '10');
      await tester.enterText(find.byKey(const ValueKey('training-actual-weight')), '12.5');
      await tester.testTextInput.hide();
      await settleFrames(tester);
      await _tap(tester, 'training-timer-primary');
      await _tap(tester, 'training-timer-primary');
      await _tap(tester, 'training-timer-confirm-exit');
      await pumpUntil(tester, () => find.byType(TrainingPlayerScreen).evaluate().isEmpty,
          'confirmed completion leaves only after a durable receipt');
      final entry = store.trainingHistory.single;
      expect(entry.snapshot.actualSets.single.reps, 10);
      expect(entry.snapshot.actualSets.single.weightKg, 12.5);
      expect(store.trainingSession, isNull);
      expect(server.trainingHistoryRows.keys, [entry.id]);
      expect((await LocalCache(raw, kFixlaufUser).readTrainingHistory())!.single.id, entry.id);
      await _tap(tester, 'training-open-history');
      expect(find.byType(TrainingHistoryScreen), findsOneWidget);
      await _tap(tester, 'training-history-${entry.id}');
      expect(find.byType(TrainingHistoryDetail), findsOneWidget);
      await tester.pageBack();
      await settleFrames(tester);
      await tester.pageBack();
      await settleFrames(tester);
      await _tap(tester, 'training-start');
      final player = tester.widget<TrainingPlayerScreen>(find.byType(TrainingPlayerScreen));
      expect(player.history.single.id, entry.id);
      expect(find.text('Last time'), findsOneWidget);
      await _tap(tester, 'training-timer-discard');
      await _tap(tester, 'training-timer-confirm-exit');
      await pumpUntil(tester, () => find.byType(TrainingPlayerScreen).evaluate().isEmpty,
          'discard leaves without another history entry');
      expect(store.trainingHistory, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await settleFrames(tester);
    });
  });
}
