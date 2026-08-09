import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/kcal/edit_meal_sheet.dart';

// B5: Sommerzeit-Umstellung ueberspringt einen Tag — die Stelle im
// Bearbeiten-Sheet (edit_meal_sheet.dart:514 bzw. :504 vor dem Fix).
//
// Frueher:
//   [for (var i = 0; i < pastDays; i++) today.subtract(Duration(days: i))]
//   final offset = today.difference(date).inDays;
//
// `Duration` ist Absolutzeit. Am Montag 30.03.2026 in Europe/Berlin
// (Fruehjahrsumstellung am Sonntag 29.03., ein 23-Stunden-Tag) liefert
// `DateTime(2026, 3, 30).subtract(Duration(days: 1))` den `2026-03-28 23:00`:
// der Sonntag war aus dem 35-Chip-Fenster NICHT erreichbar, und der Chip
// „Gestern" trug den 28.03. Wer eine Mahlzeit bewusst auf Sonntag schob,
// landete dauerhaft auf Samstag — serverseitig ueber `local_day`.
//
// ── Warum dieser Test auf einer UTC-Maschine nicht falsch rot wird ──────────
//
// `flutter test` laeuft in der Zone der Maschine; die CI steht auf UTC, wo es
// gar keine Umstellung gibt. Technik uebernommen aus test/services/
// day_math_test.dart:
//
//   1. Alle Assertions laufen auf (Jahr, Monat, Tag)-Tripeln — zonenunabhaengig.
//   2. Die Soll-Werte kommen aus einem UTC-Orakel bzw. sind hart notiert; beides
//      ist in JEDER Zone wahr.
//   3. Der eine DST-abhaengige Beleg steht unter `if (naiv.day != 29)` und
//      feuert auf UTC schlicht nicht.
//   4. Zusaetzlich pruefen zwei Faelle Eigenschaften, die die alte
//      Duration-/difference-Fassung in JEDER Zone verletzt (nicht normalisierte
//      Uhrzeit, Differenz ueber Mitternacht) — die bleiben auch auf der CI
//      aussagekraeftig.

/// Kurzform fuer Kalender-Assertions: nur (Jahr, Monat, Tag) zaehlen.
({int y, int m, int d}) ymd(DateTime value) =>
    (y: value.year, m: value.month, d: value.day);

/// Der Wert von `_EditMealSheetState._pickerDays`.
const int pickerDays = 35;

void main() {
  group('editMealPickerDays — die 35 Chips des Tag-Pickers', () {
    test('liefert GENAU count Eintraege, heute zuerst', () {
      final tage = editMealPickerDays(
        today: DateTime(2026, 3, 30),
        count: pickerDays,
      );
      // Die Off-by-one-Falle aus Welle 1: `dayStrip(pastDays: count).reversed`
      // haette 36 Eintraege, `dayStrip(pastDays: count - 1).reversed` waere
      // korrekt — aber leicht falsch abgeschrieben. recentDaysDescending nimmt
      // die ANZAHL und kann sich gar nicht erst verzaehlen.
      expect(tage.length, pickerDays);
      expect(ymd(tage.first), (y: 2026, m: 3, d: 30));
      expect(ymd(tage.last), (y: 2026, m: 2, d: 24));
    });

    test(
      'Fruehjahrsumstellung: der 29.03.2026 ist erreichbar und liegt auf Index 1',
      () {
        // Der dokumentierte Fehler, als Beleg. Nur auf einer Maschine in einer
        // Zone MIT Umstellung am 29.03.2026 (z. B. Europe/Berlin) rutscht die
        // Duration-Subtraktion auf den 28.03. um 23:00; auf UTC gibt es hier
        // nichts zu belegen und der Block laeuft nicht an.
        final naiv = DateTime(2026, 3, 30).subtract(const Duration(days: 1));
        if (naiv.day != 29) {
          expect(
            ymd(naiv),
            (y: 2026, m: 3, d: 28),
            reason: 'Duration-Subtraktion verliert hier den 29.03.',
          );
          expect(naiv.hour, 23);
        }

        // Das gilt in JEDER Zone:
        final tage = editMealPickerDays(
          today: DateTime(2026, 3, 30),
          count: pickerDays,
        );
        expect(ymd(tage[0]), (y: 2026, m: 3, d: 30));
        expect(ymd(tage[1]), (y: 2026, m: 3, d: 29)); // der verschluckte Tag
        expect(ymd(tage[2]), (y: 2026, m: 3, d: 28));
        expect(
          tage.map(ymd),
          contains((y: 2026, m: 3, d: 29)),
          reason: 'Sonntag muss aus dem Picker heraus waehlbar sein',
        );
      },
    );

    test('Herbstumstellung (25-Stunden-Tag) laeuft ebenso sauber', () {
      final tage = editMealPickerDays(
        today: DateTime(2026, 10, 26),
        count: 4,
      );
      expect(tage.map(ymd).toList(), [
        (y: 2026, m: 10, d: 26),
        (y: 2026, m: 10, d: 25),
        (y: 2026, m: 10, d: 24),
        (y: 2026, m: 10, d: 23),
      ]);
    });

    test('jeder Eintrag ist auf den Tagesbeginn normalisiert', () {
      // Zonenunabhaengig rot fuer die Altfassung: `today.subtract(...)` traegt
      // die Uhrzeit von `today` weiter. Der Wert wandert ueber onSelected in
      // `_day` und von dort in `local_day`.
      for (final tag in editMealPickerDays(
        today: DateTime(2026, 6, 10, 23, 30, 15),
        count: 7,
      )) {
        expect(startOfDay(tag), tag);
        expect(tag.isUtc, isFalse);
      }
    });

    test('das 35-Tage-Fenster ist lueckenlos und doppelfrei — fuer JEDEN Anker '
        'eines Jahres', () {
      var cursor = DateTime.utc(2026, 1, 1);
      final ende = DateTime.utc(2026, 12, 31);
      while (!cursor.isAfter(ende)) {
        final anker = DateTime(cursor.year, cursor.month, cursor.day);
        final tage = editMealPickerDays(today: anker, count: pickerDays);
        expect(tage.length, pickerDays, reason: 'falsche Chip-Zahl bei $anker');
        expect(ymd(tage.first), ymd(anker));
        for (var i = 1; i < tage.length; i++) {
          expect(
            daysBetween(tage[i - 1], tage[i]),
            1,
            reason: 'Luecke oder Dopplung zwischen Chip ${i - 1} und $i '
                'im Fenster ab $anker',
          );
        }
        cursor = cursor.add(const Duration(days: 1));
      }
    });

    test('trifft ueber 2024..2030 hinweg immer das UTC-Orakel', () {
      // UTC kennt keine Sommerzeit: dort IST `add(Duration(days: -i))` die
      // Kalenderverschiebung. Genau dieses (y, m, d) muss der Picker lokal
      // ebenfalls treffen.
      var cursor = DateTime.utc(2024, 1, 1);
      final ende = DateTime.utc(2030, 12, 31);
      var geprueft = 0;
      while (!cursor.isAfter(ende)) {
        final tage = editMealPickerDays(
          today: DateTime(cursor.year, cursor.month, cursor.day),
          count: 7,
        );
        for (var i = 0; i < tage.length; i++) {
          expect(ymd(tage[i]), ymd(cursor.add(Duration(days: -i))));
          geprueft++;
        }
        cursor = cursor.add(const Duration(days: 1));
      }
      expect(geprueft, greaterThan(15000));
    });

    test('ein ausgewaehlter Tag ausserhalb des Fensters haengt hinten an', () {
      final tage = editMealPickerDays(
        today: DateTime(2026, 3, 30),
        count: pickerDays,
        selected: DateTime(2025, 12, 24, 18, 30),
      );
      expect(tage.length, pickerDays + 1);
      expect(ymd(tage.last), (y: 2025, m: 12, d: 24));
      expect(startOfDay(tage.last), tage.last);
    });

    test('ein ausgewaehlter Tag INNERHALB des Fensters wird nicht gedoppelt', () {
      // Genau die Stelle, an der der alte Bug doppelt zuschlug: der 29.03. war
      // nicht in der Liste, also haette ihn dieser Zweig als 36. Chip ans Ende
      // gehaengt — hinter den 24.02.
      final tage = editMealPickerDays(
        today: DateTime(2026, 3, 30),
        count: pickerDays,
        selected: DateTime(2026, 3, 29),
      );
      expect(tage.length, pickerDays);
      expect(
        tage.where((t) => ymd(t) == (y: 2026, m: 3, d: 29)).length,
        1,
      );
    });

    test('count <= 0 liefert nur den ggf. gewaehlten Tag', () {
      expect(editMealPickerDays(today: DateTime(2026, 3, 30), count: 0), isEmpty);
      expect(
        editMealPickerDays(
          today: DateTime(2026, 3, 30),
          count: 0,
          selected: DateTime(2026, 3, 1),
        ).map(ymd).toList(),
        [(y: 2026, m: 3, d: 1)],
      );
    });
  });

  group('editMealDayChipLabel — „Heute" / „Gestern" / Wochentag', () {
    test('Fruehjahrsumstellung: der Vortag heisst „Gestern", nicht „Heute"', () {
      final naiv = DateTime(2026, 3, 30).difference(DateTime(2026, 3, 29));
      if (naiv.inDays != 1) {
        // Beleg, nur in einer Zone mit Umstellung: 23 Stunden -> inDays == 0.
        expect(naiv.inHours, 23);
        expect(naiv.inDays, 0);
      }

      expect(
        editMealDayChipLabel(
          today: DateTime(2026, 3, 30),
          date: DateTime(2026, 3, 30),
        ),
        'Heute',
      );
      expect(
        editMealDayChipLabel(
          today: DateTime(2026, 3, 30),
          date: DateTime(2026, 3, 29),
        ),
        'Gestern',
      );
      // Zwei Tage zurueck = Samstag, nicht mehr „Gestern".
      expect(
        editMealDayChipLabel(
          today: DateTime(2026, 3, 30),
          date: DateTime(2026, 3, 28),
        ),
        'Sa',
      );
    });

    test('Wochentagskuerzel treffen den richtigen Tag', () {
      // 30.03.2026 ist ein Montag; Anker ist Mittwoch der Folgewoche, damit
      // kein Tag in den „Heute"/„Gestern"-Nahbereich faellt.
      expect(DateTime(2026, 3, 30).weekday, DateTime.monday);
      final today = DateTime(2026, 4, 8);
      expect(editMealDayChipLabel(today: today, date: DateTime(2026, 3, 30)),
          'Mo');
      expect(
          editMealDayChipLabel(today: today, date: DateTime(2026, 4, 5)), 'So');
      expect(
          editMealDayChipLabel(today: today, date: DateTime(2026, 4, 4)), 'Sa');
      expect(
          editMealDayChipLabel(today: today, date: DateTime(2026, 4, 3)), 'Fr');
    });

    test('Uhrzeiten kippen die Beschriftung nicht (Minuten um Mitternacht)', () {
      // Zonenunabhaengig rot fuer die Altfassung: 10 Minuten Differenz ergeben
      // `inDays == 0` und damit „Heute" fuer den Vortag.
      expect(
        editMealDayChipLabel(
          today: DateTime(2026, 6, 10, 0, 5),
          date: DateTime(2026, 6, 9, 23, 55),
        ),
        'Gestern',
      );
      expect(
        editMealDayChipLabel(
          today: DateTime(2026, 6, 10, 23, 55),
          date: DateTime(2026, 6, 10, 0, 5),
        ),
        'Heute',
      );
    });

    test('jeder Chip eines 35-Tage-Fensters ueber der Umstellung ist korrekt '
        'beschriftet', () {
      final today = DateTime(2026, 3, 30);
      final tage = editMealPickerDays(today: today, count: pickerDays);
      expect(editMealDayChipLabel(today: today, date: tage[0]), 'Heute');
      expect(editMealDayChipLabel(today: today, date: tage[1]), 'Gestern');
      for (var i = 2; i < tage.length; i++) {
        expect(
          editMealDayChipLabel(today: today, date: tage[i]),
          isNot(anyOf('Heute', 'Gestern')),
          reason: 'Chip $i (${ymd(tage[i])}) traegt eine Nahbereichs-Label',
        );
      }
    });
  });

  group('Widget-Verdrahtung des Pickers', () {
    testWidgets('die sichtbaren Chips tragen die Kalendertage ab heute', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1179, 2556);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final today = startOfDay(DateTime.now());
      final erwartet = editMealPickerDays(today: today, count: pickerDays);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildEatovaTheme(Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showEditMealSheet(
                    context,
                    meal: _loggedMeal(),
                    onUpdateMeal: (
                      id, {
                      result,
                      slot,
                      day,
                    }) => null,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Nur die im Viewport gebauten Chips pruefen — der ListView baut den
      // Rest gar nicht.
      for (var i = 0; i < 4; i++) {
        final chip = find.byKey(ValueKey('edit-day-chip-$i'));
        expect(chip, findsOneWidget, reason: 'Chip $i fehlt');
        expect(
          find.descendant(
            of: chip,
            matching: find.text('${erwartet[i].day}.${erwartet[i].month}.'),
          ),
          findsOneWidget,
          reason: 'Chip $i traegt nicht ${ymd(erwartet[i])}',
        );
      }
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('edit-day-chip-0')),
          matching: find.text('Heute'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('edit-day-chip-1')),
          matching: find.text('Gestern'),
        ),
        findsOneWidget,
      );
    });
  });
}

LoggedMeal _loggedMeal() => LoggedMeal(
      id: 'meal-1',
      result: const MealAnalysisResult(
        mealName: 'Test-Bowl',
        caloriesKcal: 350,
        estimatedGrams: 350,
        kcalPer100G: 100,
        protein: '30 g',
        carbs: '40 g',
        fat: '10 g',
        confidence: 'Hoch',
        portionNotes: 'Test.',
        sourceLabel: 'Foto-KI',
      ),
      loggedAt: DateTime.now(),
      forcedSlot: MealSlot.breakfast,
    );
