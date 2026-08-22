import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meals_sync.dart';

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

  test('die neuen Codes lösen über resolve auf (Code UND legacyDe)', () {
    expect(MealResultSource.resolve('manual'), MealResultSource.manual);
    expect(MealResultSource.resolve('Manuell'), MealResultSource.manual);
    expect(MealResultConfidence.resolve('manual'), MealResultConfidence.manual);
    expect(
      MealResultPortionNote.resolve('manualEntryNote'),
      MealResultPortionNote.manual,
    );
  });

  test(
    'die manual-Codes lösen in de UND en auf die richtigen Anzeigetexte auf',
    () {
      final r = MealAnalysisResult.manualEntry(
        name: 'Bauern-Mozzarella',
        kcalPer100G: 265,
        grams: 125,
      );
      expect(r.resolvedSourceLabel(deL10n), 'Manuell');
      expect(r.resolvedSourceLabel(enL10n), 'Manual');
      expect(r.resolvedConfidence(deL10n), 'Eigene Angabe');
      expect(r.resolvedConfidence(enL10n), 'Own entry');
      expect(
        r.resolvedPortionNotes(deL10n),
        'Nährwerte manuell nach Etikett eingetragen (pro 100 g).',
      );
      expect(
        r.resolvedPortionNotes(enL10n),
        'Nutrition entered manually from the label (per 100 g).',
      );
    },
  );

  test(
    'mealResultToJson/mealResultFromJson-Roundtrip erhaelt die manual-Felder',
    () {
      final r = MealAnalysisResult.manualEntry(
        name: 'Wasser',
        kcalPer100G: 0,
        grams: 500,
      );
      final json = mealResultToJson(r);
      final back = mealResultFromJson(json);
      expect(back.sourceLabel, r.sourceLabel);
      expect(back.confidence, r.confidence);
      expect(back.portionNotes, r.portionNotes);
      expect(back.explicitZeroKcal, r.explicitZeroKcal);
      expect(back.explicitZeroKcal, isTrue);
    },
  );
}
