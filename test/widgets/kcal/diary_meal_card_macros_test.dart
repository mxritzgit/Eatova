import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/kcal/diary_meal_card.dart';

import '../../support/harness.dart';

// ---------------------------------------------------------------------------
// Macros per slot and per meal in the food tab's slot card.
//
// Slot header and each history row carry their own P/C/F line, both from
// `MacroProgress` and the ARB key `foodMacroSummary`.
//
// The width measurements run with the REAL app fonts: the headless renderer's
// test font is about twice as wide and would falsify any "fits an iPhone"
// claim (see a11y_controls_test.dart).
// ---------------------------------------------------------------------------

/// Logical width of an iPhone 12/13/14: the narrowest the card must fit.
const double _breite = 390;

/// Exactly the shape of `foodMacroSummary`, so the finder picks up neither
/// the kcal line nor the slot line.
final RegExp _makroZeile = RegExp(r'^P \d+ g · [KC] \d+ g · F \d+ g$');

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double textScale = 1.0,
  Locale locale = const Locale('de'),
}) async {
  tester.view.physicalSize = const Size(_breite * 3, 844 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await pumpLocalized(
    tester,
    child,
    locale: locale,
    textScale: textScale,
    // Same 20/12 padding as the food tab in EatovaHomePage.
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
  );
  await tester.pump();
}

MealAnalysisResult _ergebnis({
  required String name,
  required int kcal,
  required int gramm,
  required String protein,
  required String carbs,
  required String fat,
}) => MealAnalysisResult(
  mealName: name,
  caloriesKcal: kcal,
  estimatedGrams: gramm,
  kcalPer100G: gramm == 0 ? 0 : kcal * 100 / gramm,
  protein: protein,
  carbs: carbs,
  fat: fat,
  confidence: 'high',
  portionNotes: '',
);

/// Two entries with known macros; the second mixes comma and dot decimals,
/// which `MacroProgress` both read. Rows round per meal, the header the SUM.
final MealAnalysisResult _haferbrei = _ergebnis(
  name: 'Haferbrei',
  kcal: 320,
  gramm: 250,
  protein: '12 g',
  carbs: '48 g',
  fat: '6 g',
);

final MealAnalysisResult _quark = _ergebnis(
  name: 'Magerquark mit Beeren',
  kcal: 210,
  gramm: 1200,
  protein: '30,4 g',
  carbs: '10.6 g',
  fat: '20 g',
);

LoggedMeal _mahlzeit(String id, MealAnalysisResult result, MealSlot slot) =>
    LoggedMeal(
      id: id,
      result: result,
      loggedAt: DateTime(2026, 8, 21, 12, 30),
      forcedSlot: slot,
    );

/// Two lunch entries: the longest German slot name, the tightest width case.
DiaryMealCard _karteMitZweiEintraegen({ValueChanged<MealSlot>? onAddToSlot}) =>
    DiaryMealCard(
      slot: MealSlot.lunch,
      entries: <DiaryEntry>[
        DiaryEntry(_mahlzeit('m1', _haferbrei, MealSlot.lunch), 0),
        DiaryEntry(_mahlzeit('m2', _quark, MealSlot.lunch), 1),
      ],
      onAddToSlot: onAddToSlot ?? (_) {},
      onRemoveMeal: (_) {},
    );

/// All macro lines of the card in tree order, header first.
List<String> _makroZeilen(WidgetTester tester) => tester
    .widgetList<Text>(find.textContaining(_makroZeile))
    .map((t) => t.data!)
    .toList(growable: false);

void main() {
  setUpAll(() async {
    final archivo = FontLoader('Archivo');
    for (final datei in const <String>[
      'assets/fonts/Archivo-Regular.ttf',
      'assets/fonts/Archivo-Medium.ttf',
      'assets/fonts/Archivo-SemiBold.ttf',
      'assets/fonts/Archivo-Bold.ttf',
    ]) {
      archivo.addFont(
        File(datei).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
    }
    final bricolage = FontLoader('BricolageGrotesque');
    for (final datei in const <String>[
      'assets/fonts/BricolageGrotesque-Bold.ttf',
      'assets/fonts/BricolageGrotesque-ExtraBold.ttf',
    ]) {
      bricolage.addFont(
        File(datei).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
    }
    await Future.wait(<Future<void>>[archivo.load(), bricolage.load()]);
  });

  group('DiaryMealCard — Makros', () {
    testWidgets('der Slot-Kopf summiert P/K/F ueber alle Eintraege, jede '
        'Zeile zeigt ihre eigenen Makros', (tester) async {
      await _pump(tester, _karteMitZweiEintraegen());

      // The existing totals line is unchanged (other tests read it).
      expect(find.text('530 kcal · 2 Einträge'), findsOneWidget);

      expect(_makroZeilen(tester), <String>[
        'P 42 g · K 59 g · F 26 g', // slot header: sum 42.4 / 58.6 / 26
        'P 12 g · K 48 g · F 6 g', // Haferbrei
        'P 30 g · K 11 g · F 20 g', // Quark: 30.4 / 10.6 / 20
      ]);

      // The "slot · amount" line stays its own Text widget with an unchanged
      // format; edit_meal_sheet_test reads exactly that.
      expect(find.text('Mittagessen · ~250 g'), findsOneWidget);
      expect(find.text('Mittagessen · ~1200 g'), findsOneWidget);
    });

    testWidgets('auf Englisch steht C statt K', (tester) async {
      await _pump(
        tester,
        _karteMitZweiEintraegen(),
        locale: const Locale('en'),
      );

      expect(find.text('530 kcal · 2 entries'), findsOneWidget);
      expect(_makroZeilen(tester), <String>[
        'P 42 g · C 59 g · F 26 g',
        'P 12 g · C 48 g · F 6 g',
        'P 30 g · C 11 g · F 20 g',
      ]);
    });

    testWidgets('eine leere Karte zeigt keine Makro-Zeile', (tester) async {
      await _pump(
        tester,
        DiaryMealCard(
          slot: MealSlot.dinner,
          entries: const <DiaryEntry>[],
          onAddToSlot: (_) {},
        ),
      );

      expect(find.textContaining(_makroZeile), findsNothing);
      expect(
        find.byKey(const ValueKey('food-slot-empty-dinner')),
        findsOneWidget,
      );
    });

    testWidgets('ein Eintrag ohne lesbare Makros: Kopf zeigt 0 g, die Zeile '
        'blendet ihre Makros aus', (tester) async {
      await _pump(
        tester,
        DiaryMealCard(
          slot: MealSlot.snack,
          entries: <DiaryEntry>[
            DiaryEntry(
              _mahlzeit(
                's1',
                _ergebnis(
                  name: 'Unbekannt',
                  kcal: 100,
                  gramm: 0,
                  protein: '',
                  carbs: 'n/a',
                  fat: '?',
                ),
                MealSlot.snack,
              ),
              0,
            ),
          ],
        ),
      );

      // Only the header sum (0 is 0, like the day rings); a row hides unknown
      // macros so a zero never looks like a measurement.
      expect(_makroZeilen(tester), <String>['P 0 g · K 0 g · F 0 g']);
    });

    for (final scale in const <double>[1.0, 1.3]) {
      testWidgets(
        'bei 390 pt und Textskalierung $scale passt jede Makro-Zeile ohne '
        'Overflow und ohne Abschneiden',
        (tester) async {
          await _pump(tester, _karteMitZweiEintraegen(), textScale: scale);

          // No RenderFlex overflow; explicit so the assertion reads.
          expect(tester.takeException(), isNull);

          final zeilen = find.textContaining(_makroZeile);
          expect(zeilen, findsNWidgets(3));
          for (final element in zeilen.evaluate()) {
            final paragraph = element.findRenderObject()! as RenderParagraph;
            expect(
              paragraph.didExceedMaxLines,
              isFalse,
              reason:
                  '„${(element.widget as Text).data}" wird bei Skalierung '
                  '$scale abgeschnitten (Breite ${paragraph.size.width})',
            );
          }
          // The slot line must not be clipped by its new neighbour either.
          final slotZeile = tester.renderObject<RenderParagraph>(
            find.text('Mittagessen · ~1200 g'),
          );
          expect(slotZeile.didExceedMaxLines, isFalse);
        },
      );
    }
  });
}
