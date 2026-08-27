// W3-07 / B1: preview and save path of the component sheet must produce the
// SAME number.
//
// `caloriesKcal` is authoritative and density is derived from it
// (`MealComponent.adjustedToGrams`), but the preview still preferred
// `kcalPer100G`. On a component whose density contradicts grams and calories
// (a kJ value in the kcal field) the row showed one number and the sheet saved
// another: {100 g, 521 kcal, 2180 kcal/100 g} at 30 g showed 654 and saved
// 156.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/widgets/meal/meal_widgets.dart';

import 'support/harness.dart' hide testWidgetsRobust;

/// Viewport pinning plus overflow tolerance, as in the other widget suites.
void testWidgetsRobust(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    await callback(tester);
  });
}

/// A component with contradictory density: 521 kcal per 100 g, but the field
/// holds the kJ value 2180.
const _inkonsistent = MealAnalysisResult(
  mealName: 'Nussmus',
  caloriesKcal: 521,
  estimatedGrams: 100,
  kcalPer100G: 2180,
  protein: '20 g',
  carbs: '12 g',
  fat: '45 g',
  confidence: 'Mittel',
  portionNotes: 'Testposten mit kJ-Zahl im kcal-Feld.',
  sourceLabel: 'OpenFoodFacts',
  items: [
    MealComponent(
      name: 'Nussmus',
      grams: 100,
      caloriesKcal: 521,
      kcalPer100G: 2180,
    ),
  ],
);

/// A meal whose only component carries complete macros — the precondition for
/// `adjustedToItems` to sum exactly. 300 g, 200 kcal, 10/20/5 g.
const _mitMakros = MealAnalysisResult(
  mealName: 'Salat',
  caloriesKcal: 200,
  estimatedGrams: 300,
  kcalPer100G: 66.7,
  protein: '10 g',
  carbs: '20 g',
  fat: '5 g',
  confidence: 'Mittel',
  portionNotes: 'Posten mit Makros.',
  sourceLabel: 'Foto-KI',
  items: [
    MealComponent(
      name: 'Salat',
      grams: 300,
      caloriesKcal: 200,
      kcalPer100G: 66.7,
      proteinG: 10,
      carbsG: 20,
      fatG: 5,
    ),
  ],
);

/// Host with a button that opens the adjust sheet and captures its return —
/// exactly what `MealAnalysisSheet` would pass to `adjustedToItems`.
Widget _host(MealAnalysisResult result, void Function(Object?) onResult) {
  return localizedApp(
    Builder(
      builder: (context) => TextButton(
        key: const ValueKey('open-adjust'),
        onPressed: () async =>
            onResult(await showWeightAdjustmentSheet(context, result)),
        child: const Text('anpassen'),
      ),
    ),
    // Motion as before the migration.
    reducedMotion: false,
    safeArea: false,
  );
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open-adjust')));
  await tester.pumpAndSettle();
}

/// The calorie number the component row currently DISPLAYS. Read from the
/// rendered text, not computed from the model — only that compares preview
/// against save path.
int _angezeigteZeilenKcal(WidgetTester tester, int grams) {
  final muster = RegExp('^$grams g · (\\d+) kcal\$');
  final treffer = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data)
      .whereType<String>()
      .map(muster.firstMatch)
      .whereType<RegExpMatch>()
      .map((m) => int.parse(m.group(1)!))
      .toList(growable: false);
  expect(treffer, hasLength(1), reason: 'genau eine Postenzeile erwartet');
  return treffer.single;
}

void main() {
  // Regression guard: `showWeightAdjustmentSheet` only builds the component
  // sheet. The unreachable weight-only sheet still carried the B1 formula
  // `kcalPer100G * grams / 100` and was deleted; this pins that nobody brings
  // it back.
  group('B1/Uebergabe 2 — nur noch das Bestandteil-Sheet', () {
    testWidgetsRobust('das Anpassen-Sheet ist das Bestandteil-Sheet',
        (tester) async {
      await tester.pumpWidget(_host(_inkonsistent, (_) {}));
      await _openSheet(tester);

      expect(find.text('Bestandteile anpassen'), findsOneWidget);
      expect(find.text('Portion anpassen'), findsNothing);
      expect(find.byKey(const ValueKey('analyse-weight-input')), findsNothing);
      expect(
        find.byKey(const ValueKey('analyse-item-weight-input-0')),
        findsOneWidget,
      );
    });
  });

  // B8: the component dialog optionally captures macros. `adjustedToItems`
  // sums them exactly once ALL components carry them, otherwise the meal falls
  // back to unknown (`-`).
  group('B8 — Makros im Bestandteil-Dialog', () {
    testWidgetsRobust(
      'der schnelle Pfad bleibt schnell: Makro-Felder sind eingeklappt',
      (tester) async {
        await tester.pumpWidget(_host(_mitMakros, (_) {}));
        await _openSheet(tester);
        await tester.tap(find.byKey(const ValueKey('analyse-item-add-button')));
        await tester.pumpAndSettle();

        // Name, grams, calories are visible right away …
        expect(find.byKey(const ValueKey('analyse-add-item-name')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('analyse-add-item-grams')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('analyse-add-item-kcal')),
            findsOneWidget);
        // … the three macro fields only after expanding.
        expect(find.byKey(const ValueKey('analyse-add-item-protein')),
            findsNothing);
        expect(find.byKey(const ValueKey('analyse-add-item-carbs')),
            findsNothing);
        expect(find.byKey(const ValueKey('analyse-add-item-fat')),
            findsNothing);
        expect(find.byKey(const ValueKey('analyse-add-item-macros-toggle')),
            findsOneWidget);

        await tester
            .tap(find.byKey(const ValueKey('analyse-add-item-macros-toggle')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('analyse-add-item-protein')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('analyse-add-item-carbs')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('analyse-add-item-fat')),
            findsOneWidget);
      },
    );

    testWidgetsRobust(
      'leer gelassene Makros werden null — nicht 0 (0 waere eine Aussage)',
      (tester) async {
        Object? gespeichert;
        await tester.pumpWidget(_host(_mitMakros, (v) => gespeichert = v));
        await _openSheet(tester);
        await tester.tap(find.byKey(const ValueKey('analyse-item-add-button')));
        await tester.pumpAndSettle();

        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-name')), 'Brot');
        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-grams')), '50');
        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-kcal')), '130');
        await tester.pumpAndSettle();
        await tester
            .tap(find.byKey(const ValueKey('analyse-add-item-save')));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const ValueKey('analyse-save-weight-button')),
        );
        await tester.pumpAndSettle();

        final posten = gespeichert as List<MealComponent>;
        expect(posten, hasLength(2));
        final brot = posten.last;
        expect(brot.name, 'Brot');
        expect(brot.proteinG, isNull);
        expect(brot.carbsG, isNull);
        expect(brot.fatG, isNull);
        expect(brot.hasMacros, isFalse);

        // Consequently the meal reports its macros as unknown.
        final angepasst = _mitMakros.adjustedToItems(posten);
        expect(angepasst.protein, '-');
        expect(angepasst.carbs, '-');
        expect(angepasst.fat, '-');
      },
    );

    testWidgetsRobust(
      'erfasste Makros landen am Posten und werden exakt aufsummiert',
      (tester) async {
        Object? gespeichert;
        await tester.pumpWidget(_host(_mitMakros, (v) => gespeichert = v));
        await _openSheet(tester);
        await tester.tap(find.byKey(const ValueKey('analyse-item-add-button')));
        await tester.pumpAndSettle();

        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-name')), 'Olivenöl');
        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-grams')), '20');
        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-kcal')), '180');
        await tester
            .tap(find.byKey(const ValueKey('analyse-add-item-macros-toggle')));
        await tester.pumpAndSettle();

        // 0 g here is a real statement, not "unknown".
        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-protein')), '0');
        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-carbs')), '0');
        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-fat')), '20');
        await tester.pumpAndSettle();
        await tester
            .tap(find.byKey(const ValueKey('analyse-add-item-save')));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const ValueKey('analyse-save-weight-button')),
        );
        await tester.pumpAndSettle();

        final posten = gespeichert as List<MealComponent>;
        final oel = posten.last;
        expect(oel.proteinG, 0);
        expect(oel.carbsG, 0);
        expect(oel.fatG, 20);
        expect(oel.hasMacros, isTrue);

        // All components carry macros -> exact sum instead of "unknown".
        final angepasst = _mitMakros.adjustedToItems(posten);
        expect(angepasst.protein, '10 g');
        expect(angepasst.carbs, '20 g');
        expect(angepasst.fat, '25 g');
      },
    );

    testWidgetsRobust(
      'Nachkommastellen mit Komma werden uebernommen',
      (tester) async {
        Object? gespeichert;
        await tester.pumpWidget(_host(_mitMakros, (v) => gespeichert = v));
        await _openSheet(tester);
        await tester.tap(find.byKey(const ValueKey('analyse-item-add-button')));
        await tester.pumpAndSettle();

        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-name')), 'Butter');
        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-grams')), '10');
        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-kcal')), '74');
        await tester
            .tap(find.byKey(const ValueKey('analyse-add-item-macros-toggle')));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-protein')), '0,1');
        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-carbs')), '0,1');
        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-fat')), '8,2');
        await tester.pumpAndSettle();
        await tester
            .tap(find.byKey(const ValueKey('analyse-add-item-save')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('analyse-save-weight-button')),
        );
        await tester.pumpAndSettle();

        final butter = (gespeichert as List<MealComponent>).last;
        expect(butter.proteinG, closeTo(0.1, 0.0001));
        expect(butter.fatG, closeTo(8.2, 0.0001));
      },
    );

    testWidgetsRobust(
      'der Dialog sagt VORHER, was das Leerlassen kostet',
      (tester) async {
        await tester.pumpWidget(_host(_mitMakros, (_) {}));
        await _openSheet(tester);
        await tester.tap(find.byKey(const ValueKey('analyse-item-add-button')));
        await tester.pumpAndSettle();

        final hinweis = find.byKey(
          const ValueKey('analyse-add-item-macro-hint'),
        );
        expect(hinweis, findsOneWidget);
        expect(
          tester.widget<Text>(hinweis).data,
          contains('„–"'),
          reason: 'Der Hinweis muss die Folge benennen, bevor sie eintritt.',
        );

        // Once all three values are set, the hint flips to the positive
        // statement: the meal keeps its macros.
        await tester
            .tap(find.byKey(const ValueKey('analyse-add-item-macros-toggle')));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-protein')), '0');
        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-carbs')), '0');
        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-fat')), '20');
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(hinweis).data, contains('aufsummiert'));
      },
    );

    testWidgetsRobust(
      'tragen die uebrigen Posten keine Makros, verspricht der Dialog nichts',
      (tester) async {
        // _inkonsistent has a component WITHOUT macros, so even fully filled
        // macros cannot save the meal — the hint must say so.
        await tester.pumpWidget(_host(_inkonsistent, (_) {}));
        await _openSheet(tester);
        await tester.tap(find.byKey(const ValueKey('analyse-item-add-button')));
        await tester.pumpAndSettle();
        await tester
            .tap(find.byKey(const ValueKey('analyse-add-item-macros-toggle')));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-protein')), '1');
        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-carbs')), '2');
        await tester.enterText(
            find.byKey(const ValueKey('analyse-add-item-fat')), '3');
        await tester.pumpAndSettle();

        final text = tester
            .widget<Text>(
              find.byKey(const ValueKey('analyse-add-item-macro-hint')),
            )
            .data!;
        expect(text, contains('„–"'));
        expect(text, isNot(contains('aufsummiert')));
      },
    );
  });

  group('B1 — Vorschau und Speichern rechnen gleich', () {
    testWidgetsRobust(
      'inkonsistenter Posten: Zeile, Gesamtzeile und gespeicherter Wert sind identisch',
      (tester) async {
        Object? gespeichert;
        await tester.pumpWidget(_host(_inkonsistent, (v) => gespeichert = v));
        await _openSheet(tester);

        await tester.enterText(
          find.byKey(const ValueKey('analyse-item-weight-input-0')),
          '30',
        );
        await tester.pumpAndSettle();

        // What the row SHOWS (before the fix: 654 from the 2180 density).
        final vorschau = _angezeigteZeilenKcal(tester, 30);

        // The total row always went through adjustedToGrams, so the divergence
        // sat in the same sheet.
        expect(find.text('30 g ≈ 156 kcal'), findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey('analyse-save-weight-button')),
        );
        await tester.pumpAndSettle();

        // What the sheet SAVES (always 521 * 30 / 100 = 156).
        final posten = gespeichert as List<MealComponent>;
        final gespeicherteKcal = posten.single.caloriesKcal;

        expect(
          vorschau,
          gespeicherteKcal,
          reason:
              'Vorschau zeigt $vorschau kcal, gespeichert werden '
              '$gespeicherteKcal kcal — dieselbe Portion, zwei Zahlen.',
        );
        expect(posten.single.grams, 30);
        expect(gespeicherteKcal, 156);
        expect(_inkonsistent.adjustedToItems(posten).caloriesKcal, 156);
      },
    );

    testWidgetsRobust(
      'unveraendert bestaetigen laesst die Kalorien der Posten unangetastet',
      (tester) async {
        Object? gespeichert;
        await tester.pumpWidget(_host(_inkonsistent, (v) => gespeichert = v));
        await _openSheet(tester);

        // Invariant: adjustedToGrams(estimatedGrams) does not change the
        // calories, so without typing the row must show 521.
        expect(find.text('100 g · 521 kcal'), findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey('analyse-save-weight-button')),
        );
        await tester.pumpAndSettle();

        expect((gespeichert as List<MealComponent>).single.caloriesKcal, 521);
      },
    );

    testWidgetsRobust(
      'ohne Kalorienangabe uebernimmt die (plausible) Dichte die Rechnung',
      (tester) async {
        // 0 kcal means "unknown" (the old clamp sentinel), so density is the
        // only reference: 80 kcal/100 g at 250 g is 200 kcal.
        const nurDichte = MealAnalysisResult(
          mealName: 'Kartoffeln',
          caloriesKcal: 0,
          estimatedGrams: 200,
          kcalPer100G: 80,
          protein: '-',
          carbs: '-',
          fat: '-',
          confidence: 'Mittel',
          portionNotes: 'Kalorien fehlen, Dichte ist da.',
          sourceLabel: 'Foto-KI',
          items: [
            MealComponent(
              name: 'Kartoffeln',
              grams: 200,
              caloriesKcal: 0,
              kcalPer100G: 80,
            ),
          ],
        );

        Object? gespeichert;
        await tester.pumpWidget(_host(nurDichte, (v) => gespeichert = v));
        await _openSheet(tester);

        await tester.enterText(
          find.byKey(const ValueKey('analyse-item-weight-input-0')),
          '250',
        );
        await tester.pumpAndSettle();
        expect(find.text('250 g · 200 kcal'), findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey('analyse-save-weight-button')),
        );
        await tester.pumpAndSettle();
        expect((gespeichert as List<MealComponent>).single.caloriesKcal, 200);
      },
    );

    testWidgetsRobust(
      'unplausible Dichte ohne Kalorien erfindet nichts (0 kcal statt kJ-Zahl)',
      (tester) async {
        // Neither calories nor a usable density: the 2180 is the kJ value and
        // effectiveKcalPer100G drops it. The row must not invent a number —
        // 0 is what adjustedToGrams would save.
        const nurKJ = MealAnalysisResult(
          mealName: 'Datensatz ohne Naehrwerte',
          caloriesKcal: 0,
          estimatedGrams: 100,
          kcalPer100G: 2180,
          protein: '-',
          carbs: '-',
          fat: '-',
          confidence: 'Datenbank',
          portionNotes: 'kJ im kcal-Feld, keine Kalorien.',
          sourceLabel: 'OpenFoodFacts',
          items: [
            MealComponent(
              name: 'Datensatz ohne Naehrwerte',
              grams: 100,
              caloriesKcal: 0,
              kcalPer100G: 2180,
            ),
          ],
        );

        Object? gespeichert;
        await tester.pumpWidget(_host(nurKJ, (v) => gespeichert = v));
        await _openSheet(tester);

        await tester.enterText(
          find.byKey(const ValueKey('analyse-item-weight-input-0')),
          '30',
        );
        await tester.pumpAndSettle();
        expect(find.text('30 g · 0 kcal'), findsOneWidget);
        expect(find.text('30 g · 654 kcal'), findsNothing);

        await tester.tap(
          find.byKey(const ValueKey('analyse-save-weight-button')),
        );
        await tester.pumpAndSettle();
        expect((gespeichert as List<MealComponent>).single.caloriesKcal, 0);
      },
    );
  });
}
