import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/model_limits.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/kcal_calculator.dart';

// TEST-1: Makro-Aufteilung in KcalCalculator.calculate. Seit dem
// Kalorien-Review 2026-08-21 (docs/REVIEW-KCAL-2026-08-21.md):
//   * Protein = 1,6 g/kg REFERENZGEWICHT (bis BMI 25 das Ist-Gewicht, darueber
//     Gewicht bei BMI 25 + 25 % des Ueberschusses),
//   * gedeckelt auf 35 % der Energie (hart 40 %, falls sonst 1,2 g/kg
//     unterschritten wuerden),
//   * Fett 25 % der kcal, Kohlenhydrate der Rest — und der ist damit immer
//     ≥ 35 % der Energie, also ≥ 105 g beim 1200er-Boden.
//
// G4 (docs/REVIEW-2026-08-08.md) bleibt die Leitlinie: Clamp-Tests muessen den
// Clamp wirklich treffen. Zwei der alten Treffer (negative Kohlenhydrate,
// 480 g Protein bei 300 kg) sind durch die neue Formel rechnerisch
// unerreichbar geworden — dafuer sichern die Tests hier die neuen Garantien
// (KH-Boden, Energie-Deckel), und der DB-Rundgang bleibt.

void main() {
  const calc = KcalCalculator();

  group('Makro-Split: exakte Formeln', () {
    test('Protein = round(1.6 g/kg Referenz), Fett = round(25% kcal / 9)', () {
      const base = UserProfile(); // 78 kg / 178 cm (BMI 24,6), maintain
      final t = calc.calculate(base);

      // BMI ≤ 25: Referenz = Ist-Gewicht.
      expect(
        KcalCalculator.proteinReferenceWeightKg(weightKg: 78, heightCm: 178),
        78.0,
      );
      expect(t.proteinG, (78 * 1.6).round()); // 125
      expect(t.kcal, 2150);
      // Fett aus 25% des gerundeten Tagesziels.
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
        // Rundung pro Makro -> kleine Toleranz.
        expect(fromMacros, closeTo(t.kcal, 60),
            reason: 'Gewicht $w kg: $fromMacros vs ${t.kcal}');
      }
    });
  });

  group('Makro-Split: Referenzgewicht (Review 2026-08-21)', () {
    test('bis BMI 25 linear, darueber zaehlt nur ein Viertel des Ueberschusses',
        () {
      // 60 kg / 178 cm (BMI 18,9): 96 g wie bisher.
      expect(calc.calculate(const UserProfile(weightKg: 60)).proteinG, 96);
      // 90 kg / 178 cm (BMI 28,4): Normalgewicht 79,2 kg + 0,25 × 10,8 =
      // 81,9 kg → 131 g statt 144 g nach Ist-Gewicht.
      expect(
        KcalCalculator.proteinReferenceWeightKg(weightKg: 90, heightCm: 178),
        closeTo(81.9, 0.05),
      );
      expect(calc.calculate(const UserProfile(weightKg: 90)).proteinG, 131);
      // 130 kg / 175 cm (BMI 42): 76,6 + 0,25 × 53,4 = 89,9 kg → 144 g
      // statt 208 g — die alte Formel waere bei 1200 kcal auf 69 % Protein
      // gekommen.
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
      // Referenz 81 + 0,25 × 219 = 135,75 kg → 217 g (frueher 480 → 400).
      expect(t.proteinG, 217);
      expect(t.proteinG, lessThan(ProfileLimits.proteinGoalGMax));
      expect(isValidProteinGoalG(t.proteinG), isTrue);
    });

    test('Energie-Deckel: Protein hoechstens 35 %, hart 40 % der kcal', () {
      // 100 kg / 200 cm (BMI 25 → Referenz 100 kg) / weiblich / −1 kg/Woche:
      // Ziel 1200 kcal. 1,6 × 100 = 160 g waeren 53 % der Energie; der
      // 35-%-Deckel (105 g) laege unter 1,2 g/kg (120 g) → harte Grenze 40 %
      // = 120 g. Kohlenhydrate bleiben bei 106 g.
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
      // 154 kg / 150 cm / 76 J. / weiblich / sitzend / −1 kg pro Woche: mit
      // 1,6 g × Ist-Gewicht und PAL 1,2 kamen hier 246 g Protein und −20 g
      // Kohlenhydrate heraus. Jetzt: Erhaltung 2517 − 1100 = 1400 kcal,
      // Protein 122 g (Referenz 80,7 kg → 129 g, vom 35-%-Deckel auf 122 g
      // gekuerzt), 140 g Kohlenhydrate.
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
      // Der Punkt im gueltigen Eingaberaum, an dem der Rest ueber 800 g
      // liegt: 85 kg / 250 cm / 16 J. / maennlich / athlete / +0,5 kg pro
      // Woche.
      //   Erhaltung 4441 · +550 = 4991 → gerundet 5000 = kcal-Obergrenze
      //   Protein 136 g (BMI 13,6 → Ist-Gewicht) · Fett 139 g
      //   Rest = 5000 − 544 − 1251 = 3205 kcal → 801,25 g
      // Ohne `clamp` schreibt die App 801 in profiles.carbs_goal_g (Grenze
      // 800) → Constraint 23514.
      const decke = UserProfile(
        weightKg: 85,
        heightCm: 250,
        ageYears: 16,
        sex: BiologicalSex.male,
        activityLevel: ActivityLevel.athlete,
        weightGoal: WeightGoal.gain05kg,
      );
      final t = calc.calculate(decke);

      expect(t.kcal, 5000);
      expect(t.proteinG, 136);
      expect(t.fatG, 139);
      final ungeklemmt = (t.kcal - t.proteinG * 4 - t.fatG * 9) / 4;
      expect(ungeklemmt, 801.25, reason: 'ohne Clamp landet 801 in der DB');
      expect(t.carbsG, ProfileLimits.carbsGoalGMax); // 800, nicht 801
      expect(isValidCarbsGoalG(t.carbsG), isTrue);
    });

    test('Fett-Decke ist rechnerisch unerreichbar, der Clamp ist Vorsorge', () {
      // Fett = 25% des Tagesziels / 9. Das Tagesziel ist bei 5000 gedeckelt,
      // also ist 5000 × 0,25 / 9 = 138,9 g das absolute Maximum — die Grenze
      // von 300 g kann `calculate` nicht erreichen. Der Clamp bleibt trotzdem
      // stehen, damit eine spaetere Anhebung der kcal-Decke nicht still
      // 23514 erzeugt. Ein Mutationstest kann diesen Clamp nicht rot faerben.
      const maximal = UserProfile(
        weightKg: 85,
        heightCm: 250,
        ageYears: 16,
        sex: BiologicalSex.male,
        activityLevel: ActivityLevel.athlete,
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
      // Verstoesse werden gesammelt statt einzeln behauptet: ein
      // `expect` pro Kombination waere ~250.000 Aufrufe.
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

                  // DB-Grenzen (23514).
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
                  // Neue Garantien des Reviews 2026-08-21.
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
