import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';

// sourceLabel/portionLabel are language-neutral since 2026-08-11; the full
// compatibility matrix lives in the MealResultSource class doc. Covered here:
// enum resolution (legacy line -> enum -> display, unknown -> pass-through)
// and the portion, which was never persisted.
void main() {
  group('MealResultSource.resolve — Kompatibilitaetsmatrix', () {
    test('deutscher Bestandswert (Alt-Zeile) wird erkannt', () {
      expect(MealResultSource.resolve('KI-Schätzung'), MealResultSource.aiEstimate);
      expect(MealResultSource.resolve('Foto-KI'), MealResultSource.photoAi);
      expect(MealResultSource.resolve('OpenFoodFacts'), MealResultSource.openFoodFacts);
      expect(MealResultSource.resolve('Eatova Rezept'), MealResultSource.recipe);
    });

    test('neutraler Code (ab diesem PR geschrieben) wird erkannt', () {
      expect(MealResultSource.resolve('aiEstimate'), MealResultSource.aiEstimate);
      expect(MealResultSource.resolve('photoAi'), MealResultSource.photoAi);
      expect(MealResultSource.resolve('recipe'), MealResultSource.recipe);
    });

    test('englischer Anzeigetext wird als Verteidigungslinie erkannt', () {
      expect(MealResultSource.resolve('AI estimate'), MealResultSource.aiEstimate);
      expect(MealResultSource.resolve('Photo AI'), MealResultSource.photoAi);
      expect(MealResultSource.resolve('Eatova recipe'), MealResultSource.recipe);
    });

    test('unbekannter String bleibt unaufgeloest (Pass-through-Fall)', () {
      expect(MealResultSource.resolve('Ein komplett unbekannter Wert'), isNull);
      expect(MealResultSource.resolve(''), isNull);
    });
  });

  group('MealAnalysisResult.resolvedSourceLabel', () {
    MealAnalysisResult result({required String sourceLabel}) =>
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

    test('alte deutsche Zeile -> Enum -> Anzeige de/en', () {
      final r = result(sourceLabel: 'Foto-KI');
      expect(r.resolvedSourceLabel(deL10n), 'Foto-KI');
      expect(r.resolvedSourceLabel(enL10n), 'Photo AI');
    });

    test('neuer neutraler Code -> Anzeige de/en', () {
      final r = result(sourceLabel: 'aiEstimate');
      expect(r.resolvedSourceLabel(deL10n), 'KI-Schätzung');
      expect(r.resolvedSourceLabel(enL10n), 'AI estimate');
    });

    test('OpenFoodFacts bleibt in beiden Sprachen der Markenname', () {
      final r = result(sourceLabel: 'OpenFoodFacts');
      expect(r.resolvedSourceLabel(deL10n), 'OpenFoodFacts');
      expect(r.resolvedSourceLabel(enL10n), 'OpenFoodFacts');
    });

    test('unbekannter Rohwert wird UNVERAENDERT angezeigt (Pass-through)', () {
      final r = result(sourceLabel: 'Ein ganz fremder Wert');
      expect(r.resolvedSourceLabel(deL10n), 'Ein ganz fremder Wert');
      expect(r.resolvedSourceLabel(enL10n), 'Ein ganz fremder Wert');
    });
  });

  group('MealAnalysisResult.resolvedPortionLabel', () {
    test('nie persistiert — reine Zahl, sprachaufgeloest bei jedem Aufruf', () {
      const r = MealAnalysisResult(
        mealName: 'Testmahlzeit',
        caloriesKcal: 400,
        estimatedGrams: 250,
        kcalPer100G: 160,
        protein: '20 g',
        carbs: '40 g',
        fat: '10 g',
        confidence: 'Hoch',
        portionNotes: '',
      );
      expect(r.resolvedPortionLabel(deL10n), '250 g geschätzt');
      expect(r.resolvedPortionLabel(enL10n), '250 g estimated');
    });
  });
}
