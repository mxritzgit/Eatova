import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/described_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meal_description_matcher.dart';
import 'package:eatova/src/services/meals_sync.dart';

const DescribedFoodItem _toast = DescribedFoodItem(
  name: 'Toastbrot',
  searchQuery: 'Toastbrot',
  brand: 'Lidl',
  amountText: '2 Scheiben',
  grams: 50,
  gramsSource: DescribedGramsSource.stated,
  caloriesKcal: 130,
  kcalPer100G: 260,
  proteinG: 4,
  carbsG: 24.6,
  fatG: 2,
);

const DescribedFoodItem _nutella = DescribedFoodItem(
  name: 'Nutella',
  searchQuery: 'Nutella',
  grams: 15,
  gramsSource: DescribedGramsSource.estimated,
  caloriesKcal: 81,
  kcalPer100G: 539,
  proteinG: 0.9,
  carbsG: 8.6,
  fatG: 4.6,
);

const DraftCandidate _harry = DraftCandidate(
  origin: DraftItemOrigin.product,
  title: 'Toastbrot · Harry',
  brand: 'Harry',
  kcalPer100G: 255,
  proteinPer100G: 8,
  carbsPer100G: 48,
  fatPer100G: 3.5,
  servingGrams: 28,
  barcode: '4009249001119',
);

const DraftCandidate _nutellaProduct = DraftCandidate(
  origin: DraftItemOrigin.product,
  title: 'Nutella',
  brand: 'Ferrero',
  kcalPer100G: 539,
  proteinPer100G: 6.3,
  carbsPer100G: 57.5,
  fatPer100G: 30.9,
  barcode: '3017620422003',
);

DescribedMeal _meal(List<DescribedFoodItem> items) => DescribedMeal(
  base: MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
    'mealName': 'Nutella-Toast',
    'caloriesKcal': 211,
    'proteinG': 5,
    'carbsG': 33,
    'fatG': 7,
    'confidence': 'medium',
    'explanation': 'Zwei Scheiben Toast mit etwas Nutella.',
    'items': <Object?>[
      for (final item in items)
        <String, Object?>{
          'name': item.name,
          'grams': item.grams,
          'caloriesKcal': item.caloriesKcal,
          'proteinG': item.proteinG,
          'carbsG': item.carbsG,
          'fatG': item.fatG,
        },
    ],
  }),
  items: items,
  slotHint: MealSlot.breakfast,
);

DraftFoodItem _line(DescribedFoodItem item, [DraftCandidate? selected]) {
  final estimate = estimateCandidateFor(item);
  final chosen = selected ?? estimate;
  return DraftFoodItem(
    described: item,
    selected: chosen,
    candidates: [if (selected != null) selected, estimate],
    grams: portionGramsFor(item, chosen) ?? item.grams,
  );
}

void main() {
  group('countableAmount', () {
    test('Stueckzahlen ja, Gewichte und Volumen nein', () {
      final cases = <String?, double?>{
        '1 Scheibe': 1,
        '2 Scheiben': 2,
        'eine Scheibe': 1,
        'zwei Stück': 2,
        'drei Eier': 3,
        '½ Portion': .5,
        'halbe Banane': .5,
        '1,5 Portionen': 1.5,
        'two slices': 2,
        'an apple': 1,
        'Ein Glas.': 1,
        '1 Scheibe (28 g)': 1,
        '200 g': null,
        '300 ml': null,
        'ein bisschen': null,
        'Scheibe': null,
        '2 Scheibenkäse': null,
        '': null,
        null: null,
      };
      cases.forEach((text, count) {
        expect(countableAmount(text), count, reason: '"$text"');
      });
    });
  });

  group('portionGramsFor', () {
    test('Stueckzahl mal Portion; sonst null', () {
      expect(portionGramsFor(_toast, _harry), 56);
      expect(
        portionGramsFor(_toast, estimateCandidateFor(_toast)),
        50,
        reason: 'die Schaetzung hat die Menge selbst gelesen',
      );
      expect(portionGramsFor(_toast, _nutellaProduct), isNull);
      expect(portionGramsFor(_nutella, _harry), isNull, reason: 'geschaetzt');
    });
  });

  group('estimateCandidateFor', () {
    test('Kalorien sind massgeblich, Makros pro 100 g aus den Gramm', () {
      final estimate = estimateCandidateFor(_nutella);
      expect(estimate.origin, DraftItemOrigin.estimate);
      expect(estimate.title, 'Nutella');
      expect(estimate.brand, isNull);
      expect(estimate.kcalPer100G, closeTo(540, 1e-9));
      expect(estimate.proteinPer100G, closeTo(6, 1e-9));
      expect(estimate.fatPer100G, closeTo(30.667, 1e-3));
      expect(_line(_nutella).caloriesKcal, 81);
    });

    test(
      'ohne Kalorien die Dichte; unmoegliche Werte geklemmt oder unbekannt',
      () {
        const onlyDensity = DescribedFoodItem(
          name: 'Apfel',
          searchQuery: 'Apfel',
          grams: 150,
          gramsSource: DescribedGramsSource.estimated,
          kcalPer100G: 52,
          proteinG: 200,
        );
        expect(estimateCandidateFor(onlyDensity).kcalPer100G, 52);
        expect(
          estimateCandidateFor(onlyDensity).proteinPer100G,
          isNull,
          reason: 'mehr als 100 g pro 100 g',
        );

        const tooDense = DescribedFoodItem(
          name: 'Butter',
          searchQuery: 'Butter',
          grams: 10,
          gramsSource: DescribedGramsSource.estimated,
          caloriesKcal: 200,
          kcalPer100G: 741,
        );
        expect(estimateCandidateFor(tooDense).kcalPer100G, 741);

        const water = DescribedFoodItem(
          name: 'Wasser',
          searchQuery: 'Wasser',
          grams: 250,
          gramsSource: DescribedGramsSource.estimated,
          caloriesKcal: 0,
          kcalPer100G: 0,
        );
        expect(estimateCandidateFor(water).kcalPer100G, 0);
      },
    );
  });

  group('DraftFoodItem', () {
    test('withGrams klemmt auf 1..10000 g und rechnet neu', () {
      final line = _line(_nutella, _nutellaProduct);
      expect(line.withGrams(30).grams, 30);
      expect(line.withGrams(30).caloriesKcal, 162);
      expect(line.withGrams(0).grams, 1);
      expect(line.withGrams(50000).grams, 10000);
      expect(line.withGrams(30).candidates, same(line.candidates));
    });

    test('withCandidate folgt einer genannten Stueckzahl', () {
      final line = _line(_toast);
      expect(line.grams, 50);
      final harry = line.withCandidate(_harry);
      expect(harry.selected, same(_harry));
      expect(harry.grams, 56);
      expect(harry.withGrams(80).withCandidate(_nutellaProduct).grams, 80);
      expect(harry.withCandidate(line.candidates.last).grams, 50);
    });

    test('toComponent: Marke im Namen, ausser sie steht schon drin', () {
      final nutella = _line(_nutella, _nutellaProduct).toComponent();
      expect(nutella.name, 'Nutella (Ferrero)');
      expect(nutella.grams, 15);
      expect(nutella.caloriesKcal, 81);
      expect(nutella.kcalPer100G, 539);
      expect(nutella.proteinG, closeTo(0.945, 1e-9));
      expect(nutella.hasMacros, isTrue);

      expect(_line(_toast, _harry).toComponent().name, 'Toastbrot · Harry');
      expect(_line(_toast).toComponent().name, 'Toastbrot');

      const noMacros = DraftCandidate(
        origin: DraftItemOrigin.product,
        title: '   ',
        kcalPer100G: 100,
      );
      final unnamed = _line(_nutella, noMacros).toComponent();
      expect(unnamed.name, 'Nutella', reason: 'leerer Titel -> Beschreibung');
      expect(unnamed.proteinG, isNull);
      expect(unnamed.hasMacros, isFalse);
    });
  });

  group('MealDescriptionDraft', () {
    test('replaceItem, removeItem und Summen', () {
      final draft = MealDescriptionDraft(
        meal: _meal([_toast, _nutella]),
        items: [_line(_toast), _line(_nutella)],
      );
      expect(draft.slotHint, MealSlot.breakfast);
      expect(draft.caloriesKcal, 130 + 81);
      expect(draft.isLoggable, isTrue);

      final replaced = draft.replaceItem(
        0,
        draft.items[0].withCandidate(_harry),
      );
      expect(replaced.items[0].grams, 56);
      expect(replaced.caloriesKcal, 143 + 81);
      expect(draft.items[0].grams, 50, reason: 'unveraendert');

      final removed = replaced.removeItem(0);
      expect(removed.items.single.described, same(_nutella));
      expect(removed.removeItem(0).isLoggable, isFalse);
    });

    test('toResult: Summen, Makros, Quelle der Schaetzung', () {
      final draft = MealDescriptionDraft(
        meal: _meal([_toast, _nutella]),
        items: [_line(_toast), _line(_nutella)],
      );
      final result = draft.toResult();

      expect(result.mealName, 'Nutella-Toast');
      expect(result.caloriesKcal, 211);
      expect(result.estimatedGrams, 65);
      expect(result.kcalPer100G, closeTo(211 * 100 / 65, 1e-9));
      expect(result.protein, '4,9 g');
      expect(result.carbs, '33,2 g');
      expect(result.fat, '6,6 g');
      expect(result.items.map((c) => c.name), ['Toastbrot', 'Nutella']);
      expect(result.sourceLabel, MealResultSource.aiEstimate.code);
      expect(result.confidence, 'medium');
      expect(result.isAdjusted, isFalse);
      expect(result.barcode, isNull);
      expect(
        MealResultAdjustmentNote.resolve(result.portionNotes),
        isNotNull,
        reason: 'der Bestandteile-Hinweis, nicht der Modelltext',
      );
      // The add sheet's guard: no 0-kcal sentinel.
      expect(result.caloriesKcal > 0 || result.explicitZeroKcal, isTrue);
    });

    test('toResult: eine Zeile ohne Makros macht die Summe unbekannt', () {
      const noMacros = DraftCandidate(
        origin: DraftItemOrigin.product,
        title: 'Toast',
        brand: 'Lidl',
        kcalPer100G: 260,
        servingGrams: 25,
      );
      final draft = MealDescriptionDraft(
        meal: _meal([_toast, _nutella]),
        items: [_line(_toast, noMacros), _line(_nutella, _nutellaProduct)],
      );
      final result = draft.toResult();
      expect(result.protein, '-');
      expect(result.carbs, '-');
      expect(result.fat, '-');
      expect(result.caloriesKcal, 130 + 81);
      expect(result.items.first.name, 'Toast (Lidl)');
    });

    test('toResult: nur Produkte -> Datenbank-Quelle', () {
      const favorite = DraftCandidate(
        origin: DraftItemOrigin.favorite,
        title: 'Nutella · Ferrero',
        brand: 'Ferrero',
        kcalPer100G: 540,
        barcode: '3017620422003',
      );
      const scanFavorite = DraftCandidate(
        origin: DraftItemOrigin.favorite,
        title: 'Nutella-Brot',
        kcalPer100G: 300,
      );
      MealAnalysisResult resultOf(DraftCandidate nutella) =>
          MealDescriptionDraft(
            meal: _meal([_toast, _nutella]),
            items: [_line(_toast, _harry), _line(_nutella, nutella)],
          ).toResult();

      for (final backed in [_nutellaProduct, favorite]) {
        final result = resultOf(backed);
        expect(result.sourceLabel, MealResultSource.openFoodFacts.code);
        expect(result.confidence, MealResultConfidence.database.code);
      }
      final mixed = resultOf(scanFavorite);
      expect(mixed.sourceLabel, MealResultSource.aiEstimate.code);
      expect(mixed.confidence, 'medium');
    });

    test('toResult ueberlebt die Persistenz-Projektion', () {
      final result = MealDescriptionDraft(
        meal: _meal([_toast, _nutella]),
        items: [_line(_toast, _harry), _line(_nutella)],
      ).toResult();
      final back = mealResultFromJson(mealResultToJson(result));
      expect(back.caloriesKcal, result.caloriesKcal);
      expect(back.items.map((c) => c.name), result.items.map((c) => c.name));
      expect(back.sourceLabel, result.sourceLabel);
    });
  });
}
