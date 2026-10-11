// A reused portion (a recent, a favorite, an edit) rescales from the label's
// values per 100 g, not from the rounded numbers of the portion it was stored
// at: a splash of milk kept as the recent turned 250 g into 7,5 g protein and
// 5 g fat (label: 8,5 g and 3,75 g).

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/services/meals_sync.dart';

MealAnalysisResult _milk() =>
    MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
      'code': '4000000000017',
      'product_name': 'Milch 1,5 %',
      'serving_quantity': 100,
      'nutrition_data_per': '100g',
      'nutriments': <String, dynamic>{
        'energy-kcal_100g': 47,
        'proteins_100g': 3.4,
        'carbohydrates_100g': 4.8,
        'fat_100g': 1.5,
      },
    }, '4000000000017');

void _expectMilkAt250(MealAnalysisResult result) {
  expect(result.estimatedGrams, 250);
  expect(result.caloriesKcal, 118);
  expect(result.kcalPer100G, closeTo(47, 0.01));
  expect(result.protein, '8,5 g');
  expect(result.carbs, '12 g');
  expect(result.fat, '3,8 g');
}

void main() {
  test('Milch: ein Schluck als Snapshot, dann 250 g wie vom Etikett', () {
    final splash = _milk().adjustedToGrams(10);
    expect(splash.protein, '0,3 g');
    _expectMilkAt250(splash.adjustedToGrams(250));
  });

  test('der gespeicherte Snapshot behaelt die Werte pro 100 g', () {
    final stored = mealResultFromJson(
      mealResultToJson(_milk().adjustedToGrams(10)),
    );
    _expectMilkAt250(stored.adjustedToGrams(250));
    // Several small reuses in a row do not walk the numbers either.
    _expectMilkAt250(
      stored.adjustedToGrams(12).adjustedToGrams(7).adjustedToGrams(250),
    );
  });

  test('manuelle Eingabe: 5 g Bissen, dann 150 g wie vom Etikett', () {
    final apple = MealAnalysisResult.manualEntry(
      name: 'Apfel',
      kcalPer100G: 52,
      grams: 150,
      proteinPer100G: 1,
      carbsPer100G: 14,
      fatPer100G: 1,
    );
    final reused = apple.adjustedToGrams(5).adjustedToGrams(150);
    expect(reused.caloriesKcal, 78);
    expect(reused.protein, '1,5 g');
    expect(reused.carbs, '21 g');
    expect(reused.fat, '1,5 g');
  });

  test('ohne Werte pro 100 g skaliert der Makrotext wie bisher', () {
    const scan = MealAnalysisResult(
      mealName: 'Pasta',
      caloriesKcal: 600,
      estimatedGrams: 400,
      kcalPer100G: 150,
      protein: '20 g',
      carbs: '80 g',
      fat: '15 g',
      confidence: 'medium',
      portionNotes: '',
    );
    final half = scan.adjustedToGrams(200);
    expect(half.protein, '10 g');
    expect(half.fat, '7,5 g');
    expect(half.proteinPer100G, isNull);
  });

  test('ein Text, den die Werte pro 100 g nicht mehr tragen, gewinnt', () {
    // An older build changed the text and kept the field: the field is stale.
    final stale = mealResultFromJson(<String, dynamic>{
      ...mealResultToJson(_milk()),
      'protein': '9 g',
    });
    expect(stale.proteinPer100G, isNull);
    expect(stale.fatPer100G, 1.5);
    expect(stale.adjustedToGrams(200).protein, '18 g');
  });

  test('unplausible Werte pro 100 g aus dem Payload zaehlen nicht', () {
    final json = <String, dynamic>{
      ...mealResultToJson(_milk()),
      'proteinPer100G': 340,
      'fatPer100G': 'viel',
    };
    final read = mealResultFromJson(json);
    expect(read.proteinPer100G, isNull);
    expect(read.fatPer100G, isNull);
    expect(read.carbsPer100G, 4.8);
  });

  test('Komponenten setzen die Werte pro 100 g zurueck', () {
    final milk = _milk();
    final mixed = milk.adjustedToItems(const [
      MealComponent(
        name: 'Milch',
        grams: 200,
        caloriesKcal: 94,
        kcalPer100G: 47,
      ),
      MealComponent(name: 'Kakao', grams: 20, caloriesKcal: 80),
    ]);
    expect(mixed.proteinPer100G, isNull);
    expect(mixed.carbsPer100G, isNull);
    expect(mixed.fatPer100G, isNull);
  });

  test(
    'FOOD-9: a 0 g item scales its kcal and macros with the portion and '
    'keeps 0 g',
    () {
      const scan = MealAnalysisResult(
        mealName: 'Salat mit Dressing',
        caloriesKcal: 200,
        estimatedGrams: 200,
        kcalPer100G: 100,
        protein: '4 g',
        carbs: '10 g',
        fat: '14 g',
        confidence: 'Hoch',
        portionNotes: '',
        sourceLabel: 'Foto-KI',
        items: <MealComponent>[
          MealComponent(
            name: 'Salat',
            grams: 200,
            caloriesKcal: 40,
            proteinG: 2,
            carbsG: 6,
            fatG: 0,
          ),
          // The model gave the dressing calories but no mass.
          MealComponent(
            name: 'Dressing',
            grams: 0,
            caloriesKcal: 160,
            proteinG: 2,
            carbsG: 4,
            fatG: 14,
          ),
        ],
      );

      final half = scan.adjustedToGrams(100);
      final dressing = half.items.last;
      expect(dressing.grams, 0);
      expect(dressing.caloriesKcal, 80);
      expect(dressing.proteinG, 1);
      expect(dressing.carbsG, 2);
      expect(dressing.fatG, 7);
      // The components sheet's sum matches the meal it belongs to.
      expect(
        half.items.fold<int>(0, (sum, item) => sum + item.caloriesKcal),
        half.caloriesKcal,
      );
    },
  );
}
