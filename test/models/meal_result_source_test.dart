import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';

// sourceLabel/portionLabel are language-neutral since 2026-08-11; the full
// compatibility matrix lives in the MealResultSource class doc. Covered here:
// enum resolution (legacy line -> enum -> display, unknown -> pass-through)
// and the portion, which was never persisted.

MealAnalysisResult _result({String sourceLabel = 'aiEstimate'}) =>
    MealAnalysisResult(
      mealName: 'Testmahlzeit',
      caloriesKcal: 400,
      estimatedGrams: 250,
      kcalPer100G: 160,
      protein: '20 g',
      carbs: '40 g',
      fat: '10 g',
      confidence: 'Hoch',
      portionNotes: '',
      sourceLabel: sourceLabel,
    );

void main() {
  test('MealResultSource.resolve: neutraler Code, deutsche Alt-Zeile, '
      'englischer Anzeigetext; Unbekanntes bleibt unaufgeloest', () {
    for (final (roh, quelle) in <(String, MealResultSource)>[
      ('aiEstimate', MealResultSource.aiEstimate),
      ('photoAi', MealResultSource.photoAi),
      ('recipe', MealResultSource.recipe),
      ('KI-Schätzung', MealResultSource.aiEstimate),
      ('Foto-KI', MealResultSource.photoAi),
      ('OpenFoodFacts', MealResultSource.openFoodFacts),
      ('Eatova Rezept', MealResultSource.recipe),
      ('AI estimate', MealResultSource.aiEstimate),
      ('Photo AI', MealResultSource.photoAi),
      ('Eatova recipe', MealResultSource.recipe),
    ]) {
      expect(MealResultSource.resolve(roh), quelle, reason: roh);
    }
    expect(MealResultSource.resolve('Ein komplett unbekannter Wert'), isNull);
    expect(MealResultSource.resolve(''), isNull);
  });

  test('resolvedSourceLabel zeigt die Quelle in der Anzeigesprache; '
      'unbekannte Rohwerte bleiben unveraendert', () {
    // Legacy German line and neutral code both resolve per language.
    expect(_result(sourceLabel: 'Foto-KI').resolvedSourceLabel(enL10n),
        'Photo AI');
    expect(_result().resolvedSourceLabel(deL10n), 'KI-Schätzung');
    expect(_result().resolvedSourceLabel(enL10n), 'AI estimate');
    // The brand name is not translated.
    expect(_result(sourceLabel: 'OpenFoodFacts').resolvedSourceLabel(enL10n),
        'OpenFoodFacts');
    const fremd = 'Ein ganz fremder Wert';
    for (final l10n in [deL10n, enL10n]) {
      expect(_result(sourceLabel: fremd).resolvedSourceLabel(l10n), fremd);
    }
  });

  test('resolvedPortionLabel: nie persistiert, bei jedem Aufruf sprachaufgeloest',
      () {
    expect(_result().resolvedPortionLabel(deL10n), '250 g geschätzt');
    expect(_result().resolvedPortionLabel(enL10n), '250 g estimated');
  });
}
