import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/recipes/recipe_photo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  testWidgets('catalog photo survives serialization into a meal plan', (
    tester,
  ) async {
    final recipe = recipeCatalogDe.first;
    final snapshot = PlannedMeal.create(
      recipe: recipe,
      day: DateTime(2026, 9, 10),
      slot: MealSlot.lunch,
    ).recipe;
    expect(snapshot.userCreated, isTrue);
    await pumpLocalized(
      tester,
      SizedBox(width: 82, height: 92, child: RecipePhoto(recipe: snapshot)),
      settle: true,
    );
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(ImagePlaceholder), findsNothing);
  });

  for (final wrongSlug in [false, true]) {
    testWidgets(
      'persisted photo requires matching catalog slug and path ($wrongSlug)',
      (tester) async {
        final recipe = FitnessRecipe.fromRow({
          ...recipeCatalogDe.first.toRow(),
          'slug': wrongSlug ? 'user_custom' : recipeCatalogDe.first.slug,
          'image_asset': wrongSlug
              ? recipeCatalogDe.first.imageAsset
              : recipeCatalogDe.last.imageAsset,
        });
        await pumpLocalized(
          tester,
          SizedBox(width: 82, height: 92, child: RecipePhoto(recipe: recipe)),
          settle: true,
        );
        expect(find.byType(Image), findsNothing);
        expect(find.byType(ImagePlaceholder), findsOneWidget);
      },
    );
  }

  testWidgets(
    'pinned detail action leaves most of the viewport for the recipe',
    (tester) async {
      await pumpLocalized(
        tester,
        RecipeDetailScreen(
          recipe: recipeCatalogEn.first,
          onAddMeal: (_, __) {},
        ),
        locale: const Locale('en'),
        surfaceSize: const Size(393, 852),
        scaffold: false,
        safeArea: false,
        settle: true,
      );
      final body = tester.getRect(
        find.byKey(const ValueKey('recipe-detail-scroll')),
      );
      final action = tester.getRect(
        find.byKey(const ValueKey('recipe-add-card')),
      );
      expect(body.height, greaterThan(852 * .65));
      expect(action.height, lessThan(852 * .3));
      expect(body.bottom, lessThanOrEqualTo(action.top));
      expect(
        find.byKey(const ValueKey('recipe-add-button')).hitTestable(),
        findsOneWidget,
      );
    },
  );
}
