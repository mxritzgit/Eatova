part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Geteilte Kleinst-Widgets, die Karten, Detail-Ansicht und Slot-Picker
// gemeinsam nutzen: Badge, Kategorie-Pille, Rezept-Bild und Kennzahlen-Zeile.
// ---------------------------------------------------------------------------

/// Übersetzt einen neutralen Kategorie-/Filter-Wert (ein [recipeFilters]-
/// Eintrag oder die `Eigene`-Markierung von Eigen-Rezepten) in seine
/// Anzeige-Form der aktiven Sprache (Inhalte-PR, 2026-08-11).
///
/// Der Wert selbst bleibt die Logik-Identität — Filter-Vergleich
/// (`_RecipesScreenState.filteredRecipes`), Diät-Matching
/// (`FitnessRecipe.matchesDiet`), `ValueKey`s (`recipe-filter-$filter`) — und
/// ist unter `de` byte-gleich zum Vor-Migrations-Stand: [recipeFilters]
/// selbst wird NICHT angefasst. Getrennt nach dem `MealSlot`-Muster
/// (`theme/meal_slot_style.dart`): dort trägt das Enum die neutrale
/// Identität, eine separate `label(l10n)`-Funktion die Anzeige.
///
/// Ein unbekannter Wert (sollte nicht vorkommen, s. Wächter-Test) wird
/// unverändert durchgereicht statt zu crashen — dieselbe fail-soft-Regel wie
/// bei anderen Anzeige-Mappings in diesem Paket.
///
/// Die Vergleichs-Literale sind bewusst DOPPELT gequotet (Muster
/// [recipeFilters]/`categories` in den Katalogdateien): sie sind Content-
/// Identität, keine übersetzte UI-Zeichenkette, und fallen damit wie das
/// Original schon durch den Hartkodierungs-Wächter (der nur einfach
/// gequotete `'...'` prüft, s. dessen Heuristik-Kommentar).
String recipeCategoryLabel(String category, AppLocalizations l10n) {
  return switch (category) {
    "Alle" => l10n.recipesFilterAll,
    "High Protein" => l10n.recipesFilterHighProtein,
    "Hauptgericht" => l10n.recipesFilterMainCourse,
    "Frühstück" => l10n.recipesFilterBreakfast,
    "Fisch" => l10n.recipesFilterFish,
    "Vegetarisch" => l10n.recipesFilterVegetarian,
    "Vegan" => l10n.recipesFilterVegan,
    "Low Carb" => l10n.recipesFilterLowCarb,
    "Eigene" => l10n.recipesCategoryOwn,
    _ => category,
  };
}

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

/// Bild einer Rezept-Karte. Drei Faelle, in dieser Reihenfolge:
///
///  1. `local:<slug>.jpg` — ein selbst aufgenommenes Foto aus dem
///     [RecipeImageStore]. Liegt die Datei auf DIESEM Geraet, wird sie
///     gezeigt; fehlt sie (zweites Geraet, geraeumter Cache), faellt die
///     Kachel auf den Platzhalter zurueck. Nie ein graues Kaputt-Icon.
///  2. Die 30 Bestandsrezepte zeigen ihr Bundle-Asset.
///  3. Alles Uebrige (Eigen-Rezept ohne Bild) bekommt den gestreiften
///     [ImagePlaceholder] der Design-Bibliothek.
class _RecipeImage extends StatelessWidget {
  const _RecipeImage({required this.recipe, this.placeholderRadius = 0});

  final FitnessRecipe recipe;

  /// Der Platzhalter zeichnet seine eigene Ecke; die echten Assets schneidet
  /// die aufrufende Karte per ClipRRect zu.
  final double placeholderRadius;

  @override
  Widget build(BuildContext context) {
    if (RecipeImageStore.isLocalReference(recipe.imageAsset)) {
      return _LocalRecipeImage(
        reference: recipe.imageAsset,
        placeholderRadius: placeholderRadius,
      );
    }
    if (recipe.userCreated || recipe.imageAsset.isEmpty) {
      return ImagePlaceholder(
        radius: placeholderRadius,
        label: context.l10n.recipesImagePlaceholderLabel,
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

/// Ein selbst aufgenommenes Rezept-Foto aus dem App-Dokumentenverzeichnis.
///
/// Warum ein StatefulWidget statt eines [FutureBuilder]: der Ablageort steht
/// nach dem ersten Aufloesen fest, [RecipeImageStore.resolveSync] beantwortet
/// die Frage danach OHNE Frame-Verzoegerung. Ein FutureBuilder haette beim
/// Scrollen durch die Liste jedes Mal einen Platzhalter-Frame aufblitzen
/// lassen, obwohl die Datei laengst bekannt ist. Nur der allererste Zugriff
/// einer Sitzung laeuft asynchron.
class _LocalRecipeImage extends StatefulWidget {
  const _LocalRecipeImage({
    required this.reference,
    required this.placeholderRadius,
  });

  final String reference;
  final double placeholderRadius;

  @override
  State<_LocalRecipeImage> createState() => _LocalRecipeImageState();
}

class _LocalRecipeImageState extends State<_LocalRecipeImage> {
  File? _file;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _LocalRecipeImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reference != widget.reference) {
      _file = null;
      _resolve();
    }
  }

  void _resolve() {
    final store = RecipeImageStore.instance;
    if (store.baseResolved) {
      _file = store.resolveSync(widget.reference);
      return;
    }
    final gesucht = widget.reference;
    store.resolve(gesucht).then((datei) {
      // Zwischenzeitlich abgeraeumt oder auf ein anderes Rezept umgehaengt.
      if (!mounted || gesucht != widget.reference) return;
      setState(() => _file = datei);
    });
  }

  @override
  Widget build(BuildContext context) {
    final datei = _file;
    if (datei == null) {
      return ImagePlaceholder(
        radius: widget.placeholderRadius,
        label: context.l10n.recipesImagePlaceholderLabel,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final logicalWidth =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 400.0;
        return Image.file(
          datei,
          fit: BoxFit.cover,
          cacheWidth: (logicalWidth * dpr).round().clamp(1, 1600),
          // Die Datei kann zwischen Existenz-Pruefung und Dekodieren
          // verschwinden (Loeschen, Aufraeumen). Auch dann: Platzhalter.
          errorBuilder: (context, error, stack) => ImagePlaceholder(
            radius: widget.placeholderRadius,
            label: context.l10n.recipesImagePlaceholderLabel,
          ),
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
    final l10n = context.l10n;
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
        Text(l10n.recipesMetricProtein(recipe.proteinG), style: stil(leise)),
        Text(l10n.recipesMetricCarbs(recipe.carbsG), style: stil(leise)),
        Text(l10n.recipesMetricFat(recipe.fatG), style: stil(leise)),
      ],
    );
  }
}
