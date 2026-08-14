import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/food_kcal_db.dart';

// Regression zum Audit-Befund 2026-08-14: liefert das Scan-Modell keinen
// brauchbaren Gesamtwert, steht in `caloriesKcal`/`estimatedGrams` die 0 als
// dokumentierter Unbekannt-Sentinel. `autoSplitItems` lief damit trotzdem
// durch, fiel auf Faktor 1.0 zurueck und erfand aus den Default-Portionen der
// lokalen Tabelle Posten (~230 kcal fuer einen realen 700-900-kcal-Teller).
// Die 0-kcal-Sperre im Sheet blockiert nur das direkte Speichern — im
// "Anpassen"-Dialog standen die erfundenen Posten bereits vorbelegt und
// wanderten mit einem Tap ins Tagebuch.
void main() {
  // Ein Name, der sicher in >= 2 Posten zerfaellt und in der lokalen Tabelle
  // steht — ohne die Sperre lieferte er die ungeskalierten Referenzwerte.
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
      // Ohne Anker waeren die Gramm-Angaben reine Default-Portionen der
      // Tabelle und die daraus abgeleitete Dichte damit frei erfunden.
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
      // Rundung pro Posten -> Summen nahe an den Zielwerten der KI.
      expect(kcalSum, closeTo(800, 3));
      expect(gramSum, closeTo(480, 3));

      // Die Tabelle liefert nur die Verhaeltnisse: das Steak traegt mehr als
      // die Tomate, aber kein Posten steht auf seinem Referenzwert.
      expect(items.first.caloriesKcal, greaterThan(items.last.caloriesKcal));
      for (final c in items) {
        expect(c.caloriesKcal, greaterThan(0));
        expect(c.grams, greaterThan(0));
      }
    });
  });
}
