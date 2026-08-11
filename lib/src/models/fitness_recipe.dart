import '../l10n/l10n.dart';
import 'macro_progress.dart';
import 'meal_analysis_result.dart';
import 'recipe_catalog_de.dart';
import 'recipe_catalog_en.dart';
import 'user_profile.dart';

export 'recipe_catalog_de.dart' show recipeCatalogDe;
export 'recipe_catalog_en.dart' show recipeCatalogEn;

class FitnessRecipe {
  const FitnessRecipe({
    required this.slug,
    required this.title,
    required this.description,
    required this.portion,
    required this.ingredients,
    required this.preparation,
    required this.professionalHint,
    required this.imageAsset,
    required this.caloriesKcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.estimatedGrams,
    required this.categories,
    this.userCreated = false,
  });

  final String slug;
  final String title;
  final String description;
  final String portion;
  final String ingredients;
  final String preparation;
  final String professionalHint;
  final String imageAsset;
  final int caloriesKcal;
  final int proteinG;
  final int carbsG;
  final int fatG;
  final int estimatedGrams;
  final List<String> categories;

  /// True für selbst angelegte Rezepte (kein Bild-Asset, eigener Akzent).
  /// Erlaubt der UI, sie ohne Image.asset darzustellen.
  final bool userCreated;

  double get kcalPer100G => estimatedGrams <= 0 ? 0 : caloriesKcal * 100 / estimatedGrams;

  /// 0..1 wie gut dieses Rezept zu den noch offenen Tagesmakros passt.
  /// Bewertet anhand der Restmengen (Protein/KH/Fett, mit Protein doppelt
  /// gewichtet) plus eines kcal-Fit-Terms. Eine Mahlzeit, die in die
  /// Restmakros passt ohne deutlich zu überschießen, rankt höher.
  /// Reine Sortier-Heuristik — keine Ernährungsberatung.
  double matchScore(MacroProgress remaining) {
    if (remaining.kcal <= 0 &&
        remaining.proteinG <= 0 &&
        remaining.carbsG <= 0 &&
        remaining.fatG <= 0) {
      return 0;
    }
    double term(double recipeG, double remainingG, double weight) {
      if (remainingG <= 0) {
        // Kein Bedarf mehr → Überschuss wird leicht bestraft.
        return recipeG <= 0 ? weight : weight * 0.35;
      }
      final ratio = recipeG / remainingG;
      // Optimal nahe 1.0 (deckt den Rest), sanft fallend bei Über-/Unterschuss.
      final closeness = ratio <= 1
          ? 0.55 + 0.45 * ratio
          : (1 / ratio).clamp(0.0, 1.0);
      return weight * closeness;
    }

    final pScore = term(proteinG.toDouble(), remaining.proteinG, 2.0);
    final cScore = term(carbsG.toDouble(), remaining.carbsG, 1.0);
    final fScore = term(fatG.toDouble(), remaining.fatG, 1.0);

    double kcalScore;
    if (remaining.kcal <= 0) {
      kcalScore = 0.3;
    } else {
      final ratio = caloriesKcal / remaining.kcal;
      kcalScore = ratio <= 1
          ? 0.5 + 0.5 * ratio
          : (1 / ratio).clamp(0.0, 1.0);
    }

    final macroPart = (pScore + cScore + fScore) / 4.0; // weights sum to 4
    return (macroPart * 0.7 + kcalScore * 0.3).clamp(0.0, 1.0);
  }

  /// True wenn dieses Rezept zur Ernährungspräferenz [diet] passt — die
  /// Grundlage für die Empfehlungs-Filterung (recipes_screen). Rein über die
  /// bestehenden [categories], damit es deterministisch und ohne Zutaten-Parsing
  /// bleibt:
  ///  - `Fisch`            → fischhaltig
  ///  - `Vegetarisch`      → fleisch- UND fischfrei (markiert die veg/vegane Schiene)
  ///  - alles übrige mit `Hauptgericht`/`High Protein` ohne diese beiden Marker
  ///    gilt als Fleischgericht (Hähnchen/Pute/Rind etc.)
  ///
  /// Regeln:
  ///  - [DietPreference.none]        → alles erlaubt
  ///  - [DietPreference.pescetarian] → kein Fleisch, Fisch erlaubt
  ///  - [DietPreference.vegetarian]  → kein Fleisch, kein Fisch
  ///  - [DietPreference.vegan]       → nur explizit mit `Vegan` markierte,
  ///    rein pflanzliche Gerichte; vegetarische Eier-/Milch-Gerichte (z.B.
  ///    Omelett, Skyr-Bowl) fallen raus.
  ///
  /// Eigen-Rezepte ([userCreated], Kategorie `Eigene`) werden NICHT gefiltert —
  /// der User kennt seine eigenen Zutaten und soll sie immer sehen.
  ///
  /// Keine medizinische Allergie-Garantie, nur eine Empfehlungs-Heuristik.
  bool matchesDiet(DietPreference diet) {
    if (diet == DietPreference.none) return true;
    if (userCreated) return true;

    final isFish = categories.contains('Fisch');
    final isVegan = categories.contains('Vegan');
    // `Vegan` impliziert vegetarisch; zusätzlich gilt der `Vegetarisch`-Tag für
    // Ei-/Milch-Gerichte, die nicht vegan sind (Omelett, Skyr, Halloumi …).
    final isVegetarian = isVegan || categories.contains('Vegetarisch');
    // Fleisch = ein Hauptgericht/Protein-Teller, der weder als Fisch noch als
    // vegetarisch/vegan markiert ist (Hähnchen, Pute, Rind, Schwein …).
    final isMeat = !isFish &&
        !isVegetarian &&
        (categories.contains('Hauptgericht') ||
            categories.contains('High Protein'));

    return switch (diet) {
      DietPreference.none => true,
      DietPreference.pescetarian => !isMeat,
      DietPreference.vegetarian => !isMeat && !isFish,
      DietPreference.vegan => isVegan,
    };
  }

  /// Erzeugt einen stabilen Slug fuer ein neu angelegtes User-Rezept.
  /// Gleiche Konvention wie das Erstell-Sheet (recipes_screen): `user_<ms>`.
  static String userRecipeSlug() =>
      'user_${DateTime.now().millisecondsSinceEpoch}';

  /// Serialisiert dieses Rezept fuer ein upsert auf public.user_recipes.
  /// user_id setzt der Sync; id/created_at/updated_at vergibt die DB per
  /// Default bzw. Trigger. categories landet als text[].
  Map<String, dynamic> toRow() {
    return <String, dynamic>{
      'slug': slug,
      'title': title,
      'description': description,
      'portion': portion,
      'ingredients': ingredients,
      'preparation': preparation,
      'image_asset': imageAsset,
      'calories_kcal': caloriesKcal,
      'protein_g': proteinG,
      'carbs_g': carbsG,
      'fat_g': fatG,
      'estimated_g': estimatedGrams,
      'categories': categories,
    };
  }

  /// Baut ein FitnessRecipe aus einer public.user_recipes-Zeile. Defensiv:
  /// fehlende/falsch-getypte Spalten fallen auf einen LEEREN String zurueck —
  /// NICHT mehr auf einen hartkodierten deutschen Platzhaltertext (Inhalte-PR,
  /// 2026-08-11, Branch-Review-Finding: `fromRow` injizierte den Platzhalter
  /// bisher unconditional, unabhaengig von der aktiven App-Sprache). Die leere
  /// Zeichenkette ist der neutrale Marker "kein Wert hinterlegt"; die Anzeige
  /// loest ihn erst zur Laufzeit — s. [displayDescription] & Geschwister —
  /// in die aktuelle Locale auf. `professionalHint` existiert in
  /// der Tabelle ohnehin nicht (nie befuellt, immer '') — bleibt aus demselben
  /// Grund neutral statt fest deutsch. userCreated ist per Definition true —
  /// alle Zeilen dieser Tabelle sind selbst angelegt.
  factory FitnessRecipe.fromRow(Map<String, dynamic> row) {
    final rawCategories = row['categories'];
    final categories = rawCategories is List
        ? rawCategories.map((c) => c.toString()).toList(growable: false)
        : const <String>[];
    // Sentinel-Rest S4: fuer einen fehlenden Slug wurde hier ein FRISCHER
    // erfunden (userRecipeSlug()). Der Slug ist aber der Konflikt-Schluessel
    // des Upserts (user_id,slug) — ueber den Outbox-Replay legte jeder Retry
    // mit korruptem Payload damit eine NEUE Serverzeile an: Duplikate.
    // Ohne Slug ist der Payload korrupt: Wurf -> SyncOp.recipe -> null ->
    // _CorruptOpPayload-Drop. Serverzeilen trifft das nie (slug NOT NULL).
    final slug = row['slug']?.toString();
    if (slug == null || slug.isEmpty) {
      throw const FormatException('user_recipes-Zeile ohne slug');
    }
    return FitnessRecipe(
      slug: slug,
      title: row['title']?.toString() ?? 'Eigenes Rezept',
      description: row['description']?.toString() ?? '',
      portion: row['portion']?.toString() ?? '',
      ingredients: row['ingredients']?.toString() ?? '',
      preparation: row['preparation']?.toString() ?? '',
      professionalHint: '',
      imageAsset: row['image_asset']?.toString() ?? '',
      caloriesKcal: _toInt(row['calories_kcal']),
      proteinG: _toInt(row['protein_g']),
      carbsG: _toInt(row['carbs_g']),
      fatG: _toInt(row['fat_g']),
      estimatedGrams: _toInt(row['estimated_g']),
      categories: categories.isEmpty ? const <String>['Eigene'] : categories,
      userCreated: true,
    );
  }

  static int _toInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  /// Loest EINEN Platzhalter-Wert zur Anzeigezeit auf (Inhalte-PR,
  /// 2026-08-11). `value` ist entweder echter Nutzertext, der leere Marker
  /// (seit diesem PR persistiert `_save()`/`fromRow()` keinen Platzhaltertext
  /// mehr) oder — Rueckwaertskompatibilitaet — ein VOR diesem PR gespeicherter
  /// deutscher Platzhalter (die einzige Sprache, die es vorher gab). [select]
  /// liest denselben ARB-Key aus [deL10n]/[enL10n]/der aktiven `l10n`: matcht
  /// `value` einen der beiden bekannten Wortlaute (oder ist leer), gilt er als
  /// Platzhalter und wird durch die AKTUELLE Locale-Fassung ersetzt. Alles
  /// andere ist echter Nutzertext und bleibt unangetastet.
  ///
  /// Bekannte Luecke (dokumentiert, nicht behoben): ein Nutzer, der zufällig
  /// wortgleich mit einem Platzhalter tippt (z. B. „Keine Angabe" als eigene
  /// Zutatenliste), sieht seinen Text ebenfalls uebersetzt. Seiten-Effekt ist
  /// kosmetisch (derselbe Platzhalter-Wortlaut in der jeweils anderen
  /// Sprache), kein Datenverlust — die gespeicherte Zeile bleibt unveraendert.
  String _resolvePlaceholder(
    String value,
    AppLocalizations l10n,
    String Function(AppLocalizations) select,
  ) {
    if (value.isEmpty || value == select(deL10n) || value == select(enL10n)) {
      return select(l10n);
    }
    return value;
  }

  /// Anzeige-Wert von [description]. Das Anlege-Sheet hat kein eigenes
  /// Beschreibungsfeld — bei [userCreated] war/ist der Wert bis auf echten
  /// Nutzertext (theoretisch moeglich ueber `fromRow`, praktisch nie durchs
  /// Sheet) IMMER ein Platzhalter. Bestandsrezepte liefern ihren Text
  /// unveraendert.
  String displayDescription(AppLocalizations l10n) => userCreated
      ? _resolvePlaceholder(description, l10n, (x) => x.recipesOwnTitle)
      : description;

  /// Anzeige-Wert von [portion]. Das Sheet befuellt das Feld l10n-abhaengig
  /// vor (`foodPortionFallback`) — laesst der Nutzer es unveraendert oder
  /// leert er es, persistiert `_save()` seit diesem PR NICHTS mehr (leerer
  /// Marker statt Platzhaltertext).
  String displayPortion(AppLocalizations l10n) => userCreated
      ? _resolvePlaceholder(portion, l10n, (x) => x.foodPortionFallback)
      : portion;

  /// Anzeige-Wert von [ingredients]. Hat ein echtes Formularfeld — nur bei
  /// leerer Eingabe griff bisher der Platzhalter.
  String displayIngredients(AppLocalizations l10n) => userCreated
      ? _resolvePlaceholder(ingredients, l10n, (x) => x.recipesNoDataProvided)
      : ingredients;

  /// Anzeige-Wert von [preparation]. Kein Formularfeld — wie [description]
  /// bei [userCreated] immer ein Platzhalter, nie echter Nutzertext.
  String displayPreparation(AppLocalizations l10n) => userCreated
      ? _resolvePlaceholder(
          preparation, l10n, (x) => x.recipesNoPreparationYet)
      : preparation;

  /// Anzeige-Wert von [professionalHint]. Kein Formularfeld UND keine
  /// DB-Spalte (`fromRow` setzt immer '') — bei [userCreated] IMMER ein
  /// Platzhalter.
  String displayProfessionalHint(AppLocalizations l10n) => userCreated
      ? _resolvePlaceholder(
          professionalHint, l10n, (x) => x.recipesSelfCreatedHint)
      : professionalHint;

  /// [l10n] optional, Default [deL10n] (Muster `sync_error_messages.dart`):
  /// kontextfreie Aufrufer (Tests, s. `recipe_create_sheet_test.dart`) bleiben
  /// unveraendert deutsch. `portionNotes` baut auf den AUFGELOESTEN
  /// Anzeige-Werten auf ([displayPortion]/[displayDescription]/
  /// [displayProfessionalHint]) statt der Rohdaten — sonst wanderte bei einem
  /// frisch angelegten Eigen-Rezept (seit diesem PR moeglicherweise leere
  /// Felder, s. [FitnessRecipe.fromRow]) eine leere Luecke in die geloggte
  /// Mahlzeit.
  MealAnalysisResult toMealResult([AppLocalizations? l10n]) {
    final sprache = l10n ?? deL10n;
    return MealAnalysisResult(
      mealName: title,
      caloriesKcal: caloriesKcal,
      estimatedGrams: estimatedGrams,
      kcalPer100G: kcalPer100G,
      protein: '$proteinG g',
      carbs: '$carbsG g',
      fat: '$fatG g',
      confidence: 'Rezept',
      portionNotes: '${displayPortion(sprache)} · '
          '${displayDescription(sprache)} '
          '${displayProfessionalHint(sprache)}',
      sourceLabel: MealResultSource.recipe.code,
      brand: 'Eatova',
    );
  }
}

const recipeFilters = <String>[
  "Alle",
  "High Protein",
  "Hauptgericht",
  "Frühstück",
  "Fisch",
  "Vegetarisch",
  "Vegan",
  "Low Carb",
];

/// Rückwärts-kompatibler Alias: eine Reihe von Bestandstests importiert
/// `fitnessRecipes` kontextfrei (ohne Locale) direkt aus diesem Modul und
/// pinnt deutsche Titel — Tests sind API, s. i18n-Regel 1 (de bleibt
/// wortgleich). Zeigt bewusst auf [recipeCatalogDe]; neue,
/// locale-bewusste Aufrufer nutzen [recipeCatalogForLocale].
const List<FitnessRecipe> fitnessRecipes = recipeCatalogDe;

/// Wählt den Rezeptkatalog der aktiven App-Sprache (Spec §5, Inhalte-PR
/// 2026-08-11). [localeName] ist `AppLocalizations.localeName` (kanonisiert
/// `de`/`en`) — Spiegel von `resolveEatovaLocale`
/// (`lib/src/app/locale_controller.dart`): alles außer `de` fällt auf
/// Englisch. Aufrufer reichen `l10n.localeName` durch, kein eigenes
/// Locale-Lookup hier (Muster `formatThousands`/`kcal_format.dart`).
List<FitnessRecipe> recipeCatalogForLocale(String localeName) =>
    localeName == 'de' ? recipeCatalogDe : recipeCatalogEn;

