import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/meal_analysis_result.dart';
import '../../theme/app_tokens.dart';
import '../common/motion.dart';

/// Product identity and label density, separate from the editable portion.
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
    final t = context.t;
    final l10n = context.l10n;
    final brand = result.brand?.trim();
    final brandSuffix = brand == null || brand.isEmpty ? null : ' · $brand';
    final title = brandSuffix != null && result.mealName.endsWith(brandSuffix)
        ? result.mealName.substring(
            0,
            result.mealName.length - brandSuffix.length,
          )
        : result.mealName;
    final large = MediaQuery.textScalerOf(context).scale(16) > 24;
    final density = result.isRecipeWithoutCookedWeight
        ? 0
        : result.adjustedToGrams(100).caloriesKcal;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(rCard),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!large) ...[
                _ProductImage(imageUrl: imageUrl),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (brand != null && brand.isNotEmpty) ...[
                      Text(
                        brand,
                        maxLines: large ? null : 1,
                        overflow: large ? null : TextOverflow.ellipsis,
                        style: AppType.ui(
                          11,
                          weight: FontWeight.w600,
                          color: t.ink2,
                        ),
                      ),
                      const SizedBox(height: 5),
                    ],
                    Text(
                      title,
                      maxLines: large ? null : 2,
                      overflow: large ? null : TextOverflow.ellipsis,
                      style: AppType.display(17, color: t.ink, height: 1.25),
                    ),
                    const SizedBox(height: 9),
                    Text(
                      density > 0 || result.explicitZeroKcal
                          ? '$density kcal / 100 g'
                          : '${result.caloriesKcal} kcal · ${result.estimatedGrams} g',
                      style: AppType.ui(
                        13,
                        weight: FontWeight.w500,
                        color: t.ink2,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                children: [
                  if (onToggleFavorite != null)
                    IconButton(
                      key: favoriteButtonKey,
                      onPressed: onToggleFavorite,
                      tooltip: isFavorite
                          ? l10n.foodRemoveFavoriteTooltip
                          : l10n.foodAddFavoriteTooltip,
                      icon: Icon(
                        isFavorite
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 20,
                        color: isFavorite ? t.accent : t.ink2,
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: justAdded
                        ? Icon(
                            Icons.check_circle_rounded,
                            size: 22,
                            color: t.accent,
                          )
                        : AnimatedRotation(
                            duration: motionDuration(
                              context,
                              const Duration(milliseconds: 180),
                            ),
                            turns: expanded ? .5 : 0,
                            child: Icon(
                              Icons.keyboard_arrow_down_rounded,
                              color: t.ink2,
                              size: 22,
                            ),
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProductImage extends StatelessWidget {
  const _ProductImage({this.imageUrl});
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final fallback = Center(
      child: Icon(Icons.restaurant_rounded, color: t.ink2, size: 24),
    );
    return Container(
      width: 58,
      height: 78,
      padding: const EdgeInsets.all(7),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rControl),
      ),
      child: imageUrl == null || imageUrl!.isEmpty
          ? fallback
          : Image.network(
              imageUrl!,
              fit: BoxFit.contain,
              cacheWidth: (58 * MediaQuery.devicePixelRatioOf(context)).round(),
              errorBuilder: (_, __, ___) => fallback,
            ),
    );
  }
}
