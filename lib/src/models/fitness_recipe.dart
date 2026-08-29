import '../l10n/l10n.dart';
import 'macro_progress.dart';
import 'meal_analysis_result.dart';
import 'model_limits.dart';
import 'recipe_catalog_de.dart';
import 'recipe_catalog_en.dart';
import 'user_profile.dart';

export 'recipe_catalog_de.dart' show recipeCatalogDe;
export 'recipe_catalog_en.dart' show recipeCatalogEn;

/// The `High Protein` category, as a constant instead of a repeated literal:
/// it is the one tag that is DERIVED from the numbers (see [HighProteinRule]),
/// so tag and rule must stay spelled the same in both catalogs.
///
/// Double-quoted like [recipeFilters]: the value is language-neutral matching
/// data, not UI text.
const String highProteinCategory = "High Protein";

/// When a recipe may carry [highProteinCategory].
///
/// Before the fix run of 2026-08-29 the tag was assigned by feel, and no
/// threshold separated the two groups: the highest untagged recipe had 36 g of
/// protein (23.2 % of its energy) while the lowest tagged one had 26 g
/// (18.6 %). Two conditions, BOTH required:
///
///  1. **[minEnergyShare] of the energy comes from protein.** This is the legal
///     definition of the claim — EU Regulation (EC) No 1924/2006, Annex,
///     "HIGH PROTEIN" — so the tag means the same thing here as on a package.
///  2. **At least [minProteinG] per portion.** The regulation judges
///     composition, not amount; these 30 entries are whole meals, and a tag
///     that promises "high protein" on a 400 kcal plate with 22 g would be a
///     share statement dressed up as a meal statement. 30 g is the usual
///     per-meal protein dose and roughly a third of a 90–120 g day.
///
/// Condition 2 is what currently binds — every catalog recipe with >= 30 g
/// also clears 20 % — while condition 1 catches the opposite shape a future
/// recipe could have: a 1200 kcal plate with 32 g of protein.
///
/// `test/models/recipe_high_protein_rule_test.dart` checks all 30 recipes of
/// BOTH catalogs against [FitnessRecipe.meetsHighProteinRule], so a new recipe
/// cannot be tagged by feel again.
abstract final class HighProteinRule {
  /// Minimum share of the energy that must come from protein (EU 1924/2006).
  static const double minEnergyShare = 0.20;

  /// Minimum grams of protein per portion.
  static const int minProteinG = 30;

  /// Atwater factor: protein carries 4 kcal per gram.
  static const int kcalPerProteinG = 4;
}

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

  /// True for user-created recipes (no image asset), so the UI can render them
  /// without Image.asset.
  final bool userCreated;

  double get kcalPer100G =>
      estimatedGrams <= 0 ? 0 : caloriesKcal * 100 / estimatedGrams;

  /// True when this recipe earns [highProteinCategory] — see [HighProteinRule]
  /// for both conditions and why they are the ones. A recipe without calories
  /// has no energy share to compute, so it never qualifies.
  bool get meetsHighProteinRule {
    if (proteinG < HighProteinRule.minProteinG) return false;
    if (caloriesKcal <= 0) return false;
    return proteinG * HighProteinRule.kcalPerProteinG >=
        caloriesKcal * HighProteinRule.minEnergyShare;
  }

  /// 0..1 fit against the day's remaining macros (protein weighted double) plus
  /// a kcal term; filling the remainder without overshooting ranks highest.
  /// Sorting heuristic only, not nutrition advice.
  double matchScore(MacroProgress remaining) {
    if (remaining.kcal <= 0 &&
        remaining.proteinG <= 0 &&
        remaining.carbsG <= 0 &&
        remaining.fatG <= 0) {
      return 0;
    }
    double term(double recipeG, double remainingG, double weight) {
      if (remainingG <= 0) {
        // Nothing left to fill, so a surplus is penalised lightly.
        return recipeG <= 0 ? weight : weight * 0.35;
      }
      final ratio = recipeG / remainingG;
      // Best near 1.0 (covers the remainder), decaying gently either side.
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
      kcalScore = ratio <= 1 ? 0.5 + 0.5 * ratio : (1 / ratio).clamp(0.0, 1.0);
    }

    final macroPart = (pScore + cScore + fScore) / 4.0; // weights sum to 4
    return (macroPart * 0.7 + kcalScore * 0.3).clamp(0.0, 1.0);
  }

  /// True if the recipe fits diet preference [diet], driving recommendation
  /// filtering. Decided purely from [categories] so it stays deterministic
  /// without parsing ingredients: `Fisch` means fish, `Vegetarisch`/`Vegan`
  /// mean meat- and fish-free, and everything else counts as meat. Vegan
  /// matches only explicitly vegan dishes, so egg/dairy vegetarian ones drop
  /// out. User recipes are never filtered. A recommendation heuristic, not an
  /// allergy guarantee.
  bool matchesDiet(DietPreference diet) {
    if (diet == DietPreference.none) return true;
    if (userCreated) return true;

    final isFish = categories.contains('Fisch');
    final isVegan = categories.contains('Vegan');
    // `Vegan` implies vegetarian; the `Vegetarisch` tag covers non-vegan
    // egg/dairy dishes.
    final isVegetarian = isVegan || categories.contains('Vegetarisch');
    // Fail-safe default: whatever is not POSITIVELY marked fish, vegetarian or
    // vegan is treated as meat. The rule used to additionally require
    // `Hauptgericht`/`High Protein`, so a dish tagged only `Frühstück` or
    // `Low Carb` slipped through as diet-neutral and was actively recommended
    // to vegetarians. For a diet filter the safe direction is to hold an
    // unlabelled dish back, not to offer it.
    final isMeat = !isFish && !isVegetarian;

    return switch (diet) {
      DietPreference.none => true,
      DietPreference.pescetarian => !isMeat,
      DietPreference.vegetarian => !isMeat && !isFish,
      DietPreference.vegan => isVegan,
    };
  }

  /// Stable slug for a newly created user recipe: `user_<ms>`, same convention
  /// as the create sheet.
  static String userRecipeSlug() =>
      'user_${DateTime.now().millisecondsSinceEpoch}';

  /// Slug for a recipe adopted from a /recipe card, derived deterministically
  /// from the chat message id so the "added" state survives restart and sync,
  /// and a double tap hits the upsert conflict instead of creating a duplicate.
  static String coachProposalSlug(String messageId) => 'user_coach_$messageId';

  /// Serialises this recipe for an upsert on public.user_recipes. The sync sets
  /// user_id; the DB fills id/created_at/updated_at. categories becomes text[].
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

  /// Builds a FitnessRecipe from a public.user_recipes row. Missing or
  /// mistyped columns fall back to the empty string — the neutral "no value"
  /// marker that [displayDescription] & siblings resolve into the active locale
  /// at render time, rather than a hardcoded German placeholder.
  /// userCreated is true by definition: every row here is user-made.
  factory FitnessRecipe.fromRow(Map<String, dynamic> row) {
    final rawCategories = row['categories'];
    final categories = rawCategories is List
        ? rawCategories.map((c) => c.toString()).toList(growable: false)
        : const <String>[];
    // Never invent a slug: it is the upsert conflict key (user_id,slug), so a
    // fresh one per outbox retry would create duplicate server rows. A missing
    // slug means a corrupt payload -> throw -> _CorruptOpPayload drop.
    // Server rows are unaffected (slug NOT NULL).
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

  /// Resolves one placeholder value at render time. `value` is either real user
  /// text, the empty marker, or a German placeholder stored before i18n.
  /// [select] reads the same ARB key from [deL10n]/[enL10n]/active `l10n`; if
  /// `value` is empty or matches either wording it is treated as a placeholder
  /// and replaced with the current locale's version.
  ///
  /// Known gap: user text that happens to match a placeholder wording is
  /// translated too. Cosmetic only — the stored row is untouched.
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

  /// Display value of [description]. The create sheet has no description field,
  /// so for [userCreated] this is practically always a placeholder; catalog
  /// recipes return their text unchanged.
  String displayDescription(AppLocalizations l10n) => userCreated
      ? _resolvePlaceholder(description, l10n, (x) => x.recipesOwnTitle)
      : description;

  /// Display value of [portion]. The sheet prefills it per locale
  /// (`foodPortionFallback`); leaving it untouched or empty persists the empty
  /// marker rather than placeholder text.
  String displayPortion(AppLocalizations l10n) => userCreated
      ? _resolvePlaceholder(portion, l10n, (x) => x.foodPortionFallback)
      : portion;

  /// Display value of [ingredients]. Has a real form field, so the placeholder
  /// only applies to empty input.
  String displayIngredients(AppLocalizations l10n) => userCreated
      ? _resolvePlaceholder(ingredients, l10n, (x) => x.recipesNoDataProvided)
      : ingredients;

  /// Display value of [preparation]. No form field, so for [userCreated] this
  /// is always a placeholder.
  String displayPreparation(AppLocalizations l10n) => userCreated
      ? _resolvePlaceholder(preparation, l10n, (x) => x.recipesNoPreparationYet)
      : preparation;

  /// Display value of [professionalHint]. Neither a form field nor a DB column
  /// (`fromRow` always sets ''), so for [userCreated] always a placeholder.
  String displayProfessionalHint(AppLocalizations l10n) => userCreated
      ? _resolvePlaceholder(
          professionalHint,
          l10n,
          (x) => x.recipesSelfCreatedHint,
        )
      : professionalHint;

  /// A macro value as the text `MealAnalysisResult` carries, clamped to
  /// `logged_meals.protein_g` & co. (0..1000).
  ///
  /// `user_recipes` bounds macros only at `>= 0`, but `MealsSync` parses the
  /// first number out of this very text into a `numeric` column that has an
  /// upper bound — so `'5000 g'` would be written as 5000 and rejected.
  static String _macroText(int gramm) => '${clampMealMacroG(gramm).round()} g';

  /// [l10n] optional, defaults to [deL10n] so context-free callers (tests) stay
  /// German. `portionNotes` uses the resolved display values, not the raw
  /// fields, or a fresh user recipe would log an empty gap.
  ///
  /// **This is the enforcement point [UserRecipeLimits] names**: every field
  /// that ends up in a `logged_meals` COLUMN is clamped here. A recipe may be
  /// perfectly legal as a `user_recipes` row (title up to 300 code points,
  /// numbers only `>= 0`) and still break `logged_meals_safe_ranges_check` —
  /// e.g. 30 ZWJ family emoji are 30 graphemes for the create sheet's
  /// `maxLength` but 210 code points for `char_length(meal_name) <= 160`. That
  /// mismatch is silent data loss, not a visible error: the entry appears in
  /// the diary, the outbox reads the 23514 as an active server rejection,
  /// retries it eight times, drops it — and the meal is gone after the next
  /// cold start.
  ///
  /// `confidence` and `portionNotes` are NOT clamped: they live in the
  /// `payload` JSON, which is bounded only as a whole
  /// ([LoggedMealLimits.payloadMaxBytes]) and is fed from fields the create
  /// sheet already caps.
  MealAnalysisResult toMealResult([AppLocalizations? l10n]) {
    final sprache = l10n ?? deL10n;
    return MealAnalysisResult(
      mealName: clampMealName(title),
      caloriesKcal: clampMealCaloriesKcal(caloriesKcal),
      estimatedGrams: clampMealEstimatedG(estimatedGrams),
      kcalPer100G: clampKcalPer100G(kcalPer100G),
      protein: _macroText(proteinG),
      carbs: _macroText(carbsG),
      fat: _macroText(fatG),
      confidence: MealResultConfidence.recipe.code,
      portionNotes:
          '${displayPortion(sprache)} · '
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

/// Backwards-compatible alias pointing at [recipeCatalogDe]: existing tests
/// import `fitnessRecipes` without a locale and pin German titles. New
/// locale-aware callers use [recipeCatalogForLocale].
const List<FitnessRecipe> fitnessRecipes = recipeCatalogDe;

/// Search normalisation: lower case plus a simple umlaut fold, so "Haehnchen"
/// finds "Hähnchen" and vice versa. Applied to query AND fields.
///
/// Double-quoted on purpose: the literals are matching data, not UI text, so
/// the hardcoded-string guard (single quotes only) skips them.
String foldRecipeSearchText(String text) => text
    .toLowerCase()
    .replaceAll("ä", "ae")
    .replaceAll("ö", "oe")
    .replaceAll("ü", "ue")
    .replaceAll("ß", "ss");

/// Number of recipes in the recommendation carousel.
const int recipeRecommendationCount = 4;

/// Picks [count] recipes from [pool] starting at a day-based offset, so the
/// carousel rotates through the whole catalog instead of always showing the
/// first four. Wraps around; a pool shorter than [count] is returned whole.
///
/// Day counting runs in UTC on the calendar date so a DST switch never shifts
/// the offset by one (same trap as `daysBetween`).
List<FitnessRecipe> rotatedRecommendations(
  List<FitnessRecipe> pool,
  DateTime now, {
  int count = recipeRecommendationCount,
}) {
  if (pool.isEmpty || count <= 0) return const <FitnessRecipe>[];
  final day = DateTime.utc(now.year, now.month, now.day)
      .difference(DateTime.utc(2020))
      .inDays;
  final n = pool.length;
  final start = day % n;
  final take = count < n ? count : n;
  return <FitnessRecipe>[
    for (var i = 0; i < take; i++) pool[(start + i) % n],
  ];
}

/// Picks the recipe catalog for the active app language. [localeName] is
/// `AppLocalizations.localeName`; mirrors `resolveEatovaLocale` in that
/// anything but `de` falls back to English. Callers pass `l10n.localeName`
/// through instead of doing their own locale lookup.
List<FitnessRecipe> recipeCatalogForLocale(String localeName) =>
    localeName == 'de' ? recipeCatalogDe : recipeCatalogEn;
