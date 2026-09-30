import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The recipes tab's vertical list.
Finder recipesList() => find
    .descendant(
      of: find.byKey(const ValueKey('screen-recipes')),
      matching: find.byType(Scrollable),
    )
    .first;

/// Builds the chip with [key] in the lazy chip bar and scrolls it on screen,
/// without tapping it: the list back up to the bar, then the bar sideways.
Future<void> revealRecipeChip(WidgetTester tester, String key) async {
  final chip = find.byKey(ValueKey(key));
  final bar = find.byKey(const ValueKey('recipes-chip-bar'));
  if (bar.evaluate().isEmpty) {
    await tester.scrollUntilVisible(bar, -250, scrollable: recipesList());
  }
  if (chip.evaluate().isEmpty) {
    final barScroll = find
        .descendant(of: bar, matching: find.byType(Scrollable))
        .first;
    tester.state<ScrollableState>(barScroll).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(chip, 120, scrollable: barScroll);
  }
  await tester.ensureVisible(chip);
  await tester.pumpAndSettle();
}

/// Follow the library's visible tabs, including after its lazy header recycles.
///
/// The sections are chips of the horizontal chip bar (dark redesign).
Future<void> selectRecipeSection(WidgetTester tester, String section) async {
  final tab = find.byKey(ValueKey('recipes-tab-$section'));
  if (tab.evaluate().isNotEmpty &&
      tester.widget<Semantics>(tab).properties.selected == true) {
    return;
  }
  await revealRecipeChip(tester, 'recipes-tab-$section');
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

/// Taps the category chip [filter] (a `recipeFilters` identity), scrolling
/// the list up and the chip bar sideways until it is on screen.
Future<void> selectRecipeFilter(WidgetTester tester, String filter) async {
  await revealRecipeChip(tester, 'recipe-filter-$filter');
  await tester.tap(find.byKey(ValueKey('recipe-filter-$filter')));
  await tester.pumpAndSettle();
}

/// Scrolls the recipes list down until [key] is built and on screen, then
/// taps it — for the "Your recipes" card's Import/Create and other controls
/// below the fold.
Future<void> tapRecipeAction(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.scrollUntilVisible(target, 250, scrollable: recipesList());
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// Opens the create sheet through the "Your recipes" card.
Future<void> openRecipeCreateSheet(WidgetTester tester) =>
    tapRecipeAction(tester, 'recipe-create-button');
