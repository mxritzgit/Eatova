// The weekly energy check in the store (docs/WEIGHT-TREND.md, stage 2):
// today's proposal from server-answered data, and the two answers.

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/meals_sync.dart'
    show MealsSync, mealResultToJson;

import 'outbox/outbox_test_helpers.dart';

/// Noon on 3 October; the window is 12 September .. 2 October.
final DateTime _now = DateTime(2026, 10, 3, 12);

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
    diet: DietPreference.none,
    onboardingCompleted: true,
  ),
);

DateTime _daysAgo(int n) => DateTime(_now.year, _now.month, _now.day - n, 12);

Map<String, dynamic> _meal(String id, DateTime at, int kcal) =>
    <String, dynamic>{
      'id': id,
      'logged_at': at.toUtc().toIso8601String(),
      'forced_slot': null,
      'local_day': localDayKey(at),
      'payload': mealResultToJson(mealResult('Essen', kcal: kcal)),
    };

/// 21 days of 2100 kcal and a daily weigh-in losing 0.02 kg/day. No step
/// source in the fake, so the model has no steps: observed 2254 against
/// 2650 is −396, beyond the ≈277 noise guard -> −150.
void _seedThreeWeeks(FakeServer server) {
  server.profileRow = serverProfileRow(_live);
  for (var n = 1; n <= 21; n++) {
    server.mealRows['meal-$n'] = _meal(
      '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}',
      _daysAgo(n),
      2100,
    );
    server.weightRows['w$n'] = <String, dynamic>{
      'recorded_at': _daysAgo(n).toUtc().toIso8601String(),
      'weight_kg': 84 - 0.02 * (21 - n),
    };
  }
}

Future<({HomeStore store, FakeServer server, SnackCapture snacks})> _booted({
  void Function(FakeServer server)? tweak,
  InMemoryKeyValueStore? kv,
}) async {
  final a = setup(kv: kv);
  _seedThreeWeeks(a.server);
  tweak?.call(a.server);
  await boot(a.store);
  await settle();
  return (store: a.store, server: a.server, snacks: a.snacks);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('three weeks of server data propose −150 kcal', () => withClock(
    Clock.fixed(_now),
    () async {
      final a = await _booted();
      expect(a.store.energyCheckStepsReady, isTrue);
      final p = a.store.energyCheckProposal!;
      expect(p.stepKcal, -150);
      expect(p.currentGoalKcal, 2100);
      expect(p.newGoalKcal, 1950);
      expect(p.loggedDays, 21);
      expect(p.weighInDays, 21);
    },
  ));

  test('adjust: offset, answered day and live goal, synced, with a notice',
      () => withClock(Clock.fixed(_now), () async {
    final a = await _booted();
    a.snacks.messages.clear();

    await a.store.acceptEnergyCheck(a.store.energyCheckProposal!);
    await settle();

    final profile = a.store.profile;
    expect(profile.energyAdjustmentKcal, -150);
    expect(profile.energyCheckedOn, DateTime(2026, 10, 3));
    expect(profile.dailyKcalGoal, 1950);
    expect(a.server.profileRow!['energy_adjustment_kcal'], -150);
    expect(a.server.profileRow!['energy_checked_on'], '2026-10-03');
    expect(a.server.profileRow!['daily_kcal_goal'], 1950);
    expect(a.snacks.messages, contains('Tagesziel angepasst: 1950 kcal.'));
    expect(a.store.energyCheckProposal, isNull, reason: 'answered today');
  }));

  test('the step is relative: another device moved the offset meanwhile',
      () => withClock(Clock.fixed(_now), () async {
    final a = await _booted();
    final proposal = a.store.energyCheckProposal!;
    // The card was built; then a change from elsewhere moves the offset.
    await a.store.applySettings(
      newProfile: const KcalCalculator().applyLiveGoals(
        a.store.profile.copyWith(energyAdjustmentKcal: -50),
      ),
      notificationsEnabled: false,
    );

    await a.store.acceptEnergyCheck(proposal);
    await settle();

    expect(a.store.profile.energyAdjustmentKcal, -200);
  }));

  test('not now: records the day only, the goal stays', () => withClock(
    Clock.fixed(_now),
    () async {
      final a = await _booted();
      a.snacks.messages.clear();

      await a.store.dismissEnergyCheck();
      await settle();

      final profile = a.store.profile;
      expect(profile.energyAdjustmentKcal, 0);
      expect(profile.energyCheckedOn, DateTime(2026, 10, 3));
      expect(profile.dailyKcalGoal, 2100);
      expect(a.server.profileRow!['energy_checked_on'], '2026-10-03');
      expect(a.snacks.messages, isEmpty);
      expect(a.store.energyCheckProposal, isNull);
    },
  ));

  test('offline, the sync hint stays and the confirmation steps back',
      () => withClock(Clock.fixed(_now), () async {
    final a = await _booted();
    a.server.offline = true;
    a.snacks.messages.clear();

    await a.store.acceptEnergyCheck(a.store.energyCheckProposal!);
    await settle();

    expect(a.store.profile.dailyKcalGoal, 1950);
    expect(a.snacks.messages, isNotEmpty, reason: 'the sync hint');
    expect(
      a.snacks.messages.where((m) => m.startsWith('Tagesziel angepasst')),
      isEmpty,
    );
  }));

  group('no proposal without complete server data', () {
    test('cached data alone', () => withClock(Clock.fixed(_now), () async {
      final kv = InMemoryKeyValueStore();
      final a = await _booted(kv: kv);
      expect(a.store.energyCheckProposal, isNotNull, reason: 'precondition');
      a.store.flushPendingWrites();
      await settle();

      final b = setup(kv: kv);
      b.server.offline = true;
      await boot(b.store);
      await settle();

      expect(b.store.loggedMeals, isNotEmpty, reason: 'cache hydrated');
      expect(b.store.energyCheckProposal, isNull);
    }));

    test('the meal load failed while profile and weights answered',
        () => withClock(Clock.fixed(_now), () async {
      // The cache holds the same three weeks, so the numbers WOULD propose;
      // only the unanswered meal load must keep the check quiet.
      final kv = InMemoryKeyValueStore();
      await LocalCache(kv, 'user-outbox').writeLoggedMeals([
        for (var n = 1; n <= 21; n++)
          LoggedMeal(
            id: '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}',
            result: mealResult('Essen', kcal: 2100),
            loggedAt: _daysAgo(n),
          ),
      ]);
      final a = await _booted(
        kv: kv,
        tweak: (server) => server.rejectMealReads = true,
      );
      expect(a.store.loggedMeals, hasLength(21), reason: 'cached meals');
      expect(a.store.weightLog.entries, hasLength(21), reason: 'precondition');
      expect(a.store.energyCheckProposal, isNull);
    }));

    test('the meal window hit its row cap', () => withClock(
      Clock.fixed(_now),
      () async {
        final a = await _booted(
          tweak: (server) {
            // 1000 rows inside the 35-day window: older days may be cut. At
            // 1 kcal each they leave the numbers proposing (≈ −350 kcal).
            for (var i = 0; i < MealsSync.loggedMealsMaxRows; i++) {
              server.mealRows['cap-$i'] = _meal(
                '10000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
                _daysAgo(1 + i % 21),
                1,
              );
            }
          },
        );
        expect(a.store.energyCheckProposal, isNull);
      },
    ));
  });
}
