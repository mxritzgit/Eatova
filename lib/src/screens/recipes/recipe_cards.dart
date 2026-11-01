part of 'recipes_screen.dart';

/// Open photo rows continue the Food diary's restrained list treatment.
class _RecipeListTile extends StatelessWidget {
  const _RecipeListTile({
    super.key,
    required this.recipe,
    required this.onTap,
    this.avoided = const <FoodAvoidance>{},
  });
  final FitnessRecipe recipe;
  final VoidCallback onTap;

  /// The user's avoided foods; a recipe containing some gets a
  /// [RecipeAvoidHint] under its figures.
  final Set<FoodAvoidance> avoided;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final photo = ClipRRect(
      borderRadius: BorderRadius.circular(rControl),
      child: SizedBox(
        width: 78,
        height: 84,
        child: RecipePhoto(recipe: recipe),
      ),
    );
    // From 1.5x text the photo goes above the title, which then gets the
    // row's width instead of breaking "Asparagu|s" beside the photo.
    final stacked = MediaQuery.textScalerOf(context).scale(17) > 25.5;
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
              if (!stacked) ...[photo, const SizedBox(width: kRowLeadingGap)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (stacked) ...[photo, const SizedBox(height: 10)],
                    Text(
                      recipe.displayTitle(context.l10n),
                      style: AppType.display(17, color: t.ink, height: 1.2),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _recipeSummary(recipe, context.l10n),
                      style: AppType.ui(13, color: t.ink2, height: 1.4),
                    ),
                    if (recipe.avoidedFoods(avoided).isNotEmpty) ...[
                      const SizedBox(height: 6),
                      RecipeAvoidHint(recipe: recipe, avoided: avoided),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: kSpace8),
              // The list rows' disclosure: 20 px in `ink3`, quieter than the
              // figures beside it.
              Icon(
                AppIcons.chevronRight,
                size: AppIconSize.standard,
                color: t.ink3,
              ),
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
      icon: AppIcons.menuBook,
      title: l.recipesOwnEmptyTitle,
      text: l.recipesOwnEmptyBody,
      actions: [actions],
    );
  }
}

/// A search or category with no match, and the way out of it: clear the
/// search, or (with nothing typed) show all recipes. Without [onReset]
/// (already "All", nothing typed) there is no way wider and no pill.
class _RecipeNoResultState extends StatelessWidget {
  const _RecipeNoResultState({required this.hasQuery, required this.onReset});

  final bool hasQuery;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return CalmState(
      key: const ValueKey('recipes-no-result'),
      card: true,
      icon: AppIcons.searchOff,
      title: l.recipesNoResultTitle,
      text: l.recipesNoResultBody,
      actions: [
        if (onReset case final reset?)
          SoftPillButton(
            key: const ValueKey('recipes-no-result-reset'),
            label: hasQuery
                ? l.recipesSearchClearTooltip
                : l.recipesNoResultShowAll,
            icon: hasQuery
                ? AppIcons.close
                : AppIcons.restaurantMenu,
            onTap: reset,
          ),
      ],
    );
  }
}
