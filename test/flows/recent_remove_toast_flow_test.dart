// Review 2026-10-11 (FOOD-2): the add sheet forgets a recent through the
// store's removeFavorite, whose toast always said "Favorite removed" — for a
// meal that never was a favorite.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';

import 'flow_test_helpers.dart';

const MealAnalysisResult _porridge = MealAnalysisResult(
  mealName: 'Porridge',
  caloriesKcal: 310,
  estimatedGrams: 250,
  kcalPer100G: 124,
  protein: '11 g',
  carbs: '50 g',
  fat: '7 g',
  confidence: 'manual',
  portionNotes: '',
  sourceLabel: 'manual',
);

void main() {
  testWidgetsRobust(
    'Aus den letzten Mahlzeiten entfernen sagt nicht "Favorit entfernt"',
    (WidgetTester tester) async {
      tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await tester.pumpWidget(
        EatovaApp(productService: FakeProductLookupService()),
      );
      await tester.tap(find.byKey(const ValueKey('nav-Food')));
      await tester.pumpAndSettle();
      final store = storeOf(tester);
      await store.addResultToDailyTotal(_porridge, slot: MealSlot.breakfast);
      await tester.pumpAndSettle();
      expect(store.favorites.single.pinned, isFalse);

      await tester.tap(find.byKey(const ValueKey('food-search')));
      await tester.pumpAndSettle();
      final tile = find.byKey(const ValueKey('favorite-tile-0'));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      final remove = find.byKey(const ValueKey('favorite-tile-0-remove'));
      await tester.ensureVisible(remove);
      await tester.pumpAndSettle();
      await tester.tap(remove);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(store.favorites, isEmpty);
      expect(find.text('Favorit entfernt'), findsNothing);
      expect(find.text('Aus letzten Mahlzeiten entfernt'), findsOneWidget);

      // The undo still restores the recent.
      await tester.tap(find.text('Rückgängig'));
      await tester.pumpAndSettle();
      expect(store.favorites.single.result.mealName, 'Porridge');
      expect(store.favorites.single.pinned, isFalse);
    },
  );
}
