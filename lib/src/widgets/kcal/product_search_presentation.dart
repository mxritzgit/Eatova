import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/meal_analysis_result.dart';
import '../../services/kcal_format.dart';
import '../../theme/app_tokens.dart';
import 'saved_meal_presentation.dart';

/// Product identity and label density, separate from the editable portion:
/// packshot (or letter) tile, name, brand, and the kcal per 100 g on the
/// right — the label's density, since a hit has no portion yet.
class ProductSearchHeader extends StatelessWidget {
  const ProductSearchHeader({
    super.key,
    required this.result,
    required this.expanded,
    required this.justAdded,
    required this.onTap,
    this.imageUrl,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.favoriteButtonKey,
  });
  final MealAnalysisResult result;
  final bool expanded, justAdded, isFavorite;
  final VoidCallback onTap;
  final String? imageUrl;
  final VoidCallback? onToggleFavorite;
  final Key? favoriteButtonKey;

  @override
  Widget build(BuildContext context) {
    final (title, brand) = mealTitleAndBrand(result, context.l10n);
    // The same authority as the expanded preview: the raw kcalPer100G field
    // counts only where it reproduces caloriesKcal at estimatedGrams.
    final density = result.hasNoPortionWeight
        ? 0
        : result.adjustedToGrams(100).caloriesKcal;
    final hasDensity = density > 0 || result.explicitZeroKcal;
    final locale = context.l10n.localeName;
    final portion = hasDensity
        ? null
        : '${formatThousands(result.estimatedGrams, locale)} g';
    final secondary = [?brand, ?portion].join(' · ');
    return MealItemRow(
      leading: MealItemTile(
        name: title,
        imageUrl: imageUrl,
        justAdded: justAdded,
      ),
      title: title,
      secondary: secondary.isEmpty ? null : Text(secondary),
      value: hasDensity
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                MealKcalValue(number: formatThousands(density, locale)),
                Text(
                  context.l10n.foodManualPer100GSuffix,
                  style: AppType.micro(context.t.ink2),
                ),
              ],
            )
          : MealKcalValue(
              number: formatThousands(result.caloriesKcal, locale),
            ),
      onTap: onTap,
      expanded: expanded,
      actions: [
        if (onToggleFavorite != null)
          MealFavoriteButton(
            key: favoriteButtonKey,
            isFavorite: isFavorite,
            onPressed: onToggleFavorite!,
          ),
      ],
    );
  }
}
