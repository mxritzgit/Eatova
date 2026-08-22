part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Recipe detail view (own route push). [RecipeDetailScreen] is public.
// ---------------------------------------------------------------------------
class RecipeDetailScreen extends StatelessWidget {
  const RecipeDetailScreen({
    super.key,
    required this.recipe,
    required this.onAddMeal,
    this.onDelete,
  });

  final FitnessRecipe recipe;
  final void Function(MealAnalysisResult result, MealSlot slot) onAddMeal;

  /// Optional delete hook, set only for own recipes.
  final VoidCallback? onDelete;

  Future<void> _showMealPicker(BuildContext context) async {
    final slot = await showEatovaSheet<MealSlot>(
      context,
      _MealSlotPickerSheet(recipe: recipe),
    );
    if (!context.mounted || slot == null) return;
    _add(context, slot);
  }

  void _add(BuildContext context, MealSlot slot) {
    final l10n = context.l10n;
    onAddMeal(recipe.toMealResult(l10n), slot);
    showAppSnack(
      context,
      l10n.commonKcalAddedToSlot(recipe.caloriesKcal, slot.label(l10n)),
      icon: Icons.check_circle_rounded,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          key: const ValueKey('recipe-detail-scroll'),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PageHeader(
                title:
                    recipe.userCreated ? l10n.recipesOwnTitle : l10n.recipesBrandTitle,
                backKey: const ValueKey('recipe-detail-back'),
                onBack: () => Navigator.of(context).pop(),
                trailing: onDelete == null
                    // Counterweight to the back button, so the title centres.
                    ? const SizedBox(width: 34)
                    : SquareIconButton(
                        key: const ValueKey('recipe-detail-delete'),
                        icon: Icons.delete_outline_rounded,
                        semanticLabel: l10n.recipesDeleteSemantics,
                        onTap: () {
                          // Pop first: the toast belongs on the recipe list.
                          Navigator.of(context).pop();
                          onDelete!();
                        },
                      ),
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(rSheet),
                child: SizedBox(
                  height: 258,
                  width: double.infinity,
                  child: _RecipeImage(
                    recipe: recipe,
                    placeholderRadius: rSheet,
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                recipe.title,
                key: ValueKey('recipe-detail-${recipe.slug}'),
                style: AppType.display(28, color: t.ink, height: 1.1),
              ),
              const SizedBox(height: 10),
              Text(
                recipe.displayDescription(l10n),
                style: AppType.ui(14, color: t.ink2, height: 1.45),
              ),
              if (recipe.categories.isNotEmpty) ...[
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final category in recipe.categories)
                      _CategoryPill(label: recipeCategoryLabel(category, l10n)),
                  ],
                ),
              ],
              const SizedBox(height: 18),
              _NutritionGrid(recipe: recipe),
              const SizedBox(height: 18),
              _AddToMealCard(
                recipe: recipe,
                onTap: () => _showMealPicker(context),
              ),
              const SizedBox(height: 18),
              _RecipeInfoSection(
                title: l10n.recipesSectionPortion,
                body: recipe.displayPortion(l10n),
              ),
              _RecipeInfoSection(
                title: l10n.recipesSectionIngredients,
                body: recipe.displayIngredients(l10n),
              ),
              _RecipeInfoSection(
                title: l10n.recipesSectionPreparation,
                body: recipe.displayPreparation(l10n),
              ),
              _RecipeInfoSection(
                title: l10n.recipesSectionProHint,
                body: recipe.displayProfessionalHint(l10n),
                highlight: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddToMealCard extends StatelessWidget {
  const _AddToMealCard({required this.recipe, required this.onTap});

  final FitnessRecipe recipe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return AppCard(
      key: const ValueKey('recipe-add-card'),
      radius: rSheet,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconTile(icon: Icons.add_rounded, color: t.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.recipesAddToTrackerTitle,
                      style: AppType.display(
                        15,
                        weight: FontWeight.w700,
                        color: t.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      l10n.recipesKcalProteinSummary(
                        recipe.caloriesKcal,
                        recipe.proteinG,
                      ),
                      style: AppType.ui(
                        12,
                        weight: FontWeight.w500,
                        color: t.ink2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          PrimaryActionButton(
            key: const ValueKey('recipe-add-button'),
            label: l10n.commonAdd,
            icon: Icons.add_rounded,
            onTap: onTap,
          ),
          const SizedBox(height: 10),
          Text(
            l10n.recipesAddToTrackerHint,
            style: AppType.ui(11.5, color: t.ink2, height: 1.35),
          ),
        ],
      ),
    );
  }
}

class _NutritionGrid extends StatelessWidget {
  const _NutritionGrid({required this.recipe});

  final FitnessRecipe recipe;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    // One distinct macro token per tile: `orange` and `macroFat` are equal.
    return Row(
      children: [
        Expanded(
          child: _NutritionTile(
            label: l10n.recipesNutritionKcalLabel,
            value: '${recipe.caloriesKcal}',
            color: t.accent,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _NutritionTile(
            label: l10n.todayMacroProtein,
            value: '${recipe.proteinG} g',
            color: t.protein,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _NutritionTile(
            label: l10n.recipesNutritionCarbsLabel,
            value: '${recipe.carbsG} g',
            color: t.carbs,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _NutritionTile(
            label: l10n.todayMacroFat,
            value: '${recipe.fatG} g',
            color: t.fat,
          ),
        ),
      ],
    );
  }
}

class _NutritionTile extends StatelessWidget {
  const _NutritionTile({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AppCard(
      radius: rCard,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Column(
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.display(16, weight: FontWeight.w700, color: color),
          ),
          const SizedBox(height: 4),
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.eyebrow(t.ink2, size: 9.5),
          ),
        ],
      ),
    );
  }
}

class _RecipeInfoSection extends StatelessWidget {
  const _RecipeInfoSection({
    required this.title,
    required this.body,
    this.highlight = false,
  });

  final String title;
  final String body;

  /// Tints the dot before the heading with the accent colour.
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: highlight ? t.accent : t.ink2,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: SectionHeading(title: title)),
            ],
          ),
          const SizedBox(height: 10),
          AppCard(
            radius: rSheet,
            child: SizedBox(
              width: double.infinity,
              child: Text(
                body,
                style: AppType.ui(13, color: t.ink2, height: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
