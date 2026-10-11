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

/// No own recipe yet: the app's calm empty card, holding the import/create
/// pair itself (the separate "Your recipes" card would say the same thing
/// again right above it).
class _RecipeOwnEmptyState extends StatelessWidget {
  const _RecipeOwnEmptyState({required this.actions});

  /// The "Your recipes" pills: import and create.
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return CalmState(
      key: const ValueKey('recipes-own-empty'),
      card: true,
      icon: Icons.menu_book_rounded,
      title: l.recipesOwnEmptyTitle,
      text: l.recipesOwnEmptyBody,
      actions: [actions],
    );
  }
}

/// A search or category with no match, and the way out of it: clear the
/// search, or (with nothing typed) show all recipes.
class _RecipeNoResultState extends StatelessWidget {
  const _RecipeNoResultState({required this.hasQuery, required this.onReset});

  final bool hasQuery;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return CalmState(
      key: const ValueKey('recipes-no-result'),
      card: true,
      icon: Icons.search_off_rounded,
      title: l.recipesNoResultTitle,
      text: l.recipesNoResultBody,
      actions: [
        SoftPillButton(
          key: const ValueKey('recipes-no-result-reset'),
          label: hasQuery
              ? l.recipesSearchClearTooltip
              : l.recipesNoResultShowAll,
          icon: hasQuery
              ? Icons.close_rounded
              : Icons.restaurant_menu_rounded,
          onTap: onReset,
        ),
      ],
    );
  }
}
