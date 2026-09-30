part of 'recipes_screen.dart';

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
                      recipe.displayTitle(context.l10n),
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

/// Empty list. The own-recipes variant needs no button of its own: the
/// "Your recipes" card above it offers import and create.
class _RecipeEmptyState extends StatelessWidget {
  const _RecipeEmptyState({this.own = false});
  final bool own;

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
          ],
        ],
      ),
    );
  }
}
