import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';

// Reine Logik-Unit-Tests für bislang ungetestete, korrektheitskritische Pfade:
// die Foto-/Barcode-Parser (fromEdgeFunction/fromOpenFoodFacts), die Portions-
// Mathematik (adjustedToGrams/adjustedToItems), Makro-Komponenten, die Rezept-
// Match-Heuristik, Gewichts-Log-Ringpuffer und den Produkt-Such-Mapper.
// Deterministisch, netz-/UI-frei. Ergänzt logic_test.dart (das Slot-Heuristik,
// Streak, Makro-Aggregation, JSON-Roundtrip + Auto-Split bereits abdeckt —
// hier NICHT dupliziert).

FitnessRecipe _recipe({
  int caloriesKcal = 500,
  int proteinG = 40,
  int carbsG = 40,
  int fatG = 15,
  int estimatedGrams = 400,
}) {
  return FitnessRecipe(
    slug: 'test',
    title: 'Testrezept',
    description: 'desc',
    portion: '1 Teller',
    ingredients: 'x',
    preparation: 'y',
    professionalHint: 'z',
    imageAsset: '',
    caloriesKcal: caloriesKcal,
    proteinG: proteinG,
    carbsG: carbsG,
    fatG: fatG,
    estimatedGrams: estimatedGrams,
    categories: const <String>[],
  );
}

void main() {
  group('MealAnalysisResult.adjustedToGrams (Portions-Mathematik)', () {
    const base = MealAnalysisResult(
      mealName: 'Reis',
      caloriesKcal: 200,
      estimatedGrams: 200,
      kcalPer100G: 100,
      protein: '10 g',
      carbs: '40 g',
      fat: '2 g',
      confidence: 'Hoch',
      portionNotes: '',
    );

    test('verdoppeltes Gewicht verdoppelt kcal + skaliert Makros', () {
      final r = base.adjustedToGrams(400);
      expect(r.caloriesKcal, 400); // kcalPer100G(100) * 400 / 100
      expect(r.estimatedGrams, 400);
      expect(r.isAdjusted, isTrue);
      expect(r.protein, '20 g'); // 10 * 2.0
    });

    test('estimatedGrams==0 -> factor 1.0, kein Division-durch-0-Crash', () {
      const zero = MealAnalysisResult(
        mealName: 'X',
        caloriesKcal: 0,
        estimatedGrams: 0,
        kcalPer100G: 100,
        protein: '-',
        carbs: '-',
        fat: '-',
        confidence: 'Hoch',
        portionNotes: '',
      );
      final r = zero.adjustedToGrams(150);
      expect(r.caloriesKcal, 150); // 100 * 150 / 100
      expect(r.estimatedGrams, 150);
    });

    test('Einzelposten werden proportional mitskaliert', () {
      const withItem = MealAnalysisResult(
        mealName: 'Reisgericht',
        caloriesKcal: 130,
        estimatedGrams: 100,
        kcalPer100G: 130,
        protein: '-',
        carbs: '-',
        fat: '-',
        confidence: 'Hoch',
        portionNotes: '',
        items: [
          MealComponent(
              name: 'Reis', grams: 100, caloriesKcal: 130, kcalPer100G: 130),
        ],
      );
      final r = withItem.adjustedToGrams(200);
      expect(r.items.single.grams, 200);
      expect(r.items.single.caloriesKcal, 260); // 130/100g * 200g
    });
  });

  group('MealAnalysisResult.adjustedToItems (Summe der Positionen)', () {
    const base = MealAnalysisResult(
      mealName: 'Teller',
      caloriesKcal: 0,
      estimatedGrams: 300,
      kcalPer100G: 50,
      protein: '20 g',
      carbs: '-',
      fat: '-',
      confidence: 'Hoch',
      portionNotes: '',
    );

    test('Summe der Items treibt kcal/Gramm + neuberechnetes kcalPer100G', () {
      final r = base.adjustedToItems(const [
        MealComponent(name: 'A', grams: 100, caloriesKcal: 150),
        MealComponent(name: 'B', grams: 100, caloriesKcal: 50),
      ]);
      expect(r.caloriesKcal, 200);
      expect(r.estimatedGrams, 200);
      expect(r.kcalPer100G, closeTo(100, 0.001)); // 200 kcal * 100 / 200 g
      expect(r.isAdjusted, isTrue);
    });

    test('leere Item-Liste behält altes kcalPer100G ohne Crash', () {
      final r = base.adjustedToItems(const []);
      expect(r.caloriesKcal, 0);
      expect(r.estimatedGrams, 0);
      expect(r.kcalPer100G, 50); // Fallback auf bisheriges per100
    });
  });

  group('MealAnalysisResult.fromEdgeFunction (Foto-KI-Parser)', () {
    test('Einzel-Food: kcal+Gramm -> kcalPer100G berechnet', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Müsliriegel',
        'kcal': 200,
        'estimatedGrams': 50,
        'confidence': 'high',
        'proteinG': 8,
      });
      expect(r.mealName, 'Müsliriegel');
      expect(r.caloriesKcal, 200);
      expect(r.estimatedGrams, 50);
      expect(r.kcalPer100G, closeTo(400, 0.001)); // 200 * 100 / 50
      expect(r.confidence, 'Hoch'); // high -> Hoch
      expect(r.protein, '8 g');
      expect(r.sourceLabel, 'Foto-KI');
    });

    test('bekanntes Obst nutzt Referenz-kcal-Dichte', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Apfel',
        'kcal': 95,
      });
      expect(r.kcalPer100G, 52); // _knownKcalPer100G('apfel')
      expect(r.estimatedGrams, 150); // Default ohne Grammangabe
    });

    test('fehlende Makros werden zu "-"', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Etwas',
        'kcal': 100,
      });
      expect(r.protein, '-');
      expect(r.carbs, '-');
      expect(r.fat, '-');
      // Sentinel-Rest C: fehlende confidence ist keine Aussage des Modells —
      // frueher wurde hier 'Mittel' erfunden.
      expect(r.confidence, 'Unbekannt');
    });

    test('Mehr-Komponenten-Name wird lokal aufgesplittet (>=2 Items)', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Hähnchen mit Reis und Brokkoli',
        'kcal': 700,
        'estimatedGrams': 600,
      });
      expect(r.items.length, greaterThanOrEqualTo(2));
    });
  });

  group('MealAnalysisResult.fromOpenFoodFacts (Barcode-Parser)', () {
    test('Portionswerte + Marken-Name + deutsche Dezimal-Makros', () {
      final r = MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
        'product_name': 'Magerquark',
        'brands': 'Milbona',
        'serving_quantity': 250,
        'nutriments': <String, dynamic>{
          'energy-kcal_100g': 67,
          'proteins_100g': 12,
          'carbohydrates_100g': 4,
          'fat_100g': 0.2,
        },
      }, '40111');
      expect(r.mealName, 'Magerquark · Milbona');
      expect(r.kcalPer100G, 67);
      expect(r.estimatedGrams, 250);
      expect(r.caloriesKcal, 168); // (67 * 250 / 100).round() = 167.5 -> 168
      expect(r.protein, '30 g'); // 12/100g * 250g
      expect(r.fat, '0,5 g'); // 0.2/100g * 250g -> 0,5 (Komma)
      expect(r.confidence, 'Datenbank');
      expect(r.barcode, '40111');
    });

    test('fehlende Nährwerte -> kcal 0, Makros "-", 100 g Default', () {
      final r = MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
        'product_name': 'Wasser',
      }, 'x');
      expect(r.mealName, 'Wasser'); // ohne Marke kein " · "
      expect(r.caloriesKcal, 0);
      expect(r.estimatedGrams, 100);
      expect(r.protein, '-');
      expect(r.carbs, '-');
      expect(r.fat, '-');
    });

    test('Portionsgröße fällt auf serving_size-Text zurück', () {
      final r = MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
        'product_name': 'Keks',
        'serving_size': 'ca. 30 g',
        'nutriments': <String, dynamic>{'energy-kcal_100g': 450},
      }, 'y');
      expect(r.estimatedGrams, 30);
      expect(r.caloriesKcal, 135); // 450 * 30 / 100
    });
  });

  group('MealComponent.fromJson / adjustedToGrams', () {
    test('Dichte-only JSON berechnet Kalorien aus kcalPer100G * Gramm', () {
      final c = MealComponent.fromJson(const <String, dynamic>{
        'name': 'Reis',
        'kcalPer100G': 130,
        'grams': 100,
      });
      expect(c.name, 'Reis');
      expect(c.grams, 100);
      expect(c.caloriesKcal, 130);
      expect(c.kcalPer100G, 130);
    });

    test('fehlender Name -> "Zutat"', () {
      final c = MealComponent.fromJson(const <String, dynamic>{
        'grams': 50,
        'kcal': 75,
      });
      expect(c.name, 'Zutat');
      expect(c.caloriesKcal, 75);
    });

    test('adjustedToGrams erhält die kcal-Dichte', () {
      const c = MealComponent(
          name: 'X', grams: 100, caloriesKcal: 130, kcalPer100G: 130);
      final a = c.adjustedToGrams(200);
      expect(a.grams, 200);
      expect(a.caloriesKcal, 260);
      expect(a.kcalPer100G, 130);
    });

    test('adjustedToGrams leitet Dichte aus kcal/Gramm ab wenn keine vorhanden',
        () {
      const c = MealComponent(name: 'Y', grams: 100, caloriesKcal: 200);
      final a = c.adjustedToGrams(50);
      expect(a.caloriesKcal, 100); // 200/100g * 50g
      expect(a.kcalPer100G, 200);
    });
  });

  group('FitnessRecipe.matchScore (Sortier-Heuristik)', () {
    test('alle Restmakros 0 -> Score 0', () {
      const remaining =
          MacroProgress(proteinG: 0, carbsG: 0, fatG: 0, kcal: 0);
      expect(_recipe().matchScore(remaining), 0);
    });

    test('Score immer in [0,1]', () {
      const remaining =
          MacroProgress(proteinG: 40, carbsG: 40, fatG: 15, kcal: 500);
      final score = _recipe().matchScore(remaining);
      expect(score, greaterThanOrEqualTo(0));
      expect(score, lessThanOrEqualTo(1));
    });

    test('passendes Rezept rankt höher als stark überschießendes', () {
      const remaining =
          MacroProgress(proteinG: 40, carbsG: 40, fatG: 15, kcal: 500);
      final fit = _recipe(
          caloriesKcal: 500, proteinG: 40, carbsG: 40, fatG: 15);
      final over = _recipe(
          caloriesKcal: 3000, proteinG: 200, carbsG: 300, fatG: 120);
      expect(fit.matchScore(remaining),
          greaterThan(over.matchScore(remaining)));
    });

    test('kcalPer100G mit 0 Gramm crasht nicht', () {
      expect(_recipe(estimatedGrams: 0).kcalPer100G, 0);
    });
  });

  group('WeightLog (Ringpuffer + Trend)', () {
    test('add ignoriert 0 / negativ', () {
      const log = WeightLog();
      expect(log.add(0).entries, isEmpty);
      expect(log.add(-5).entries, isEmpty);
    });

    test('trendDelta null bei <2 Einträgen, sonst last-first', () {
      const log = WeightLog();
      expect(log.add(80).trendDelta, isNull);
      expect(log.add(70).add(75).trendDelta, closeTo(5, 0.001));
    });

    test('begrenzt auf 30 Einträge, ältester fällt raus', () {
      var log = const WeightLog();
      for (var i = 1; i <= 31; i++) {
        log = log.add(i.toDouble());
      }
      expect(log.entries.length, 30);
      expect(log.entries.first.weightKg, 2); // 1.0 verdrängt
      expect(log.latest!.weightKg, 31);
    });
  });

  group('ProductSearchResult.fromOpenFoodFacts (Such-Mapper)', () {
    test('Subtitle = Marke · Menge · kcal/100g, Code getrimmt', () {
      final p = ProductSearchResult.fromOpenFoodFacts(<String, dynamic>{
        'code': '  123 ',
        'product_name': 'Skyr',
        'brands': 'Arla',
        'quantity': '450 g',
        'nutriments': <String, dynamic>{'energy-kcal_100g': 63},
        'image_front_small_url': 'http://img/x.jpg',
      });
      expect(p.code, '123');
      expect(p.title, 'Skyr · Arla');
      expect(p.subtitle, 'Arla · 450 g · 63 kcal / 100 g');
      expect(p.imageUrl, 'http://img/x.jpg');
    });

    test('ohne Marke/Menge bleibt nur die kcal-Angabe', () {
      final p = ProductSearchResult.fromOpenFoodFacts(<String, dynamic>{
        'code': '9',
        'product_name': 'Wasser',
        'nutriments': <String, dynamic>{'energy-kcal_100g': 0},
      });
      expect(p.subtitle, '0 kcal / 100 g');
      expect(p.imageUrl, isNull);
      expect(p.title, 'Wasser');
    });

    test('Bild-URL-Präzedenz: front_small vor image_url', () {
      final p = ProductSearchResult.fromOpenFoodFacts(<String, dynamic>{
        'code': '1',
        'product_name': 'P',
        'image_front_small_url': 'http://small',
        'image_url': 'http://full',
      });
      expect(p.imageUrl, 'http://small');
    });
  });
}
