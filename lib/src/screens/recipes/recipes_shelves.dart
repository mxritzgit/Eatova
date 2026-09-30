part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Shelves of the Recipes tab (dark redesign 2026-09-28): the horizontal
// recipe carousels with their heading, and the "Your recipes" card with the
// import and create actions.
// ---------------------------------------------------------------------------

/// Heading of a section: Bricolage 20/700 with a "See all" link or a muted
/// note on the right.
class _ShelfHeading extends StatelessWidget {
  const _ShelfHeading({
    required this.title,
    this.actionLabel,
    this.onAction,
    this.actionKey,
    this.trailing,
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Key? actionKey;

  /// Muted note instead of an action (a count, a reason).
  final String? trailing;

  /// How far the link's 44 px touch target reaches above and below the
  /// design's 24 px title line; the gaps around a linked heading absorb it.
  static const double linkOverhang = 10;

  bool get hasLink => actionLabel != null && onAction != null;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final heading = HeadingSemantics(
      level: 2,
      child: Text(
        title,
        style: AppType.display(
          20,
          weight: FontWeight.w700,
          color: t.ink,
          letterSpacing: -0.2,
          height: 1.2,
        ),
      ),
    );
    Widget? side;
    if (hasLink) {
      side = Semantics(
        button: true,
        child: InkWell(
          key: actionKey,
          onTap: onAction,
          borderRadius: BorderRadius.circular(rControl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Center(
                widthFactor: 1,
                child: Text(
                  actionLabel!,
                  style: AppType.ui(
                    14,
                    weight: FontWeight.w700,
                    color: t.accentText,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    } else if (trailing != null) {
      side = Text(
        trailing!,
        textAlign: TextAlign.right,
        style: AppType.ui(12, weight: FontWeight.w600, color: t.ink2),
      );
    }
    if (side == null) return heading;
    // Large text: the link moves under the title instead of squeezing it.
    if (MediaQuery.textScalerOf(context).scale(14) > 19) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [heading, side],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: heading),
        const SizedBox(width: 12),
        side,
      ],
    );
  }
}

/// A heading plus a horizontal row of [_ShelfCard]s that runs to the screen
/// edge. Cards share the height of the tallest one.
class _RecipeShelf extends StatelessWidget {
  const _RecipeShelf({
    required this.shelfKey,
    required this.cardKeyPrefix,
    required this.heading,
    required this.recipes,
    required this.onOpen,
  });

  final Key shelfKey;
  final String cardKeyPrefix;
  final _ShelfHeading heading;
  final List<FitnessRecipe> recipes;
  final ValueChanged<FitnessRecipe> onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The design's "4px 4px 0" around the title and 12 px to the cards;
        // a link's taller touch target takes its overhang out of both.
        Padding(
          padding: EdgeInsets.fromLTRB(
            _kGutter + 4,
            heading.hasLink ? 0 : 4,
            _kGutter + 4,
            0,
          ),
          child: heading,
        ),
        SizedBox(
          height: heading.hasLink ? 12 - _ShelfHeading.linkOverhang : 12,
        ),
        // Its own storage slot: without one the shelf shares the list's
        // PageStorage entry and restores the page's vertical offset as its
        // horizontal one when it scrolls into view.
        KeyedSubtree(
          key: PageStorageKey<String>('scroll-$cardKeyPrefix'),
          child: SingleChildScrollView(
            key: shelfKey,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: _kGutter),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < recipes.length; i++) ...[
                    if (i > 0) const SizedBox(width: 12),
                    _ShelfCard(
                      key: ValueKey('$cardKeyPrefix${recipes[i].slug}'),
                      recipe: recipes[i],
                      onTap: () => onOpen(recipes[i]),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// kcal and protein per portion for the shelf cards ("380 kcal · 32 g
/// protein"); a dash for an unknown value.
String _shelfMeta(FitnessRecipe recipe, AppLocalizations l10n) {
  final n = recipe.displayNutrition;
  final kcal = n.caloriesKcal, protein = n.proteinG;
  if (kcal == null || protein == null) return _recipeSummary(recipe, l10n);
  return l10n.recipesKcalProteinSummary(kcal.round(), protein.round());
}

/// Square-ish card of a shelf: photo or the glowing placeholder, the title
/// and kcal · protein. Opens the recipe.
class _ShelfCard extends StatelessWidget {
  const _ShelfCard({super.key, required this.recipe, required this.onTap});

  static const double width = 164;

  final FitnessRecipe recipe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return SizedBox(
      width: width,
      child: MergeSemantics(
        child: Semantics(
          button: true,
          child: PressScale(
            child: Material(
              color: t.surf,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(rCard),
                side: BorderSide(color: t.cardBorder),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: 112,
                      child: RecipePhoto(
                        recipe: recipe,
                        placeholder: (_) => _RecipeArt(recipe: recipe),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            recipe.displayTitle(l10n),
                            key: const ValueKey('recipe-shelf-card-title'),
                            // Two lines at most: the row shares the tallest
                            // card's height, so one long title would stretch
                            // every card.
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.ui(
                              14,
                              weight: FontWeight.w700,
                              color: t.ink,
                              height: 1.25,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _shelfMeta(recipe, l10n),
                            style: AppType.ui(12, color: t.ink3),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Your recipes": import one or create one, the design's two pills.
class _YourRecipesCard extends StatelessWidget {
  const _YourRecipesCard({required this.onCreate, this.onImport});

  final VoidCallback onCreate;

  /// Null (no import service wired) leaves Create alone in the card.
  final VoidCallback? onImport;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final create = _Pill(
      key: const ValueKey('recipe-create-button'),
      label: l10n.recipesCreateButton,
      glyph: _RecipeGlyph.pencil,
      height: 46,
      fontSize: 14,
      horizontalPadding: 16,
      grow: true,
      onTap: onCreate,
    );
    return Container(
      key: const ValueKey('recipes-your-recipes'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: t.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HeadingSemantics(
            level: 2,
            child: Text(
              l10n.recipesYourRecipesTitle,
              style: AppType.ui(17, weight: FontWeight.w700, color: t.ink),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.recipesYourRecipesBody,
            style: AppType.ui(14, color: t.ink2, height: 1.45),
          ),
          const SizedBox(height: 12),
          if (onImport == null)
            create
          else
            _PillPair(
              equal: true,
              first: _Pill(
                key: const ValueKey('recipe-import-button'),
                label: l10n.recipeImportAction,
                glyph: _RecipeGlyph.download,
                height: 46,
                fontSize: 14,
                horizontalPadding: 16,
                onTap: onImport,
              ),
              second: create,
            ),
        ],
      ),
    );
  }
}
