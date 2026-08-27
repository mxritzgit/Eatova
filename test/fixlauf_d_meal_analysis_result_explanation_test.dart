import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';

// Fix run 2026-08-27, F4-06: the server normalizes a missing explanation to
// '' (normalize.ts) and the meal name to 'Mahlzeit'. The client chose the
// i18n marker only for null, so the info sheet showed a blank line.

Map<String, dynamic> _answer({
  Object? explanation = '',
  List<Map<String, Object?>> items = const [],
}) =>
    <String, dynamic>{
      'mealName': 'Mahlzeit',
      'caloriesKcal': 500,
      'estimatedGrams': 300,
      'kcalPer100G': 166.7,
      'proteinG': 20,
      'carbsG': 50,
      'fatG': 20,
      'confidence': 'medium',
      'explanation': explanation,
      'items': items,
    };

void main() {
  test('explanation "" -> Marker wie bei null (plain)', () {
    final r = MealAnalysisResult.fromEdgeFunction(_answer());
    expect(r.portionNotes, MealResultPortionNote.plain.code);
    expect(r.mealName, 'Mahlzeit');
  });

  test('explanation nur Whitespace -> Marker', () {
    final r = MealAnalysisResult.fromEdgeFunction(_answer(explanation: '  '));
    expect(r.portionNotes, MealResultPortionNote.plain.code);
  });

  test('explanation null -> Marker (unveraendert)', () {
    final r = MealAnalysisResult.fromEdgeFunction(_answer(explanation: null));
    expect(r.portionNotes, MealResultPortionNote.plain.code);
  });

  test('explanation "" mit Einzelposten -> itemized-Marker', () {
    final r = MealAnalysisResult.fromEdgeFunction(_answer(
      items: const [
        {'name': 'Reis', 'grams': 200, 'caloriesKcal': 260},
        {'name': 'Huhn', 'grams': 100, 'caloriesKcal': 240},
      ],
    ));
    expect(r.portionNotes, MealResultPortionNote.itemized.code);
  });

  test('echte explanation bleibt Text', () {
    final r = MealAnalysisResult.fromEdgeFunction(
      _answer(explanation: 'Ein großer Teller mit Reis.'),
    );
    expect(r.portionNotes, 'Ein großer Teller mit Reis.');
  });
}
