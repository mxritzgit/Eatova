import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';

// TEST-1: MacroProgress.add/subtract — daily macro aggregation from the meals'
// macro strings. logic_test.dart covers the happy path; here the parser edge
// cases and the clamp/accumulation invariants (subtract clamps, kcal stays a
// non-negative int).

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
  group('add: Makro-String-Parsing', () {
    test('einfache "30 g"-Werte werden summiert', () {
      final p = MacroProgress.empty
          .add(_r(kcal: 500, protein: '30 g', carbs: '50 g', fat: '20 g'));
      expect(p.proteinG, 30);
      expect(p.carbsG, 50);
      expect(p.fatG, 20);
      expect(p.kcal, 500);
    });

    test('Komma-Dezimalzahlen ("12,5 g") parsen korrekt', () {
      final p = MacroProgress.empty.add(_r(protein: '12,5 g'));
      expect(p.proteinG, closeTo(12.5, 1e-9));
    });

    test('Punkt-Dezimalzahlen ("0.2 g") parsen korrekt', () {
      final p = MacroProgress.empty.add(_r(fat: '0.2 g'));
      expect(p.fatG, closeTo(0.2, 1e-9));
    });

    test('"-" und nicht-numerische Strings zaehlen als 0', () {
      final p = MacroProgress.empty
          .add(_r(kcal: 90, protein: '-', carbs: 'k. A.', fat: ''));
      expect(p.proteinG, 0);
      expect(p.carbsG, 0);
      expect(p.fatG, 0);
      expect(p.kcal, 90); // kcal comes straight from the int field
    });

    test('nimmt die erste Zahl im String (z.B. "32 g Eiweiss")', () {
      final p = MacroProgress.empty.add(_r(protein: '32 g Eiweiss'));
      expect(p.proteinG, 32);
    });

    test('mehrere add() akkumulieren', () {
      final p = MacroProgress.empty
          .add(_r(kcal: 200, protein: '10 g'))
          .add(_r(kcal: 300, protein: '15 g'));
      expect(p.proteinG, 25);
      expect(p.kcal, 500);
    });
  });

  group('subtract: Clamp + Symmetrie', () {
    test('add gefolgt von subtract derselben Mahlzeit -> wieder leer', () {
      final r = _r(kcal: 400, protein: '25 g', carbs: '40 g', fat: '15 g');
      final p = MacroProgress.empty.add(r).subtract(r);
      expect(p.proteinG, 0);
      expect(p.carbsG, 0);
      expect(p.fatG, 0);
      expect(p.kcal, 0);
    });

    test('subtract unter 0 wird auf 0 geclampt (Makros)', () {
      final p = MacroProgress.empty
          .subtract(_r(protein: '30 g', carbs: '40 g', fat: '10 g'));
      expect(p.proteinG, 0);
      expect(p.carbsG, 0);
      expect(p.fatG, 0);
    });

    test('subtract unter 0 wird auf 0 geclampt (kcal, bleibt int)', () {
      final p = MacroProgress.empty.subtract(_r(kcal: 500));
      expect(p.kcal, 0);
      expect(p.kcal, isA<int>());
    });

    test('Teil-Abzug laesst den Rest stehen', () {
      final p = MacroProgress.empty
          .add(_r(kcal: 600, protein: '40 g'))
          .subtract(_r(kcal: 200, protein: '15 g'));
      expect(p.proteinG, 25);
      expect(p.kcal, 400);
    });
  });

  test('empty ist neutral (alles 0)', () {
    expect(MacroProgress.empty.proteinG, 0);
    expect(MacroProgress.empty.carbsG, 0);
    expect(MacroProgress.empty.fatG, 0);
    expect(MacroProgress.empty.kcal, 0);
  });

  test('add nutzt das kcal-Feld des Ergebnisses, nicht die Makro-Strings', () {
    // The kcal integer counts even without plausible macros.
    const withItems = MealAnalysisResult(
      mealName: 'Teller',
      caloriesKcal: 720,
      estimatedGrams: 300,
      kcalPer100G: 240,
      protein: '-',
      carbs: '-',
      fat: '-',
      confidence: 'Mittel',
      portionNotes: '',
      items: [
        MealComponent(name: 'A', grams: 150, caloriesKcal: 360),
        MealComponent(name: 'B', grams: 150, caloriesKcal: 360),
      ],
    );
    final p = MacroProgress.empty.add(withItems);
    expect(p.kcal, 720);
    expect(p.proteinG, 0); // "-" -> 0
  });
}
