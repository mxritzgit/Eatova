part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Geteilte Kleinst-Widgets, die Karten, Detail-Ansicht und Slot-Picker
// gemeinsam nutzen: Badge, Kategorie-Pille, Rezept-Bild und Kennzahlen-Zeile.
// ---------------------------------------------------------------------------

/// Kleines Etikett — gefuellt als Markierung auf einem Foto („EMPFOHLEN",
/// „Match"), ungefuellt als ruhiger Hinweis auf einer Karte.
///
/// Zusammenzug der frueheren `_GlassBadge` + `_MatchBadge`: beide zeichneten
/// dieselbe Kapsel, nur mit anderer Fuellung.
class _RecipeBadge extends StatelessWidget {
  const _RecipeBadge({required this.text, this.icon, this.filled = false});

  final String text;
  final IconData? icon;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final foreground = filled ? t.onLime : t.ink;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: filled ? t.lime : t.surf,
        borderRadius: BorderRadius.circular(7),
        border: filled ? null : Border.all(color: t.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: AppType.ui(
              9.5,
              weight: FontWeight.w700,
              color: foreground,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Kompakte Kategorie-Pille der Detail-Ansicht.
///
/// Faerbt einheitlich in [AppTokens.accent]: die Vorlage nimmt hier
/// Makro-Toene, unsere Pillen tragen aber Rezept-KATEGORIEN („Fisch",
/// „Low Carb") — und Makro-Farben kodieren laut Token-Vertrag ausschliesslich
/// Naehrwerte.
class _CategoryPill extends StatelessWidget {
  const _CategoryPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: t.tile,
        borderRadius: BorderRadius.circular(rChip),
      ),
      child: Text(
        label,
        style: AppType.ui(10.5, weight: FontWeight.w600, color: t.accent),
      ),
    );
  }
}

/// Bild einer Rezept-Karte. Die 30 Bestandsrezepte zeigen ihr echtes Asset;
/// nur selbst angelegte Rezepte (ohne Asset) fallen auf den gestreiften
/// [ImagePlaceholder] der Design-Bibliothek zurueck.
class _RecipeImage extends StatelessWidget {
  const _RecipeImage({required this.recipe, this.placeholderRadius = 0});

  final FitnessRecipe recipe;

  /// Der Platzhalter zeichnet seine eigene Ecke; die echten Assets schneidet
  /// die aufrufende Karte per ClipRRect zu.
  final double placeholderRadius;

  @override
  Widget build(BuildContext context) {
    if (recipe.userCreated || recipe.imageAsset.isEmpty) {
      return ImagePlaceholder(radius: placeholderRadius, label: 'REZEPT');
    }
    // Decode-Auflösung an die tatsächliche Slot-Breite koppeln: die Rezept-PNGs
    // sind ~1800px/2.4MB groß und würden sonst voll dekodiert (Hero, Liste,
    // Picker, Detail teilen sich dieses Widget bei sehr unterschiedlicher Größe).
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final logicalWidth =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 400.0;
        return Image.asset(
          recipe.imageAsset,
          fit: BoxFit.cover,
          cacheWidth: (logicalWidth * dpr).round().clamp(1, 1600),
        );
      },
    );
  }
}

/// Die Kennzahlen-Zeile unter einem Rezept-Titel.
///
/// Die Vorlage zeigt hier „480 kcal · 25 min · Serves 2". [FitnessRecipe] kennt
/// weder Zubereitungszeit noch Portionsanzahl — statt Daten zu erfinden stehen
/// hier die vier Werte, die eine Fitness-Rezeptliste ueberhaupt scanbar machen:
/// Kalorien (betont) und das komplette Makro-Trio.
///
/// Die Beschriftungen sind buchstabengleich der frueheren `_MacroRow`
/// (`24g P` · `30g KH` · `12g F`) — der Umbau hatte KH und Fett von den Karten
/// genommen, sie standen danach nur noch in der Detail-Ansicht.
///
/// Bewusst NICHT [FitnessRecipe.portion]: das Feld ist Fliesstext, kein Mass
/// („1 großer Fitness-Teller / 1 Hauptmahlzeit"). In der Kennzahlen-Zeile lief
/// es ueber vier Zeilen und sprengte die Bildkachel; als Beschreibung steht es
/// weiterhin in der Detail-Ansicht unter „Portion".
///
/// `Wrap` statt der `Row` der Vorlage: bei doppelter Schrift bricht die Zeile
/// um, statt ueberzulaufen. Bei normaler Schrift passen alle vier Werte auf
/// eine Zeile — auch in der 280 px breiten Bildkachel.
class _RecipeMetrics extends StatelessWidget {
  const _RecipeMetrics({required this.recipe, this.onImage = false});

  final FitnessRecipe recipe;

  /// Auf dem Foto braucht auch der gedaempfte Wert einen hellen Ton — `ink2`
  /// waere dort in beiden Modi zu dunkel.
  final bool onImage;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final stark = onImage ? t.onForest : t.ink;
    final leise = onImage ? t.onForest.withValues(alpha: 0.78) : t.ink2;
    // Makro-Toene kodieren laut Token-Vertrag Naehrwerte — hier steht der Wert
    // aber schon im Text („30g KH"), und drei Farben auf einer Kachel neben
    // dem Foto waeren Laerm. Die Kodierung traegt das Naehrwert-Grid im Detail.
    TextStyle stil(Color color) =>
        AppType.ui(11, weight: FontWeight.w600, color: color);
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        Text('${recipe.caloriesKcal} kcal', style: stil(stark)),
        Text('${recipe.proteinG}g P', style: stil(leise)),
        Text('${recipe.carbsG}g KH', style: stil(leise)),
        Text('${recipe.fatG}g F', style: stil(leise)),
      ],
    );
  }
}
