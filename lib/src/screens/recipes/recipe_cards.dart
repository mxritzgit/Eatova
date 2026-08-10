part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Rezept-Karten der Übersicht: die grosse Bildkachel der Karussells
// (Empfehlungen + „Passt zu deinem Ziel"), die Listenzeile der Hauptliste und
// der Empty State.
// ---------------------------------------------------------------------------

/// Die `FeaturedRecipeCard`-Sprache des Entwurfs: Foto als Grund, Verlauf nach
/// unten, darauf Badge, Titel und Kennzahlen.
class _RecipeHeroCard extends StatelessWidget {
  const _RecipeHeroCard({
    required this.recipe,
    required this.onTap,
    this.badgeText,
  });

  final FitnessRecipe recipe;
  final VoidCallback onTap;

  /// Ersetzt das „EMPFOHLEN"-Etikett (z.B. durch „Match" in der Ziel-Sektion).
  final String? badgeText;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(26),
      child: SizedBox(
        // Breiter als die frueheren 200 px: der Titel steht jetzt in
        // Display-Groesse auf voller Kartenbreite und wuerde bei 200 px in
        // Silben zerfallen. 280 laesst auf einem 393er Viewport die naechste
        // Karte weiterhin anschneiden — das Karussell bleibt als solches
        // erkennbar.
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
                    // Ein Foto-Scrim MUSS in beiden Anzeige-Modi dunkel sein
                    // (das Foto ist in beiden dasselbe), taugt also fuer keinen
                    // Tinten-Token. `Colors.black` ist kein Color(0x…)-Literal
                    // und entspricht dem bisherigen Verlauf.
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
                      _RecipeBadge(
                        text: badgeText ?? context.l10n.recipesRecommendedBadge,
                        icon: badgeText == null ? null : Icons.bolt_rounded,
                        filled: true,
                      ),
                      const SizedBox(height: 9),
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

/// Die `RecipeCard`-Sprache des Entwurfs: 96×96-Bild links, Kategorie als
/// farbige Versalien-Zeile, Titel, zweizeilige Beschreibung, Kennzahlen.
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
                      recipe.categories.first.toUpperCase(),
                      // Einheitlich `accent`: die Vorlage faerbt diese Zeile
                      // nach MealSlot in Makro-Toenen — unsere Karten tragen
                      // aber Rezept-KATEGORIEN, und Makro-Farben kodieren laut
                      // Token-Vertrag ausschliesslich Naehrwerte.
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
                    recipe.description,
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
