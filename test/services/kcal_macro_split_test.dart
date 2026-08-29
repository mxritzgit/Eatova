import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/model_limits.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/kcal_calculator.dart';

// TEST-1: macro split in KcalCalculator.calculate (Review 2026-08-21). Protein
// is 1.6 g/kg REFERENCE weight (actual up to BMI 25, above that the BMI-25
// weight plus a quarter of the excess), capped at 35 % of energy (hard 40 % if
// 1.2 g/kg would be undercut); fat is 25 % of kcal and carbs the remainder.
// G4 stays the guideline — clamp tests must actually hit the clamp.

void main() {
  const calc = KcalCalculator();

  group('Makro-Split: exakte Formeln', () {
    test('Protein = round(1.6 g/kg Referenz), Fett = round(25% kcal / 9)', () {
      const base = UserProfile(); // 78 kg / 178 cm (BMI 24.6), maintain
      final t = calc.calculate(base);

      // BMI <= 25: reference = actual weight.
      expect(
        KcalCalculator.proteinReferenceWeightKg(weightKg: 78, heightCm: 178),
        78.0,
      );
      expect(t.proteinG, (78 * 1.6).round()); // 125
      expect(t.kcal, 2150);
      // Fat from 25 % of the rounded daily target.
      expect(t.fatG, ((t.kcal * 0.25) / 9).round()); // 60
    });

    test('Carbs = round((kcal - 4*Protein - 9*Fett) / 4)', () {
      const base = UserProfile();
      final t = calc.calculate(base);
      final remaining = t.kcal - t.proteinG * 4 - t.fatG * 9;
      expect(t.carbsG, (remaining / 4).round());
    });

    test('rekonstruiertes kcal aus Makros bleibt nahe am Ziel', () {
      for (final w in const [55, 78, 110]) {
        final t = calc.calculate(UserProfile(weightKg: w));
        final fromMacros = t.proteinG * 4 + t.carbsG * 4 + t.fatG * 9;
        // Per-macro rounding -> small tolerance.
        expect(fromMacros, closeTo(t.kcal, 60),
            reason: 'Gewicht $w kg: $fromMacros vs ${t.kcal}');
      }
    });
  });

  group('Makro-Split: Referenzgewicht (Review 2026-08-21)', () {
    test('bis BMI 25 linear, darueber zaehlt nur ein Viertel des Ueberschusses',
        () {
      // 60 kg / 178 cm (BMI 18.9): 96 g, unchanged.
      expect(calc.calculate(const UserProfile(weightKg: 60)).proteinG, 96);
      // 90 kg / 178 cm (BMI 28.4): 79.2 + 0.25 x 10.8 = 81.9 kg -> 131 g
      // instead of 144 g by actual weight.
      expect(
        KcalCalculator.proteinReferenceWeightKg(weightKg: 90, heightCm: 178),
        closeTo(81.9, 0.05),
      );
      expect(calc.calculate(const UserProfile(weightKg: 90)).proteinG, 131);
      // 130 kg / 175 cm (BMI 42): 76.6 + 0.25 x 53.4 = 89.9 kg -> 144 g
      // instead of 208 g, which would have been 69 % protein at 1200 kcal.
      expect(
        calc
            .calculate(const UserProfile(weightKg: 130, heightCm: 175))
            .proteinG,
        144,
      );
    });

    test('300 kg treffen die 400-g-Grenze nicht mehr — sie bleibt Vorsorge',
        () {
      const schwer = UserProfile(
        weightKg: ProfileLimits.weightKgMax,
        heightCm: 180,
        ageYears: 40,
        sex: BiologicalSex.male,
      );
      final t = calc.calculate(schwer);
      // Reference 81 + 0.25 x 219 = 135.75 kg -> 217 g (formerly 480 -> 400).
      expect(t.proteinG, 217);
      expect(t.proteinG, lessThan(ProfileLimits.proteinGoalGMax));
      expect(isValidProteinGoalG(t.proteinG), isTrue);
    });

    test('Energie-Deckel: Protein hoechstens 35 %, hart 40 % der kcal', () {
      // 100 kg / 200 cm (BMI 25, reference 100 kg), target 1200 kcal:
      // 160 g would be 53 % of energy, and the 35 % cap (105 g) sits below
      // 1.2 g/kg (120 g), so the hard 40 % limit applies -> 120 g.
      const deckel = UserProfile(
        weightKg: 100,
        heightCm: 200,
        ageYears: 100,
        sex: BiologicalSex.female,
        weightGoal: WeightGoal.lose1kg,
      );
      final t = calc.calculate(deckel);
      expect(t.kcal, KcalCalculator.kcalFloor);
      expect(t.proteinG, 120);
      expect(t.proteinG * 4, lessThanOrEqualTo(t.kcal * 0.40));
      expect(t.fatG, 33);
      expect(t.carbsG, 106);
      expect(t.carbsG, greaterThanOrEqualTo(KcalCalculator.carbsMinG));
    });

    test('der alte Carb-Boden-Fall ist entschaerft', () {
      // The old formula produced 246 g protein and -20 g carbs here. Now:
      // 2517 - 1100 = 1400 kcal, protein 129 g by reference weight, cut to
      // 122 g by the 35 % cap, leaving 140 g carbs.
      const boden = UserProfile(
        weightKg: 154,
        heightCm: 150,
        ageYears: 76,
        sex: BiologicalSex.female,
        weightGoal: WeightGoal.lose1kg,
      );
      final t = calc.calculate(boden);
      expect(t.kcal, 1400);
      expect(t.proteinG, 122);
      expect(t.fatG, 39);
      expect(t.carbsG, 140);
    });
  });

  group('Makro-Split: Rand- und Clamp-Pfade', () {
    test('alle Makros strikt > 0 fuer normale Profile', () {
      final t = calc.calculate(const UserProfile());
      expect(t.proteinG, greaterThan(0));
      expect(t.carbsG, greaterThan(0));
      expect(t.fatG, greaterThan(0));
    });

    test('Carb-Decke: 800 g werden exakt getroffen und geklemmt', () {
      // The one point in the valid input space where the remainder exceeds
      // 800 g: 5000 kcal ceiling, 136 g protein, 139 g fat leave 3205 kcal
      // = 801.25 g. Without the clamp the app writes 801 into
      // profiles.carbs_goal_g (limit 800) -> constraint 23514.
      const decke = UserProfile(
        weightKg: 85,
        heightCm: 250,
        ageYears: 16,
        sex: BiologicalSex.male,
        activityLevel: ActivityLevel.athlete,
        // Wunschgewicht UEBER dem heutigen: seit P9-08d rechnet calculate mit
        // dem wirksamen Ziel, und eine Zunahme auf 78 kg bei 85 kg ist keine.
        targetWeightKg: 95,
        weightGoal: WeightGoal.gain05kg,
      );
      final t = calc.calculate(decke);

      expect(t.kcal, 5000);
      expect(t.proteinG, 136);
      expect(t.fatG, 139);
      final ungeklemmt = (t.kcal - t.proteinG * 4 - t.fatG * 9) / 4;
      expect(ungeklemmt, 801.25, reason: 'ohne Clamp landet 801 in der DB');
      expect(t.carbsG, ProfileLimits.carbsGoalGMax); // 800, not 801
      expect(isValidCarbsGoalG(t.carbsG), isTrue);
    });

    test('Fett-Decke ist rechnerisch unerreichbar, der Clamp ist Vorsorge', () {
      // Fat = 25 % of the target / 9, and the target is capped at 5000, so
      // 138.9 g is the absolute maximum and the 300 g limit is unreachable.
      // The clamp stays so a later ceiling raise cannot silently cause 23514.
      const maximal = UserProfile(
        weightKg: 85,
        heightCm: 250,
        ageYears: 16,
        sex: BiologicalSex.male,
        activityLevel: ActivityLevel.athlete,
        targetWeightKg: 95,
        weightGoal: WeightGoal.gain05kg,
      );
      final t = calc.calculate(maximal);

      expect(t.fatG, 139);
      expect(((KcalCalculator.kcalCeiling * 0.25) / 9).round(), 139);
      expect(t.fatG, lessThan(ProfileLimits.fatGoalGMax));
      expect(isValidFatGoalG(t.fatG), isTrue);
    });
  });

  group('Makro-Split: nichts verlaesst calculate() ausserhalb der Garantien',
      () {
    test('Rundgang durch den gesamten gueltigen Eingaberaum', () {
      // Violations are collected, not asserted one by one: an `expect` per
      // combination would be ~250,000 calls.
      final verstoesse = <String>[];

      for (var weight = ProfileLimits.weightKgMin;
          weight <= ProfileLimits.weightKgMax;
          weight += 5) {
        for (var height = ProfileLimits.heightCmMin;
            height <= ProfileLimits.heightCmMax;
            height += 10) {
          for (final age in const [
            ProfileLimits.ageYearsMin,
            45,
            ProfileLimits.ageYearsMax,
          ]) {
            for (final sex in BiologicalSex.values) {
              for (final level in ActivityLevel.values) {
                for (final goal in WeightGoal.values) {
                  final t = calc.calculate(UserProfile(
                    weightKg: weight,
                    heightCm: height,
                    ageYears: age,
                    sex: sex,
                    activityLevel: level,
                    weightGoal: goal,
                  ));
                  final wer = '$weight kg / $height cm / $age J. / '
                      '${sex.name} / ${level.name} / ${goal.name}';

                  // DB bounds (23514).
                  if (!isValidDailyKcalGoal(t.kcal)) {
                    verstoesse.add('$wer: daily_kcal_goal ${t.kcal}');
                  }
                  if (!isValidProteinGoalG(t.proteinG)) {
                    verstoesse.add('$wer: protein_goal_g ${t.proteinG}');
                  }
                  if (!isValidCarbsGoalG(t.carbsG)) {
                    verstoesse.add('$wer: carbs_goal_g ${t.carbsG}');
                  }
                  if (!isValidFatGoalG(t.fatG)) {
                    verstoesse.add('$wer: fat_goal_g ${t.fatG}');
                  }
                  // New guarantees from the 2026-08-21 review.
                  if (t.carbsG < KcalCalculator.carbsMinG) {
                    verstoesse.add('$wer: nur ${t.carbsG} g Kohlenhydrate');
                  }
                  if (t.proteinG * 4 > t.kcal * 0.40 + 4) {
                    verstoesse.add('$wer: Protein ${t.proteinG} g > 40 %');
                  }
                  if (t.kcal < KcalCalculator.kcalFloorFor(sex)) {
                    verstoesse.add('$wer: ${t.kcal} unter der Untergrenze');
                  }
                }
              }
            }
          }
        }
      }

      expect(
        verstoesse,
        isEmpty,
        reason: '${verstoesse.length} Verstoesse: '
            '${verstoesse.take(5).join(' | ')}',
      );
    });
  });
}
