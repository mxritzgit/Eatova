part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Recipe cards: carousel image tile, main-list row, empty state.
// ---------------------------------------------------------------------------

/// Photo background with a bottom gradient carrying badge, title and metrics.
class _RecipeHeroCard extends StatelessWidget {
  const _RecipeHeroCard({
    super.key,
    required this.recipe,
    required this.onTap,
    this.badgeText,
  });

  final FitnessRecipe recipe;
  final VoidCallback onTap;

  /// Replaces the default recommended badge label.
  final String? badgeText;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(26),
      child: SizedBox(
        // 280 keeps the display-size title from breaking into syllables and
        // still clips the next card on a 393 px viewport.
        width: 280,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _RecipeImage(recipe: recipe),
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  decoration: BoxDecoration(
                    // A photo scrim must stay dark in both display modes, so
                    // no ink token applies here.
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.92),
                        Colors.black.withValues(alpha: 0.55),
                        Colors.black.withValues(alpha: 0.0),
                      ],
                      stops: const [0, 0.55, 1],
                    ),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // The default "recommended" badge is reserved for the
                      // catalog; an own recipe only carries an explicit badge
                      // (goal match).
                      if (badgeText != null || !recipe.userCreated) ...[
                        _RecipeBadge(
                          text:
                              badgeText ?? context.l10n.recipesRecommendedBadge,
                          icon: badgeText == null ? null : Icons.bolt_rounded,
                          filled: true,
                        ),
                        const SizedBox(height: 9),
                      ],
                      Text(
                        recipe.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.display(
                          19,
                          color: t.onForest,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 9),
                      _RecipeMetrics(recipe: recipe, onImage: true),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// List row: 96×96 image, category eyebrow, title, description, metrics.
class _RecipeListTile extends StatelessWidget {
  const _RecipeListTile({
    super.key,
    required this.recipe,
    required this.onTap,
  });

  final FitnessRecipe recipe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(rCard),
      child: AppCard(
        radius: rCard,
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 96,
              height: 96,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(rControl),
                child: _RecipeImage(
                  recipe: recipe,
                  placeholderRadius: rControl,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (recipe.categories.isNotEmpty) ...[
                    Text(
                      recipeCategoryLabel(recipe.categories.first, l10n)
                          .toUpperCase(),
                      // Always `accent`: this row shows recipe categories, and
                      // macro colors are reserved for nutrients by contract.
                      style: AppType.eyebrow(t.accent, size: 9.5),
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(
                    recipe.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.display(
                      16.5,
                      weight: FontWeight.w700,
                      color: t.ink,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    recipe.displayDescription(l10n),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.ui(11.5, color: t.ink2, height: 1.4),
                  ),
                  const SizedBox(height: 8),
                  _RecipeMetrics(recipe: recipe),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecipeEmptyState extends StatelessWidget {
  const _RecipeEmptyState();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: AppCard(
        radius: rCard,
        child: Text(
          context.l10n.recipesEmptyStateMessage,
          style: AppType.ui(13, color: t.ink2, height: 1.4),
        ),
      ),
    );
  }
}
