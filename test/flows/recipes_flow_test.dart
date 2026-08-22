// Recipe flows: the recipe detail adds the meal to the kcal/macro tracker, on
// the day selected in the food tab, not blindly on today.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';

import 'flow_test_helpers.dart';

void main() {
  testWidgetsRobust('Recipe detail can add a meal into kcal and macro tracker', (
    WidgetTester tester,
  ) async {
    // Pin the device language: without an override EatovaApp resolves via
    // resolveEatovaLocale, and the assertions below check verbatim German ARB
    // texts (including slot.label).
    tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
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

    // The daily total lives in the today tab, no longer on a food-tab card
    // (see expectTagestotalAufHeute).
    await expectTagestotalAufHeute(tester, '590');

    // And the food tab holds the entry itself, with name and kcal.
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('food-history-entry-0')), findsOneWidget);
    expect(find.text('Hähnchen mit Reis & Brokkoli'), findsWidgets);
    expect(find.textContaining('590'), findsWidgets);
  });

  // Bugfix: RecipesScreen got a hardcoded `foodDate: DateTime.now()`, so adding
  // to the tracker always landed on today. The path now falls back to the
  // store's selectedFoodDate.
  testWidgetsRobust('Recipe lands on the day selected in the food tab', (
    WidgetTester tester,
  ) async {
    // Pin the device language: without an override EatovaApp resolves via
    // resolveEatovaLocale, and the assertions below check verbatim German ARB
    // texts (including slot.label).
    tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(const EatovaApp());

    // Food tab: pick an archive day. The chip index IS the day offset
    // (chip-0 = today), so chip-3 is three days ago.
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('food-date-chip-3')));
    await tester.pumpAndSettle();
    expect(find.text('Vor 3 Tagen'), findsOneWidget);

    // Add the recipe to the tracker via the detail screen.
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

    // Back in the food tab: the selection is still on the archive day and
    // carries the history entry …
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();
    expect(find.text('Vor 3 Tagen'), findsOneWidget);
    expect(find.byKey(const ValueKey('food-history-entry-0')), findsOneWidget);
    // … and the 590 kcal in the daily total, which the today tab shows for the
    // same selected day.
    await expectTagestotalAufHeute(tester, '590');

    // Another day stays empty — exactly what the bug broke.
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('food-date-chip-4')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('food-history-entry-0')), findsNothing);
    await expectTagestotalAufHeute(tester, '0');
  });
}
