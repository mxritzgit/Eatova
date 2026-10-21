import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';

// Manual entry: label values per 100 g plus the eaten portion. The factory
// derives the portion values and carries the manual provenance codes.
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
    // The form rejects such input; the factory still clamps in case another
    // caller appears.
    final r = MealAnalysisResult.manualEntry(
      name: '',
      kcalPer100G: 5000,
      grams: 0,
    );
    expect(r.kcalPer100G, 900);
    expect(r.estimatedGrams, 1);
    expect(r.mealName, isNotEmpty);
  });

  test('die manual-Codes (und das alte "Manuell") loesen auf die manuellen '
      'Anzeigetexte auf', () {
    expect(MealResultSource.resolve('Manuell'), MealResultSource.manual);
    final r = MealAnalysisResult.manualEntry(
      name: 'Bauern-Mozzarella',
      kcalPer100G: 265,
      grams: 125,
    );
    for (final l10n in [deL10n, enL10n]) {
      expect(r.resolvedSourceLabel(l10n), l10n.foodSourceManual);
      expect(r.resolvedConfidence(l10n), l10n.foodConfidenceManual);
      expect(r.resolvedPortionNotes(l10n), l10n.foodManualEntryNote);
    }
  });
}
