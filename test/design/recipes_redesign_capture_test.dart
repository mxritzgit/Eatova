// Visual evidence for the Recipes tab of the dark redesign (Task 4).
//
// Mounts the real home page at the design's reference geometry in the design
// scenario: Mon 2026-09-28 18:30, a 2,123 kcal goal, breakfast, lunch and
// snacks logged (1,221 kcal), dinner open, so the shared pick is the turkey
// steak (610 kcal, 58 g protein) that fits the 902 kcal left. Three own
// recipes without photos stand in for the design's placeholder cards on the
// "High protein, under 500 kcal" shelf.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the shots land in
// build/dark-redesign/recipes-00.png and recipes-01.png (scroll 383, the
// design's `recipes-01`). Without it the suite still pins the scenario.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_day.dart';

import '../flows/flow_test_helpers.dart' show storeOf;
import '../support/design_capture.dart';
import '../support/harness.dart';

final _now = DateTime(2026, 9, 28, 18, 30);

const _profile = UserProfile(
  dailyKcalGoal: 2123,
  proteinGoalG: 162,
  carbsGoalG: 222,
  fatGoalG: 57,
);

LoggedMeal _meal(
  String id,
  DateTime at,
  int kcal,
  String protein, {
  MealSlot? slot,
}) => LoggedMeal(
  id: id,
  loggedAt: at,
  localDay: localDayKey(at),
  forcedSlot: slot,
  result: MealAnalysisResult(
    mealName: 'Meal $id',
    caloriesKcal: kcal,
    estimatedGrams: 200,
    kcalPer100G: kcal / 2,
    protein: protein,
    carbs: '0 g',
    fat: '0 g',
    confidence: 'Hoch',
    portionNotes: '',
  ),
);

/// The design day: 401 + 597 + 223 = 1,221 kcal; dinner still open.
List<LoggedMeal> designDay() => [
  _meal('b1', DateTime(2026, 9, 28, 8, 10), 158, '25 g'),
  _meal('b2', DateTime(2026, 9, 28, 8, 12), 186, '7 g'),
  _meal('b3', DateTime(2026, 9, 28, 8, 11), 57, '1 g'),
  _meal('l1', DateTime(2026, 9, 28, 12, 45), 597, '50 g'),
  _meal('s1', DateTime(2026, 9, 28, 16, 20), 105, '1 g', slot: MealSlot.snack),
  _meal('s2', DateTime(2026, 9, 28, 16, 25), 118, '27 g', slot: MealSlot.snack),
];

FitnessRecipe _own(
  String slug,
  String title,
  int kcal,
  int protein, {
  List<String> categories = const <String>[],
}) => FitnessRecipe(
  slug: 'user_$slug',
  title: title,
  description: '',
  portion: '1 bowl',
  ingredients: '',
  preparation: '',
  professionalHint: '',
  imageAsset: '',
  caloriesKcal: kcal,
  proteinG: protein,
  carbsG: 30,
  fatG: 12,
  estimatedGrams: 350,
  categories: categories,
  userCreated: true,
);

/// The design's shelf cards, as own recipes without photos. Saved in reverse:
/// the store puts the newest first.
final designOwnRecipes = <FitnessRecipe>[
  _own('soup', 'Chicken Lentil Soup', 420, 38),
  _own('poke', 'Salmon & Greens Poke', 480, 36, categories: ['Fisch']),
  _own('yogurt', 'Greek Yogurt Berry Bowl', 380, 32),
];

/// Mounts the home page, seeds the design scenario and opens Recipes.
Future<HomeStore> pumpDesignRecipes(WidgetTester tester) async {
  pinDesignViewport(tester);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        EatovaHomePage(),
        locale: const Locale('en'),
        safeArea: false,
        scaffold: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
  final store = storeOf(tester)
    ..profile = _profile
    ..loggedMeals = designDay();
  for (final recipe in designOwnRecipes) {
    await store.saveUserRecipe(recipe);
  }
  await tester.tap(find.byKey(const ValueKey('nav-Rezepte')));
  await tester.pumpAndSettle();
  return store;
}

void main() {
  setUpAll(loadDesignFonts);

  testWidgets('recipes-00 / recipes-01: the design scenario', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final store = await pumpDesignRecipes(tester);
      expect(store.selectedTab, 2);

      // The hero is the shared pick of the design scenario.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('recipe-hero')),
          matching: find.text('Turkey Steak with Quinoa & Roasted Vegetables'),
        ),
        findsOneWidget,
      );
      expect(find.text('PICKED FOR TONIGHT'), findsOneWidget);
      expect(find.byKey(const ValueKey('recipe-hero-fits')), findsOneWidget);
      expect(find.text('Add to dinner'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('recipe-hero-ai-label')),
        findsOneWidget,
      );
      // The design's first shelf cards are the three own recipes.
      for (final recipe in designOwnRecipes) {
        expect(
          find.byKey(ValueKey('recipe-shelf-lean-${recipe.slug}')),
          findsOneWidget,
        );
      }

      await precacheDesignImages(tester);
      await captureDesignShot(tester, 'recipes-00');

      final list = find.byKey(const ValueKey('screen-recipes'));
      final offset = await scrollDesignTabBy(
        tester,
        383,
        scrollable: find
            .descendant(of: list, matching: find.byType(Scrollable))
            .first,
      );
      expect(offset, 383, reason: 'design shot recipes-01 sits at 383');
      expect(
        find.byKey(const ValueKey('recipes-your-recipes')),
        findsOneWidget,
      );
      await precacheDesignImages(tester);
      await captureDesignShot(tester, 'recipes-01');
      expect(tester.takeException(), isNull);
    });
  });
}
