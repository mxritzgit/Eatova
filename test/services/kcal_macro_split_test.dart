import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/model_limits.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/kcal_calculator.dart';

// TEST-1: Makro-Aufteilung in KcalCalculator.calculate (1.6 g Protein/kg,
// 25% kcal aus Fett, Rest Kohlenhydrate). logic_test.dart deckt den Happy
// Path ab — hier die exakte Arithmetik + die Rand-/Clamp-Pfade.
//
// G4 (docs/REVIEW-2026-08-08.md): Die frueheren „Clamp"-Tests erreichten
// keinen einzigen Clamp — das Decken-Profil kam auf 636 g Kohlenhydrate
// (Grenze 800), das Boden-Profil auf 18 g (Grenze 0). `lessThanOrEqualTo(800)`
// war trivial wahr. Die Profile unten sind aus dem gesamten gueltigen
// Eingaberaum (ProfileLimits) hergeleitet und treffen die Grenzen exakt;
// jeder dieser Tests wird rot, wenn man den zugehoerigen Clamp entfernt.

void main() {
  const calc = KcalCalculator();

  group('Makro-Split: exakte Formeln', () {
    test('Protein = round(1.6 g/kg), Fett = round(25% kcal / 9)', () {
      const base = UserProfile(); // 78 kg, neutral, sedentary, maintain
      final t = calc.calculate(base);

      expect(t.proteinG, (78 * 1.6).round()); // 125
      // Fett aus 25% des gerundeten Tagesziels.
      final expectedFat = ((t.kcal * 0.25) / 9).round();
      expect(t.fatG, expectedFat);
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

  group('Makro-Split: Rand- und Clamp-Pfade', () {
    test('alle Makros strikt > 0 fuer normale Profile', () {
      final t = calc.calculate(const UserProfile());
      expect(t.proteinG, greaterThan(0));
      expect(t.carbsG, greaterThan(0));
      expect(t.fatG, greaterThan(0));
    });

    test('Carb-Decke: 800 g werden exakt getroffen und geklemmt', () {
      // Der EINZIGE Punkt im gesamten gueltigen Eingaberaum (Gewicht 30..300,
      // Groesse 100..250, Alter 16..100, 3 Geschlechter, 5 PAL-Stufen,
      // 7 Ziele), an dem der Rest ueber 800 g liegt: 85 kg / 250 cm / 16 J. /
      // maennlich / athlete / +0,5 kg pro Woche.
      //   Erhaltung 4441 · +550 = 4991 → gerundet 5000 (kcal-Obergrenze)
      //   Protein 136 g · Fett 139 g
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

    test('Carb-Boden: negativer Rest wird auf 0 geklemmt', () {
      // 154 kg / 150 cm / 76 J. / weiblich / sitzend / −1 kg pro Woche:
      //   Erhaltung 2323 · −1100 = 1224 → gerundet 1200 (kcal-Untergrenze)
      //   Protein 246 g (984 kcal) · Fett 33 g (297 kcal)
      //   Rest = 1200 − 984 − 297 = −81 kcal → −20,25 g
      // Ohne `clamp` schreibt die App −20 in profiles.carbs_goal_g → 23514.
      const boden = UserProfile(
        weightKg: 154,
        heightCm: 150,
        ageYears: 76,
        sex: BiologicalSex.female,
        weightGoal: WeightGoal.lose1kg,
      );
      final t = calc.calculate(boden);

      expect(t.kcal, KcalCalculator.kcalFloor);
      expect(t.proteinG, 246);
      expect(t.fatG, 33);
      final ungeklemmt = (t.kcal - t.proteinG * 4 - t.fatG * 9) / 4;
      expect(ungeklemmt, -20.25, reason: 'ohne Clamp landet −20 in der DB');
      expect(t.carbsG, ProfileLimits.carbsGoalGMin); // 0, nicht −20
      expect(isValidCarbsGoalG(t.carbsG), isTrue);
    });

    test('Protein-Decke: 1,6 g/kg ueberschreitet ab 251 kg die 400-g-Grenze',
        () {
      // 300 kg ist das Maximum von profiles.weight_kg. 1,6 × 300 = 480 g —
      // profiles.protein_goal_g erlaubt hoechstens 400.
      const schwer = UserProfile(
        weightKg: ProfileLimits.weightKgMax,
        heightCm: 180,
        ageYears: 40,
        sex: BiologicalSex.male,
      );
      final t = calc.calculate(schwer);

      expect((schwer.weightKg * 1.6).round(), 480, reason: 'ohne Clamp: 480');
      expect(t.proteinG, ProfileLimits.proteinGoalGMax); // 400
      expect(isValidProteinGoalG(t.proteinG), isTrue);

      // Direkt unterhalb der Schwelle bleibt der Wert unveraendert.
      final knappDrunter = calc.calculate(schwer.copyWith(weightKg: 250));
      expect(knappDrunter.proteinG, 400);
      final drunter = calc.calculate(schwer.copyWith(weightKg: 200));
      expect(drunter.proteinG, 320);
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

    test('Protein skaliert linear mit dem Gewicht, unabhaengig vom kcal-Ziel',
        () {
      final light = calc.calculate(const UserProfile(weightKg: 60));
      final heavy = calc.calculate(const UserProfile(weightKg: 90));
      expect(light.proteinG, (60 * 1.6).round()); // 96
      expect(heavy.proteinG, (90 * 1.6).round()); // 144
      expect(heavy.proteinG, greaterThan(light.proteinG));
    });
  });

  group('Makro-Split: nichts verlaesst calculate() ausserhalb der DB-Grenzen',
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
                }
              }
            }
          }
        }
      }

      expect(
        verstoesse,
        isEmpty,
        reason: '${verstoesse.length} Profile schreiben 23514: '
            '${verstoesse.take(5).join(' | ')}',
      );
    });
  });
}
