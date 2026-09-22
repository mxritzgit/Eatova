import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/recipe_import_result.dart';
import '../../theme/app_tokens.dart';

class RecipeImportNutrition extends StatelessWidget {
  const RecipeImportNutrition({super.key, required this.candidate});
  final RecipeImportCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final values = [
      (
        l10n.recipesNutritionKcalLabel,
        candidate.caloriesKcal,
        '',
        t.brandSurface,
        t.onBrandSurface,
      ),
      (
        l10n.todayMacroProtein,
        candidate.proteinG,
        'g',
        t.proteinSurface,
        t.protein,
      ),
      (
        l10n.recipesNutritionCarbsLabel,
        candidate.carbsG,
        'g',
        t.carbsSurface,
        t.carbs,
      ),
      (l10n.todayMacroFat, candidate.fatG, 'g', t.fatSurface, t.fat),
    ];
    return Column(
      key: const ValueKey('recipe-import-nutrition'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          candidate.nutritionBasisUnclear
              ? l10n.recipeImportNutritionSource
              : l10n.recipesPerPortion,
          style: AppType.ui(13, weight: FontWeight.w600, color: t.ink2),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = MediaQuery.textScalerOf(context).scale(14) > 20
                ? 1
                : constraints.maxWidth >= 500
                ? 4
                : 2;
            final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final (label, value, unit, surface, color) in values)
                  SizedBox(
                    width: width,
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: surface,
                        borderRadius: BorderRadius.circular(rCard),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            value == null
                                ? '—'
                                : [
                                    value.toString(),
                                    if (unit.isNotEmpty) unit,
                                  ].join(' '),
                            style: AppType.display(24, color: t.ink),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            label,
                            style: AppType.ui(
                              12,
                              color: color,
                              weight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        if (candidate.nutritionBasisUnclear || !candidate.hasNutrition) ...[
          const SizedBox(height: 12),
          Text(
            candidate.nutritionBasisUnclear
                ? l10n.recipeImportBasisHint
                : l10n.recipeImportNutritionPendingHint,
            style: AppType.ui(13, color: t.ink2, height: 1.5),
          ),
        ],
        if (candidate.hasNutrition && candidate.nutritionEstimated) ...[
          const SizedBox(height: 8),
          Text(
            l10n.recipeImportNutritionEstimate,
            style: AppType.ui(12, color: t.ink2, height: 1.5),
          ),
        ],
      ],
    );
  }
}
