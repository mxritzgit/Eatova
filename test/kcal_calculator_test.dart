import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/kcal_calculator.dart';

// Kcal review 2026-08-21 (docs/REVIEW-KCAL-2026-08-21.md): PAL ladder 1.3…1.9
// with walking excluded and no step baseline, sex-dependent floor, 1 % deficit
// cap, protein on reference weight, forecast as a range. The numbers come from
// the Python mirror and were checked against calculator.net / NIH BWP.

void main() {
  group('estimateKcalBurnedFromSteps', () {
    test('uses body weight and height-derived walking distance', () {
      final averageMale = estimateKcalBurnedFromSteps(
        steps: 10000,
        weightKg: 78,
        heightCm: 178,
        sex: BiologicalSex.male,
      );
      final heavierMale = estimateKcalBurnedFromSteps(
        steps: 10000,
        weightKg: 200,
        heightCm: 178,
        sex: BiologicalSex.male,
      );
      final lighterMale = estimateKcalBurnedFromSteps(
        steps: 10000,
        weightKg: 67,
        heightCm: 178,
        sex: BiologicalSex.male,
      );

      // 0.739 m × 10 000 = 7.39 km × 0.5 kcal/kg/km.
      expect(averageMale, 288);
      expect(heavierMale, 739);
      expect(lighterMale, 247);
      expect(heavierMale, greaterThan(lighterMale));
    });

    test('uses profile height so taller users burn more for the same step count', () {
      final shorter = estimateKcalBurnedFromSteps(
        steps: 10000,
        weightKg: 78,
        heightCm: 165,
        sex: BiologicalSex.neutral,
      );
      final taller = estimateKcalBurnedFromSteps(
        steps: 10000,
        weightKg: 78,
        heightCm: 195,
        sex: BiologicalSex.neutral,
      );

      expect(shorter, 266);
      expect(taller, 315);
      expect(taller, greaterThan(shorter));
    });

    test('returns zero for invalid step or body inputs', () {
      expect(
        estimateKcalBurnedFromSteps(
          steps: 0,
          weightKg: 78,
          heightCm: 178,
          sex: BiologicalSex.neutral,
        ),
        0,
      );
      expect(
        estimateKcalBurnedFromSteps(
          steps: 10000,
          weightKg: 0,
          heightCm: 178,
          sex: BiologicalSex.neutral,
        ),
        0,
      );
      expect(
        estimateKcalBurnedFromSteps(
          steps: 10000,
          weightKg: 78,
          heightCm: 0,
          sex: BiologicalSex.neutral,
        ),
        0,
      );
    });

    test('jeder Schritt zaehlt — linear, ohne Schwelle', () {
      // The PAL ladder excludes walking, so NO step baseline is subtracted:
      // the first step counts as much as the ten-thousandth.
      final fuenf = estimateKcalBurnedFromSteps(
        steps: 5000,
        weightKg: 78,
        heightCm: 178,
        sex: BiologicalSex.male,
      );
      final zehn = estimateKcalBurnedFromSteps(
        steps: 10000,
        weightKg: 78,
        heightCm: 178,
        sex: BiologicalSex.male,
      );
      expect(fuenf, 144);
      expect(zehn, 288);
      expect(
        estimateKcalBurnedFromSteps(
          steps: 1,
          weightKg: 78,
          heightCm: 178,
          sex: BiologicalSex.male,
        ),
        0,
        reason: '0,029 kcal runden auf 0 — aber nicht wegen einer Schwelle',
      );
      expect(
        estimateKcalBurnedFromSteps(
          steps: 100,
          weightKg: 78,
          heightCm: 178,
          sex: BiologicalSex.male,
        ),
        3,
      );
    });

    test('das Beispiel aus dem Review: 7000 Schritte bei 100 kg / 180 cm', () {
      // Net (ACSM horizontal component), not the old gross value including
      // BMR: 0.747 m × 7000 = 5.23 km × 100 kg × 0.5 = 261 kcal.
      expect(
        estimateKcalBurnedFromSteps(
          steps: 7000,
          weightKg: 100,
          heightCm: 180,
          sex: BiologicalSex.male,
        ),
        261,
      );
    });
  });

  group('KcalCalculator.calculate', () {
    const calc = KcalCalculator();
    const base = UserProfile(); // 78kg, 178cm, 30y, neutral, sedentary

    test('maintenance uses the activity level, not the step goal', () {
      // The bug: the requirement was scaled from the step GOAL and the real
      // steps added on top. The goal must NOT affect the requirement.
      final low = calc.calculate(base.copyWith(dailyStepsGoal: 3000));
      final high = calc.calculate(base.copyWith(dailyStepsGoal: 15000));
      expect(low.kcal, high.kcal);
      expect(low.maintenanceKcal, high.maintenanceKcal);
    });

    test('maintain goal targets the maintenance need (~BMR x 1.3)', () {
      final t = calc.calculate(base); // WeightGoal.maintain
      expect(t.goal, WeightGoal.maintain);
      expect(t.bmr, 1665); // 1664.5 rounded
      expect(t.maintenanceKcal, 2164); // 1664.5 BMR × 1.3 = 2163.85
      expect(t.kcal, 2150); // rounded to 50
      expect(t.floor, KcalCalculator.kcalFloorNeutral);
      expect(t.deficitCapApplied, isFalse);
    });

    test('weight goal applies its kcal delta on top of maintenance', () {
      final maintain = calc.calculate(base.copyWith(weightGoal: WeightGoal.maintain));
      final lose = calc.calculate(base.copyWith(weightGoal: WeightGoal.lose05kg));
      final gain = calc.calculate(base.copyWith(weightGoal: WeightGoal.gain05kg));

      expect(lose.kcal, maintain.kcal - 550); // −0.5 kg/week → 1600
      expect(gain.kcal, maintain.kcal + 550); // +0.5 kg/week → 2700
      // Maintenance stays the same regardless of the goal.
      expect(lose.maintenanceKcal, maintain.maintenanceKcal);
      expect(gain.maintenanceKcal, maintain.maintenanceKcal);
    });

    test('-1 kg/week applies the full 1100 kcal deficit from 100 kg upwards', () {
      // 1 % of body weight per week: at 110 kg the cap does not bite.
      const heavy = UserProfile(
        weightKg: 110,
        heightCm: 185,
        ageYears: 30,
        sex: BiologicalSex.male,
        activityLevel: ActivityLevel.moderate,
      );
      final maintain = calc.calculate(heavy.copyWith(weightGoal: WeightGoal.maintain));
      final lose1kg = calc.calculate(heavy.copyWith(weightGoal: WeightGoal.lose1kg));
      expect(WeightGoal.lose1kg.weeklyRateKg, 1.0);
      // 110 × 11 = 1210 ≥ 1100: the cap does not bite.
      expect(KcalCalculator.maxDeficitKcalPerDay(110), 1210);
      expect(lose1kg.deficitCapApplied, isFalse);
      expect(lose1kg.appliedKcalDelta, -1100);
      expect(lose1kg.kcal, maintain.kcal - 1100);
    });

    test('1-%-Deckel: unter 100 kg wird das Defizit begrenzt', () {
      // 78 kg → 858 kcal/day, rounded down to a 0.05 kg/week step = 825, so
      // "−1 kg/week" really means −0.75 kg/week.
      final t = calc.calculate(base.copyWith(weightGoal: WeightGoal.lose1kg));
      expect(KcalCalculator.maxDeficitKcalPerDay(78), 825);
      expect(t.maxDeficitKcal, 825);
      expect(t.appliedKcalDelta, -825);
      expect(t.deficitCapApplied, isTrue);
      expect(t.uncappedKcal, 1350); // 2163.85 − 825 = 1339 → 1350
      expect(t.kcal, 1350); // = the neutral floor, but not clamped
      expect(t.floorApplied, isFalse);
      expect(t.effectiveKcalDelta, -814);
      expect(t.effectiveWeeklyRateKg, closeTo(-0.74, 0.0005));
      expect(t.effectivePaceLabel(), '−0,75 kg/Woche');
      expect(t.paceWarning(), contains('825'));
      expect(t.paceWarning(), contains('1 %'));
      expect(t.paceWarning(), contains('−0,75 kg/Woche statt −1 kg/Woche'));

      // −0.75 kg/week hits the cap exactly: not a capped case, same plan.
      final t075 = calc.calculate(base.copyWith(weightGoal: WeightGoal.lose075kg));
      expect(t075.deficitCapApplied, isFalse);
      expect(t075.kcal, 1350);
      expect(t075.paceWarning(), isNull);
    });

    test('Deckel rastert auf 0,05 kg/Woche (55-kcal-Schritte)', () {
      // kg × 11, rounded down to 55-steps = (kg ÷ 5) × 55, at least 275.
      expect(KcalCalculator.maxDeficitKcalPerDay(30), 330); // 0.3 kg/week
      expect(KcalCalculator.maxDeficitKcalPerDay(45), 495); // 0.45
      expect(KcalCalculator.maxDeficitKcalPerDay(55), 605); // 0.55
      expect(KcalCalculator.maxDeficitKcalPerDay(60), 660); // 0.6
      expect(KcalCalculator.maxDeficitKcalPerDay(70), 770); // 0.7
      expect(KcalCalculator.maxDeficitKcalPerDay(74), 770); // 814 → 770
      expect(KcalCalculator.maxDeficitKcalPerDay(78), 825); // 858 → 825
      expect(KcalCalculator.maxDeficitKcalPerDay(99), 1045); // 1089 → 1045
      expect(KcalCalculator.maxDeficitKcalPerDay(100), 1100);
      expect(KcalCalculator.maxDeficitKcalPerDay(130), 1430);
      for (var kg = 30; kg <= 300; kg++) {
        final cap = KcalCalculator.maxDeficitKcalPerDay(kg);
        expect(cap % 55, 0, reason: '$kg kg');
        expect(cap, lessThanOrEqualTo(kg * 11), reason: '$kg kg');
        expect(cap, greaterThan(kg * 11 - 55), reason: '$kg kg');
      }
    });

    test('Zunahme-Stufen kennen keinen Deckel', () {
      final t = calc.calculate(base.copyWith(weightGoal: WeightGoal.gain05kg));
      expect(t.appliedKcalDelta, 550);
      expect(t.deficitCapApplied, isFalse);
    });

    test('clamps daily kcal into a sane range — per sex', () {
      const tiny = UserProfile(
        weightKg: 35,
        heightCm: 140,
        ageYears: 80,
        weightGoal: WeightGoal.lose1kg,
      );
      expect(calc.calculate(tiny).kcal, KcalCalculator.kcalFloorNeutral);
      expect(
        calc.calculate(tiny.copyWith(sex: BiologicalSex.female)).kcal,
        KcalCalculator.kcalFloor,
      );
      expect(
        calc.calculate(tiny.copyWith(sex: BiologicalSex.male)).kcal,
        KcalCalculator.kcalFloorMale,
      );
    });

    test('Untergrenzen: 1200 weiblich, 1500 maennlich, 1350 neutral', () {
      expect(KcalCalculator.kcalFloorFor(BiologicalSex.female), 1200);
      expect(KcalCalculator.kcalFloorFor(BiologicalSex.male), 1500);
      expect(KcalCalculator.kcalFloorFor(BiologicalSex.neutral), 1350);
      expect(KcalCalculator.kcalFloor, 1200, reason: 'absolutes Minimum');
    });

    test('100-kg-Mann, sitzend, −1 kg/Woche: 1500 MIT Warnung statt 1200 ohne',
        () {
      // PAL 1.3 → 2509 − 1100 = 1409 → 1400, lifted to the male floor 1500,
      // and the hint says so.
      const mann = UserProfile(
        weightKg: 100,
        heightCm: 180,
        ageYears: 40,
        sex: BiologicalSex.male,
        weightGoal: WeightGoal.lose1kg,
      );
      final t = calc.calculate(mann);
      expect(t.maintenanceKcal, 2509);
      expect(t.uncappedKcal, 1400);
      expect(t.kcal, 1500);
      expect(t.floor, 1500);
      expect(t.floorApplied, isTrue);
      expect(t.effectivePaceLabel(), '−0,9 kg/Woche');
      expect(t.paceWarning(), contains('1500 kcal statt 1400 kcal'));
    });

    test('activity level scales maintenance via its PAL factor', () {
      final sedentary =
          calc.calculate(base.copyWith(activityLevel: ActivityLevel.sedentary));
      final moderate =
          calc.calculate(base.copyWith(activityLevel: ActivityLevel.moderate));
      final athlete =
          calc.calculate(base.copyWith(activityLevel: ActivityLevel.athlete));

      // 1664.5 BMR × {1.3, 1.6, 1.9}
      expect(sedentary.maintenanceKcal, 2164);
      expect(moderate.maintenanceKcal, 2663);
      expect(athlete.maintenanceKcal, 3163);
      expect(moderate.kcal, greaterThan(sedentary.kcal));
      expect(athlete.kcal, greaterThan(moderate.kcal));
    });

    test('PAL-Leiter OHNE Gehen: 1,3 … 1,9 (FAO-Sitzbasis + Thermogenese)', () {
      // DGE/FAO ladder (1.4 … 2.0) minus the ~0.1 walking share, which the
      // steps contribute separately.
      expect(ActivityLevel.sedentary.palFactor, 1.3);
      expect(ActivityLevel.light.palFactor, 1.45);
      expect(ActivityLevel.moderate.palFactor, 1.6);
      expect(ActivityLevel.active.palFactor, 1.75);
      expect(ActivityLevel.athlete.palFactor, 1.9);
    });
  });

  group('KcalCalculator.weeksToGoal', () {
    const calc = KcalCalculator();
    const base = UserProfile();

    test('Prognose folgt der EFFEKTIVEN Rate, nicht dem Wunsch-Delta', () {
      // B2: the old `kcalDelta / 7700` used the chosen pace, not the pace the
      // rounded daily target delivers. 78 → 68 kg at maintenance 2164: target
      // 1600 → 564 kcal/day ≙ 0.5127 kg/week → 20 weeks.
      final profile = base.copyWith(
        targetWeightKg: 68,
        weightGoal: WeightGoal.lose05kg,
      );
      expect(calc.weeksToGoal(profile), 20);

      // −1 kg/week: the 1 % cap allows 825 → target 1350, really 0.74 kg/week
      // → 14 weeks, not 10.
      expect(
        calc.weeksToGoal(base.copyWith(
          targetWeightKg: 68,
          weightGoal: WeightGoal.lose1kg,
        )),
        14,
      );
    });

    test('is null when maintaining or already at target', () {
      expect(calc.weeksToGoal(base.copyWith(weightGoal: WeightGoal.maintain)), isNull);
      expect(
        calc.weeksToGoal(base.copyWith(
          targetWeightKg: 78,
          weightGoal: WeightGoal.lose05kg,
        )),
        isNull,
      );
    });

    test('is null when target direction contradicts the goal', () {
      // Target above the current weight but a losing goal: nonsense.
      expect(
        calc.weeksToGoal(base.copyWith(
          targetWeightKg: 90,
          weightGoal: WeightGoal.lose05kg,
        )),
        isNull,
      );
    });
  });

  group('KcalCalculator.weeksToGoalRange', () {
    const calc = KcalCalculator();
    const base = UserProfile();

    test('linear ist die Untergrenze, dynamisch die Obergrenze', () {
      // 78 → 68 kg at −0.5 kg/week: 20 weeks linear, 25 with the falling
      // requirement (22 kcal/day per lost kg, Hall).
      final profile = base.copyWith(
        targetWeightKg: 68,
        weightGoal: WeightGoal.lose05kg,
      );
      final range = calc.weeksToGoalRange(profile);
      expect(range, isNotNull);
      expect(range!.linearWeeks, 20);
      expect(range.dynamicWeeks, 25);
      expect(calc.weeksToGoal(profile), range.linearWeeks);
    });

    test('das Review-Beispiel: 100 → 85 kg, sitzend, −0,5 kg/Woche', () {
      // 30 weeks linear, 45 dynamic; the NIH planner says ~41 for a comparable
      // profile, so linear alone was a third too optimistic.
      const p3 = UserProfile(
        weightKg: 100,
        heightCm: 180,
        ageYears: 40,
        sex: BiologicalSex.male,
        targetWeightKg: 85,
        weightGoal: WeightGoal.lose05kg,
      );
      final range = calc.weeksToGoalRange(p3);
      expect(range, (linearWeeks: 30, dynamicWeeks: 45));
    });

    test('ohne Prognose (weeksToGoal null) auch keine Spanne', () {
      expect(calc.weeksToGoalRange(base), isNull);
      expect(
        calc.weeksToGoalRange(base.copyWith(
          targetWeightKg: 90,
          weightGoal: WeightGoal.lose05kg,
        )),
        isNull,
      );
    });

    test('Defizit vor dem Ziel aufgebraucht ⇒ dynamisch null („fruehestens")', () {
      // 68 kg at −0.25 kg/week: 264 kcal/day, shrinking by 22 per lost kg, so
      // the rate falls below noise. Linear says 42 weeks, dynamic says never.
      final profile = base.copyWith(
        targetWeightKg: 68,
        weightGoal: WeightGoal.lose025kg,
      );
      final range = calc.weeksToGoalRange(profile);
      expect(range, isNotNull);
      expect(range!.linearWeeks, 42);
      expect(range.dynamicWeeks, isNull);
    });

    test('Zunahme: der Bedarf steigt mit jedem Kilo, die Spanne oeffnet sich', () {
      final profile = base.copyWith(
        targetWeightKg: 88,
        weightGoal: WeightGoal.gain05kg,
      );
      final range = calc.weeksToGoalRange(profile);
      expect(range, (linearWeeks: 21, dynamicWeeks: 27));
    });

    test('dynamisch ist nie kleiner als linear', () {
      for (final goal in WeightGoal.values) {
        for (final weight in const [50, 78, 120, 200]) {
          final profile = UserProfile(
            weightKg: weight,
            targetWeightKg: goal.isGain ? weight + 6 : weight - 6,
            weightGoal: goal,
          );
          final range = calc.weeksToGoalRange(profile);
          if (range == null) continue;
          expect(range.linearWeeks, greaterThan(0));
          final dynamicWeeks = range.dynamicWeeks;
          if (dynamicWeeks != null) {
            expect(dynamicWeeks, greaterThanOrEqualTo(range.linearWeeks),
                reason: '$weight kg / ${goal.name}');
          }
        }
      }
    });
  });

  group('Prognose-Texte', () {
    test('Spanne, Einzelwert und „fruehestens" (deutsch)', () {
      expect(
        timelineEstimateText(
          deL10n,
          targetWeightKg: 68,
          weeks: (linearWeeks: 13, dynamicWeeks: 15),
        ),
        '68 kg in ca. 13–15 Wochen erreichbar – anfangs schneller, später '
        'langsamer.',
      );
      expect(
        timelineEstimateText(
          deL10n,
          targetWeightKg: 68,
          weeks: (linearWeeks: 13, dynamicWeeks: 13),
        ),
        '68 kg in ca. 13 Wochen erreichbar.',
      );
      expect(
        timelineEstimateText(
          deL10n,
          targetWeightKg: 40,
          weeks: (linearWeeks: 57, dynamicWeeks: null),
        ),
        '40 kg frühestens in ca. 57 Wochen erreichbar – mit sinkendem Gewicht '
        'lässt das Tempo nach.',
      );
      expect(
        goalProgressWeeksText(
          deL10n,
          gap: 10,
          weeks: (linearWeeks: 13, dynamicWeeks: 15),
        ),
        'Noch 10 kg · Ziel in ca. 13–15 Wochen',
      );
      expect(
        goalProgressWeeksText(
          deL10n,
          gap: 10,
          weeks: (linearWeeks: 13, dynamicWeeks: 13),
        ),
        'Noch 10 kg · Ziel in ca. 13 Wochen',
      );
      expect(
        goalProgressWeeksText(
          deL10n,
          gap: 5,
          weeks: (linearWeeks: 57, dynamicWeeks: null),
        ),
        'Noch 5 kg · Ziel frühestens in ca. 57 Wochen',
      );
    });
  });
}
