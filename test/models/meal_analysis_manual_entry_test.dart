import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';

// Manueller Eintrag (Spec 2026-08-13): Etikett-Werte pro 100 g plus die
// gegessene Portion — die Factory rechnet die Portionswerte aus und traegt
// die neuen manual-Herkunfts-Codes.
void main() {
  test('manualEntry rechnet die Portion aus den 100-g-Werten', () {
    final r = MealAnalysisResult.manualEntry(
      name: 'Bauern-Mozzarella',
      kcalPer100G: 265,
      grams: 125,
      proteinPer100G: 18,
      carbsPer100G: 2,
      fatPer100G: 22,
    );
    expect(r.mealName, 'Bauern-Mozzarella');
    expect(r.caloriesKcal, 331, reason: '265 × 1,25 = 331,25 → gerundet');
    expect(r.estimatedGrams, 125);
    expect(r.kcalPer100G, 265);
    expect(r.protein, '22,5 g');
    expect(r.carbs, '2,5 g');
    expect(r.fat, '27,5 g');
    expect(r.sourceLabel, 'manual');
    expect(r.confidence, 'manual');
    expect(r.portionNotes, 'manualEntryNote');
    expect(r.explicitZeroKcal, isFalse);
    expect(r.items, isEmpty);
    expect(r.barcode, isNull);
  });

  test('leere Makros bleiben unbekannt statt erfunden', () {
    final r = MealAnalysisResult.manualEntry(
      name: 'Sülze',
      kcalPer100G: 120,
      grams: 100,
    );
    expect(r.protein, '-');
    expect(r.carbs, '-');
    expect(r.fat, '-');
  });

  test('ausdrückliche 0 kcal ist eine Messung (Wasser), kein Sentinel', () {
    final r = MealAnalysisResult.manualEntry(
      name: 'Wasser',
      kcalPer100G: 0,
      grams: 500,
    );
    expect(r.caloriesKcal, 0);
    expect(r.explicitZeroKcal, isTrue);
  });

  test('Defensiv-Klemmen für Werte außerhalb der Formulargrenzen', () {
    // Das Formular lehnt solche Eingaben ab; die Factory klemmt trotzdem,
    // falls je ein anderer Aufrufer entsteht.
    final r = MealAnalysisResult.manualEntry(
      name: '',
      kcalPer100G: 5000,
      grams: 0,
    );
    expect(r.kcalPer100G, 900);
    expect(r.estimatedGrams, 1);
    expect(r.mealName, isNotEmpty);
  });

  test('die neuen Codes lösen über resolve auf (Code UND legacyDe)', () {
    expect(MealResultSource.resolve('manual'), MealResultSource.manual);
    expect(MealResultSource.resolve('Manuell'), MealResultSource.manual);
    expect(MealResultConfidence.resolve('manual'), MealResultConfidence.manual);
    expect(
      MealResultPortionNote.resolve('manualEntryNote'),
      MealResultPortionNote.manual,
    );
  });
}
