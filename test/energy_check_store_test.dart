// The weekly energy check in the store (docs/WEIGHT-TREND.md, stage 2):
// today's proposal from server-answered data, and the two answers.

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/meals_sync.dart' show mealResultToJson;

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

/// 21 days of 2300 kcal and a weigh-in every third day losing 0.02 kg/day:
/// observed 2454 kcal against a modelled 2650 (no step source) -> −150.
void _seedThreeWeeks(FakeServer server) {
  server.profileRow = serverProfileRow(_live);
  for (var n = 1; n <= 21; n++) {
    final at = _daysAgo(n);
    server.mealRows['meal-$n'] = <String, dynamic>{
      'id': '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}',
      'logged_at': at.toUtc().toIso8601String(),
      'forced_slot': null,
      'local_day': localDayKey(at),
      'payload': mealResultToJson(mealResult('Tag $n', kcal: 2300)),
    };
  }
  for (final n in [21, 18, 15, 12, 9, 6, 3, 1]) {
    server.weightRows['w$n'] = <String, dynamic>{
      'recorded_at': _daysAgo(n).toUtc().toIso8601String(),
      'weight_kg': 84 - 0.02 * (21 - n),
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('three weeks of server data propose −150 kcal', () => withClock(
    Clock.fixed(_now),
    () async {
      final a = setup();
      _seedThreeWeeks(a.server);
      await boot(a.store);
      await settle();

      final p = a.store.energyCheckProposal!;
      expect(p.stepKcal, -150);
      expect(p.currentGoalKcal, 2100);
      expect(p.newGoalKcal, 1950);
      expect(p.loggedDays, 21);
      expect(p.weighInDays, 8);
    },
  ));

  test('adjust: offset, answered day and live goal, synced, with a notice',
      () => withClock(Clock.fixed(_now), () async {
    final a = setup();
    _seedThreeWeeks(a.server);
    await boot(a.store);
    await settle();
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

  test('not now: records the day only, the goal stays', () => withClock(
    Clock.fixed(_now),
    () async {
      final a = setup();
      _seedThreeWeeks(a.server);
      await boot(a.store);
      await settle();
      a.snacks.messages.clear();

      await a.store.dismissEnergyCheck();
      await settle();

      expect(a.store.profile.energyAdjustmentKcal, 0);
      expect(a.store.profile.energyCheckedOn, DateTime(2026, 10, 3));
      expect(a.store.profile.dailyKcalGoal, 2100);
      expect(a.server.profileRow!['energy_checked_on'], '2026-10-03');
      expect(a.snacks.messages, isEmpty);
      expect(a.store.energyCheckProposal, isNull);
    },
  ));

  test('no proposal from cached data alone', () => withClock(
    Clock.fixed(_now),
    () async {
      final kv = InMemoryKeyValueStore();
      final a = setup(kv: kv);
      _seedThreeWeeks(a.server);
      await boot(a.store);
      await settle();
      expect(a.store.energyCheckProposal, isNotNull, reason: 'precondition');
      a.store.flushPendingWrites();
      await settle();

      final b = setup(kv: kv);
      b.server.offline = true;
      await boot(b.store);
      await settle();

      expect(b.store.loggedMeals, isNotEmpty, reason: 'cache hydrated');
      expect(b.store.energyCheckProposal, isNull);
    },
  ));
}
