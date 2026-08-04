import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meal_totals.dart';

// Tests für die aus dem God-Object (_EatovaHomePageState) extrahierte reine
// Tages-Aggregation. Stellt sicher, dass die kcal-/Makro-Summen tag-genau
// filtern und das kcal-Override Felder erhält.

MealAnalysisResult _r({
  int kcal = 500,
  String protein = '30 g',
  String carbs = '50 g',
  String fat = '20 g',
}) {
  return MealAnalysisResult(
    mealName: 'M',
    caloriesKcal: kcal,
    estimatedGrams: 300,
    kcalPer100G: 100,
    protein: protein,
    carbs: carbs,
    fat: fat,
    confidence: 'Hoch',
    portionNotes: '',
  );
}

LoggedMeal _meal(DateTime at, {int kcal = 500}) =>
    LoggedMeal(id: 'id-$at', result: _r(kcal: kcal), loggedAt: at);

void main() {
  final today = DateTime(2026, 6, 2, 12, 30);
  final todayEvening = DateTime(2026, 6, 2, 20, 0);
  final yesterday = DateTime(2026, 6, 1, 9, 0);

  group('mealsForFoodDate', () {
    test('liefert nur Mahlzeiten des gewählten Tages (Uhrzeit egal)', () {
      final meals = [
        _meal(today),
        _meal(todayEvening),
        _meal(yesterday),
      ];
      final result = mealsForFoodDate(meals, DateTime(2026, 6, 2));
      expect(result.length, 2);
      final back = mealsForFoodDate(meals, DateTime(2026, 6, 1));
      expect(back.length, 1);
    });

    test('leere Liste -> leeres Ergebnis', () {
      expect(mealsForFoodDate(const [], today), isEmpty);
    });
  });

  group('consumedKcalForFoodDate', () {
    test('summiert nur den gewählten Tag', () {
      final meals = [
        _meal(today, kcal: 400),
        _meal(todayEvening, kcal: 350),
        _meal(yesterday, kcal: 999),
      ];
      expect(consumedKcalForFoodDate(meals, DateTime(2026, 6, 2)), 750);
      expect(consumedKcalForFoodDate(meals, DateTime(2026, 6, 1)), 999);
    });
  });

  group('macroProgressForFoodDate', () {
    test('summiert Makros + kcal des Tages', () {
      final meals = [
        _meal(today, kcal: 400),
        _meal(todayEvening, kcal: 350),
      ];
      final p = macroProgressForFoodDate(meals, DateTime(2026, 6, 2));
      expect(p.proteinG, 60); // 2x 30 g
      expect(p.carbsG, 100); // 2x 50 g
      expect(p.fatG, 40); // 2x 20 g
      expect(p.kcal, 750);
    });
  });

  group('copyResultWithKcal', () {
    test('überschreibt kcal, markiert angepasst, behält übrige Felder', () {
      final original = _r(kcal: 500, protein: '30 g');
      final copy = copyResultWithKcal(original, 250);
      expect(copy.caloriesKcal, 250);
      expect(copy.isAdjusted, isTrue);
      expect(copy.protein, '30 g');
      expect(copy.estimatedGrams, original.estimatedGrams);
      expect(copy.mealName, original.mealName);
    });
  });
}
