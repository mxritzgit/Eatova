// The weekly energy check models the window's step values as full-day totals
// (docs/WEIGHT-TREND.md, stage 2). A session that lives across midnight (the
// app left open, or suspended and resumed the next day without a cold start)
// holds the day that just ended only as its last in-day snapshot, so the check
// waits until that day is re-read from the health store.

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/meals_sync.dart' show mealResultToJson;
import 'package:eatova/src/services/notification_service.dart';

import 'outbox/outbox_test_helpers.dart';

/// Steps for today from the snapshot, full-day totals from the history.
class _StepsHealth implements HealthService {
  int stepsToday = 0;
  final Map<String, int> fullDay = <String, int>{};
  final List<String> dayReads = <String>[];

  @override
  HealthAuthState get authState => HealthAuthState.granted;

  @override
  void reset() {}

  @override
  Future<HealthAuthState> requestAuthorization() async =>
      HealthAuthState.granted;

  @override
  Future<HealthSnapshot?> readSnapshot() async =>
      HealthSnapshot(stepsToday: stepsToday, fetchedAt: clock.now());

  @override
  Future<int?> readStepsOnDay(DateTime day) async {
    dayReads.add(localDayKey(day));
    return fullDay[localDayKey(day)];
  }

  @override
  Future<bool> writeWeight(double kg, DateTime when) async => false;
}

final UserProfile _live = const KcalCalculator().applyLiveGoals(
  const UserProfile(
    weightKg: 84,
    heightCm: 182,
    ageYears: 31,
    sex: BiologicalSex.male,
    activityLevel: ActivityLevel.light,
    targetWeightKg: 70,
    weightGoal: WeightGoal.lose05kg,
    onboardingCompleted: true,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a new day re-reads the day that ended before the check proposes',
      () async {
    var now = DateTime(2026, 10, 3, 12);
    await withClock(Clock(() => now), () async {
      final server = FakeServer()..profileRow = serverProfileRow(_live);
      final health = _StepsHealth();
      for (var n = 1; n <= 22; n++) {
        final day = DateTime(2026, 10, 4 - n, 12);
        server.mealRows['meal-$n'] = <String, dynamic>{
          'id': '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}',
          'logged_at': day.toUtc().toIso8601String(),
          'forced_slot': null,
          'local_day': localDayKey(day),
          'payload': mealResultToJson(mealResult('Essen', kcal: 2100)),
        };
        server.weightRows['w$n'] = <String, dynamic>{
          'recorded_at': day.toUtc().toIso8601String(),
          'weight_kg': 84 - 0.02 * (22 - n),
        };
        health.fullDay[localDayKey(day)] = 8000;
      }
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-anon-key',
        httpClient: server.client(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      final store = HomeStore(
        sync: EatovaSync.forUser(client, 'user-outbox'),
        health: health,
        notificationService: const NoopNotificationService(),
        initialUserName: 'Test',
        emitSnack: SnackCapture().call,
        debugCache: LocalCache(InMemoryKeyValueStore(), 'user-outbox'),
      );
      addTearDown(store.dispose);

      await boot(store);
      // Lunch on 3 October: today's steps so far, pinned as the snapshot.
      health.stepsToday = 3000;
      await store.refreshHealthSteps();
      await settle();
      expect(store.dailyActivity['2026-10-03']!.steps, 3000);
      expect(store.energyCheckStepsReady, isTrue, reason: 'precondition');
      expect(health.dayReads, isNot(contains('2026-10-03')));

      // Resumed the next morning: 3 October now belongs to the window.
      now = DateTime(2026, 10, 4, 9);
      store.maybeRollOverToToday();
      expect(store.energyCheckStepsReady, isFalse,
          reason: 'the ended day still holds its lunch-time snapshot');
      expect(store.energyCheckProposal, isNull);

      await settle();
      expect(health.dayReads, contains('2026-10-03'));
      expect(store.dailyActivity['2026-10-03']!.steps, 8000,
          reason: 'the full-day total replaces the snapshot');
      expect(store.energyCheckStepsReady, isTrue);
    });
  });
}
