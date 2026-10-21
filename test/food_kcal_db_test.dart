import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/food_kcal_db.dart';

// The local kcal table and `autoSplitItems`, which turns a scanned meal's
// totals into editable items.
//
// P2-05 (review 2026-08-29): a table row whose normalized form is not the row
// itself can never be hit — `_normalize` runs BEFORE the table is asked.
// 'gemischter salat' was exactly that: `_adjectiveStrip` removed 'gemischt'
// with its inflection ending, leaving 'salat'.
//
// P2-06: autoSplitItems preserves BOTH totals. Only the kcal sum used to be
// exact; the gram sum drifted by up to n/2 g through per-item rounding, so
// confirming the components sheet unchanged moved the portion.
//
// Audit 2026-08-14: without a usable total (0 is the documented unknown
// sentinel) the split used to fall back to factor 1.0 and invent items from
// the table's default portions, one tap from the diary.
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

  group('autoSplitItems', () {
    test('verteilt die Gesamtwerte nach den Tabellen-Verhaeltnissen', () {
      const teller = 'Steak mit Ofenkartoffeln und Tomate';
      final items = autoSplitItems(
        mealName: teller,
        totalGrams: 480,
        totalKcal: 800,
      );

      expect(items.map((c) => c.name), ['Steak', 'Ofenkartoffeln', 'Tomate']);
      // The table only supplies ratios: the steak outweighs the tomato, but no
      // item sits on its reference value.
      expect(items.first.caloriesKcal, greaterThan(items.last.caloriesKcal));
      for (final c in items) {
        // The derived density matches the item's own grams and kcal.
        expect(c.kcalPer100G, closeTo(c.caloriesKcal * 100 / c.grams, 0.001));
      }
    });

    // EXACT, not close: autoSplitItems spreads the rounding remainder over the
    // items (_spreadRemainder), so both totals land on the model's anchors. A
    // tolerance would wave a returning drift straight through. The finding's
    // example is in the matrix: 200 + 180 + 80 reference grams scaled to 100 g
    // rounded to 43 + 39 + 17 = 99 g.
    test('beide Summen stimmen ueber eine Matrix von Gesamtwerten (P2-06)', () {
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
            // A single item would hold both sums trivially.
            expect(
              items.length,
              greaterThan(1),
              reason: '$name / $g g / $k kcal',
            );
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

    test('ohne positive Gesamtwerte erfindet sie keine Posten', () {
      const teller = 'Steak mit Ofenkartoffeln und Tomate';
      for (final (grams, kcal) in const <(int, int)>[
        (480, 0), // the unknown sentinel
        (480, -1),
        (0, 800), // no anchor: the grams would be the table's defaults
        (-5, 800),
      ]) {
        expect(
          autoSplitItems(mealName: teller, totalGrams: grams, totalKcal: kcal),
          isEmpty,
          reason: '$grams g / $kcal kcal',
        );
      }
    });
  });
}
