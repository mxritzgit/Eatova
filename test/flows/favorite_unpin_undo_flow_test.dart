// Review 2026-10-11 (FOOD-1): the favorites menu's heart sits right above
// the one-tap "+", and unpinning there had no undo. The store runs an unpin
// through the recents cap, so a favorite that has not been logged lately is
// deleted outright; a scan or a manual entry cannot be found again. The
// toast now carries an undo that pins it back.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';

import 'flow_test_helpers.dart';

MealAnalysisResult _meal(String name, int kcal) => MealAnalysisResult(
  mealName: name,
  caloriesKcal: kcal,
  estimatedGrams: 300,
  kcalPer100G: kcal / 3,
  protein: '18 g',
  carbs: '40 g',
  fat: '9 g',
  confidence: 'manual',
  portionNotes: '',
  sourceLabel: 'manual',
);

final MealAnalysisResult _soup = _meal('Omas Linsensuppe', 420);

Future<void> _bootFood(WidgetTester tester) async {
  tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  await tester.pumpWidget(EatovaApp(productService: FakeProductLookupService()));
  await tester.tap(find.byKey(const ValueKey('nav-Food')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgetsRobust(
    'Entpinnen im Favoriten-Sheet lässt sich rückgängig machen, auch wenn '
    'der Favorit dabei aus dem Store fällt',
    (WidgetTester tester) async {
      await _bootFood(tester);
      final store = storeOf(tester);

      // Pinned long ago, then a full cap of meals logged since: an unpin
      // sorts the soup behind them and the cap drops it.
      await withClock(
        Clock.fixed(DateTime(2026, 9, 1, 12)),
        () => store.toggleFavorite(_soup),
      );
      for (var i = 0; i < FavoriteMeal.maxAutoRecents; i++) {
        await withClock(
          Clock.fixed(DateTime(2026, 10, 1 + i, 12)),
          () => store.addResultToDailyTotal(
            _meal('Mahlzeit $i', 300 + i),
            slot: MealSlot.lunch,
          ),
        );
      }
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('food-search')));
      await tester.pumpAndSettle();
      final all = find.byKey(const ValueKey('add-meal-favorites-all'));
      await tester.ensureVisible(all);
      await tester.tap(all);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('favorites-sheet-fav-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        store.favorites.where((f) => f.result.mealName == _soup.mealName),
        isEmpty,
        reason: 'das Entpinnen hat den Favoriten über den Recents-Deckel '
            'gelöscht',
      );
      expect(find.text('Favorit entfernt'), findsOneWidget);

      final undo = find.text('Rückgängig');
      expect(undo.hitTestable(), findsOneWidget,
          reason: 'ohne Rückgängig ist der Favorit endgültig weg');
      await tester.tap(undo);
      await tester.pumpAndSettle();

      final restored = store.favorites
          .where((f) => f.result.mealName == _soup.mealName)
          .toList();
      expect(restored, hasLength(1));
      expect(restored.single.pinned, isTrue);
      expect(restored.single.result.caloriesKcal, 420);
      expect(restored.single.result.protein, '18 g');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('favorites-sheet')),
          matching: find.text('Omas Linsensuppe'),
        ),
        findsOneWidget,
        reason: 'die Zeile kommt im offenen Favoriten-Sheet zurück',
      );
    },
  );
}
