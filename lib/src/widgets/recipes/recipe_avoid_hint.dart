import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/fitness_recipe.dart';
import '../../models/food_preferences.dart';
import '../../theme/app_tokens.dart';

/// "Enthält Nüsse": a quiet chip on a recipe that contains foods the user
/// avoids ([FitnessRecipe.avoidedFoods]). Suggestions leave such recipes
/// out; browse lists and the detail keep them and say why instead. Nothing
/// when the recipe contains none of [avoided].
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
    final t = context.t;
    final names = foods.map((food) => food.label(l10n)).join(', ');
    return Semantics(
      container: true,
      label: l10n.recipesAvoidContainsSemantics(names),
      excludeSemantics: true,
      child: Container(
        key: ValueKey('recipe-avoid-hint-${recipe.slug}'),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: t.tile,
          borderRadius: BorderRadius.circular(rChip),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.info_outline_rounded, size: 14, color: t.ink2),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                l10n.recipesAvoidContains(names),
                style: AppType.ui(12, weight: FontWeight.w600, color: t.ink2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
