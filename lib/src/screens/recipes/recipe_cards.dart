part of 'recipes_screen.dart';

/// Photo and information stay separate, so text remains legible in both themes.
class _RecipeHeroCard extends StatelessWidget {
  const _RecipeHeroCard({
    super.key,
    required this.recipe,
    required this.onTap,
    required this.imageHeight,
    this.badgeText,
  });

  final FitnessRecipe recipe;
  final VoidCallback onTap;
  final double imageHeight;
  final String? badgeText;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l = context.l10n;
    final n = _recipeNutrition(recipe);
    return Material(
      color: t.brandSurface,
      borderRadius: BorderRadius.circular(rSheet),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: imageHeight,
              child: RecipePhoto(recipe: recipe),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      badgeText ?? l.recipesTryToday,
                      style: AppType.ui(
                        13,
                        color: t.accent,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      recipe.title,
                      style: AppType.display(
                        24,
                        color: t.onBrandSurface,
                        height: 1.12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 18,
                      runSpacing: 8,
                      children: [
                        _SpotlightMetric(
                          value: _nutritionNumber(n.caloriesKcal),
                          unit: 'kcal',
                        ),
                        _SpotlightMetric(
                          value: _nutritionNumber(n.proteinG),
                          unit: 'g ${l.todayMacroProtein}',
                        ),
                      ],
                    ),
                    const Spacer(),
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(minHeight: 48),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: t.surf,
                        borderRadius: BorderRadius.circular(rControl),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              l.recipesViewRecipe,
                              textAlign: TextAlign.center,
                              style: AppType.ui(
                                14,
                                color: t.accent,
                                weight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: t.accent,
                            size: 22,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpotlightMetric extends StatelessWidget {
  const _SpotlightMetric({required this.value, required this.unit});
  final String value, unit;
  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: value,
          style: AppType.display(22, color: context.t.onBrandSurface),
        ),
        TextSpan(
          text: ' $unit',
          style: AppType.ui(14, color: context.t.onBrandSurface),
        ),
      ],
    ),
  );
}

/// Size to the actual text, including long recipe names and system text scaling.
class _RecipeSpotlight extends StatelessWidget {
  const _RecipeSpotlight({
    required this.recipes,
    required this.onOpen,
    required this.carouselKey,
    this.badgeText,
    this.keyPrefix,
  });
  final List<FitnessRecipe> recipes;
  final ValueChanged<FitnessRecipe> onOpen;
  final Key carouselKey;
  final String? badgeText, keyPrefix;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = (constraints.maxWidth - 22).clamp(220.0, 420.0);
      final imageHeight = width * .62;
      return SingleChildScrollView(
        key: carouselKey,
        scrollDirection: Axis.horizontal,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < recipes.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                SizedBox(
                  width: width,
                  child: _RecipeHeroCard(
                    key: keyPrefix == null
                        ? null
                        : ValueKey('$keyPrefix${recipes[i].slug}'),
                    recipe: recipes[i],
                    imageHeight: imageHeight,
                    badgeText: badgeText,
                    onTap: () => onOpen(recipes[i]),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

/// Open photo rows continue the Food diary's restrained list treatment.
class _RecipeListTile extends StatelessWidget {
  const _RecipeListTile({super.key, required this.recipe, required this.onTap});
  final FitnessRecipe recipe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(rControl),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(rControl),
                child: SizedBox(
                  width: 78,
                  height: 84,
                  child: RecipePhoto(recipe: recipe),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      recipe.title,
                      style: AppType.display(17, color: t.ink, height: 1.2),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _recipeSummary(recipe, context.l10n),
                      style: AppType.ui(13, color: t.ink2, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, size: 20, color: t.ink2),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecipeEmptyState extends StatelessWidget {
  const _RecipeEmptyState({this.own = false, this.onCreate});
  final bool own;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l = context.l10n;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: t.tile,
        borderRadius: BorderRadius.circular(rSheet),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            own ? Icons.menu_book_rounded : Icons.search_rounded,
            color: t.accent,
            size: 30,
          ),
          const SizedBox(height: 16),
          Text(
            own ? l.recipesOwnEmptyTitle : l.recipesEmptyStateMessage,
            style: AppType.display(20, color: t.ink),
          ),
          if (own) ...[
            const SizedBox(height: 8),
            Text(
              l.recipesOwnEmptyBody,
              style: AppType.ui(14, color: t.ink2, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded),
              label: Text(l.recipesCreateAction),
            ),
          ],
        ],
      ),
    );
  }
}
