import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';

// How MealAnalysisResult turns server, Open Food Facts and component data into
// loggable numbers (reviews 2026-08-08 B1/B7/B8 and 2026-08-19): density
// fallbacks, kJ and reference sizes, the reference table, component
// reconciliation and the language-neutral OFF note.
//
// The test data mirrors the REAL server shapes: number, 0 (the old clampNumber
// sentinel), null (the shape after the server fix) and missing key.

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
      // The macros belong to the same portion: only kcal was measured, so a
      // factor stuck at 1.0 would have shown half the calories next to the
      // full protein/carb/fat numbers.
      expect(r.protein, '15 g');
      expect(r.carbs, '40 g');
      expect(r.fat, '12,5 g');
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

    test('unplausible Dichte erfindet keine Kalorien, wo keine gemessen sind',
        () {
      // The second guard in effectiveKcalPer100G: 2180 kcal/100 g is above
      // anything edible (900) and the only caller is adjustedToGrams, which
      // falls back to the density exactly when kcal or grams are missing.
      // Without the plausibility check a 0-kcal entry silently gains 2180 kcal
      // on the first portion change — and nothing in the suite noticed the
      // check was gone.
      const ohneKalorien = MealAnalysisResult(
        mealName: 'Unbekannt',
        caloriesKcal: 0,
        estimatedGrams: 200,
        kcalPer100G: 2180,
        protein: '',
        carbs: '',
        fat: '',
        confidence: 'Niedrig',
        portionNotes: '',
      );
      expect(ohneKalorien.effectiveKcalPer100G, isNull);
      expect(ohneKalorien.adjustedToGrams(100).caloriesKcal, 0);
      // The counter-case: a plausible density IS used.
      const mitDichte = MealAnalysisResult(
        mealName: 'Unbekannt',
        caloriesKcal: 0,
        estimatedGrams: 200,
        kcalPer100G: 260,
        protein: '',
        carbs: '',
        fat: '',
        confidence: 'Niedrig',
        portionNotes: '',
      );
      expect(mitDichte.effectiveKcalPer100G, 260);
      expect(mitDichte.adjustedToGrams(100).caloriesKcal, 260);
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
    test('kcalPer100G/estimatedGrams 0 (alter Sentinel) und null (Serverform '
        'nach dem Fix) machen die Fallback-Kette erreichbar', () {
      for (final unbekannt in <Object?>[0, null]) {
        final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
          'mealName': 'Apfel',
          'caloriesKcal': 95,
          'estimatedGrams': unbekannt,
          'kcalPer100G': unbekannt,
          'proteinG': null,
          'confidence': 'medium',
          'explanation': 'Ein mittelgrosser Apfel.',
          'items': <dynamic>[],
        });
        expect(r.kcalPer100G, 52,
            reason: '$unbekannt: _knownKcalPer100G muss greifen');
        expect(r.estimatedGrams, 150,
            reason: '$unbekannt: estimatedGrams heisst "unbekannt"');
        expect(r.caloriesKcal, 95);
      }
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

    test('echte Modellzahlen schlagen die namensbasierte Referenzdichte', () {
      // 'Apfel' is an exact entry of the reference table (52 kcal/100 g), but
      // the two authoritative numbers of this photo say 333.
      final r = MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
        'mealName': 'Apfel',
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

    test('kJ-Fallback: energy_100g ohne Einheit und energy-kj_100g sind kJ',
        () {
      for (final feld in const ['energy_100g', 'energy-kj_100g']) {
        final r = MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
          'product_name': 'Riegel',
          'nutriments': <String, dynamic>{feld: 1611},
        }, '113');
        expect(r.kcalPer100G, closeTo(385.0, 0.5), reason: feld);
        expect(r.caloriesKcal, closeTo(385, 1), reason: feld);
      }
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

    // Review 2026-10-11 (FOOD-5): a 0 in the kcal field next to a positive
    // kJ value is a gap in the record (OFF flags the mismatch), not water.
    // It was logged as a measured 0 kcal.
    test('eine 0 neben einem positiven Energiewert ist keine gemessene 0', () {
      for (final nutriments in <Map<String, dynamic>>[
        // kcal 0 next to a positive kJ value.
        <String, dynamic>{
          'energy-kcal_100g': 0,
          'energy-kcal_value': 0,
          'energy-kj_100g': 1046,
          'energy_100g': 1046,
        },
        // kJ 0 next to a positive energy_100g.
        <String, dynamic>{'energy-kj_100g': 0, 'energy_100g': 1046},
      ]) {
        final product = <String, dynamic>{
          'product_name': 'Haferkeks',
          'nutrition_data_per': '100g',
          'nutriments': nutriments,
        };
        final r = MealAnalysisResult.fromOpenFoodFacts(product, '119');
        expect(MealAnalysisResult.offMeldetExplizitNullKcal(product), isFalse,
            reason: '$nutriments');
        expect(r.explicitZeroKcal, isFalse, reason: '$nutriments');
        expect(r.kcalPer100G, closeTo(250.0, 0.5), reason: '$nutriments');
        expect(r.caloriesKcal, 250, reason: '$nutriments');
      }
    });

    test('kcal 0 und kJ 0 bleiben die gemessene 0 (Wasser)', () {
      final product = <String, dynamic>{
        'product_name': 'Mineralwasser',
        'serving_quantity': 250,
        'nutriments': <String, dynamic>{
          'energy-kcal_100g': 0,
          'energy-kj_100g': 0,
          'energy_100g': 0,
        },
      };
      final r = MealAnalysisResult.fromOpenFoodFacts(product, '120');
      expect(MealAnalysisResult.offMeldetExplizitNullKcal(product), isTrue);
      expect(r.explicitZeroKcal, isTrue);
      expect(r.caloriesKcal, 0);
    });

    test('serving_quantity 0 oder unplausibel faellt auf den 100-g-Bezug '
        'zurueck', () {
      // 250 kg is not a serving. Clamping to 10000 g would invent a 10 kg
      // plate; the 100 g reference is what the nutrients are normalized to.
      for (final menge in const [0, 250000]) {
        final r = MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
          'product_name': 'Sack Mehl',
          'serving_quantity': menge,
          'nutriments': <String, dynamic>{'energy-kcal_100g': 340},
        }, '118');
        expect(r.estimatedGrams, 100, reason: '$menge');
        expect(r.caloriesKcal, 340, reason: '$menge');
      }
    });

    MealAnalysisResult portion(String servingSize, {num? quantity}) =>
        MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
          'product_name': 'Produkt',
          'serving_quantity': ?quantity,
          'serving_size': servingSize,
          'nutriments': <String, dynamic>{'energy-kcal_100g': 390},
        }, '121');

    test('Portion unter 1 g im Text: 100-g-Bezug statt 49 g', () {
      // One mint: serving_quantity 0.49 is rejected, and the text used to be
      // read as "49 g", logging 191 kcal for a single Tic Tac.
      final tictac = portion('1 Dragee (0,49 g)', quantity: 0.49);
      expect(tictac.estimatedGrams, 100);
      expect(tictac.caloriesKcal, 390);
      expect(portion('1 Tablette (0,06 g)').estimatedGrams, 100);
      expect(portion('0.49 g').estimatedGrams, 100);
    });

    test('Dezimalzahlen im Portionstext werden ganz gelesen', () {
      expect(portion('1,25 g').estimatedGrams, 1, reason: 'nicht 25 g');
      expect(portion('2,50 g').estimatedGrams, 3, reason: 'nicht 50 g');
      expect(portion('1 Riegel (12,5 g)').estimatedGrams, 13);
      expect(portion('5 g').estimatedGrams, 5);
    });

    test('Gramm-Angaben im Portionstext bleiben erkannt', () {
      expect(portion('2 Scheiben (50 g)').estimatedGrams, 50);
      expect(portion('30 g').estimatedGrams, 30);
      expect(portion('50gr').estimatedGrams, 50);
      expect(portion('50 Gramm').estimatedGrams, 50);
      expect(portion('2 galettes (20 g)').estimatedGrams, 20);
      // An item word starting with "g" is no gram unit.
      expect(portion('1 glass (250 ml)').estimatedGrams, 100);
    });

    test('kleine Portion: die Dichte des Etiketts traegt die Skalierung', () {
      // Chewing gum: 1.4 g -> 1 g, 1.53 kcal -> 2. Scaling that 2 showed
      // 200 kcal / 100 g and logged 28 kcal for 14 g instead of 21.
      final kaugummi = MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
        'product_name': 'Kaugummi',
        'serving_quantity': 1.4,
        'nutriments': <String, dynamic>{'energy-kcal_100g': 153},
      }, '4000000000000');
      expect(kaugummi.estimatedGrams, 1);
      expect(kaugummi.caloriesKcal, 2);
      expect(kaugummi.adjustedToGrams(1).caloriesKcal, 2, reason: 'Invariante');
      expect(kaugummi.adjustedToGrams(100).caloriesKcal, 153);
      expect(kaugummi.adjustedToGrams(14).caloriesKcal, 21);
      final zweimal = kaugummi.adjustedToGrams(50).adjustedToGrams(100);
      expect(zweimal.caloriesKcal, 153, reason: 'keine Drift');
      expect(zweimal.kcalPer100G, 153);
      // The weight sheet previews the synthesized component; saving applies
      // adjustedToGrams. Both must name the same number.
      final vorschau = kaugummi.asSingleComponent.adjustedToGrams(14);
      expect(vorschau.caloriesKcal, 21);
      expect(vorschau.kcalPer100G, 153);
    });

    test('eine widersprechende Dichte skaliert weiterhin nicht', () {
      // 850 kcal on 300 g next to 260 kcal/100 g (780 kcal): the calories win.
      const bowl = MealAnalysisResult(
        mealName: 'Bowl',
        caloriesKcal: 850,
        estimatedGrams: 300,
        kcalPer100G: 260,
        protein: '-',
        carbs: '-',
        fat: '-',
        confidence: 'Mittel',
        portionNotes: '',
      );
      expect(bowl.adjustedToGrams(150).caloriesKcal, 425);
      expect(bowl.asSingleComponent.adjustedToGrams(150).caloriesKcal, 425);
    });

    test('Portion unter 1 kcal mit bekannter Dichte ist eine Messung', () {
      final teebeutel = MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
        'product_name': 'Kräutertee',
        'serving_quantity': 2,
        'nutriments': <String, dynamic>{'energy-kcal_100g': 1},
      }, '122');
      expect(teebeutel.caloriesKcal, 0);
      expect(teebeutel.explicitZeroKcal, isTrue, reason: 'loggbar');
      expect(teebeutel.adjustedToGrams(300).caloriesKcal, 3);
      final ohne = MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
        'product_name': 'Kräutertee',
        'serving_quantity': 2,
        'nutriments': <String, dynamic>{},
      }, '123');
      expect(ohne.explicitZeroKcal, isFalse, reason: 'unbekannt');
    });

    test('unmoegliche Makros pro 100 g werden "-" statt hochgerechnet', () {
      // 100 g of food cannot hold more than 100 g of one macro, and none can
      // be negative: a unit slip in the crowd-sourced record is not a
      // measurement, and scaled to the serving it reached the diary as 825 g
      // protein.
      final r = MealAnalysisResult.fromOpenFoodFacts(<String, dynamic>{
        'product_name': 'Proteinshake',
        'serving_quantity': 330,
        'nutriments': <String, dynamic>{
          'energy-kcal_100g': 60,
          'proteins_100g': 250,
          'carbohydrates_100g': -4,
          'fat_100g': 2,
        },
      }, '120');
      expect(r.protein, '-');
      expect(r.carbs, '-');
      expect(r.fat, '6,6 g', reason: 'ein plausibler Wert bleibt gerechnet');
      expect(r.caloriesKcal, 198);
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

  // Review 2026-08-19: the substring reference table turned 'Erdbeerkuchen'
  // into a strawberry, and reference density x default portion became
  // loggable calories.
  group('Referenzdichte erfindet keine Kalorien', () {
    test('Teilstring-Treffer ist weg: Erdbeerkuchen ist keine Erdbeere', () {
      // Before: 'erdbeerkuchen'.contains('erdbeer') -> 32 kcal/100 g times the
      // 150 g default portion -> 48 loggable kcal from a numberless answer.
      // The unknown form is 0 WITHOUT explicitZeroKcal; the log guards block
      // that with a hint.
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

  // Review 2026-08-19: `items[]` and `caloriesKcal` were unreconciled, so
  // merely confirming the components moved the meal.
  group('Postensumme und Gesamtwert werden abgeglichen', () {
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

  // Review 2026-08-19: the first gram figure in `explanation` counted as total
  // weight and even beat the item sum.
  group('Grammangabe aus dem Erklaertext', () {
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

  // Review 2026-08-19: `fromOpenFoodFacts` persisted a ready-made German
  // paragraph. It now persists a code; old rows must stay readable.
  group('OFF-Hinweis ist sprachneutral persistiert', () {
    final salami = MealAnalysisResult.fromOpenFoodFacts(const <String, dynamic>{
      'product_name': 'Die Ofenfrische Salami',
      'brands': 'Dr. Oetker',
      'quantity': '390 g',
      'serving_size': '100 g',
      'serving_quantity': 100,
      'nutriments': <String, dynamic>{'energy-kcal_100g': 252},
    }, '4001724012345');

    test('persistiert wird ein Code; Anzeige de wortgleich zur Bestandsfassung, '
        'en komplett englisch', () {
      expect(salami.portionNotes, startsWith('offProductNote:'));
      expect(salami.portionNotes, isNot(contains('Nährwerte')));
      expect(salami.resolvedPortionNotes(deL10n), _altzeileDe);
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

    test('Alt-Zeilen (deutscher Absatz, mit und ohne Marke/Packung/Portion) '
        'werden erkannt und uebersetzt', () {
      final alt = _mitNotiz(_altzeileDe);
      expect(alt.resolvedPortionNotes(enL10n), _altzeileEn);
      expect(alt.resolvedPortionNotes(deL10n), _altzeileDe);
      final kurz = _mitNotiz(
        'OpenFoodFacts Barcode 999. Nährwerte kommen aus der '
        'Produktdatenbank, nicht aus einer Foto-Schätzung. Du kannst das '
        'gegessene Gewicht weiter anpassen.',
      );
      expect(
        kurz.resolvedPortionNotes(enL10n),
        'Open Food Facts barcode 999. Nutrition values come from the product '
        'database, not from a photo estimate. You can still adjust the weight '
        'you ate.',
      );
    });

    test('Freitext und ein beschaedigter Code bleiben unveraendert stehen', () {
      const freitext = 'Ein halber Teller, geschätzt aus dem Foto.';
      expect(_mitNotiz(freitext).resolvedPortionNotes(enL10n), freitext);
      const kaputt = 'offProductNote:{nicht wirklich json';
      expect(_mitNotiz(kaputt).resolvedPortionNotes(enL10n), kaputt);
    });
  });
}
