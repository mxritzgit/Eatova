import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/kcal_calculator.dart';

// TEST-1: Makro-Aufteilung in KcalCalculator.calculate (1.6 g Protein/kg,
// 25% kcal aus Fett, Rest Kohlenhydrate). logic_test.dart deckt den Happy
// Path ab — hier die exakte Arithmetik + die Rand-/Clamp-Pfade
// (carbs clamp 0..800, negativer Rest -> 0), die sonst stille Zielbugs waeren.

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

    test('schweres Profil mit hohem PAL: carbs bleiben <= 800 (Clamp-Decke)', () {
      // Sehr hohes kcal-Ziel treibt remainingKcal hoch — der Clamp(0,800)
      // verhindert absurde Carb-Werte. Wir verifizieren die Decke greift.
      const huge = UserProfile(
        weightKg: 60, // niedriges Protein -> mehr Rest fuer Carbs
        heightCm: 200,
        ageYears: 20,
        sex: BiologicalSex.male,
        activityLevel: ActivityLevel.athlete,
        weightGoal: WeightGoal.gain05kg,
      );
      final t = calc.calculate(huge);
      expect(t.carbsG, lessThanOrEqualTo(800));
      expect(t.carbsG, greaterThanOrEqualTo(0));
    });

    test('hohes Gewicht + tiefes kcal-Ziel: carbs nie negativ (Clamp-Boden)', () {
      // Viel Protein (Gewicht) gegen ein an die Untergrenze geclamptes
      // kcal-Ziel -> remainingKcal koennte rechnerisch negativ werden; der
      // Clamp(0, …) faengt das ab.
      const cut = UserProfile(
        weightKg: 130,
        heightCm: 150,
        ageYears: 75,
        weightGoal: WeightGoal.lose1kg,
      );
      final t = calc.calculate(cut);
      expect(t.kcal, greaterThanOrEqualTo(1200)); // Untergrenze
      expect(t.carbsG, greaterThanOrEqualTo(0));
      expect(t.fatG, greaterThanOrEqualTo(0));
    });

    test('Protein skaliert linear mit dem Gewicht, unabhaengig vom kcal-Ziel', () {
      final light = calc.calculate(const UserProfile(weightKg: 60));
      final heavy = calc.calculate(const UserProfile(weightKg: 90));
      expect(light.proteinG, (60 * 1.6).round()); // 96
      expect(heavy.proteinG, (90 * 1.6).round()); // 144
      expect(heavy.proteinG, greaterThan(light.proteinG));
    });
  });
}
