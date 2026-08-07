part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Geteilte Kleinst-Widgets, die Karten, Detail-Ansicht und Slot-Picker
// gemeinsam nutzen: Badges, Kategorie-Pille, Rezept-Bild und Makro-Zeile.
// ---------------------------------------------------------------------------
class _GlassBadge extends StatelessWidget {
  const _GlassBadge({required this.text, this.dark = false});

  final String text;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: dark ? surface : Colors.black.withValues(alpha: 0.48),
        borderRadius: BorderRadius.circular(rPill),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: textPrimary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.1,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Lime-getöntes Badge oben rechts auf der „Passt zu deinem Ziel"-Karte.
class _MatchBadge extends StatelessWidget {
  const _MatchBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: lime,
        borderRadius: BorderRadius.circular(rPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.bolt_rounded, color: bg, size: 12),
          const SizedBox(width: 3),
          Text(
            text,
            style: const TextStyle(
              color: bg,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Kompakte Kategorie-Pille. Auf dem Bild (onImage) dunkel-transluzent, sonst
/// lime-getönt — nutzt dieselbe Token-Skala wie der Rest des Screens.
class _CategoryPill extends StatelessWidget {
  const _CategoryPill({required this.label, this.onImage = false});

  final String label;
  final bool onImage;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: onImage
            ? Colors.black.withValues(alpha: 0.5)
            : lime.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(rPill),
        border: Border.all(
          color: onImage
              ? Colors.white.withValues(alpha: 0.18)
              : lime.withValues(alpha: 0.3),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: onImage ? textPrimary : lime,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}

/// Bild für eine Rezept-Karte. Asset-Rezepte zeigen ihr PNG, selbst angelegte
/// Rezepte (ohne Asset) bekommen einen ruhigen lime-getönten Platzhalter.
class _RecipeImage extends StatelessWidget {
  const _RecipeImage({required this.recipe});

  final FitnessRecipe recipe;

  @override
  Widget build(BuildContext context) {
    if (recipe.userCreated || recipe.imageAsset.isEmpty) {
      return Container(
        color: surfaceSoft,
        alignment: Alignment.center,
        child: const Icon(
          Icons.ramen_dining_outlined,
          color: lime,
          size: 30,
        ),
      );
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

class _MacroRow extends StatelessWidget {
  const _MacroRow({required this.recipe, this.compact = false});

  final FitnessRecipe recipe;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final fontSize = compact ? 10.5 : 11.2;
    const tabular = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);
    // FittedBox laesst die Makro-Zeile bei dreistelligen Werten in der schmalen
    // Hero-Kachel proportional schrumpfen statt rechts ueberzulaufen; passt sie,
    // bleibt die Darstellung pixelgenau identisch.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Text(
            '${recipe.proteinG}g P',
            style: tabular.copyWith(
              color: lime,
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${recipe.carbsG}g KH',
            style: tabular.copyWith(
              color: textMuted,
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${recipe.fatG}g F',
            style: tabular.copyWith(
              color: textMuted,
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
