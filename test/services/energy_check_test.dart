// EnergyCheck — the weekly expenditure check (docs/WEIGHT-TREND.md, stage 2).
//
// Observed expenditure = mean intake of the logged days − weight slope × 7700;
// modelled = maintenance (incl. the current offset) + mean step kcal. A
// difference of 100 kcal or more AND beyond two standard errors of the slope
// (noise floor 0.5 kg per weigh-in) proposes a step, rounded to 50 and capped
// at ±150, with the offset itself capped at ±500.

import 'dart:math' as math;

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

DateTime _daysAgo(int n, {DateTime? today}) {
  final t = today ?? _today;
  return DateTime(t.year, t.month, t.day - n);
}

/// Weigh-ins at 7:00 on [daysAgo], following [kgPerDay] from 84 kg 21 days ago.
WeightLog _weights(
  List<int> daysAgo, {
  double kgPerDay = 0,
  Map<int, double>? override,
  DateTime? today,
}) => WeightLog.capped([
  for (final n in daysAgo)
    WeightLogEntry(
      timestamp: _daysAgo(n, today: today).add(const Duration(hours: 7)),
      weightKg: override?[n] ?? 84 + kgPerDay * (21 - n),
    ),
]);

/// A weigh-in every day of the window: the 2-SE guard is 2 × 0.5 / √770 ×
/// 7700 ≈ 277 kcal.
final List<int> _daily = [for (var n = 21; n >= 1; n--) n];

EnergyCheckProposal? _evaluate({
  UserProfile? profile,
  int intake = 2300,
  int? burned = 200,
  int? Function(int daysAgo)? burnedOn,
  bool stepSourceToday = false,
  Set<int> skipIntakeDaysAgo = const {},
  int todayIntake = 0,
  WeightLog? weights,
  DateTime? today,
}) {
  final t = today ?? _today;
  return const EnergyCheck().evaluate(
    profile: profile ?? _profile(),
    today: t,
    intakeKcal: (day) {
      final n = DateTime.utc(t.year, t.month, t.day)
          .difference(DateTime.utc(day.year, day.month, day.day))
          .inDays;
      if (n == 0) return todayIntake;
      return skipIntakeDaysAgo.contains(n) ? 0 : intake;
    },
    burnedKcal: (day) {
      final n = DateTime.utc(t.year, t.month, t.day)
          .difference(DateTime.utc(day.year, day.month, day.day))
          .inDays;
      return burnedOn == null ? burned : burnedOn(n);
    },
    stepSourceToday: stepSourceToday,
    weightLog: weights ?? _weights(_daily, kgPerDay: -0.02),
  );
}

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
      expect(p.weighInDays, 21);
      expect(p.weeklyRateKg, closeTo(-0.14, 1e-6));
    });

    test('burning more than modelled raises the goal', () {
      // Observed 2100 + 0.12 × 7700 = 3024; modelled 2650 + 0 = 2650.
      final p = _evaluate(
        intake: 2100,
        burned: 0,
        weights: _weights(_daily, kgPerDay: -0.12),
      )!;
      expect(p.stepKcal, 150);
      expect(p.newGoalKcal, 2250);
    });

    test('the offset stays within ±500', () {
      // Observed 1954. At −450 the model is 2400 (−446), at −500 it is 2350
      // (−396): both want −150, the cap allows −50 and 0.
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
      // With −150 applied the model is 2700: observed 2354 is −346 off.
      final p = _evaluate(profile: _profile(adjustment: -150), intake: 2200)!;
      expect(p.modelledKcal, 2700);
      expect(p.newAdjustmentKcal, -300);
    });
  });

  group('noise', () {
    test('a difference under 100 kcal proposes nothing', () {
      expect(
        _evaluate(intake: 2700, burned: 0, weights: _weights(_daily)),
        isNull,
      );
    });

    test('a difference inside two standard errors proposes nothing', () {
      // +250 against a guard of ≈277 (daily weigh-ins); +300 passes it.
      expect(
        _evaluate(intake: 2900, burned: 0, weights: _weights(_daily)),
        isNull,
      );
      expect(
        _evaluate(intake: 2950, burned: 0, weights: _weights(_daily))!.stepKcal,
        150,
      );
    });

    test('water swings on four weigh-ins do not fake a slope', () {
      // Review case: true expenditure = model, weigh-ins on window days 0, 1,
      // 13, 14 with +0.3/+0.2/−0.2/−0.3 kg of water. The fitted slope is
      // −0.039 kg/day (+299 kcal/day), but its residuals are tiny by chance;
      // the 0.5 kg noise floor keeps the guard at ≈590 kcal.
      final p = _evaluate(
        intake: 2850,
        burned: 200,
        weights: _weights(
          [21, 20, 8, 7],
          override: {21: 84.3, 20: 84.2, 8: 83.8, 7: 83.7},
        ),
      );
      expect(p, isNull);
    });

    test('the guard is 2 × σ / √Sxx × 7700 with σ ≥ 0.5 kg', () {
      // Daily weigh-ins, exact line: σ = 0 -> the floor; Sxx = 770.
      final guard = 2 * 0.5 / math.sqrt(770) * 7700;
      expect(guard, closeTo(277.5, 0.1));
    });
  });

  group('step data (not synced between devices)', () {
    test('with a step source, days without a step value do not count', () {
      // Eight days without a value (a new phone): 13 days left.
      final p = _evaluate(burnedOn: (n) => n <= 8 ? null : 200);
      expect(p, isNull);
      final q = _evaluate(burnedOn: (n) => n <= 7 ? null : 200)!;
      expect(q.loggedDays, 14);
      expect(q.modelledKcal, 2850, reason: 'the mean of the days WITH steps');
    });

    test('a step source today but no step values in the window: no check', () {
      expect(_evaluate(burned: null, stepSourceToday: true), isNull);
    });

    test('no step source at all models no steps, as the budget credits none', () {
      // Observed 2454 against 2650 is −196, inside the ≈277 guard; with less
      // intake (2254, −396) it proposes against the step-free model.
      expect(_evaluate(burned: null), isNull);
      final p = _evaluate(burned: null, intake: 2100)!;
      expect(p.modelledKcal, 2650);
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
      // A strong signal (observed 1654 vs 2850), so only the count and span
      // rules decide; four sparse weigh-ins carry a guard of ≈750 kcal.
      expect(_evaluate(intake: 1500, weights: _weights([21, 12, 3])), isNull);
      expect(_evaluate(intake: 1500, weights: _weights([14, 10, 6, 2])), isNull);
      expect(
        _evaluate(intake: 1500, weights: _weights([15, 10, 6, 1])),
        isNotNull,
      );
    });
  });

  group('the window', () {
    test('a weigh-in typo is dropped from the slope', () {
      final clean = _evaluate()!;
      final typo = _evaluate(
        weights: _weights(_daily, kgPerDay: -0.02, override: {9: 64.0}),
      )!;
      expect(typo.observedKcal, closeTo(clean.observedKcal, 1e-6));
      expect(typo.weighInDays, clean.weighInDays - 1);
    });

    test('today and day 22 are outside it', () {
      final base = _evaluate()!;
      final p = _evaluate(
        todayIntake: 9000,
        weights: WeightLog.capped([
          ..._weights(_daily, kgPerDay: -0.02).entries,
          WeightLogEntry(timestamp: _daysAgo(22), weightKg: 87),
          WeightLogEntry(
            timestamp: _today.add(const Duration(hours: 7)),
            weightKg: 80,
          ),
        ]),
      )!;
      expect(p.observedKcal, closeTo(base.observedKcal, 1e-6));
      expect(p.weighInDays, 21);
    });

    test('the last weigh-in of a day counts', () {
      // Day 5 starts with 81.0 (off the line, within 5 %) and is corrected.
      final base = _evaluate()!;
      const line = 84 - 0.02 * (21 - 5);
      final p = _evaluate(
        weights: WeightLog.capped([
          ..._weights(_daily, kgPerDay: -0.02).entries,
          WeightLogEntry(
            timestamp: _daysAgo(5).add(const Duration(hours: 6)),
            weightKg: 81.0,
          ),
          WeightLogEntry(
            timestamp: _daysAgo(5).add(const Duration(hours: 22)),
            weightKg: line,
          ),
        ]),
      )!;
      expect(p.observedKcal, closeTo(base.observedKcal, 1e-6));
    });

    test('a window across the spring DST change still has 21 days', () {
      final spring = DateTime(2026, 4, 5);
      final p = _evaluate(
        today: spring,
        weights: _weights(_daily, kgPerDay: -0.02, today: spring),
      )!;
      expect(p.loggedDays, 21);
      expect(p.weighInDays, 21);
      expect(p.weeklyRateKg, closeTo(-0.14, 1e-6));
    });
  });
}
