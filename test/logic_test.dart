import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/services/food_kcal_db.dart';
import 'package:eatova/src/services/meals_sync.dart';

// Pure logic tests: the food-history JSON roundtrip and the meal-name split.
// Deterministic, no network or UI. Neighbours: the streak in
// test/models/lifetime_stats_test.dart, strict payload parsing in
// test/services/meal_payload_strict_test.dart, and the autoSplitItems totals in
// test/food_kcal_sentinel_test.dart and test/food_kcal_db_invariants_test.dart.

MealAnalysisResult _result({
  String name = 'Testmahlzeit',
  int kcal = 500,
  int grams = 300,
  String protein = '30 g',
  String carbs = '50 g',
  String fat = '20 g',
  List<MealComponent> items = const <MealComponent>[],
  String? barcode,
  String? brand,
}) {
  return MealAnalysisResult(
    mealName: name,
    caloriesKcal: kcal,
    estimatedGrams: grams,
    kcalPer100G: grams > 0 ? kcal * 100 / grams : 0,
    protein: protein,
    carbs: carbs,
    fat: fat,
    confidence: 'Hoch',
    portionNotes: 'Notiz',
    items: items,
    barcode: barcode,
    brand: brand,
  );
}

void main() {
  group('mealResultToJson/fromJson Roundtrip (Food-History-Persistenz)', () {
    test('vollständiges Ergebnis inkl. items/barcode/brand übersteht den Trip', () {
      final r = _result(
        name: 'Pizza Salami',
        kcal: 820,
        grams: 350,
        protein: '32 g',
        carbs: '90 g',
        fat: '34 g',
        barcode: '4001234567890',
        brand: 'Dr. Oetker',
        items: const [
          MealComponent(
              name: 'Teig', grams: 200, caloriesKcal: 500, kcalPer100G: 250),
          MealComponent(
              name: 'Salami', grams: 150, caloriesKcal: 320, kcalPer100G: 213),
        ],
      );
      final back = mealResultFromJson(mealResultToJson(r));
      expect(back.mealName, 'Pizza Salami');
      expect(back.caloriesKcal, 820);
      expect(back.estimatedGrams, 350);
      expect(back.protein, '32 g');
      expect(back.barcode, '4001234567890');
      expect(back.brand, 'Dr. Oetker');
      expect(back.items.length, 2);
      expect(back.items.first.name, 'Teig');
      expect(back.items.first.grams, 200);
      expect(back.items[1].caloriesKcal, 320);
    });
    test('teilbefuelltes JSON (caloriesKcal vorhanden) behaelt Label-Defaults',
        () {
      final back = mealResultFromJson(<String, dynamic>{'caloriesKcal': 300});
      expect(back.mealName, 'Mahlzeit');
      expect(back.caloriesKcal, 300);
      expect(back.items, isEmpty);
      // The fallback for a missing sourceLabel is the language-neutral code,
      // not a German display string (see MealResultSource docs).
      expect(back.sourceLabel, 'aiEstimate');
      expect(back.resolvedSourceLabel(deL10n), 'KI-Schätzung');
      expect(back.resolvedSourceLabel(enL10n), 'AI estimate');
    });
  });

  group('food_kcal_db splitMealName / autoSplitItems', () {
    test('splitMealName trennt an mit/und/&/+ und filtert Füllwörter', () {
      expect(splitMealName('Hähnchen mit Reis und Brokkoli'),
          ['Hähnchen', 'Reis', 'Brokkoli']);
      expect(splitMealName('Lachs & Spargel + Kartoffeln auf einem Teller'),
          contains('Lachs'));
      expect(splitMealName('Pizza'), ['Pizza']); // not splittable
    });
    test('autoSplitItems gibt [] zurück wenn nicht teilbar', () {
      expect(
        autoSplitItems(mealName: 'Apfel', totalGrams: 120, totalKcal: 62),
        isEmpty,
      );
    });
  });
}
