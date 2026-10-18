// E3 through the real shell: the Food tab hands the add sheet the store's
// whole diary and its own recipes (FoodStoreScope in eatova_home_page.dart),
// so the search finds a meal that already fell out of the recents.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';

import '../flows/flow_test_helpers.dart';

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

const FitnessRecipe _chili = FitnessRecipe(
  slug: 'user_chili_sin_carne',
  title: 'Chili sin Carne',
  description: '',
  portion: '',
  ingredients: '',
  preparation: '',
  professionalHint: '',
  imageAsset: '',
  caloriesKcal: 520,
  proteinG: 28,
  carbsG: 60,
  fatG: 14,
  estimatedGrams: 450,
  categories: <String>[],
  userCreated: true,
);

Finder _input() => find.byKey(const ValueKey('kcal-product-search-input'));

/// [text] inside the "From you" section, not the diary behind the sheet.
Finder _inSection(String text) => find.descendant(
  of: find.byKey(const ValueKey('food-history-section')),
  matching: find.text(text),
);

void main() {
  testWidgetsRobust('die Suche findet ein Gericht aus dem Tagebuch, das aus '
      'den Zuletzt-Einträgen gefallen ist, und ein eigenes Rezept', (
    WidgetTester tester,
  ) async {
    tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(
      EatovaApp(productService: FakeProductLookupService()),
    );
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();
    final store = storeOf(tester);

    final soup = _meal('Omas Linsensuppe', 420);
    await withClock(
      Clock.fixed(DateTime(2026, 9, 1, 12)),
      // A past day: the sheet's own day list cannot hold it.
      () => store.addResultToDailyTotal(
        soup,
        slot: MealSlot.lunch,
        foodDate: DateTime(2026, 9, 1),
      ),
    );
    // A full cap of newer meals pushes the soup out of the recents.
    for (var i = 0; i < FavoriteMeal.maxAutoRecents; i++) {
      await withClock(
        Clock.fixed(DateTime(2026, 10, 1 + i, 12)),
        () => store.addResultToDailyTotal(
          _meal('Mahlzeit $i', 300 + i),
          slot: MealSlot.lunch,
        ),
      );
    }
    await store.createUserRecipe(_chili);
    await tester.pumpAndSettle();
    expect(
      store.favorites.where((f) => f.result.mealName == soup.mealName),
      isEmpty,
      reason: 'Voraussetzung: die Suppe ist kein Zuletzt-Eintrag mehr',
    );
    expect(store.favorites, hasLength(FavoriteMeal.maxAutoRecents));

    await tester.tap(find.byKey(const ValueKey('food-search')));
    await tester.pumpAndSettle();

    await tester.enterText(_input(), 'linsen');
    await tester.pump();
    expect(_inSection('Omas Linsensuppe'), findsOneWidget);

    await tester.enterText(_input(), 'chili');
    await tester.pump(const Duration(milliseconds: 200));
    expect(_inSection('Chili sin Carne'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });
}
