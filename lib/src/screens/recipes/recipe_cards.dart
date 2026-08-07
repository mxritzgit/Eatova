part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Rezept-Karten der Übersicht: horizontale Hero-Kachel (Empfehlungen +
// „Passt zu deinem Ziel"), Listen-Kachel der Hauptliste und der Empty State.
// ---------------------------------------------------------------------------
class _RecipeHeroCard extends StatelessWidget {
  const _RecipeHeroCard({
    required this.recipe,
    required this.onTap,
    this.badgeText,
  });

  final FitnessRecipe recipe;
  final VoidCallback onTap;

  /// Optionales zweites Badge oben rechts (z.B. „Match" in der Ziel-Sektion).
  final String? badgeText;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(rSheet),
      child: SizedBox(
        width: 200,
        child: Container(
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(rSheet),
            border: Border.all(color: hairline),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  SizedBox(
                    height: 132,
                    width: double.infinity,
                    child: _RecipeImage(recipe: recipe),
                  ),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.55),
                          ],
                          stops: const [0.45, 1.0],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 10,
                    top: 10,
                    child: _GlassBadge(text: '${recipe.caloriesKcal} kcal'),
                  ),
                  if (badgeText != null)
                    Positioned(
                      right: 10,
                      top: 10,
                      child: _MatchBadge(text: badgeText!),
                    ),
                  if (recipe.categories.isNotEmpty)
                    Positioned(
                      left: 10,
                      bottom: 10,
                      child: _CategoryPill(
                        label: recipe.categories.first,
                        onImage: true,
                      ),
                    ),
                ],
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        recipe.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: textPrimary,
                          fontSize: 15,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        recipe.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: textMuted,
                          fontSize: 11.5,
                          height: 1.32,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const Spacer(),
                      _MacroRow(recipe: recipe, compact: true),
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(rCard),
      child: Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(color: hairline),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(rControl),
                  child: SizedBox(
                    width: 84,
                    height: 84,
                    child: _RecipeImage(recipe: recipe),
                  ),
                ),
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: _GlassBadge(text: '${recipe.caloriesKcal} kcal'),
                ),
              ],
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          recipe.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: textPrimary,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.15,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: textMuted,
                        size: 20,
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    recipe.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: textMuted,
                      fontSize: 11.5,
                      height: 1.3,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 9),
                  _MacroRow(recipe: recipe),
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
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: hairline),
      ),
      child: const Text(
        'Kein Rezept gefunden. Versuch eine andere Kategorie oder Suche.',
        style: TextStyle(color: textMuted, fontSize: 13, height: 1.4),
      ),
    );
  }
}
