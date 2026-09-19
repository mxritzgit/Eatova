import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/screens/today/today_hero.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

import 'fixlauf_a_helpers.dart';
import 'flows/flow_test_helpers.dart' show pumpUntil, settleFrames, storeOf;
import 'support/harness.dart';

final _today = DateTime(2026, 9, 19, 12);
const _profile = UserProfile(
  dailyKcalGoal: 2000,
  weightKg: 80,
  heightCm: 181,
  onboardingCompleted: true,
  manualEnergy: true,
);

class _Health extends NoopHealthService implements HealthConnectAccess {
  HealthSnapshot? snapshot;

  @override
  HealthAuthState get authState => HealthAuthState.granted;

  @override
  Future<HealthSnapshot?> readSnapshot() async => snapshot;

  @override
  Future<bool> openSettings() async => false;

  @override
  void restoreConnection() {}
}

void _snack(
  String message, {
  IconData icon = Icons.info_outline,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

MealAnalysisResult _meal(int kcal) => MealAnalysisResult(
  mealName: 'Lunch',
  caloriesKcal: kcal,
  estimatedGrams: 500,
  kcalPer100G: kcal / 5,
  protein: '30 g',
  carbs: '50 g',
  fat: '15 g',
  confidence: 'Mittel',
  portionNotes: '',
  sourceLabel: 'Test',
);

String _coachContext(WidgetTester tester) =>
    tester.widget<CoachChatScreen>(find.byType(CoachChatScreen)).userContext!;

void main() {
  for (final scenario in [
    (
      name: 'current measured activity',
      steps: 10000,
      eaten: 500,
      left: 1800,
      text: '1.800',
    ),
    (
      name: 'unknown activity',
      steps: null,
      eaten: 500,
      left: 1500,
      text: '1.500',
    ),
    (name: 'over budget', steps: 10000, eaten: 2500, left: -200, text: '200'),
  ]) {
    testWidgets('Coach and Today agree with ${scenario.name}', (tester) async {
      await withClock(Clock.fixed(_today), () async {
        final health = _Health();
        if (scenario.steps case final int steps) {
          health.snapshot = HealthSnapshot(
            stepsToday: steps,
            fetchedAt: _today,
          );
        }
        final store = HomeStore(
          sync: null,
          health: health,
          notificationService: const NoopNotificationService(),
          initialUserName: 'Test',
          emitSnack: _snack,
        )..profile = _profile;
        addTearDown(store.dispose);
        await store.refreshHealthSteps();
        store.addResultToDailyTotal(_meal(scenario.eaten));
        final bonus = scenario.steps == null ? 0 : 300;
        expect(store.burnedKcalForFoodDate(_today), bonus);

        await pumpLocalized(
          tester,
          TodayCalorieHero(
            consumedKcal: store.dailyConsumedKcal,
            burnedKcal: store.burnedKcalForFoodDate(_today),
            kcalGoal: store.profile.dailyKcalGoal,
            streak: 0,
          ),
        );
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('today-kcal-remaining')))
              .data,
          scenario.text,
        );
        expect(
          find.text(scenario.left < 0 ? 'kcal drüber' : 'kcal übrig'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('today-kcal-goal')))
              .data,
          contains('2.000 kcal'),
        );
        expect(
          store.coachContext,
          contains('(noch ${scenario.left} kcal übrig).'),
        );
        expect(store.coachContext, contains('von ${2000 + bonus} kcal'));
        expect(
          store.coachContext,
          contains('Basisziel: 2000 kcal; Aktivitätsbonus: $bonus kcal.'),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      });
    });
  }

  testWidgets(
    'mounted Coach receives changed activity and snapshot freshness',
    (tester) async {
      var now = _today;
      await withClock(Clock(() => now), () async {
        pinPhoneViewport(tester);
        final health = _Health();
        final server = FixlaufServer()..profileRow = serverProfileRow(_profile);
        // Mock transport owns no sockets; Supabase disposal waits on fake async
        // (same lifecycle as the signed-in flow harness).
        final client = SupabaseClient(
          'https://example.supabase.co',
          'test-anon-key',
          httpClient: server.client(),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        await pumpLocalized(
          tester,
          EatovaHomePage(
            healthService: health,
            sync: EatovaSync.forUser(client, kFixlaufUser),
            debugCache: LocalCache(InMemoryKeyValueStore(), kFixlaufUser),
          ),
          reducedMotion: false,
          scaffold: false,
          safeArea: false,
        );
        await pumpUntil(
          tester,
          () => find.byKey(const ValueKey('screen-welcome')).evaluate().isEmpty,
          'boot completes',
        );
        final store = storeOf(tester);
        store.addResultToDailyTotal(_meal(500));
        store.setTab(4);
        await settleFrames(tester);
        expect(_coachContext(tester), contains('(noch 1500 kcal übrig).'));

        health.snapshot = HealthSnapshot(stepsToday: 10000, fetchedAt: now);
        await store.refreshHealthSteps();
        await settleFrames(tester);
        expect(
          _coachContext(tester),
          contains('(noch 1800 kcal übrig).'),
          reason: 'The already-mounted Coach must receive the activity bonus.',
        );

        final afterBonus = debugTabBuilds[4];
        health.snapshot = HealthSnapshot(
          stepsToday: 10000,
          fetchedAt: now.add(const Duration(minutes: 1)),
        );
        await store.refreshHealthSteps();
        await settleFrames(tester);
        expect(
          debugTabBuilds[4],
          afterBonus,
          reason: 'An unchanged valid bonus does not rebuild the Coach.',
        );

        // Only freshness changes: the meal remains an archive entry and the
        // same raw steps cannot count toward a different day's budget.
        now = DateTime(2026, 9, 20, 12);
        store.maybeRollOverToToday();
        await settleFrames(tester);
        expect(_coachContext(tester), contains('(noch 2000 kcal übrig).'));

        health.snapshot = HealthSnapshot(stepsToday: 10000, fetchedAt: now);
        await store.refreshHealthSteps();
        await settleFrames(tester);
        expect(
          _coachContext(tester),
          contains('(noch 2300 kcal übrig).'),
          reason: 'The same step count becomes valid again after a fresh read.',
        );

        await tester.pumpWidget(const SizedBox.shrink());
      });
    },
  );
}
