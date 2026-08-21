import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/kcal/diary_meal_card.dart';

// ---------------------------------------------------------------------------
// Makros pro Slot und pro Mahlzeit in der Slot-Karte des Food-Tabs.
//
// Der Slot-Kopf traegt unter „N kcal · N Eintraege" eine zweite Zeile mit den
// Slot-Summen (P/K/F), jede Verlaufszeile unter „Slot · Menge" ihre eigenen
// Makros. Beide kommen aus `MacroProgress` — derselben Zahlenbasis wie die
// Tagesbilanz — und aus dem ARB-Schluessel `foodMacroSummary`.
//
// Die Breitenmessungen (390 pt, Textskalierung 1.0 und 1.3) laufen mit den
// ECHTEN App-Schriften: die Test-Schrift des Headless-Renderers ist rund
// doppelt so breit wie Archivo/Bricolage und wuerde jede Aussage ueber „passt
// auf ein iPhone 12/13/14" verfaelschen (s. a11y_controls_test.dart).
// ---------------------------------------------------------------------------

/// Logische Breite eines iPhone 12/13/14 — die schmalste Breite, fuer die
/// die Karte ohne Abschneiden ausgelegt ist.
const double _breite = 390;

/// `^P … g · K … g · F … g$` (de) bzw. mit `C` (en) — genau die Form von
/// `foodMacroSummary`, damit der Finder weder die kcal-Zeile noch die
/// Slot-Zeile mitnimmt.
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

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      locale: locale,
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: SafeArea(
              // Dasselbe 20/12-Padding wie der Food-Tab in EatovaHomePage.
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                child: child,
              ),
            ),
          ),
        ),
      ),
    ),
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

/// Zwei Eintraege mit bekannten Makros. Der zweite traegt Dezimalwerte mit
/// Komma UND Punkt — `MacroProgress` liest beide; die Zeile rundet pro
/// Mahlzeit (30,4 → 30; 10.6 → 11), der Kopf rundet die SUMME
/// (42,4 → 42; 58,6 → 59; 26).
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

/// Zwei Eintraege im Mittagessen — der laengste deutsche Slot-Name, damit die
/// Breitenmessung den engsten Fall sieht.
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

/// Alle Makro-Zeilen der Karte in Baumreihenfolge (Kopf zuerst, dann die
/// Zeilen von oben nach unten).
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

      // Die bestehende Summenzeile bleibt unveraendert (Tests lesen sie).
      expect(find.text('530 kcal · 2 Einträge'), findsOneWidget);

      expect(_makroZeilen(tester), <String>[
        'P 42 g · K 59 g · F 26 g', // Slot-Kopf: Summe 42,4 / 58,6 / 26
        'P 12 g · K 48 g · F 6 g', // Haferbrei
        'P 30 g · K 11 g · F 20 g', // Quark: 30,4 / 10.6 / 20
      ]);

      // Die Slot-Zeile „Slot · Menge" bleibt ein eigenes Text-Widget mit
      // unveraendertem Format — edit_meal_sheet_test liest genau das.
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

      // Nur die Slot-Summe im Kopf (wie die Tagesringe: 0 ist 0). Die
      // Verlaufszeile verschweigt unbekannte Makros — dieselbe Regel wie
      // ExistingMealsList, damit „P 0 g" nie wie eine Messung aussieht.
      expect(_makroZeilen(tester), <String>['P 0 g · K 0 g · F 0 g']);
    });

    for (final scale in const <double>[1.0, 1.3]) {
      testWidgets(
        'bei 390 pt und Textskalierung $scale passt jede Makro-Zeile ohne '
        'Overflow und ohne Abschneiden',
        (tester) async {
          await _pump(tester, _karteMitZweiEintraegen(), textScale: scale);

          // Kein RenderFlex-Overflow (waere ueber FlutterError.onError schon
          // ein Testfehler — hier explizit, damit die Aussage lesbar bleibt).
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
          // Auch die Slot-Zeile darf durch die neue Nachbarschaft nicht
          // abgeschnitten werden.
          final slotZeile = tester.renderObject<RenderParagraph>(
            find.text('Mittagessen · ~1200 g'),
          );
          expect(slotZeile.didExceedMaxLines, isFalse);
        },
      );
    }
  });
}
