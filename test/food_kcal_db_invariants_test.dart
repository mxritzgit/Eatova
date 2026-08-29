import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/food_kcal_db.dart';

// Review 2026-08-29, P2-05 and P2-06.
//
// P2-05: a table row whose normalized form is not the row itself can never be
// hit — `_normalize` runs BEFORE the table is asked, so the key the lookup
// searches for is a different string than the one that was written down.
// 'gemischter salat' was exactly that: `_adjectiveStrip` removed 'gemischt'
// with its inflection ending, leaving 'salat'.
//
// P2-06: autoSplitItems documents that it preserves BOTH totals. Only the kcal
// sum was made exact; the gram sum drifted by up to n/2 g through per-item
// rounding. Confirming the components sheet unchanged then moved the portion
// (and with it the density the user had just seen).
void main() {
  group('Tabelle: jede Zeile ist erreichbar (P2-05)', () {
    test('jeder Schluessel normalisiert auf sich selbst', () {
      final abweichend = <String, String>{
        for (final key in foodDbEntries.keys)
          if (normalizeFoodName(key) != key) key: normalizeFoodName(key),
      };
      expect(
        abweichend,
        isEmpty,
        reason:
            'Diese Schluessel werden vor der Abfrage umgeschrieben und sind '
            'damit tote Tabellenzeilen: $abweichend',
      );
    });

    test('jeder Schluessel findet ueber _lookup genau seinen eigenen Eintrag',
        () {
      final falsch = <String, FoodEntry>{};
      for (final entry in foodDbEntries.entries) {
        final treffer = lookupFoodEntry(entry.key);
        if (treffer != entry.value) {
          falsch[entry.key] = treffer;
        }
      }
      expect(
        falsch,
        isEmpty,
        reason: 'Zeilen, die einen fremden Eintrag zurueckgeben: $falsch',
      );
    });

    test('Salat bleibt als Referenz erhalten, egal wie er flektiert ankommt',
        () {
      // German declension is the reason a two-word key with an adjective can
      // never be a reliable entry: the model writes 'gemischtem' just as often
      // as 'gemischter'. The adjective strip is what makes them converge.
      const salat = (kcalPer100G: 15.0, defaultGrams: 80);
      expect(lookupFoodEntry('Salat'), salat);
      expect(lookupFoodEntry('gemischter Salat'), salat);
      expect(lookupFoodEntry('gemischtem Salat'), salat);
      expect(lookupFoodEntry('gemischten Salat'), salat);
    });
  });

  group('autoSplitItems haelt beide Summen ein (P2-06)', () {
    // The example from the finding: reference grams 200 + 180 + 80 = 460,
    // gramFactor 0.217391 -> 43.478 / 39.130 / 17.391 -> 43 + 39 + 17 = 99 g.
    test('kleines Gesamtgewicht rundet nicht unter den Zielwert', () {
      final items = autoSplitItems(
        mealName: 'Steak mit Reis und Salat',
        totalGrams: 100,
        totalKcal: 300,
      );
      expect(items.length, 3);
      expect(items.fold<int>(0, (s, c) => s + c.grams), 100);
      expect(items.fold<int>(0, (s, c) => s + c.caloriesKcal), 300);
      for (final c in items) {
        expect(c.grams, greaterThan(0));
      }
    });

    test('Gegenprobe: der Fall ohne Drift bleibt exakt', () {
      final items = autoSplitItems(
        mealName: 'Steak mit Reis und Salat',
        totalGrams: 500,
        totalKcal: 800,
      );
      expect(items.fold<int>(0, (s, c) => s + c.grams), 500);
      expect(items.fold<int>(0, (s, c) => s + c.caloriesKcal), 800);
    });

    test('beide Summen stimmen ueber eine Matrix von Gesamtwerten', () {
      const namen = <String>[
        'Steak mit Reis und Salat',
        'Hähnchen mit Reis und Brokkoli',
        'Steak mit Ofenkartoffeln und Tomate',
        'Lachs mit Kartoffeln, Brokkoli und Sauce',
        'Nudeln mit Pesto',
      ];
      const gramm = <int>[47, 100, 233, 400, 480, 617, 1000];
      const kcal = <int>[63, 300, 512, 800, 1234, 2000];

      for (final name in namen) {
        for (final g in gramm) {
          for (final k in kcal) {
            final items = autoSplitItems(
              mealName: name,
              totalGrams: g,
              totalKcal: k,
            );
            expect(items, isNotEmpty, reason: '$name / $g g / $k kcal');
            expect(
              items.fold<int>(0, (s, c) => s + c.grams),
              g,
              reason: 'Gramm-Summe bei $name / $g g / $k kcal',
            );
            expect(
              items.fold<int>(0, (s, c) => s + c.caloriesKcal),
              k,
              reason: 'kcal-Summe bei $name / $g g / $k kcal',
            );
            for (final c in items) {
              expect(c.grams, greaterThan(0), reason: '$name / $g g');
            }
          }
        }
      }
    });

    test('die abgeleitete Dichte passt zu Gramm und kcal des Postens', () {
      final items = autoSplitItems(
        mealName: 'Steak mit Reis und Salat',
        totalGrams: 100,
        totalKcal: 300,
      );
      for (final c in items) {
        expect(c.kcalPer100G, closeTo(c.caloriesKcal * 100 / c.grams, 0.001));
      }
    });
  });
}
