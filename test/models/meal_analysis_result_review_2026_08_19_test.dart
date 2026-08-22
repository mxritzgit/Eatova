import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';

// Regression tests for review 2026-08-19, findings 1-4 in
// `lib/src/models/meal_analysis_result.dart`:
//   1 — the substring reference table turned 'Erdbeerkuchen' into a strawberry,
//       and reference density x default portion became loggable calories.
//   2 — `items[]` and `caloriesKcal` were unreconciled, so merely confirming
//       the components moved the meal.
//   3 — the first gram figure in `explanation` counted as total weight and even
//       beat the item sum.
//   4 — `fromOpenFoodFacts` persisted a ready-made German paragraph.

/// The legacy German paragraph `fromOpenFoodFacts` used to write into
/// `portionNotes`; it must stay readable.
const String _altzeileDe =
    'OpenFoodFacts Barcode 4001724012345. Marke: Dr. Oetker. Packung: 390 g. '
    'Portion laut Datenbank: 100 g. Nährwerte kommen aus der Produktdatenbank, '
    'nicht aus einer Foto-Schätzung. Du kannst das gegessene Gewicht weiter '
    'anpassen.';

const String _altzeileEn =
    'Open Food Facts barcode 4001724012345. Brand: Dr. Oetker. Package: 390 g. '
    'Serving size per database: 100 g. Nutrition values come from the product '
    'database, not from a photo estimate. You can still adjust the weight you '
    'ate.';

MealAnalysisResult _mitNotiz(String portionNotes) => MealAnalysisResult(
  mealName: 'Testprodukt',
  caloriesKcal: 252,
  estimatedGrams: 100,
  kcalPer100G: 252,
  protein: '10 g',
  carbs: '31 g',
  fat: '9 g',
  confidence: 'database',
  portionNotes: portionNotes,
);

void main() {
  group('Fund 1 · Referenzdichte erfindet keine Kalorien mehr', () {
    test('Teilstring-Treffer ist weg: Erdbeerkuchen ist keine Erdbeere', () {
      // Before: 'erdbeerkuchen'.contains('erdbeer') -> 32 kcal/100 g times the
      // 150 g default portion -> 48 loggable kcal from a numberless answer.
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Erdbeerkuchen',
        'caloriesKcal': null,
        'estimatedGrams': null,
        'kcalPer100G': null,
      });
      expect(r.kcalPer100G, 0, reason: 'ein Kuchen ist keine Erdbeere');
      expect(r.caloriesKcal, 0);
      expect(
        r.explicitZeroKcal,
        isFalse,
        reason: 'diese 0 heisst "unbekannt" — nur so greifen die Log-Guards',
      );
    });

    test('exakter Treffer bleibt erhalten', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Apfel',
        'kcal': 95,
      });
      expect(r.kcalPer100G, 52);
    });

    test('Referenzdichte allein macht keine Gesamtkalorien', () {
      // The name hits the table but the model gave neither kcal nor grams:
      // 52 kcal/100 g x the 150 g default were 78 invented kcal.
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Apfel',
        'caloriesKcal': null,
        'estimatedGrams': null,
        'kcalPer100G': null,
      });
      expect(r.caloriesKcal, 0, reason: '78 kcal aus einer Default-Portion');
      expect(r.kcalPer100G, 52, reason: 'die Dichte selbst bleibt eine Angabe');
      expect(r.explicitZeroKcal, isFalse);
    });

    test('mit GEMESSENER Portion wird weiterhin hergeleitet', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Apfel',
        'caloriesKcal': null,
        'estimatedGrams': 200,
        'kcalPer100G': null,
      });
      expect(r.caloriesKcal, 104, reason: '52 kcal/100 g auf gemessene 200 g');
      expect(r.estimatedGrams, 200);
    });
  });

  group('Fund 2 · Postensumme und Gesamtwert werden abgeglichen', () {
    test('Bestaetigen ohne Aenderung verschiebt die Kalorien nicht', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Bowl',
        'caloriesKcal': 500,
        'estimatedGrams': 400,
        'kcalPer100G': 125,
        'items': <dynamic>[
          <String, dynamic>{'name': 'Reis', 'grams': 200, 'caloriesKcal': 260},
          <String, dynamic>{
            'name': 'Haehnchen',
            'grams': 200,
            'caloriesKcal': 220,
          },
        ],
      });
      expect(r.caloriesKcal, 500);
      expect(
        r.items.fold<int>(0, (sum, item) => sum + item.caloriesKcal),
        500,
        reason: 'die Aufschluesselung muss den Gesamtwert ergeben',
      );
      expect(
        r.adjustedToItems(r.items).caloriesKcal,
        500,
        reason: 'blosses Bestaetigen darf die Mahlzeit nicht aendern',
      );
    });

    test('die Verhaeltnisse der Posten bleiben erhalten', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Bowl',
        'caloriesKcal': 500,
        'estimatedGrams': 400,
        'items': <dynamic>[
          <String, dynamic>{'name': 'Reis', 'grams': 200, 'caloriesKcal': 260},
          <String, dynamic>{
            'name': 'Haehnchen',
            'grams': 200,
            'caloriesKcal': 220,
          },
        ],
      });
      expect(r.items.first.caloriesKcal, 271); // 260 * 500 / 480
      expect(r.items.last.caloriesKcal, 229); // 220 * 500 / 480
      expect(
        r.items.first.kcalPer100G,
        closeTo(135.5, 0.01),
        reason: 'die Dichte des Postens folgt seiner neuen Kalorienzahl',
      );
    });

    test('Posten ohne Kalorien werden nicht mit einer Verteilung befuellt', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Bowl',
        'caloriesKcal': 500,
        'estimatedGrams': 400,
        'items': <dynamic>[
          <String, dynamic>{
            'name': 'Reis',
            'grams': 200,
            'caloriesKcal': null,
            'kcalPer100G': null,
          },
        ],
      });
      expect(r.caloriesKcal, 500);
      expect(
        r.items.single.caloriesKcal,
        0,
        reason: 'ohne Bezugsgroesse gibt es nichts zu verteilen',
      );
    });
  });

  group('Fund 3 · Grammangabe aus dem Erklaertext', () {
    test('die Postensumme schlaegt den Erklaertext', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Pastagericht',
        'caloriesKcal': 600,
        'estimatedGrams': null,
        'kcalPer100G': null,
        'explanation': 'Etwa 120 g Nudeln mit 80 g Sauce.',
        'items': <dynamic>[
          <String, dynamic>{
            'name': 'Nudeln',
            'grams': 120,
            'caloriesKcal': 190,
          },
          <String, dynamic>{'name': 'Sauce', 'grams': 130, 'caloriesKcal': 410},
        ],
      });
      expect(r.estimatedGrams, 250, reason: '120 g war nur der erste Posten');
    });

    test('mehrere Grammangaben ergeben kein Gesamtgewicht', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Pastagericht',
        'caloriesKcal': 600,
        'estimatedGrams': null,
        'kcalPer100G': null,
        'explanation': 'Etwa 120 g Nudeln mit 80 g Sauce.',
      });
      expect(r.estimatedGrams, isNot(120));
      expect(r.estimatedGrams, 150, reason: 'unbekannt heisst Default-Portion');
    });

    test('genau eine Grammangabe zaehlt weiterhin', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Steak',
        'caloriesKcal': 550,
        'estimatedGrams': 0,
        'kcalPer100G': 0,
        'explanation': 'Geschaetzt rund 250 g Fleisch.',
      });
      expect(r.estimatedGrams, 250);
    });
  });

  group('Fund 4 · OFF-Hinweis ist sprachneutral persistiert', () {
    final salami = MealAnalysisResult.fromOpenFoodFacts(const <String, dynamic>{
      'product_name': 'Die Ofenfrische Salami',
      'brands': 'Dr. Oetker',
      'quantity': '390 g',
      'serving_size': '100 g',
      'serving_quantity': 100,
      'nutriments': <String, dynamic>{'energy-kcal_100g': 252},
    }, '4001724012345');

    test('persistiert wird ein Code, kein deutscher Absatz', () {
      expect(salami.portionNotes, startsWith('offProductNote:'));
      expect(salami.portionNotes, isNot(contains('Nährwerte')));
    });

    test('die deutsche Anzeige bleibt wortgleich zur Bestandsfassung', () {
      expect(salami.resolvedPortionNotes(deL10n), _altzeileDe);
    });

    test('die englische Anzeige ist komplett englisch', () {
      expect(salami.resolvedPortionNotes(enL10n), _altzeileEn);
    });

    test('fehlende Felder lassen ihre Saetze weg', () {
      final wasser = MealAnalysisResult.fromOpenFoodFacts(
        const <String, dynamic>{
          'product_name': 'Wasser',
          'nutriments': <String, dynamic>{'energy-kcal_100g': 0},
        },
        '999',
      );
      expect(
        wasser.resolvedPortionNotes(deL10n),
        'OpenFoodFacts Barcode 999. Nährwerte kommen aus der '
        'Produktdatenbank, nicht aus einer Foto-Schätzung. Du kannst das '
        'gegessene Gewicht weiter anpassen.',
      );
      expect(
        wasser.resolvedPortionNotes(enL10n),
        'Open Food Facts barcode 999. Nutrition values come from the product '
        'database, not from a photo estimate. You can still adjust the weight '
        'you ate.',
      );
    });

    test('Alt-Zeile (deutscher Absatz) wird erkannt und uebersetzt', () {
      final alt = _mitNotiz(_altzeileDe);
      expect(alt.resolvedPortionNotes(enL10n), _altzeileEn);
      expect(alt.resolvedPortionNotes(deL10n), _altzeileDe);
    });

    test('Alt-Zeile ohne Marke/Packung/Portion wird ebenfalls erkannt', () {
      final alt = _mitNotiz(
        'OpenFoodFacts Barcode 999. Nährwerte kommen aus der '
        'Produktdatenbank, nicht aus einer Foto-Schätzung. Du kannst das '
        'gegessene Gewicht weiter anpassen.',
      );
      expect(
        alt.resolvedPortionNotes(enL10n),
        'Open Food Facts barcode 999. Nutrition values come from the product '
        'database, not from a photo estimate. You can still adjust the weight '
        'you ate.',
      );
    });

    test('unbekannter Freitext bleibt unveraendert (Pass-through)', () {
      const freitext = 'Ein halber Teller, geschätzt aus dem Foto.';
      expect(_mitNotiz(freitext).resolvedPortionNotes(enL10n), freitext);
    });

    test('beschaedigter Code verliert die Zeile nicht', () {
      const kaputt = 'offProductNote:{nicht wirklich json';
      expect(_mitNotiz(kaputt).resolvedPortionNotes(enL10n), kaputt);
    });

    test('Kodierung und Aufloesung sind ein Rundlauf', () {
      const notiz = MealResultOffNote(
        barcode: '123',
        brand: 'Marke',
        package: '500 g',
        serving: '25 g',
      );
      final zurueck = MealResultOffNote.resolve(notiz.encode());
      expect(zurueck, isNotNull);
      expect(zurueck!.text(deL10n), notiz.text(deL10n));
      expect(zurueck.text(enL10n), notiz.text(enL10n));
    });
  });
}
