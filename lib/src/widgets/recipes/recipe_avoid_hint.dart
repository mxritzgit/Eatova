import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/fitness_recipe.dart';
import '../../models/food_preferences.dart';
import '../design/design.dart';

/// "Enthält Nüsse": a quiet status pill on a recipe that contains foods the
/// user avoids ([FitnessRecipe.avoidedFoods]). Suggestions leave such
/// recipes out; browse lists and the detail keep them and say why instead.
/// Nothing when the recipe contains none of [avoided].
class RecipeAvoidHint extends StatelessWidget {
  const RecipeAvoidHint({
    super.key,
    required this.recipe,
    required this.avoided,
  });

  final FitnessRecipe recipe;
  final Set<FoodAvoidance> avoided;

  @override
  Widget build(BuildContext context) {
    final foods = recipe.avoidedFoods(avoided);
    if (foods.isEmpty) return const SizedBox.shrink();
    final l10n = context.l10n;
    final names = foods.map((food) => food.label(l10n)).join(', ');
    return StatusPill(
      key: ValueKey('recipe-avoid-hint-${recipe.slug}'),
      icon: AppIcons.info,
      label: l10n.recipesAvoidContains(names),
      semanticLabel: l10n.recipesAvoidContainsSemantics(names),
    );
  }
}
