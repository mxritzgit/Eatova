import '../l10n/l10n.dart';

/// German fallback texts that writers put into persisted rows: diary and
/// favorite payloads, `logged_meals.meal_name`, recipe rows and snapshots.
///
/// These are WIRE values, not UI text. Rows from every earlier build carry
/// them, already-installed builds on other devices render them verbatim, and
/// favorite keys are derived from the meal name. Writers therefore keep
/// producing exactly these strings; only the display maps them to the active
/// language. Changing a value orphans every stored row that carries it.
abstract final class PersistedLabels {
  /// `MealAnalysisResult.fromEdgeFunction` when the model names no meal.
  static const String unknownMealName = 'Unbekannte Mahlzeit';

  /// `clampMealName` for an empty name, and the payload reader's default.
  static const String mealNameFallback = 'Mahlzeit';

  /// `FitnessRecipe.fromRow` for a row without a title.
  static const String ownRecipeTitle = 'Eigenes Rezept';

  /// `MealComponent.fromJson` for a model item without a name.
  static const String ingredientNameFallback = 'Zutat';

  /// `MealAnalysisResult.fromOpenFoodFacts` for a product without a name.
  static String productName(String code) => 'Produkt $code';

  /// Display value of a product fallback name, or `null` when [name] is not
  /// the fallback for exactly [code].
  ///
  /// The stored code is the evidence: a user-typed "Produkt 42" on a manual
  /// entry has none, and a real product name never repeats its own barcode.
  /// A brand suffix (`' · Milka'`) is kept as is.
  static String? resolveProductName(
    String name,
    String? code,
    AppLocalizations l10n,
  ) {
    if (code == null) return null;
    final stored = productName(code);
    final display = l10n.foodProductFallbackName(code).trim();
    if (name == stored.trim()) return display;
    if (name.startsWith('$stored · ')) {
      return '$display${name.substring(stored.length)}';
    }
    return null;
  }

  /// A macro text such as `'12,5 g'` with the decimal separator of [l10n].
  ///
  /// Writers format macros with a German comma; `MacroProgress` and the sync
  /// parse either separator, so only the display converts. Digits are never
  /// re-rounded, and anything that is not exactly `<number> g` (the `'-'`
  /// unknown marker, free text) passes through unchanged.
  static String macroText(String raw, AppLocalizations l10n) {
    final match = _macroText.firstMatch(raw);
    if (match == null || match.group(2) == null) return raw;
    final separator = l10n.localeName == 'de' ? ',' : '.';
    return '${match.group(1)}$separator${match.group(2)} g';
  }

  static final RegExp _macroText = RegExp(r'^(\d+)(?:[.,](\d+))? g$');
}
