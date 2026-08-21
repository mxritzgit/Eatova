// Slot-Gesamt mit Makros in der „Schon hinzugefuegt"-Liste des Add-Sheets
// (2026-08-21): der Kopf der Liste zeigt neben der kcal-Summe jetzt auch
// Protein/KH/Fett des Slots, jede Zeile optional ihre eigenen Makros.
//
// Die Fixtures tragen bewusst gemischte Schreibweisen ('34 g', '6,5 g',
// '1.4 g', '-'): Summe und Rundung muessen ueber denselben Parser laufen wie
// die Tagesringe (MacroProgress), nicht ueber eigenes String-Gefummel.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/kcal/existing_meals_list.dart';

import '../design/design_harness.dart';

LoggedMeal _meal({
  required String id,
  required String name,
  required int kcal,
  required int grams,
  required String protein,
  required String carbs,
  required String fat,
}) {
  return LoggedMeal(
    id: id,
    result: MealAnalysisResult(
      mealName: name,
      caloriesKcal: kcal,
      estimatedGrams: grams,
      kcalPer100G: grams == 0 ? 0 : kcal * 100 / grams,
      protein: protein,
      carbs: carbs,
      fat: fat,
      confidence: 'high',
      portionNotes: '',
    ),
    loggedAt: DateTime(2026, 8, 21, 19, 30),
    forcedSlot: MealSlot.dinner,
  );
}

/// Drei Abendessen-Eintraege: kcal 420 + 300 + 0 = 720;
/// Protein 34 + 6,5 + 0 = 40,5 -> 41; KH 2 + 65 + 0 = 67;
/// Fett 28 + 1,4 + 0 = 29,4 -> 29. Der dritte Eintrag hat unbekannte Makros.
final List<LoggedMeal> _meals = <LoggedMeal>[
  _meal(
    id: 'm1',
    name: 'Lachsfilet',
    kcal: 420,
    grams: 200,
    protein: '34 g',
    carbs: '2 g',
    fat: '28 g',
  ),
  _meal(
    id: 'm2',
    name: 'Basmatireis',
    kcal: 300,
    grams: 250,
    protein: '6,5 g',
    carbs: '65 g',
    fat: '1.4 g',
  ),
  _meal(
    id: 'm3',
    name: 'Wasser',
    kcal: 0,
    grams: 500,
    protein: '-',
    carbs: '-',
    fat: '-',
  ),
];

/// 390 pt logische Breite (Vorgabe des Pakets) bei 3x — etwas schmaler als
/// der iPhone-14-Viewport des Harness (393).
void _pin390(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Der String des Text-Widgets mit [key] — die Keys sitzen direkt auf den
/// Texten, ein `find.descendant` saehe an der Wurzel vorbei.
String? _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data;

Widget _list({List<LoggedMeal>? meals}) => ExistingMealsList(
      meals: meals ?? _meals,
      slot: MealSlot.dinner,
      onRemove: (_) {},
      onEdit: (_) {},
    );

void main() {
  testWidgets('Kopf zeigt Gesamt-kcal und summierte Makros des Slots',
      (tester) async {
    _pin390(tester);
    await tester.pumpWidget(designHarness(_list()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(find.byKey(const ValueKey('analyse-existing-meals')), findsOneWidget);
    expect(find.byKey(const ValueKey('analyse-existing-total')), findsOneWidget);
    expect(find.text('Gesamt'), findsOneWidget);
    // Die kcal-Zahl bleibt ein eigenes Text-Widget mit dem alten Wortlaut —
    // Flow-Tests suchen genau diesen Text.
    expect(_textOf(tester, 'analyse-existing-total-kcal'), '720 kcal');
    // 40,5 -> 41 (kaufmaennisch), 29,4 -> 29, Komma UND Punkt geparst.
    expect(
      _textOf(tester, 'analyse-existing-total-macros'),
      'P 41 g · K 67 g · F 29 g',
    );
  });

  testWidgets('Zeilen zeigen eigene Makros; unbekannte Makros bleiben stumm',
      (tester) async {
    _pin390(tester);
    await tester.pumpWidget(designHarness(_list()));
    await tester.pumpAndSettle();

    expect(
      _textOf(tester, 'analyse-existing-macros-m1'),
      'P 34 g · K 2 g · F 28 g',
    );
    // 6,5 -> 7 und 1,4 -> 1 je Zeile gerundet.
    expect(
      _textOf(tester, 'analyse-existing-macros-m2'),
      'P 7 g · K 65 g · F 1 g',
    );
    // '-' ueberall -> keine „P 0 g"-Zeile, die eine Messung vortaeuscht.
    expect(
      find.byKey(const ValueKey('analyse-existing-macros-m3')),
      findsNothing,
    );
    // Die kcal/Gramm-Zeile bleibt byte-identisch (edit_meal_sheet_test liest
    // sie wortgleich) — die Makros stehen darunter, nicht darin.
    expect(find.text('420 kcal · 200 g'), findsOneWidget);
    expect(find.text('300 kcal · 250 g'), findsOneWidget);
    // Entfernen-Knopf je Zeile unveraendert vorhanden.
    expect(
      find.byKey(const ValueKey('analyse-existing-remove-m1')),
      findsOneWidget,
    );
  });

  testWidgets('Englisch: Total + C statt K', (tester) async {
    _pin390(tester);
    await tester.pumpWidget(designHarness(_list(), locale: const Locale('en')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(find.text('Total'), findsOneWidget);
    expect(find.text('P 41 g · C 67 g · F 29 g'), findsOneWidget);
  });

  testWidgets('Rendert bei 390 pt und Textskala 1.3 in Hell UND Dunkel ohne '
      'Ueberlauf', (tester) async {
    _pin390(tester);
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        designHarness(
          _list(),
          brightness: brightness,
          textScaler: const TextScaler.linear(1.3),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'Ueberlauf/Exception unter $brightness bei Skala 1.3',
      );
      expect(
        find.byKey(const ValueKey('analyse-existing-total-macros')),
        findsOneWidget,
      );
    }
  });

  testWidgets('Ueberlebt die doppelte Systemschrift (EatovaApp-Deckel)',
      (tester) async {
    _pin390(tester);
    await expectSurvivesTextScale(tester, _list());
  });

  testWidgets('Eine einzelne Mahlzeit: Summe gleich Zeile', (tester) async {
    _pin390(tester);
    await tester.pumpWidget(designHarness(_list(meals: [_meals.first])));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(find.text('420 kcal'), findsOneWidget);
    // Einmal im Kopf, einmal in der Zeile.
    expect(find.text('P 34 g · K 2 g · F 28 g'), findsNWidgets(2));
  });
}
