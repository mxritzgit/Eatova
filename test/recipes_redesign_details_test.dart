// Details of the redesigned Recipes tab (dark redesign Task 4) that the
// wiring suite does not reach: which photos carry the "AI-generated image"
// label, and that the horizontal shelves keep their own scroll position.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/recipe_pick.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/widgets/recipes/recipe_photo.dart';

import 'design/recipes_redesign_capture_test.dart'
    show designOwnRecipes, pumpDesignRecipes;
import 'support/design_capture.dart' show loadDesignFonts;
import 'support/harness.dart';

FitnessRecipe _own({String slug = 'user_bowl', String imageAsset = ''}) =>
    FitnessRecipe(
      slug: slug,
      title: 'Own bowl',
      description: '',
      portion: '',
      ingredients: '',
      preparation: '',
      professionalHint: '',
      imageAsset: imageAsset,
      caloriesKcal: 450,
      proteinG: 35,
      carbsG: 40,
      fatG: 12,
      estimatedGrams: 300,
      categories: const <String>[],
      userCreated: true,
    );

RecipePick _pick(FitnessRecipe recipe) => RecipePick(
  recipe: recipe,
  slot: MealSlot.dinner,
  source: RecipePickSource.suggested,
  servings: 1,
  kcal: recipe.caloriesKcal,
  proteinG: recipe.proteinG,
  remainingKcalBefore: 900,
);

Future<void> _pumpHero(WidgetTester tester, FitnessRecipe recipe) async {
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    RecipesScreen(
      onAddMeal: (MealAnalysisResult _, MealSlot __) {},
      mealPick: _pick(recipe),
      onAddPickToToday: (_, _) async => 'id',
    ),
    locale: const Locale('en'),
    settle: true,
  );
}

void main() {
  group('AI-generated label', () {
    final catalog = recipeCatalogDe.first;

    test('only bundled catalog photos are known to be AI-generated', () {
      expect(RecipePhoto.isAiGenerated(catalog), isTrue);
      // A meal-plan snapshot of a catalog recipe keeps its bundled photo.
      expect(
        RecipePhoto.isAiGenerated(
          _own(slug: catalog.slug, imageAsset: catalog.imageAsset),
        ),
        isTrue,
      );
      // No photo, a device photo (may be the user's own shot, even on a coach
      // recipe) or a foreign path: never claimed as AI.
      expect(RecipePhoto.isAiGenerated(_own()), isFalse);
      expect(
        RecipePhoto.isAiGenerated(
          _own(slug: 'user_coach_m1', imageAsset: 'local:img_ab.jpg'),
        ),
        isFalse,
      );
      expect(
        RecipePhoto.isAiGenerated(_own(imageAsset: catalog.imageAsset)),
        isFalse,
      );
    });

    testWidgets('the hero labels a catalog photo', (tester) async {
      await _pumpHero(tester, recipeCatalogEn.first);
      expect(
        find.byKey(const ValueKey('recipe-hero-ai-label')),
        findsOneWidget,
      );
      expect(find.text('AI-generated image'), findsOneWidget);
    });

    testWidgets('the hero shows no label and the glowing art without a photo', (
      tester,
    ) async {
      await _pumpHero(tester, _own());
      expect(find.byKey(const ValueKey('recipe-hero-ai-label')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('recipe-hero')),
          matching: find.byKey(const ValueKey('recipe-art-bowl')),
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('a shelf does not take over the page\'s scroll offset', (
    tester,
  ) async {
    // Regression: without their own PageStorage slot the shelves shared the
    // list's entry and, when they scrolled into view, restored the page's
    // vertical offset as their horizontal one (first card half off screen).
    await withClock(Clock.fixed(DateTime(2026, 9, 28, 18, 30)), () async {
      await pumpDesignRecipes(tester);
      final list = find
          .descendant(
            of: find.byKey(const ValueKey('screen-recipes')),
            matching: find.byType(Scrollable),
          )
          .first;
      Future<void> expectShelvesAtStart(String where) async {
        for (final key in const ['recipe-shelf-lean', 'recipe-goal-matches']) {
          final shelf = find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(Scrollable),
          );
          if (shelf.evaluate().isEmpty) continue;
          expect(
            tester.state<ScrollableState>(shelf.first).position.pixels,
            0,
            reason: '$key $where',
          );
        }
      }

      // The goal shelf sits at the list end and is built only there.
      final position = tester.state<ScrollableState>(list).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recipe-goal-matches')),
        findsOneWidget,
        reason: 'Vorbedingung: the goal shelf is built at the end.',
      );
      await expectShelvesAtStart('at the end');
      // Back to the top: the lean shelf is rebuilt from storage.
      position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('recipe-shelf-lean')),
        200,
        scrollable: list,
      );
      expect(find.byKey(const ValueKey('recipe-shelf-lean')), findsOneWidget);
      await expectShelvesAtStart('back at the top');
    });
  });

  group('text scale: no overflow over the whole For you page and a list', () {
    setUpAll(loadDesignFonts);

    for (final (size, scale, locale) in const <(Size, double, String)>[
      (Size(390, 844), 1.3, 'de'),
      (Size(390, 844), 1.3, 'en'),
      (Size(320, 568), 1.0, 'de'),
      (Size(320, 568), 1.0, 'en'),
    ]) {
      testWidgets('${size.width.toInt()} px, ${scale}x, $locale', (
        tester,
      ) async {
        final errors = <String>[];
        final prior = FlutterError.onError;
        FlutterError.onError = (details) =>
            errors.add(details.exceptionAsString().split('\n').first);
        try {
          await pumpLocalized(
            tester,
            RecipesScreen(
              onAddMeal: (MealAnalysisResult _, MealSlot __) {},
              mealPick: _pick(
                recipeCatalogForLocale(locale).firstWhere(
                  (r) => r.slug == 'putensteak_mit_quinoa_and_ofengemuse',
                ),
              ),
              onAddPickToToday: (_, _) async => 'id',
              isFavorite: (_) => false,
              onToggleFavorite: (_) async {},
              onImport: () {},
              onOpenMealPlan: () {},
              initialUserRecipes: designOwnRecipes,
              remainingMacros: const MacroProgress(
                proteinG: 60,
                carbsG: 80,
                fatG: 30,
                kcal: 900,
              ),
            ),
            locale: Locale(locale),
            textScale: scale,
            surfaceSize: size,
            settle: true,
          );
          final list = find
              .descendant(
                of: find.byKey(const ValueKey('screen-recipes')),
                matching: find.byType(Scrollable),
              )
              .first;
          Future<void> scrollThrough() async {
            final position = tester.state<ScrollableState>(list).position;
            position.jumpTo(0);
            await tester.pumpAndSettle();
            while (position.pixels < position.maxScrollExtent) {
              position.jumpTo(
                (position.pixels + 300).clamp(0.0, position.maxScrollExtent),
              );
              await tester.pumpAndSettle();
            }
          }

          await scrollThrough();
          // A list view with the own section (card, heading, rows).
          tester.state<ScrollableState>(list).position.jumpTo(0);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('recipes-tab-own')));
          await tester.pumpAndSettle();
          await scrollThrough();
        } finally {
          FlutterError.onError = prior;
        }
        expect(errors, isEmpty, reason: errors.join('\n'));
      });
    }
  });
}
