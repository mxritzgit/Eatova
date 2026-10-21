import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';

// MacroProgress.add — daily macro aggregation from the meals' macro strings:
// the parser edge cases and the accumulation invariants.

MealAnalysisResult _r({
  int kcal = 0,
  String protein = '0 g',
  String carbs = '0 g',
  String fat = '0 g',
}) =>
    MealAnalysisResult(
      mealName: 'x',
      caloriesKcal: kcal,
      estimatedGrams: 100,
      kcalPer100G: 100,
      protein: protein,
      carbs: carbs,
      fat: fat,
      confidence: 'Hoch',
      portionNotes: '',
    );

void main() {
  test('Makro-Strings: ganze Zahl, Komma, Punkt, erste Zahl im Text', () {
    final p = MacroProgress.empty.add(
      _r(kcal: 500, protein: '32 g Eiweiss', carbs: '12,5 g', fat: '0.2 g'),
    );
    expect(p.proteinG, 32);
    expect(p.carbsG, closeTo(12.5, 1e-9));
    expect(p.fatG, closeTo(0.2, 1e-9));
    expect(p.kcal, 500);
  });

  test('"-", Text und leer zaehlen 0; kcal kommt aus dem int-Feld', () {
    final p = MacroProgress.empty
        .add(_r(kcal: 90, protein: '-', carbs: 'k. A.', fat: ''));
    expect(p.proteinG, 0);
    expect(p.carbsG, 0);
    expect(p.fatG, 0);
    expect(p.kcal, 90);
  });

  test('mehrere add() akkumulieren ab dem neutralen empty', () {
    expect(MacroProgress.empty.kcal, 0);
    expect(MacroProgress.empty.proteinG, 0);
    final p = MacroProgress.empty
        .add(_r(kcal: 200, protein: '10 g', fat: '1 g'))
        .add(_r(kcal: 300, protein: '15 g', fat: '2,5 g'));
    expect(p.proteinG, 25);
    expect(p.fatG, closeTo(3.5, 1e-9));
    expect(p.kcal, 500);
  });
}
