// The weekly energy check and the device's step values (docs/WEIGHT-TREND.md,
// stage 2): each window day is modelled with its full-day step total, and
// with a step source only days with their own value count.

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

/// Male, 182 cm, light, −0.5 kg/week: maintenance 2650, goal 2100 kcal.
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

/// 2100 kcal and a weigh-in on each of the [days] days before 4 October;
/// without step values that alone proposes −150 (energy_check_store_test).
FakeServer _server({int days = 22}) {
  final server = FakeServer()..profileRow = serverProfileRow(_live);
  for (var n = 1; n <= days; n++) {
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
      'weight_kg': 84 - 0.02 * (days - n),
    };
  }
  return server;
}

HomeStore _store(FakeServer server, HealthService health, LocalCache cache) {
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
    debugCache: cache,
  );
  addTearDown(store.dispose);
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a new day re-reads the day that ended before the check proposes',
      () async {
    // The session lives across midnight: left open, or suspended and resumed
    // the next day without a cold start.
    var now = DateTime(2026, 10, 3, 12);
    await withClock(Clock(() => now), () async {
      final health = _StepsHealth();
      for (var n = 1; n <= 22; n++) {
        health.fullDay[localDayKey(DateTime(2026, 10, 4 - n))] = 8000;
      }
      final store = _store(
        _server(),
        health,
        LocalCache(InMemoryKeyValueStore(), 'user-outbox'),
      );

      await boot(store);
      // Lunch on 3 October: today's steps so far, pinned as the snapshot.
      health.stepsToday = 3000;
      await store.refreshHealthSteps();
      await settle();
      expect(store.dailyActivity['2026-10-03']!.steps, 3000);
      expect(store.energyCheckStepsReady, isTrue, reason: 'precondition');
      expect(health.dayReads, isNot(contains('2026-10-03')));

      // The next morning 3 October belongs to the window.
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

  test('a step reading today that arrives after the proposal withdraws it',
      () => withClock(Clock.fixed(DateTime(2026, 10, 4, 12)), () async {
    // The health store has no history for the window; today's value is in
    // the cache from earlier today, and the reading repeats it.
    final kv = InMemoryKeyValueStore();
    final cache = LocalCache(kv, 'user-outbox');
    await cache.writeDailyActivity(<String, ({int steps, int kcal})>{
      '2026-10-04': (
        steps: 4000,
        kcal: estimateKcalBurnedFromSteps(
          steps: 4000,
          weightKg: _live.weightKg,
          heightCm: _live.heightCm,
          sex: _live.sex,
        ),
      ),
    });
    final health = _StepsHealth()..stepsToday = 4000;
    final store = _store(_server(), health, cache);

    await boot(store);
    expect(store.energyCheckProposal?.stepKcal, -150,
        reason: 'no step source known yet: the model has no steps');

    await store.refreshHealthSteps();
    await settle();

    expect(store.stepsForFoodDate(clock.now()), 4000, reason: 'precondition');
    expect(store.energyCheckProposal, isNull,
        reason: 'a step source, but no window day has a step value');
  }));
}
