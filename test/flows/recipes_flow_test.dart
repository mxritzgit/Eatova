// Rezept-Flows (aus test/widget_test.dart aufgeteilt): Rezept-Detail traegt
// die Mahlzeit in den kcal-/Makro-Tracker ein — und zwar auf den im Food-Tab
// gewaehlten Tag, nicht stumpf auf heute.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';

import 'flow_test_helpers.dart';

void main() {
  testWidgetsRobust('Recipe detail can add a meal into kcal and macro tracker', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const EatovaApp());

    await tester.tap(find.byKey(const ValueKey('nav-Rezepte')));
    await tester.pumpAndSettle();

    final recipeTile = find.byKey(
      const ValueKey('recipe-tile-hahnchen_mit_reis_and_brokkoli'),
    );
    await tester.ensureVisible(recipeTile);
    await tester.tap(recipeTile);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('recipe-detail-hahnchen_mit_reis_and_brokkoli')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('recipe-add-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('recipe-add-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('recipe-meal-picker-lunch')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('recipe-add-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recipe-meal-picker-sheet')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('recipe-meal-picker-lunch')));
    await tester.pumpAndSettle();
    expect(find.text('590 kcal zu Mittagessen hinzugefügt.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('recipe-detail-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('590 kcal'),
      ),
      findsOneWidget,
    );

    expect(find.text('Hähnchen mit Reis & Brokkoli'), findsWidgets);
    expect(find.textContaining('590'), findsWidgets);
  });

  // Bugfix 2026-08-06: RecipesScreen bekam ein hartes foodDate:
  // DateTime.now() — „Zum Tracker hinzufügen" landete IMMER auf heute, auch
  // wenn im Food-Tab ein anderer Tag gewaehlt war. Jetzt faellt der Pfad auf
  // das im Store gewaehlte selectedFoodDate zurueck.
  testWidgetsRobust('Recipe lands on the day selected in the food tab', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const EatovaApp());

    // Food-Tab: Gestern waehlen (Chip 3, Heute ist Chip 4).
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('food-date-chip-3')));
    await tester.pumpAndSettle();
    expect(find.text('Gestern'), findsWidgets);

    // Rezept ueber den Detail-Screen zum Tracker hinzufuegen.
    await tester.tap(find.byKey(const ValueKey('nav-Rezepte')));
    await tester.pumpAndSettle();
    final recipeTile = find.byKey(
      const ValueKey('recipe-tile-hahnchen_mit_reis_and_brokkoli'),
    );
    await tester.ensureVisible(recipeTile);
    await tester.tap(recipeTile);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recipe-add-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recipe-meal-picker-lunch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recipe-detail-back')));
    await tester.pumpAndSettle();

    // Zurueck im Food-Tab: die Auswahl steht noch auf Gestern und traegt
    // die 590 kcal des Rezepts + den Verlaufseintrag.
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();
    expect(find.text('Gestern'), findsWidgets);
    expect(find.byKey(const ValueKey('food-history-entry-0')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('590 kcal'),
      ),
      findsOneWidget,
    );

    // Heute bleibt leer — genau das war der Bug.
    await tester.tap(find.byKey(const ValueKey('food-date-chip-4')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('food-history-entry-0')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('0 kcal'),
      ),
      findsOneWidget,
    );
  });
}
