import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';

// Regression tests for docs/REVIEW-2026-08-08.md, B1 / B7 / B8.
//
// Deliberately without importing open_food_facts_product_service.dart so this
// test compiles independently of the service rework.
//
// The test data mirrors the REAL server shapes: number, 0 (the old clampNumber
// sentinel), null (the shape after the server fix) and missing key. The old
// coverage only fed missing keys, a shape the server never sends.

void main() {
  group('B1 · adjustedToGrams behandelt kcalPer100G <= 0 als "fehlt"', () {
    // The server returned 0 instead of null for unparsable model values.
    // 780 kcal on 300 g, density field unusable.
    const tellerOhneDichte = MealAnalysisResult(
      mealName: 'Teller',
      caloriesKcal: 780,
      estimatedGrams: 300,
      kcalPer100G: 0,
      protein: '30 g',
      carbs: '80 g',
      fat: '25 g',
      confidence: 'Mittel',
      portionNotes: '',
    );

    test('Bestaetigen ohne Aenderung loggt nicht 0 kcal', () {
      final r = tellerOhneDichte.adjustedToGrams(300);
      expect(r.caloriesKcal, 780);
    });

    test('Portionsaenderung skaliert aus caloriesKcal statt aus der 0-Dichte', () {
      final r = tellerOhneDichte.adjustedToGrams(150);
      expect(r.caloriesKcal, 390);
    });

    test('die abgeleitete Dichte wird mitgefuehrt statt bei 0 zu bleiben', () {
      final r = tellerOhneDichte.adjustedToGrams(300);
      expect(r.kcalPer100G, closeTo(260, 0.001));
    });

    test('caloriesKcal ist autoritativ gegenueber widerspruechlicher Dichte', () {
      // The server clamps caloriesKcal, estimatedGrams and kcalPer100G
      // independently and never reconciles them: 850/300 g is 283, not 260.
      const widerspruch = MealAnalysisResult(
        mealName: 'Bowl',
        caloriesKcal: 850,
        estimatedGrams: 300,
        kcalPer100G: 260,
        protein: '40 g',
        carbs: '60 g',
        fat: '30 g',
        confidence: 'Mittel',
        portionNotes: '',
      );
      final r = widerspruch.adjustedToGrams(300);
      expect(r.caloriesKcal, 850, reason: 'blosses Bestaetigen darf nichts aendern');
      expect(r.kcalPer100G, closeTo(850 * 100 / 300, 0.001));
    });

    test('geklemmte Portion: mehr als 10000 g sind nicht schreibbar', () {
      final r = tellerOhneDichte.adjustedToGrams(999999);
      expect(r.estimatedGrams, 10000);
      expect(r.caloriesKcal, lessThanOrEqualTo(10000));
    });
  });

  group('B1 · MealComponent.adjustedToGrams behandelt 0-Dichte als "fehlt"', () {
    test('kcalPer100G == 0 faellt auf kcal/Gramm zurueck', () {
      const c = MealComponent(
        name: 'Reis',
        grams: 200,
        caloriesKcal: 260,
        kcalPer100G: 0,
      );
      final a = c.adjustedToGrams(100);
      expect(a.caloriesKcal, 130);
      expect(a.kcalPer100G, closeTo(130, 0.001));
    });

    test('unplausible Dichte (kJ-Zahl) wird verworfen, nicht verrechnet', () {
      const c = MealComponent(
        name: 'Keks',
        grams: 100,
        caloriesKcal: 521,
        kcalPer100G: 2180,
      );
      final a = c.adjustedToGrams(30);
      expect(a.caloriesKcal, 156);
    });
  });

  group('B1 · fromEdgeFunction gegen die realen Serverformen', () {
    test('kcalPer100G: 0 (alter Sentinel) macht die Fallback-Kette erreichbar', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Apfel',
        'caloriesKcal': 95,
        'estimatedGrams': 0,
        'kcalPer100G': 0,
        'proteinG': null,
        'carbsG': null,
        'fatG': null,
        'confidence': 'medium',
        'explanation': 'Ein mittelgrosser Apfel.',
        'items': <dynamic>[],
      });
      expect(r.kcalPer100G, 52, reason: '_knownKcalPer100G muss greifen');
      expect(r.estimatedGrams, 150, reason: 'estimatedGrams 0 heisst "unbekannt"');
      expect(r.caloriesKcal, 95);
    });

    test('kcalPer100G: null (Serverform nach dem Fix) verhaelt sich identisch', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Apfel',
        'caloriesKcal': 95,
        'estimatedGrams': null,
        'kcalPer100G': null,
        'confidence': 'medium',
        'items': <dynamic>[],
      });
      expect(r.kcalPer100G, 52);
      expect(r.estimatedGrams, 150);
    });

    test('caloriesKcal: 0 wird aus Dichte und Gramm hergeleitet', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Nudeln',
        'caloriesKcal': 0,
        'estimatedGrams': 250,
        'kcalPer100G': 130,
      });
      expect(r.caloriesKcal, 325);
    });

    test('_estimateGramsFromText greift bei estimatedGrams: 0', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Steak',
        'caloriesKcal': 550,
        'estimatedGrams': 0,
        'kcalPer100G': 0,
        'explanation': 'Geschaetzt rund 250 g Fleisch.',
      });
      expect(r.estimatedGrams, 250);
    });

    test('unplausible Modelldichte (>900) wird verworfen', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Salat',
        'caloriesKcal': 120,
        'estimatedGrams': 300,
        'kcalPer100G': 5200,
      });
      expect(r.kcalPer100G, closeTo(40, 0.001));
      expect(r.caloriesKcal, 120);
    });

    test('kcalPer100G: -1 wird serverseitig zu 0 und gilt als "fehlt"', () {
      // The server clamps parsable negative values to 0 instead of dropping
      // them, so the guard must check <= 0, not == null.
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Suppe',
        'caloriesKcal': 240,
        'estimatedGrams': 400,
        'kcalPer100G': 0,
      });
      expect(r.kcalPer100G, closeTo(60, 0.001));
    });

    test('echte Modellzahlen schlagen die namensbasierte Referenzdichte', () {
      // 'Apfelkuchen' contains 'apfel' -> _knownKcalPer100G returns 52, but the
      // two authoritative numbers of this photo say 333.
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Apfelkuchen',
        'caloriesKcal': 400,
        'estimatedGrams': 120,
        'kcalPer100G': null,
      });
      expect(r.kcalPer100G, closeTo(333.33, 0.01));
    });

    test('nicht parsebare Makros werden "-" statt 0 g', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Eintopf',
        'caloriesKcal': 300,
        'estimatedGrams': 400,
        'kcalPer100G': 75,
        'proteinG': 'viel',
        'carbsG': null,
        'fatG': 12,
      });
      expect(r.protein, '-');
      expect(r.carbs, '-');
      expect(r.fat, '12 g');
    });

    test('items mit null-Feldern kippen die Summen nicht', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Bowl',
        'caloriesKcal': 500,
        'estimatedGrams': 400,
        'kcalPer100G': 125,
        'items': <dynamic>[
          <String, dynamic>{
            'name': 'Reis',
            'grams': null,
            'caloriesKcal': null,
            'kcalPer100G': 130,
          },
        ],
      });
      expect(r.caloriesKcal, 500);
      expect(r.estimatedGrams, 400);
    });

    test(
        'Sentinel-Rest C: ohne jede Zahl und ohne Referenztreffer wird '
        'NICHTS erfunden', () {
      // The density chain used to end in a bare `: 52.0`, turning a photo with
      // no kcal, no grams, no density and no reference-table hit into a
      // loggable "78 kcal / 150 g" meal. The unknown form is 0 WITHOUT
      // explicitZeroKcal; the log guards block that with a hint.
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Xyzzq',
        'caloriesKcal': null,
        'estimatedGrams': null,
        'kcalPer100G': null,
      });
      expect(r.caloriesKcal, 0,
          reason: 'erfundene 78 kcal wuerden als Messung geloggt');
      expect(r.kcalPer100G, 0,
          reason: '52.0 aus dem Nichts ist keine Dichte, sondern ein Wuerfel');
      expect(r.explicitZeroKcal, isFalse,
          reason: 'diese 0 ist "unbekannt", keine gemessene 0 — nur so '
              'greifen die Log-Guards');
    });

    test('Sentinel-Rest C: fehlende confidence wird nicht zu "Mittel"', () {
      // `confidence` is the MODEL's own statement about its certainty. Missing
      // is not "medium"; the user calibrates their trust by it.
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Apfel',
        'caloriesKcal': 95,
        'estimatedGrams': 150,
        'kcalPer100G': 63,
      });
      // Neutral code instead of a localized label.
      expect(r.confidence, 'unknown');
      expect(r.resolvedConfidence(deL10n), 'Unbekannt');
    });

    test('DB-Grenzen werden geklemmt statt eine 23514 zu provozieren', () {
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': '',
        'caloriesKcal': 99999,
        'estimatedGrams': 99999,
        'kcalPer100G': 500,
        'proteinG': 5000,
      });
      expect(r.mealName, 'Mahlzeit');
      expect(r.caloriesKcal, 10000);
      expect(r.estimatedGrams, 10000);
      expect(r.protein, '1000 g');
    });
  });

  group('B7 · Open Food Facts: Bezugsgroesse, kJ, Plausibilitaet', () {
    test('energy-kcal_value allein wird NICHT als per-100-g gelesen', () {
      // Frozen pizza, recorded per serving. Without nutrition_data_per the
      // reference size is unknown, so the value is unusable.
      final r = MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
        'product_name': 'Ofenfrische Salami',
        'nutriments': <String, dynamic>{'energy-kcal_value': 900},
      }, '111');
      expect(r.kcalPer100G, 0);
      expect(r.caloriesKcal, 0);
    });

    test('energy-kcal_value zaehlt nur mit nutrition_data_per == "100g"', () {
      final r = MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
        'product_name': 'Riegel',
        'nutrition_data_per': '100g',
        'nutriments': <String, dynamic>{'energy-kcal_value': 385},
      }, '112');
      expect(r.kcalPer100G, 385);
    });

    test('kJ-Fallback: energy_100g ohne Einheit ist kJ', () {
      final r = MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
        'product_name': 'Riegel',
        'nutriments': <String, dynamic>{'energy_100g': 1611},
      }, '113');
      expect(r.kcalPer100G, closeTo(385.0, 0.5));
      expect(r.caloriesKcal, closeTo(385, 1));
    });

    test('kJ-Fallback: energy-kj_100g', () {
      final r = MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
        'product_name': 'Riegel',
        'nutriments': <String, dynamic>{'energy-kj_100g': 1611},
      }, '114');
      expect(r.kcalPer100G, closeTo(385.0, 0.5));
    });

    test('energy_unit == "kcal" verhindert die kJ-Division', () {
      final r = MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
        'product_name': 'Riegel',
        'nutriments': <String, dynamic>{
          'energy_100g': 385,
          'energy_unit': 'kcal',
        },
      }, '115');
      expect(r.kcalPer100G, 385);
    });

    test('unplausible kcal (2180 = kJ-Zahl) wird verworfen, nicht umgerechnet', () {
      final r = MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
        'product_name': 'Keks',
        'serving_quantity': 30,
        'nutriments': <String, dynamic>{'energy-kcal_100g': 2180},
      }, '116');
      expect(r.kcalPer100G, 0, reason: 'raten waere schlimmer als fehlen');
      expect(r.caloriesKcal, 0);
    });

    test('unplausibler kcal-Wert faellt auf den kJ-Schluessel zurueck', () {
      final r = MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
        'product_name': 'Keks',
        'nutriments': <String, dynamic>{
          'energy-kcal_100g': 2180,
          'energy-kj_100g': 2180,
        },
      }, '117');
      expect(r.kcalPer100G, closeTo(521.0, 0.5));
    });

    test('serving_quantity 0 faellt auf den 100-g-Default zurueck', () {
      final r = MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
        'product_name': 'Quark',
        'serving_quantity': 0,
        'nutriments': <String, dynamic>{'energy-kcal_100g': 67},
      }, '118');
      expect(r.estimatedGrams, 100);
      expect(r.caloriesKcal, 67);
    });

    test('unplausible serving_quantity faellt auf den 100-g-Bezug zurueck', () {
      // 250 kg is not a serving. Clamping to 10000 g would invent a 10 kg
      // plate; the 100 g reference is what the nutrients are normalized to.
      final r = MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
        'product_name': 'Sack Mehl',
        'serving_quantity': 250000,
        'nutriments': <String, dynamic>{'energy-kcal_100g': 340},
      }, '119');
      expect(r.estimatedGrams, 100);
      expect(r.caloriesKcal, 340);
    });
  });

  group('B8 · Makros folgen den Bestandteilen, nicht der Masse', () {
    const salat = MealAnalysisResult(
      mealName: 'Salat mit Haehnchen',
      caloriesKcal: 380,
      estimatedGrams: 400,
      kcalPer100G: 95,
      protein: '35 g',
      carbs: '18 g',
      fat: '12 g',
      confidence: 'Mittel',
      portionNotes: '',
      items: [
        MealComponent(name: 'Salat', grams: 250, caloriesKcal: 60),
        MealComponent(name: 'Haehnchen', grams: 150, caloriesKcal: 320),
      ],
    );

    test('hinzugefuegter Bestandteil erfindet keine Massenskalierung', () {
      final r = salat.adjustedToItems(const [
        MealComponent(name: 'Salat', grams: 250, caloriesKcal: 60),
        MealComponent(name: 'Haehnchen', grams: 150, caloriesKcal: 320),
        MealComponent(name: 'Olivenoel', grams: 20, caloriesKcal: 180),
      ]);
      expect(r.caloriesKcal, 560);
      expect(r.fat, '-', reason: '12,6 g waere schlichtweg falsch');
      expect(r.protein, '-');
      expect(r.carbs, '-');
    });

    test('entfernter Bestandteil erfindet keine Kohlenhydrate', () {
      const teller = MealAnalysisResult(
        mealName: 'Steak mit Pommes',
        caloriesKcal: 900,
        estimatedGrams: 400,
        kcalPer100G: 225,
        protein: '48 g',
        carbs: '60 g',
        fat: '45 g',
        confidence: 'Mittel',
        portionNotes: '',
        items: [
          MealComponent(name: 'Steak', grams: 250, caloriesKcal: 550),
          MealComponent(name: 'Pommes', grams: 150, caloriesKcal: 350),
        ],
      );
      final r = teller.adjustedToItems(const [
        MealComponent(name: 'Steak', grams: 250, caloriesKcal: 550),
      ]);
      expect(r.caloriesKcal, 550);
      expect(r.carbs, '-', reason: '38 g erfundene KH aus einem Steak');
      expect(r.protein, '-');
    });

    test('unveraenderte Bestandteilsliste laesst die Makros unangetastet', () {
      final r = salat.adjustedToItems(const [
        MealComponent(name: 'Salat', grams: 250, caloriesKcal: 60),
        MealComponent(name: 'Haehnchen', grams: 150, caloriesKcal: 320),
      ]);
      expect(r.protein, '35 g');
      expect(r.fat, '12 g');
      expect(r.caloriesKcal, 380);
    });

    test('einheitliche Umskalierung aller Posten skaliert die Makros mit', () {
      final r = salat.adjustedToItems(const [
        MealComponent(name: 'Salat', grams: 500, caloriesKcal: 120),
        MealComponent(name: 'Haehnchen', grams: 300, caloriesKcal: 640),
      ]);
      expect(r.protein, '70 g');
      expect(r.fat, '24 g');
    });

    test('synthetisierter Einzelposten (OFF/Barcode) skaliert die Makros', () {
      // Without items the components sheet synthesizes exactly one item from
      // the whole meal, so a gram change on it is a real portion change, not a
      // composition change.
      const produkt = MealAnalysisResult(
        mealName: 'Magerquark',
        caloriesKcal: 168,
        estimatedGrams: 250,
        kcalPer100G: 67,
        protein: '30 g',
        carbs: '10 g',
        fat: '0,5 g',
        confidence: 'Datenbank',
        portionNotes: '',
      );
      final r = produkt.adjustedToItems(const [
        MealComponent(name: 'Magerquark', grams: 500, caloriesKcal: 336),
      ]);
      expect(r.protein, '60 g');
      expect(r.caloriesKcal, 336);
    });

    test('Bestandteile mit eigenen Makros werden aufsummiert', () {
      final r = salat.adjustedToItems(const [
        MealComponent(
          name: 'Salat',
          grams: 250,
          caloriesKcal: 60,
          proteinG: 3,
          carbsG: 6,
          fatG: 1,
        ),
        MealComponent(
          name: 'Haehnchen',
          grams: 150,
          caloriesKcal: 320,
          proteinG: 32,
          carbsG: 0,
          fatG: 11,
        ),
        MealComponent(
          name: 'Olivenoel',
          grams: 20,
          caloriesKcal: 180,
          proteinG: 0,
          carbsG: 0,
          fatG: 20,
        ),
      ]);
      expect(r.protein, '35 g');
      expect(r.carbs, '6 g');
      expect(r.fat, '32 g');
    });

    test('MealComponent.adjustedToGrams skaliert eigene Makros mit', () {
      const c = MealComponent(
        name: 'Haehnchen',
        grams: 150,
        caloriesKcal: 320,
        proteinG: 32,
        fatG: 11,
      );
      final a = c.adjustedToGrams(300);
      expect(a.proteinG, closeTo(64, 0.001));
      expect(a.fatG, closeTo(22, 0.001));
      expect(a.carbsG, isNull);
    });

    test('MealComponent.fromJson liest optionale Makros', () {
      final c = MealComponent.fromJson(const <String, dynamic>{
        'name': 'Reis',
        'grams': 100,
        'caloriesKcal': 130,
        'proteinG': 2.7,
        'carbsG': 28,
        'fatG': null,
      });
      expect(c.proteinG, closeTo(2.7, 0.001));
      expect(c.carbsG, closeTo(28, 0.001));
      expect(c.fatG, isNull);
    });
  });
}
