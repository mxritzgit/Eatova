// Gaps 1 and 3 from B1 (docs/REVIEW-2026-08-08.md), measured on the expanded
// MealSuggestionItem. Core question: does the kcal preview beside the round
// add button show the value that gets logged on tap?

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

/// The live preview next to the add button — the number the user sees right
/// before tapping. (The row header shows the saved portion's kcal, so the
/// preview is read by its key, not as "the only `<n> kcal` text".)
int vorschauKcal(WidgetTester tester) {
  final vorschau = find.byKey(const ValueKey('live-preview-kcal'));
  expect(vorschau, findsOneWidget, reason: 'genau eine Live-Vorschau erwartet');
  final text = tester.widget<Text>(vorschau).textSpan!.toPlainText();
  expect(text, matches(RegExp(r'^\d+ kcal$')));
  return int.parse(text.split(' ').first);
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
    'Apfelkuchen: Vorschau und geloggter Wert sind ueber den ganzen Regler '
    'gleich, an der Ursprungsportion die gemessenen 420 kcal',
    (tester) async {
      // null = the original portion, untouched.
      for (final (gramm, erwartet) in <(int?, int?)>[
        (null, 420),
        (300, 840),
        (5, null),
        (90, null),
        (999, null),
      ]) {
        final geloggt = await pumpItem(tester, apfelkuchen);
        if (gramm != null) await tippeGramm(tester, '$gramm');
        final angezeigt = vorschauKcal(tester);
        if (erwartet != null) expect(angezeigt, erwartet, reason: '$gramm g');

        await tester.tap(find.byKey(_addKey));
        await tester.pump();

        expect(
          geloggt.single.caloriesKcal,
          angezeigt,
          reason: 'bei $gramm g divergieren Vorschau und Speicherpfad',
        );
        if (gramm != null) expect(geloggt.single.estimatedGrams, gramm);
      }
    },
  );

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

  // ─── Gap 3: bounds ───────────────────────────────────────────────────

  testWidgets('1200 g sind gueltig und ungeklemmt; 12000 g und 0 g werden '
      'abgelehnt statt still auf eine Grenze geklemmt', (tester) async {
    final gross = await pumpItem(tester, apfelkuchen);
    await tippeGramm(tester, '1200');
    await tester.tap(find.byKey(_addKey));
    await tester.pump();
    expect(gross.single.estimatedGrams, 1200);
    expect(gross.single.caloriesKcal, 3360);

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

  // Review 2026-10-04: a screen reader heard the portion slider as "15%"
  // (its share of the 1..1000 g window) and the field as an unnamed "150".
  testWidgets('Regler und Feld nennen dem Screenreader die Portion in Gramm', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpItem(tester, apfelkuchen);

    expect(find.semantics.byValue('150 g'), findsOne);
    expect(find.semantics.byValue('15%'), findsNothing);
    expect(tester.getSemantics(find.byType(TextField)).label, 'Gewicht');

    await tippeGramm(tester, '300');
    expect(find.semantics.byValue('300 g'), findsOne);
    semantics.dispose();
  });
}
