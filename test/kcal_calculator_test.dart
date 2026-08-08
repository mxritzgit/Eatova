import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/kcal_calculator.dart';

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
  });

  group('KcalCalculator.calculate', () {
    const calc = KcalCalculator();
    const base = UserProfile(); // 78kg, 178cm, 30J, neutral

    test('maintenance uses base lifestyle factor, not the step goal', () {
      // Der Bug war: Tagesbedarf wurde aus dem Schritt-ZIEL hochgerechnet
      // und die echten Schritte nochmal addiert. Jetzt darf das Schrittziel
      // den Bedarf NICHT mehr beeinflussen.
      final low = calc.calculate(base.copyWith(dailyStepsGoal: 3000));
      final high = calc.calculate(base.copyWith(dailyStepsGoal: 15000));
      expect(low.kcal, high.kcal);
      expect(low.maintenanceKcal, high.maintenanceKcal);
    });

    test('maintain goal targets the maintenance need (~BMR x 1.2)', () {
      final t = calc.calculate(base); // WeightGoal.maintain
      expect(t.goal, WeightGoal.maintain);
      expect(t.maintenanceKcal, 1997); // 1664.5 BMR x 1.2
      expect(t.kcal, 2000); // auf 50 gerundet
    });

    test('weight goal applies its kcal delta on top of maintenance', () {
      final maintain = calc.calculate(base.copyWith(weightGoal: WeightGoal.maintain));
      final lose = calc.calculate(base.copyWith(weightGoal: WeightGoal.lose05kg));
      final gain = calc.calculate(base.copyWith(weightGoal: WeightGoal.gain05kg));

      expect(lose.kcal, maintain.kcal - 550); // −0,5 kg/Woche
      expect(gain.kcal, maintain.kcal + 550); // +0,5 kg/Woche
      // Erhaltungsbedarf bleibt unabhängig vom Ziel gleich.
      expect(lose.maintenanceKcal, maintain.maintenanceKcal);
      expect(gain.maintenanceKcal, maintain.maintenanceKcal);
    });

    test('aggressive -1 kg/week applies the full 1100 kcal deficit', () {
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
      expect(lose1kg.kcal, maintain.kcal - 1100);
    });

    test('clamps daily kcal into a sane range', () {
      final tiny = calc.calculate(const UserProfile(
        weightKg: 35,
        heightCm: 140,
        ageYears: 80,
        weightGoal: WeightGoal.lose1kg,
      ));
      expect(tiny.kcal, greaterThanOrEqualTo(1200));
    });

    test('activity level scales maintenance via its PAL factor', () {
      final sedentary =
          calc.calculate(base.copyWith(activityLevel: ActivityLevel.sedentary));
      final moderate =
          calc.calculate(base.copyWith(activityLevel: ActivityLevel.moderate));
      final athlete =
          calc.calculate(base.copyWith(activityLevel: ActivityLevel.athlete));

      // 1664.5 BMR × {1.2, 1.55, 1.9}
      expect(sedentary.maintenanceKcal, 1997);
      expect(moderate.maintenanceKcal, 2580);
      expect(athlete.maintenanceKcal, 3163);
      expect(moderate.kcal, greaterThan(sedentary.kcal));
      expect(athlete.kcal, greaterThan(moderate.kcal));
    });
  });

  group('KcalCalculator.weeksToGoal', () {
    const calc = KcalCalculator();
    const base = UserProfile();

    test('Prognose folgt der EFFEKTIVEN Rate, nicht dem Wunsch-Delta', () {
      // B2: Frueher wurde stur `kcalDelta / 7700` gerechnet — also das
      // Tempo, das der Nutzer gewaehlt hat, nicht das, was sein Tagesziel
      // hergibt.
      //
      // 78 → 68 kg = 10 kg. Erhaltung 1997.
      //   −0,5 kg/Woche → Ziel 1450 kcal (50er-Rundung) → real 547 kcal/Tag
      //     ≙ 0,4973 kg/Woche → 10 / 0,4973 = 20,1 → 21 Wochen (frueher 20).
      final profile = base.copyWith(
        targetWeightKg: 68,
        weightGoal: WeightGoal.lose05kg,
      );
      expect(calc.weeksToGoal(profile), 21);

      // −1 kg/Woche waere 897 kcal; die Untergrenze hebt auf 1200 an. Real
      // bleiben 797 kcal/Tag ≙ 0,7245 kg/Woche → 13,8 → 14 Wochen
      // (frueher versprach die App 10).
      expect(
        calc.weeksToGoal(base.copyWith(
          targetWeightKg: 68,
          weightGoal: WeightGoal.lose1kg,
        )),
        14,
      );
    });

    test('gleiches Tagesziel ⇒ gleiche Prognose (lose075kg vs. lose1kg)', () {
      // Beide Tempi landen fuer dieses Profil auf 1200 kcal. Zwei
      // verschiedene Wochenzahlen fuer denselben Plan waren der Kern von B2.
      final ziel = base.copyWith(targetWeightKg: 68);
      expect(
        calc.calculate(ziel.copyWith(weightGoal: WeightGoal.lose1kg)).kcal,
        calc.calculate(ziel.copyWith(weightGoal: WeightGoal.lose075kg)).kcal,
      );
      expect(
        calc.weeksToGoal(ziel.copyWith(weightGoal: WeightGoal.lose1kg)),
        calc.weeksToGoal(ziel.copyWith(weightGoal: WeightGoal.lose075kg)),
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
      // Ziel über aktuellem Gewicht, aber Abnehm-Ziel gewählt → kein Sinn.
      expect(
        calc.weeksToGoal(base.copyWith(
          targetWeightKg: 90,
          weightGoal: WeightGoal.lose05kg,
        )),
        isNull,
      );
    });
  });
}
