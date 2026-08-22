import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/kcal/edit_meal_sheet.dart';

final AppLocalizations _de = lookupAppLocalizations(const Locale('de'));

// B5: the DST switch skipped a day in the edit sheet's day picker.
//
// `Duration` is absolute time: on 2026-03-30 in Europe/Berlin (23-hour Sunday)
// `DateTime(2026, 3, 30).subtract(Duration(days: 1))` yields 2026-03-28 23:00,
// so Sunday was unreachable and the "yesterday" chip carried the 28th.
//
// Why this test is not falsely red on a UTC machine (CI): all assertions use
// (year, month, day) triples, expectations come from a UTC oracle or are
// hardcoded, the one DST-dependent proof sits behind `if (naiv.day != 29)`, and
// two cases check properties the old version violated in EVERY zone.

/// Shorthand for calendar assertions: only (year, month, day) count.
({int y, int m, int d}) ymd(DateTime value) =>
    (y: value.year, m: value.month, d: value.day);

/// The value of `_EditMealSheetState._pickerDays`.
const int pickerDays = 35;

void main() {
  group('editMealPickerDays — die 35 Chips des Tag-Pickers', () {
    test('liefert GENAU count Eintraege, heute zuerst', () {
      final tage = editMealPickerDays(
        today: DateTime(2026, 3, 30),
        count: pickerDays,
      );
      // Off-by-one trap: `dayStrip(pastDays: count).reversed` would give 36
      // entries. recentDaysDescending takes the COUNT and cannot miscount.
      expect(tage.length, pickerDays);
      expect(ymd(tage.first), (y: 2026, m: 3, d: 30));
      expect(ymd(tage.last), (y: 2026, m: 2, d: 24));
    });

    test(
      'Fruehjahrsumstellung: der 29.03.2026 ist erreichbar und liegt auf Index 1',
      () {
        // The documented bug as proof. Only in a zone WITH a switch on
        // 2026-03-29 does the Duration subtraction slip to 03-28 23:00; on UTC
        // this block does not run.
        final naiv = DateTime(2026, 3, 30).subtract(const Duration(days: 1));
        if (naiv.day != 29) {
          expect(
            ymd(naiv),
            (y: 2026, m: 3, d: 28),
            reason: 'Duration-Subtraktion verliert hier den 29.03.',
          );
          expect(naiv.hour, 23);
        }

        // True in EVERY zone:
        final tage = editMealPickerDays(
          today: DateTime(2026, 3, 30),
          count: pickerDays,
        );
        expect(ymd(tage[0]), (y: 2026, m: 3, d: 30));
        expect(ymd(tage[1]), (y: 2026, m: 3, d: 29)); // the swallowed day
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
      // Red for the old version in every zone: `today.subtract(...)` carries
      // the time of day along, and that value ends up in `local_day`.
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
      // UTC has no DST, so there `add(Duration(days: -i))` IS the calendar
      // shift; the picker must hit the same (y, m, d) locally.
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
      // Where the old bug struck twice: the 29th was missing from the list, so
      // this branch would have appended it as a 36th chip at the end.
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
        // Proof, only in a zone with a switch: 23 hours -> inDays == 0.
        expect(naiv.inHours, 23);
        expect(naiv.inDays, 0);
      }

      expect(
        editMealDayChipLabel(
          today: DateTime(2026, 3, 30),
          date: DateTime(2026, 3, 30),
          l10n: _de,
        ),
        'Heute',
      );
      expect(
        editMealDayChipLabel(
          today: DateTime(2026, 3, 30),
          date: DateTime(2026, 3, 29),
          l10n: _de,
        ),
        'Gestern',
      );
      // Two days back is Saturday, no longer "yesterday".
      expect(
        editMealDayChipLabel(
          today: DateTime(2026, 3, 30),
          date: DateTime(2026, 3, 28),
          l10n: _de,
        ),
        'Sa',
      );
    });

    test('Wochentagskuerzel treffen den richtigen Tag', () {
      // 2026-03-30 is a Monday; the anchor is the following Wednesday so no day
      // falls into the today/yesterday range.
      expect(DateTime(2026, 3, 30).weekday, DateTime.monday);
      final today = DateTime(2026, 4, 8);
      expect(
          editMealDayChipLabel(
              today: today, date: DateTime(2026, 3, 30), l10n: _de),
          'Mo');
      expect(
          editMealDayChipLabel(
              today: today, date: DateTime(2026, 4, 5), l10n: _de),
          'So');
      expect(
          editMealDayChipLabel(
              today: today, date: DateTime(2026, 4, 4), l10n: _de),
          'Sa');
      expect(
          editMealDayChipLabel(
              today: today, date: DateTime(2026, 4, 3), l10n: _de),
          'Fr');
    });

    test('Uhrzeiten kippen die Beschriftung nicht (Minuten um Mitternacht)', () {
      // Red for the old version in every zone: a 10-minute difference gives
      // `inDays == 0` and thus "today" for the previous day.
      expect(
        editMealDayChipLabel(
          today: DateTime(2026, 6, 10, 0, 5),
          date: DateTime(2026, 6, 9, 23, 55),
          l10n: _de,
        ),
        'Gestern',
      );
      expect(
        editMealDayChipLabel(
          today: DateTime(2026, 6, 10, 23, 55),
          date: DateTime(2026, 6, 10, 0, 5),
          l10n: _de,
        ),
        'Heute',
      );
    });

    test('jeder Chip eines 35-Tage-Fensters ueber der Umstellung ist korrekt '
        'beschriftet', () {
      final today = DateTime(2026, 3, 30);
      final tage = editMealPickerDays(today: today, count: pickerDays);
      expect(
          editMealDayChipLabel(today: today, date: tage[0], l10n: _de),
          'Heute');
      expect(
          editMealDayChipLabel(today: today, date: tage[1], l10n: _de),
          'Gestern');
      for (var i = 2; i < tage.length; i++) {
        expect(
          editMealDayChipLabel(today: today, date: tage[i], l10n: _de),
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
          // EditMealSheet reads context.l10n.
          locale: const Locale('de'),
          supportedLocales: const [Locale('de'), Locale('en')],
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
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

      // Only check chips built in the viewport; the ListView skips the rest.
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
