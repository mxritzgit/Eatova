import '../../support/food_navigation.dart';

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
// Tapping the slot header opens the macro details: a P/C/F line for the slot
// and one per history row, both from `MacroProgress` and the ARB key
// `foodMacroSummary` (`expandFoodEntries` opens them).
//
// The width measurements run with the REAL app fonts: the headless renderer's
// test font is about twice as wide and would falsify any "fits an iPhone"
// claim (see a11y_controls_test.dart).
// ---------------------------------------------------------------------------

/// Logical width of an iPhone 12/13/14: the narrowest the card must fit.
const double _breite = 390;

/// Exactly the shape of `foodMacroSummary`, so the finder picks up neither
/// the kcal line nor the slot line.
final RegExp _makroZeile = RegExp(
  r'^P\u00a0\d+\u00a0g\u00a0· [KC]\u00a0\d+\u00a0g\u00a0· F\u00a0\d+\u00a0g$',
);

/// `foodMacroSummary` as rendered: no-break spaces hold each token ("P 41 g")
/// together, so a narrow line breaks only after a ' · ' separator.
String _macros(String line) =>
    line.replaceAll(' ', '\u00a0').replaceAll('\u00a0·\u00a0', '\u00a0· ');

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double textScale = 1.0,
  Locale locale = const Locale('de'),
  double breite = _breite,
}) async {
  tester.view.physicalSize = Size(breite * 3, 844 * 3);
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
  await expandFoodEntries(tester);
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
    final figtree = FontLoader('Figtree');
    for (final datei in const <String>[
      'assets/fonts/Figtree-Regular.ttf',
      'assets/fonts/Figtree-Medium.ttf',
      'assets/fonts/Figtree-SemiBold.ttf',
      'assets/fonts/Figtree-Bold.ttf',
    ]) {
      figtree.addFont(
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
    await Future.wait(<Future<void>>[figtree.load(), bricolage.load()]);
  });

  group('DiaryMealCard — Makros', () {
    testWidgets('der Slot-Kopf summiert P/K/F ueber alle Eintraege, jede '
        'Zeile zeigt ihre eigenen Makros', (tester) async {
      await _pump(tester, _karteMitZweiEintraegen());

      // The existing totals line is unchanged (other tests read it).
      expect(find.text('530'), findsOneWidget);
      expect(find.text('12:30 · 2 Einträge'), findsOneWidget);

      expect(_makroZeilen(tester), <String>[
        _macros('P 42 g · K 59 g · F 26 g'), // slot header: sum 42.4 / 58.6 / 26
        _macros('P 12 g · K 48 g · F 6 g'), // Haferbrei
        _macros('P 30 g · K 11 g · F 20 g'), // Quark: 30.4 / 10.6 / 20
      ]);

      // The amount line stays its own Text widget; an AI estimate keeps
      // its "~".
      expect(find.text('~250 g'), findsOneWidget);
      expect(find.text('~1200 g'), findsOneWidget);
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

    // Entries without a macro add 0 g. The header read "P 0 g" for them and
    // a sum with them as exact (review 2026-10-22): such a sum is a lower
    // bound, and a macro nothing is known of has no number.
    testWidgets('unbekannte Makros: der Kopf zeigt Untergrenzen oder "–", '
        'eine Zeile keine erfundene 0', (tester) async {
      List<String> zeilen() => tester
          .widgetList<Text>(find.textContaining(RegExp('^P ')))
          .map((t) => t.data!)
          .toList(growable: false);

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
      // Header only: the row hides macros it does not know.
      expect(zeilen(), <String>[_macros('P – · K – · F –')]);

      final shake = _ergebnis(
        name: 'Proteinshake',
        kcal: 150,
        gramm: 300,
        protein: '25 g',
        carbs: '-',
        fat: '-',
      );
      await _pump(
        tester,
        DiaryMealCard(
          slot: MealSlot.lunch,
          entries: <DiaryEntry>[
            DiaryEntry(_mahlzeit('m1', _haferbrei, MealSlot.lunch), 0),
            DiaryEntry(_mahlzeit('m2', shake, MealSlot.lunch), 1),
          ],
          onAddToSlot: (_) {},
        ),
      );
      expect(zeilen(), <String>[
        _macros('P 37 g · K ≥48 g · F ≥6 g'), // protein known in both
        _macros('P 12 g · K 48 g · F 6 g'),
        _macros('P 25 g · K – · F –'),
      ]);
    });

    // 1.0 is the first test's layout; overflow there already fails it.
    for (final scale in const <double>[1.3]) {
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
          // The amount line must not be clipped by its neighbour either.
          final slotZeile = tester.renderObject<RenderParagraph>(
            find.text('~1200 g'),
          );
          expect(slotZeile.didExceedMaxLines, isFalse);
        },
      );
    }

    // At the 2x cap on a 320 pt phone the lines wrap. They may only break
    // after a ' · ' separator: "F" on one line and "0 g" on the next read as
    // two values (design review, 2026-10-11).
    final trennerMuster = RegExp('[ \u00a0]· ');
    // "K" (de) and "C" (en) wrap alike; one locale is enough.
    for (final locale in const [Locale('de')]) {
      testWidgets(
        'bei 320 pt und 2x Text bricht eine Makro-Zeile nur am Trenner '
        '(${locale.languageCode})',
        (tester) async {
          await _pump(
            tester,
            _karteMitZweiEintraegen(),
            textScale: 2,
            locale: locale,
            breite: 320,
          );
          expect(tester.takeException(), isNull);

          final zeilen = find.textContaining(_makroZeile);
          expect(zeilen, findsNWidgets(3));
          var umbrochen = false;
          for (final element in zeilen.evaluate()) {
            final text = (element.widget as Text).data!;
            final paragraph = element.findRenderObject()! as RenderParagraph;
            final zeilenTops = paragraph
                .getBoxesForSelection(
                  TextSelection(baseOffset: 0, extentOffset: text.length),
                )
                .map((box) => box.top)
                .toSet();
            if (zeilenTops.length > 1) umbrochen = true;
            // The tokens between the separators, by offset.
            var start = 0;
            final ends = [
              for (final trenner in trennerMuster.allMatches(text))
                (trenner.start, trenner.end),
              (text.length, text.length),
            ];
            for (final (end, next) in ends) {
              final boxes = paragraph.getBoxesForSelection(
                TextSelection(baseOffset: start, extentOffset: end),
              );
              expect(
                boxes.map((box) => box.top).toSet(),
                hasLength(1),
                reason:
                    '"${text.substring(start, end)}" in "$text" breaks '
                    'across lines',
              );
              start = next;
            }
          }
          expect(
            umbrochen,
            isTrue,
            reason: 'the case needs at least one wrapped line',
          );
        },
      );
    }
  });
}
