// Gaps 1 and 3 from B1 (docs/REVIEW-2026-08-08.md), measured on the expanded
// MealSuggestionItem. Core question: does the number right above the add
// button show the value that gets logged on tap?

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/kcal/meal_suggestion_item.dart';

import 'support/harness.dart';

/// What `fromEdgeFunction` builds from an answer without grams or density:
/// 420 kcal measured, 150 g default, 52 kcal/100 g from the name table. The
/// three numbers disagree by a factor of 5.4.
const MealAnalysisResult apfelkuchen = MealAnalysisResult(
  mealName: 'Apfelkuchen',
  caloriesKcal: 420,
  estimatedGrams: 150,
  kcalPer100G: 52,
  protein: '4 g',
  carbs: '55 g',
  fat: '20 g',
  confidence: 'Mittel',
  portionNotes: 'KI-Schätzung aus dem Foto.',
);

/// Second case: a density the server deliberately does NOT reconcile with
/// calories and grams.
const MealAnalysisResult fertiggericht = MealAnalysisResult(
  mealName: 'Fertiggericht',
  caloriesKcal: 850,
  estimatedGrams: 300,
  kcalPer100G: 260,
  protein: '30 g',
  carbs: '80 g',
  fat: '35 g',
  confidence: 'Datenbank',
  portionNotes: 'Produktdatenbank.',
);

const Key _addKey = ValueKey('suggestion-add');

/// The only `<n> kcal` number in the expanded card: the live preview above the
/// button. The header subtitle ends in "/ 100 g" and is not matched.
int vorschauKcal(WidgetTester tester) {
  final treffer = tester
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.data)
      .whereType<String>()
      .where((text) => RegExp(r'^\d+ kcal$').hasMatch(text))
      .toList(growable: false);
  expect(treffer, hasLength(1), reason: 'genau eine Live-Vorschau erwartet');
  return int.parse(treffer.single.split(' ').first);
}

Future<List<MealAnalysisResult>> pumpItem(
  WidgetTester tester,
  MealAnalysisResult result,
) async {
  final geloggt = <MealAnalysisResult>[];
  await pumpLocalized(
    tester,
    Center(
      child: SizedBox(
        width: 360,
        child: MealSuggestionItem(
          result: result,
          expanded: true,
          onTap: () {},
          onAdd: geloggt.add,
          addButtonKey: _addKey,
        ),
      ),
    ),
    // Motion as before the migration.
    reducedMotion: false,
    safeArea: false,
    settle: true,
  );
  return geloggt;
}

Future<void> tippeGramm(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Apfelkuchen: Vorschau bei der Ursprungsportion zeigt die geloggten 420 kcal',
    (tester) async {
      final geloggt = await pumpItem(tester, apfelkuchen);

      expect(vorschauKcal(tester), 420);

      await tester.tap(find.byKey(_addKey));
      await tester.pump();

      expect(geloggt, hasLength(1));
      expect(geloggt.single.caloriesKcal, 420);
      expect(geloggt.single.caloriesKcal, vorschauKcal(tester));
    },
  );

  testWidgets('Apfelkuchen: 300 g zeigen und loggen dieselben 840 kcal', (
    tester,
  ) async {
    final geloggt = await pumpItem(tester, apfelkuchen);
    await tippeGramm(tester, '300');

    expect(vorschauKcal(tester), 840);

    await tester.tap(find.byKey(_addKey));
    await tester.pump();

    expect(geloggt.single.caloriesKcal, 840);
    expect(geloggt.single.estimatedGrams, 300);
  });

  testWidgets(
    'Unpassende Dichte: 300 g zeigen und loggen die autoritativen 850 kcal',
    (tester) async {
      final geloggt = await pumpItem(tester, fertiggericht);

      expect(vorschauKcal(tester), 850);

      await tester.tap(find.byKey(_addKey));
      await tester.pump();

      expect(geloggt.single.caloriesKcal, 850);
    },
  );

  testWidgets('Vorschau und geloggter Wert sind über den ganzen Regler gleich', (
    tester,
  ) async {
    for (final gramm in <int>[5, 90, 150, 300, 999]) {
      final geloggt = await pumpItem(tester, apfelkuchen);
      await tippeGramm(tester, '$gramm');
      final angezeigt = vorschauKcal(tester);

      await tester.tap(find.byKey(_addKey));
      await tester.pump();

      expect(
        geloggt.single.caloriesKcal,
        angezeigt,
        reason: 'bei $gramm g divergieren Vorschau und Speicherpfad',
      );
    }
  });

  // ─── Gap 3: bounds ───────────────────────────────────────────────────

  testWidgets('1200 g sind eine gültige Portion und werden nicht geklemmt', (
    tester,
  ) async {
    final geloggt = await pumpItem(tester, apfelkuchen);
    await tippeGramm(tester, '1200');

    await tester.tap(find.byKey(_addKey));
    await tester.pump();

    expect(geloggt.single.estimatedGrams, 1200);
    expect(geloggt.single.caloriesKcal, 3360);
  });

  testWidgets('12000 g werden abgelehnt statt still auf die Grenze geklemmt', (
    tester,
  ) async {
    final geloggt = await pumpItem(tester, apfelkuchen);
    await tippeGramm(tester, '12000');

    expect(
      find.byKey(const ValueKey('kcal-suggestion-grams-hint')),
      findsOneWidget,
      reason: 'unplausible Eingabe muss sichtbar zurückgewiesen werden',
    );
    expect(
      tester.widget<FilledButton>(find.byKey(_addKey)).enabled,
      isFalse,
      reason: 'mit ungültiger Portion darf nichts loggbar sein',
    );

    await tester.tap(find.byKey(_addKey));
    await tester.pump();
    expect(geloggt, isEmpty);

    // 0 g is no portion either, and a valid entry lifts the lock again.
    await tippeGramm(tester, '0');
    expect(
      find.byKey(const ValueKey('kcal-suggestion-grams-hint')),
      findsOneWidget,
    );

    await tippeGramm(tester, '200');
    expect(
      find.byKey(const ValueKey('kcal-suggestion-grams-hint')),
      findsNothing,
    );
    await tester.tap(find.byKey(_addKey));
    await tester.pump();
    expect(geloggt.single.estimatedGrams, 200);
  });
}
