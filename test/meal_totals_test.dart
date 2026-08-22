import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meal_totals.dart';

// Tests for the pure per-day aggregation: kcal and macro sums must filter by
// day, and the kcal override must preserve fields.

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

  // Per-slot breakdown for the coach context: filter by day, sum AND count per
  // slot, omit empty slots and keep the canonical slot order.
  group('slotTotalsForFoodDate', () {
    final day = DateTime(2026, 6, 2);

    test('summiert je Slot, leere Slots fehlen, anderer Tag bleibt draußen',
        () {
      final meals = [
        // Dinner: once by time of day (20:00), once forced.
        _slotMeal(todayEvening, kcal: 400, protein: '30 g', fat: '20 g'),
        _slotMeal(today,
            slot: MealSlot.dinner, kcal: 350, protein: '30 g', fat: '20 g'),
        // Breakfast: one forced entry (12:30 would otherwise be lunch).
        _slotMeal(today,
            slot: MealSlot.breakfast,
            kcal: 200,
            protein: '10 g',
            carbs: '25 g',
            fat: '5 g'),
        // Yesterday: must not appear in any of today's slots.
        _slotMeal(yesterday, slot: MealSlot.dinner, kcal: 999),
      ];

      final bySlot = slotTotalsForFoodDate(meals, day);

      expect(bySlot.keys.toList(), [MealSlot.breakfast, MealSlot.dinner],
          reason: 'Mittagessen/Snacks ohne Eintrag fehlen komplett');

      final dinner = bySlot[MealSlot.dinner]!;
      expect(dinner.entries, 2);
      expect(dinner.macros.kcal, 750);
      expect(dinner.macros.proteinG, 60);
      expect(dinner.macros.carbsG, 100);
      expect(dinner.macros.fatG, 40);

      final breakfast = bySlot[MealSlot.breakfast]!;
      expect(breakfast.entries, 1);
      expect(breakfast.macros.kcal, 200);
      expect(breakfast.macros.proteinG, 10);
      expect(breakfast.macros.carbsG, 25);
      expect(breakfast.macros.fatG, 5);
    });

    test('Tagesfilter greift: gestern hat seine eigenen Slot-Summen', () {
      final meals = [
        _slotMeal(today, slot: MealSlot.breakfast, kcal: 200),
        _slotMeal(yesterday, slot: MealSlot.dinner, kcal: 999),
      ];
      final gestern = slotTotalsForFoodDate(meals, DateTime(2026, 6, 1));
      expect(gestern.keys.toList(), [MealSlot.dinner]);
      expect(gestern[MealSlot.dinner]!.macros.kcal, 999);
      expect(gestern[MealSlot.dinner]!.entries, 1);
    });

    test('Reihenfolge folgt MealSlot.values, nicht der Log-Reihenfolge', () {
      // The store keeps loggedMeals newest-first, so insert them reversed.
      final meals = [
        _slotMeal(today, slot: MealSlot.snack),
        _slotMeal(today, slot: MealSlot.dinner),
        _slotMeal(today, slot: MealSlot.breakfast),
      ];
      expect(
        slotTotalsForFoodDate(meals, day).keys.toList(),
        [MealSlot.breakfast, MealSlot.dinner, MealSlot.snack],
      );
    });

    test('forcedSlot schlägt die Uhrzeit-Heuristik', () {
      final meals = [
        _slotMeal(todayEvening, slot: MealSlot.breakfast, kcal: 123),
      ];
      final bySlot = slotTotalsForFoodDate(meals, day);
      expect(bySlot.keys.toList(), [MealSlot.breakfast]);
      expect(bySlot.containsKey(MealSlot.dinner), isFalse);
    });

    test('leere Liste -> leere Map', () {
      expect(slotTotalsForFoodDate(const [], day), isEmpty);
    });
  });
}

LoggedMeal _slotMeal(
  DateTime at, {
  MealSlot? slot,
  int kcal = 500,
  String protein = '30 g',
  String carbs = '50 g',
  String fat = '20 g',
}) {
  return LoggedMeal(
    id: 'id-$at-$slot-$kcal',
    result: _r(kcal: kcal, protein: protein, carbs: carbs, fat: fat),
    loggedAt: at,
    forcedSlot: slot,
  );
}
