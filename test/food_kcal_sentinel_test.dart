import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/food_kcal_db.dart';

// Regression (audit 2026-08-14): when the scan model has no usable total, 0 is
// the documented unknown sentinel. autoSplitItems used to run anyway, fall
// back to factor 1.0 and invent items from the local table's default portions.
// The 0 kcal block in the sheet only stops direct saving; the adjust dialog
// showed the invented items pre-filled, one tap from the diary.
void main() {
  // A name that reliably splits into >= 2 items and exists in the local table;
  // without the guard it returned the unscaled reference values.
  const teller = 'Steak mit Ofenkartoffeln und Tomate';

  group('autoSplitItems erfindet nichts ohne Gesamtwert', () {
    test('totalKcal == 0 (Unbekannt-Sentinel) liefert keine Posten', () {
      expect(
        autoSplitItems(mealName: teller, totalGrams: 480, totalKcal: 0),
        isEmpty,
      );
    });

    test('negativer totalKcal liefert ebenfalls keine Posten', () {
      expect(
        autoSplitItems(mealName: teller, totalGrams: 480, totalKcal: -1),
        isEmpty,
      );
    });

    test('fehlendes Gesamtgewicht liefert keine Posten', () {
      // Without an anchor the grams would be the table's default portions and
      // the derived density pure invention.
      expect(
        autoSplitItems(mealName: teller, totalGrams: 0, totalKcal: 800),
        isEmpty,
      );
      expect(
        autoSplitItems(mealName: teller, totalGrams: -5, totalKcal: 800),
        isEmpty,
      );
    });
  });

  group('Normalfall bleibt unveraendert', () {
    test('gueltige Gesamtwerte liefern korrekt skalierte Posten', () {
      final items = autoSplitItems(
        mealName: teller,
        totalGrams: 480,
        totalKcal: 800,
      );

      expect(items.length, 3);
      expect(items.map((c) => c.name), ['Steak', 'Ofenkartoffeln', 'Tomate']);

      final kcalSum = items.fold<int>(0, (s, c) => s + c.caloriesKcal);
      final gramSum = items.fold<int>(0, (s, c) => s + c.grams);
      // Per-item rounding keeps the sums close to the model's targets.
      expect(kcalSum, closeTo(800, 3));
      expect(gramSum, closeTo(480, 3));

      // The table only supplies ratios: the steak outweighs the tomato, but no
      // item sits on its reference value.
      expect(items.first.caloriesKcal, greaterThan(items.last.caloriesKcal));
      for (final c in items) {
        expect(c.caloriesKcal, greaterThan(0));
        expect(c.grams, greaterThan(0));
      }
    });
  });
}
