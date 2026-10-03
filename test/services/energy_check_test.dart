// EnergyCheck — the weekly expenditure check (docs/WEIGHT-TREND.md, stage 2).
//
// Observed expenditure = mean intake of the logged days − weight slope × 7700;
// modelled = maintenance (incl. the current offset) + mean step kcal. A
// difference of 100 kcal or more proposes a step, rounded to 50 and capped at
// ±150, with the offset itself capped at ±500.

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/energy_check.dart';
import 'package:eatova/src/services/kcal_calculator.dart';

final DateTime _today = DateTime(2026, 10, 3);

/// Male, 182 cm, light, −0.5 kg/week: maintenance 2650, goal 2100 kcal.
UserProfile _profile({
  int adjustment = 0,
  DateTime? checkedOn,
  bool manual = false,
  bool onboarded = true,
  BiologicalSex sex = BiologicalSex.male,
  int weightKg = 84,
  int heightCm = 182,
  int targetWeightKg = 70,
}) => const KcalCalculator().applyLiveGoals(
  UserProfile(
    weightKg: weightKg,
    heightCm: heightCm,
    ageYears: 31,
    sex: sex,
    activityLevel: ActivityLevel.light,
    targetWeightKg: targetWeightKg,
    weightGoal: WeightGoal.lose05kg,
    onboardingCompleted: onboarded,
    manualEnergy: manual,
    energyAdjustmentKcal: adjustment,
    energyCheckedOn: checkedOn,
  ),
);

DateTime _daysAgo(int n) => DateTime(_today.year, _today.month, _today.day - n);

/// Weigh-ins at 7:00 on [daysAgo], following [kgPerDay] from 84 kg 21 days ago.
WeightLog _weights(List<int> daysAgo, {double kgPerDay = 0, Map<int, double>? override}) =>
    WeightLog.capped([
      for (final n in daysAgo)
        WeightLogEntry(
          timestamp: _daysAgo(n).add(const Duration(hours: 7)),
          weightKg: override?[n] ?? 84 + kgPerDay * (21 - n),
        ),
    ]);

const List<int> _everyThirdDay = [21, 18, 15, 12, 9, 6, 3, 1];

EnergyCheckProposal? _evaluate({
  UserProfile? profile,
  int intake = 2300,
  int burned = 200,
  Set<int> skipIntakeDaysAgo = const {},
  int todayIntake = 0,
  WeightLog? weights,
}) => const EnergyCheck().evaluate(
  profile: profile ?? _profile(),
  today: _today,
  intakeKcal: (day) {
    final n = _today.difference(day).inDays;
    if (n == 0) return todayIntake;
    return skipIntakeDaysAgo.contains(n) ? 0 : intake;
  },
  burnedKcal: (_) => burned,
  weightLog: weights ?? _weights(_everyThirdDay, kgPerDay: -0.02),
);

void main() {
  test('precondition: maintenance 2650, goal 2100', () {
    final t = const KcalCalculator().calculate(_profile());
    expect(t.maintenanceKcal, 2650);
    expect(t.kcal, 2100);
  });

  group('proposals', () {
    test('burning less than modelled lowers the goal by at most 150', () {
      // Observed 2300 + 0.02 × 7700 = 2454; modelled 2650 + 200 = 2850.
      final p = _evaluate()!;
      expect(p.observedKcal, closeTo(2454, 1));
      expect(p.modelledKcal, 2850);
      expect(p.stepKcal, -150);
      expect(p.newAdjustmentKcal, -150);
      expect(p.currentGoalKcal, 2100);
      expect(p.newGoalKcal, 1950);
      expect(p.loggedDays, 21);
      expect(p.weighInDays, 8);
      expect(p.weeklyRateKg, closeTo(-0.14, 1e-6));
    });

    test('burning more than modelled raises the goal', () {
      // Observed 2100 + 0.12 × 7700 = 3024; modelled 2650 + 0 = 2650.
      final p = _evaluate(
        intake: 2100,
        burned: 0,
        weights: _weights(_everyThirdDay, kgPerDay: -0.12),
      )!;
      expect(p.stepKcal, 150);
      expect(p.newGoalKcal, 2250);
    });

    test('a difference under 100 kcal proposes nothing', () {
      // Observed 2700 + 0 = 2700; modelled 2650 + 0: +50.
      expect(
        _evaluate(intake: 2700, burned: 0, weights: _weights(_everyThirdDay)),
        isNull,
      );
    });

    test('the step is rounded to 50', () {
      // Observed 2770; modelled 2650: +120 -> +100.
      final p = _evaluate(
        intake: 2770,
        burned: 0,
        weights: _weights(_everyThirdDay),
      )!;
      expect(p.stepKcal, 100);
    });

    test('the offset stays within ±500', () {
      // Observed 1800 + 154 = 1954. At −450 the model is 2400 (−446), at
      // −500 it is 2350 (−396): both want −150, the cap allows −50 and 0.
      final p = _evaluate(profile: _profile(adjustment: -450), intake: 1800)!;
      expect(p.newAdjustmentKcal, -500);
      expect(p.stepKcal, -50);
      expect(
        _evaluate(profile: _profile(adjustment: -500), intake: 1800),
        isNull,
      );
    });

    test('a goal held by the floor proposes nothing', () {
      // Small woman: the goal already sits on the 1200 floor, so lowering
      // maintenance would change nothing the user can see.
      final floored = _profile(
        sex: BiologicalSex.female,
        weightKg: 50,
        heightCm: 155,
        targetWeightKg: 46,
      );
      expect(const KcalCalculator().calculate(floored).kcal, 1200, reason: 'precondition');
      expect(_evaluate(profile: floored, intake: 1000, burned: 0), isNull);
    });

    test('the current offset is part of the model', () {
      // With −150 already applied the model is 2700: observed 2454 is still
      // −246 off, so the next step goes on from there.
      final p = _evaluate(profile: _profile(adjustment: -150))!;
      expect(p.modelledKcal, 2700);
      expect(p.newAdjustmentKcal, -300);
    });
  });

  group('when it stays quiet', () {
    test('manual mode and an unfinished onboarding', () {
      expect(_evaluate(profile: _profile(manual: true)), isNull);
      expect(_evaluate(profile: _profile(onboarded: false)), isNull);
    });

    test('less than 7 days after the last answer', () {
      expect(_evaluate(profile: _profile(checkedOn: _daysAgo(6))), isNull);
      expect(_evaluate(profile: _profile(checkedOn: _daysAgo(7))), isNotNull);
    });

    test('fewer than 14 logged days', () {
      // Days under 50 % of the goal (here: nothing) do not count.
      final eightSkipped = {for (var n = 1; n <= 8; n++) n};
      expect(_evaluate(skipIntakeDaysAgo: eightSkipped), isNull);
      final sevenSkipped = {for (var n = 1; n <= 7; n++) n};
      expect(_evaluate(skipIntakeDaysAgo: sevenSkipped)!.loggedDays, 14);
    });

    test('too few weigh-in days, or too short a span', () {
      expect(_evaluate(weights: _weights([21, 12, 3])), isNull);
      expect(_evaluate(weights: _weights([14, 10, 6, 2])), isNull);
      expect(_evaluate(weights: _weights([15, 10, 6, 1])), isNotNull);
    });
  });

  test('a weigh-in typo is dropped from the slope', () {
    final clean = _evaluate()!;
    final typo = _evaluate(
      weights: _weights(_everyThirdDay, kgPerDay: -0.02, override: {9: 64.0}),
    )!;
    expect(typo.observedKcal, closeTo(clean.observedKcal, 1e-6));
    expect(typo.weighInDays, clean.weighInDays - 1);
  });

  test('today is not part of the window', () {
    final p = _evaluate(todayIntake: 9000)!;
    expect(p.observedKcal, closeTo(2454, 1));
  });
}
