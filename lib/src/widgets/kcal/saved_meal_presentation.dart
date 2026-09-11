import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/meal_analysis_result.dart';
import '../../theme/app_tokens.dart';

/// One shared surface makes saved meals read as a collection, not search hits.
class SavedMealCollection extends StatelessWidget {
  const SavedMealCollection({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Material(
    color: context.t.surf,
    borderRadius: BorderRadius.circular(rCard),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          children[i],
          if (i < children.length - 1)
            Divider(
              height: 1,
              indent: 16,
              endIndent: 16,
              color: context.t.line,
            ),
        ],
      ],
    ),
  );
}

class SavedMealHeader extends StatelessWidget {
  const SavedMealHeader({
    super.key,
    required this.result,
    required this.expanded,
    required this.justAdded,
    required this.onTap,
    required this.isFavorite,
    this.onToggleFavorite,
    this.favoriteButtonKey,
  });

  final MealAnalysisResult result;
  final bool expanded, justAdded, isFavorite;
  final VoidCallback onTap;
  final VoidCallback? onToggleFavorite;
  final Key? favoriteButtonKey;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final portion = result.isRecipeWithoutCookedWeight
        ? l10n.recipeCalcSavedPortion
        : '${result.estimatedGrams} g';
    final knownCalories = result.caloriesKcal > 0 || result.explicitZeroKcal;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(rControl),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    result.mealName,
                    style: AppType.display(17, color: t.ink, height: 1.25),
                  ),
                ),
                if (onToggleFavorite != null)
                  IconButton(
                    key: favoriteButtonKey,
                    tooltip: isFavorite
                        ? l10n.foodRemoveFavoriteTooltip
                        : l10n.foodAddFavoriteTooltip,
                    onPressed: onToggleFavorite,
                    icon: Icon(
                      isFavorite
                          ? Icons.favorite_rounded
                          : Icons.favorite_outline_rounded,
                      size: 19,
                      color: isFavorite ? t.accent : t.ink2,
                    ),
                  ),
              ],
            ),
            if (result.brand?.trim().isNotEmpty ?? false) ...[
              Text(result.brand!, style: AppType.ui(12, color: t.ink2)),
              const SizedBox(height: 6),
            ],
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        knownCalories
                            ? '${result.caloriesKcal} kcal'
                            : l10n.ingredientUnknown,
                        style: AppType.display(20, color: t.ink),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        result.isRecipeWithoutCookedWeight
                            ? portion
                            : '${expanded ? l10n.foodManualGroupPortion : l10n.foodFavoriteSavedPortion} · $portion',
                        style: AppType.ui(12, color: t.ink2, height: 1.4),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                IconButton.filledTonal(
                  tooltip: justAdded
                      ? '${l10n.foodFavoriteAdded} · ${l10n.foodFavoritePortionAction}'
                      : l10n.foodFavoritePortionAction,
                  onPressed: onTap,
                  style: IconButton.styleFrom(
                    backgroundColor: t.brandSurface,
                    foregroundColor: t.accent,
                    minimumSize: const Size(44, 44),
                  ),
                  icon: Icon(
                    justAdded
                        ? Icons.check_rounded
                        : expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.tune_rounded,
                    size: 21,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Nutrient colors encode the current portion, using the same result as Add.
class SavedMealNutrients extends StatelessWidget {
  const SavedMealNutrients({super.key, required this.result});

  final MealAnalysisResult result;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (value, label, color) in [
          (
            result.protein,
            l10n.foodMacroProteinShort(result.protein),
            t.proteinSurface,
          ),
          (
            result.carbs,
            l10n.foodMacroCarbsShort(result.carbs),
            t.carbsSurface,
          ),
          (result.fat, l10n.foodMacroFatShort(result.fat), t.fatSurface),
        ])
          if (value != '-' && value.trim().isNotEmpty)
            DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(rChip),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Text(
                  label,
                  style: AppType.ui(12, weight: FontWeight.w600, color: t.ink),
                ),
              ),
            ),
      ],
    );
  }
}
