// W3-07 / B1: Vorschau und Speicherpfad des Bestandteil-Sheets muessen
// DIESELBE Zahl liefern.
//
// Welle 2 hat entschieden, dass `caloriesKcal` autoritativ ist und die Dichte
// daraus hergeleitet wird (`MealComponent.adjustedToGrams`). Die Vorschau in
// `_MealItemAdjustmentSheet._itemKcalFor` bevorzugte danach weiterhin
// `kcalPer100G` — bei einem Posten, dessen Dichte nicht zu Gramm und Kalorien
// passt (die klassische kJ-Zahl im kcal-Feld), zeigte die Zeile deshalb eine
// andere Zahl, als das Sheet beim Uebernehmen speicherte.
//
// Der Referenzfall aus dem Review: {100 g, 521 kcal, 2180 kcal/100 g} auf 30 g
//   * Zeile zeigte   2180 * 30 / 100          = 654 kcal
//   * gespeichert war 521  * 30 / 100          = 156 kcal
//   * die Gesamtzeile darunter zeigte ebenfalls 156 kcal — die Divergenz war
//     also im selben Sheet gleichzeitig sichtbar.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/meal/meal_widgets.dart';

/// Viewport-Pinning + Overflow-Toleranz wie in den uebrigen Widget-Suiten.
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

/// Ein Posten mit widerspruechlicher Dichte: 521 kcal auf 100 g sind 521
/// kcal/100 g, im Feld steht aber die kJ-Zahl 2180.
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

/// Eine Mahlzeit, deren einziger Posten vollstaendige Makros traegt — die
/// Voraussetzung dafuer, dass `adjustedToItems` ueberhaupt exakt aufsummieren
/// darf. 300 g Salat, 200 kcal, 10/20/5 g.
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

/// Host mit einem Knopf, der das Anpassen-Sheet oeffnet und dessen Rueckgabe
/// festhaelt — genau der Wert, den `MealAnalysisSheet` an `adjustedToItems`
/// weiterreichen wuerde.
Widget _host(MealAnalysisResult result, void Function(Object?) onResult) {
  return MaterialApp(
    // Die Anpassen-Flaechen lesen ihre Farben seit dem Design-Refactor aus der
    // AppTokens-ThemeExtension — ohne Eatova-Theme wirft AppTokens.of bewusst.
    theme: buildEatovaTheme(Brightness.dark),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          key: const ValueKey('open-adjust'),
          onPressed: () async =>
              onResult(await showWeightAdjustmentSheet(context, result)),
          child: const Text('anpassen'),
        ),
      ),
    ),
  );
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open-adjust')));
  await tester.pumpAndSettle();
}

/// Die Kalorienzahl, die die Postenzeile GERADE ANZEIGT ("30 g · 654 kcal").
/// Bewusst aus dem gerenderten Text gelesen statt aus dem Modell gerechnet:
/// nur so vergleicht der Test wirklich Vorschau gegen Speicherpfad, und die
/// Fehlermeldung nennt beide Zahlen.
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
  // Regressionsschutz zu Uebergabe 2: `showWeightAdjustmentSheet` baut
  // ausschliesslich das Bestandteil-Sheet. Das frueher danebenliegende
  // reine Gewichts-Sheet (`_MealWeightAdjustmentSheet`, Titel "Portion
  // anpassen", Feld `analyse-weight-input`) war unerreichbar und trug die
  // B1-Formel `kcalPer100G * grams / 100` weiter mit sich herum; es ist
  // geloescht. Dieser Test war auch vor dem Loeschen gruen — toter Code
  // rendert nicht — und haelt lediglich fest, dass niemand ihn zurueckholt.
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

  // B8: Der Bestandteil-Dialog erfasst jetzt optional Makros. `adjustedToItems`
  // summiert sie exakt, sobald ALLE Posten welche tragen — sonst gilt
  // "unbekannt" (`-`). Ohne Erfassung im Dialog fiel jede Zusammensetzungs-
  // aenderung zwangslaeufig auf "unbekannt".
  group('B8 — Makros im Bestandteil-Dialog', () {
    testWidgetsRobust(
      'der schnelle Pfad bleibt schnell: Makro-Felder sind eingeklappt',
      (tester) async {
        await tester.pumpWidget(_host(_mitMakros, (_) {}));
        await _openSheet(tester);
        await tester.tap(find.byKey(const ValueKey('analyse-item-add-button')));
        await tester.pumpAndSettle();

        // Name, Gramm, Kalorien stehen sofort da …
        expect(find.byKey(const ValueKey('analyse-add-item-name')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('analyse-add-item-grams')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('analyse-add-item-kcal')),
            findsOneWidget);
        // … die drei Makro-Felder erst nach dem Aufklappen.
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

        // Folgerichtig: die Mahlzeit weist ihre Makros als unbekannt aus.
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

        // 0 g Protein/KH ist hier eine echte Aussage, kein "unbekannt".
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

        // Alle Posten tragen Makros -> exakte Summe statt "unbekannt".
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

        // Sobald alle drei Werte stehen, wechselt der Hinweis auf die
        // positive Aussage — die Mahlzeit behaelt ihre Makros.
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
        // _inkonsistent hat einen Posten OHNE Makros. Selbst vollstaendig
        // ausgefuellte Makros retten die Mahlzeit dann nicht — und genau das
        // muss dastehen, statt eine exakte Summe zu versprechen.
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

        // Was die Zeile ZEIGT (vor dem Fix: 654 aus der 2180er-Dichte).
        final vorschau = _angezeigteZeilenKcal(tester, 30);

        // Die Gesamtzeile rechnete schon immer ueber adjustedToGrams — die
        // Divergenz stand also im selben Sheet direkt untereinander.
        expect(find.text('30 g ≈ 156 kcal'), findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey('analyse-save-weight-button')),
        );
        await tester.pumpAndSettle();

        // Was das Sheet SPEICHERT (immer 521 * 30 / 100 = 156).
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

        // Invariante aus Welle 2: adjustedToGrams(estimatedGrams) aendert die
        // Kalorien nicht. Ohne Tippen muss die Zeile deshalb 521 zeigen.
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
        // 0 kcal heisst "unbekannt" (der alte Clamp-Sentinel), nicht "0 kcal".
        // Dann ist die Dichte die einzige Bezugsgroesse — 80 kcal/100 g auf
        // 250 g sind 200 kcal.
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
        // Weder Kalorien noch eine brauchbare Dichte: die 2180 sind die
        // kJ-Zahl und werden von effectiveKcalPer100G verworfen. Die Zeile
        // darf dann keine Zahl erfinden — 0 ist hier die ehrliche Antwort und
        // exakt das, was adjustedToGrams speichern wuerde.
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
