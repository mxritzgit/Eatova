import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../l10n/l10n.dart';
import '../services/local_day.dart';
import 'planned_meal.dart';
import 'recipe_ingredient_projection.dart';

class ShoppingItem {
  const ShoppingItem({
    required this.id,
    required this.name,
    this.grams,
    this.recipeTitle,
    this.servings,
    this.originalQuantities = false,
    this.originalBatchServings,
    this.planId,
  });
  final String id, name;
  final double? grams;
  final String? recipeTitle;

  /// The planned meal behind a free-text item (for its photo); display only,
  /// not part of [id].
  final String? planId;
  final double? servings;
  final bool originalQuantities;
  final double? originalBatchServings;
}

/// Combines only exact structured identities in grams. Free text retains its
/// recipe and serving context without inferring units or parsing quantities.
/// [decimalSeparator] and [l10n] only affect displayed names; ids stay
/// locale-neutral.
List<ShoppingItem> buildShoppingList(
  List<PlannedMeal> plans,
  DateTime weekStart, {
  String decimalSeparator = '.',
  AppLocalizations? l10n,
}) {
  final start = localDayKey(weekStart);
  final end = localDayKey(
    DateTime(weekStart.year, weekStart.month, weekStart.day + 7),
  );
  final groups = <String, ({String name, double grams})>{};
  final sources = <String, Set<String>>{};
  final unquantified = <ShoppingItem>[];
  String identity(Object value) =>
      '$start:${sha256.convert(utf8.encode(jsonEncode(value)))}';
  final sorted =
      plans
          .where(
            (p) =>
                !p.removed &&
                !p.isEaten &&
                p.day.compareTo(start) >= 0 &&
                p.day.compareTo(end) < 0,
          )
          .toList()
        ..sort((a, b) => a.id.compareTo(b.id));
  for (final plan in sorted) {
    final recipe = plan.recipe;
    final projection = recipe.ingredientProjectionForServings(plan.servings);
    if (recipe.structuredIngredients.isEmpty ||
        recipe.ingredients.trim().isNotEmpty) {
      unquantified.add(
        ShoppingItem(
          id: identity(['text', plan.id, projection.text, plan.servings]),
          name: decimalSeparator == '.'
              ? projection.text
              : recipe.ingredientProjectionForServings(plan.servings,
                  decimalSeparator: decimalSeparator).text,
          originalQuantities: recipe.hasImportedIngredientContext && !projection.isScaled,
          originalBatchServings: recipe.ingredientsBasis == RecipeIngredientsBasis.perRecipe
              ? recipe.batchServings : recipe.ingredientsBasis == RecipeIngredientsBasis.perServing ? 1 : null,
          recipeTitle: l10n == null ? recipe.title : recipe.displayTitle(l10n),
          servings: plan.servings,
          planId: plan.id,
        ),
      );
    }
    for (final ingredient in recipe.structuredIngredients) {
      final key = ingredient.shoppingKey;
      (sources[key] ??= {}).add(plan.id);
      final previous = groups[key];
      groups[key] = (
        name:
            previous?.name ??
            (l10n == null ? ingredient.name : ingredient.displayName(l10n)),
        grams:
            (previous?.grams ?? 0) +
            ingredient.grams * plan.servings / recipe.batchServings,
      );
    }
  }
  final quantified =
      groups.entries
          .map(
            (e) => ShoppingItem(
              id: identity([
                'grams',
                e.key,
                e.value.grams.toStringAsFixed(6),
                sources[e.key]!.toList()..sort(),
              ]),
              name: e.value.name,
              grams: e.value.grams,
            ),
          )
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return [...quantified, ...unquantified];
}
