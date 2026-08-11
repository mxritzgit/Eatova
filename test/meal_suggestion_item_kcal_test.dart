// Lücke 1 + Lücke 3 aus B1 (docs/REVIEW-2026-08-08.md), gemessen am
// aufgeklappten MealSuggestionItem — dem Kärtchen, das Suchtreffer,
// angeheftete Favoriten und Recents im AddMealSheet bedient.
//
// Die Kernfrage dieser Suite: zeigt die Zahl direkt über dem
// „Hinzufügen"-Knopf denselben Wert, der beim Tippen geloggt wird?

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/kcal/meal_suggestion_item.dart';

/// Apfelkuchen wie ihn `fromEdgeFunction` aus einer Antwort ohne Gramm- und
/// ohne Dichteangabe baut: 420 kcal sind gemessen, die 150 g sind der
/// Default und die 52 kcal/100 g stammen aus der Namenstabelle
/// (`_knownKcalPer100G` matcht den Teilstring „apfel"). Die drei Zahlen
/// passen um den Faktor 5,4 nicht zusammen.
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

/// Der zweite von V1 gemessene Fall: eine Dichte, die der Server bewusst
/// NICHT mit Kalorien und Gramm abgleicht.
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

/// Die einzige Zahl der Form `<n> kcal` im aufgeklappten Kärtchen — die
/// Live-Vorschau direkt über dem Knopf. Der Untertitel im Kopf endet auf
/// „/ 100 g" und wird davon nicht erfasst.
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
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      // MealSuggestionItem liest seit der i18n-Migration context.l10n.
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: Center(
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
      ),
    ),
  );
  await tester.pumpAndSettle();
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

  // ─── Lücke 3: Grenzen ────────────────────────────────────────────────

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

    // 0 g ist ebenfalls keine Portion — und eine gültige Eingabe hebt die
    // Sperre danach wieder auf.
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
