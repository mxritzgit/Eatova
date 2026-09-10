import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../services/local_day.dart';
import 'planned_meal.dart';

class ShoppingItem {
  const ShoppingItem({
    required this.id,
    required this.name,
    this.grams,
    this.recipeTitle,
    this.servings,
  });
  final String id, name;
  final double? grams;
  final String? recipeTitle;
  final double? servings;
}

/// Combines only exact structured identities in grams. Free text retains its
/// recipe and serving context without inferring units or parsing quantities.
List<ShoppingItem> buildShoppingList(
  List<PlannedMeal> plans,
  DateTime weekStart,
) {
  final start = localDayKey(weekStart);
  final end = localDayKey(
    DateTime(weekStart.year, weekStart.month, weekStart.day + 7),
  );
  final groups = <String, ({String name, double grams})>{};
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
    if (recipe.structuredIngredients.isEmpty) {
      unquantified.add(
        ShoppingItem(
          id: identity(['text', plan.id, recipe.ingredients, plan.servings]),
          name: recipe.ingredients,
          recipeTitle: recipe.title,
          servings: plan.servings,
        ),
      );
      continue;
    }
    for (final ingredient in recipe.structuredIngredients) {
      final key = ingredient.shoppingKey;
      final previous = groups[key];
      groups[key] = (
        name: previous?.name ?? ingredient.name,
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
              id: identity(['grams', e.key, e.value.grams.toStringAsFixed(6)]),
              name: e.value.name,
              grams: e.value.grams,
            ),
          )
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return [...quantified, ...unquantified];
}
