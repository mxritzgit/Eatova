// The weekly check's result without a proposal (2026-10-19): on server
// data, once a week (EnergyCheck.resultWeekday), Today gets the check's own
// numbers. A proposal always wins, and other weekdays stay quiet.

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/energy_check.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/meals_sync.dart' show mealResultToJson;

import 'outbox/outbox_test_helpers.dart';

/// Monday 5 October 2026, noon.
final DateTime _monday = DateTime(2026, 10, 5, 12);

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

/// 21 days of [kcal] before [now] and a daily weigh-in moving [kgPerDay].
void _seed(FakeServer server, DateTime now, int kcal, double kgPerDay) {
  server.profileRow = serverProfileRow(_live);
  for (var n = 1; n <= 21; n++) {
    final at = DateTime(now.year, now.month, now.day - n, 12);
    server.mealRows['meal-$n'] = <String, dynamic>{
      'id': '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}',
      'logged_at': at.toUtc().toIso8601String(),
      'forced_slot': null,
      'local_day': localDayKey(at),
      'payload': mealResultToJson(mealResult('Essen', kcal: kcal)),
    };
    server.weightRows['w$n'] = <String, dynamic>{
      'recorded_at': at.toUtc().toIso8601String(),
      'weight_kg': 84 + kgPerDay * (21 - n),
    };
  }
}

Future<HomeStore> _booted(DateTime now, int kcal, double kgPerDay) async {
  final a = setup();
  _seed(a.server, now, kcal, kgPerDay);
  await boot(a.store);
  await settle();
  return a.store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Montag ohne Vorschlag: das Ergebnis mit den Zahlen des Checks', () {
    return withClock(Clock.fixed(_monday), () async {
      expect(_monday.weekday, EnergyCheck.resultWeekday);
      // 2700 kcal at a steady weight: observed 2700 against 2650 modelled.
      final store = await _booted(_monday, 2700, 0);
      expect(store.energyCheckProposal, isNull);
      final result = store.energyCheckResult!;
      expect(result.proposal, isNull);
      expect(result.withinNoise, isTrue);
      expect(result.observedKcal, closeTo(2700, 0.5));
      expect(result.modelledKcal, 2650);
      expect(result.currentGoalKcal, 2100);
      expect(result.weeklyRateKg, closeTo(0, 1e-9));
      expect(
        result.planWeeklyRateKg,
        const KcalCalculator().calculate(_live).effectiveWeeklyRateKg,
      );
      expect(result.loggedDays, 21);
      expect(result.weighInDays, 21);
    });
  });

  test('an einem anderen Tag bleibt es bei der Zeile', () {
    final tuesday = DateTime(2026, 10, 6, 12);
    return withClock(Clock.fixed(tuesday), () async {
      final store = await _booted(tuesday, 2700, 0);
      expect(store.energyCheckResult, isNull);
      expect(store.energyCheckProgress!.ready, isTrue);
    });
  });

  test('ein Vorschlag geht dem Ergebnis vor', () {
    return withClock(Clock.fixed(_monday), () async {
      final store = await _booted(_monday, 2100, -0.02);
      expect(store.energyCheckProposal!.stepKcal, -150);
      expect(store.energyCheckResult, isNull);
    });
  });
}
