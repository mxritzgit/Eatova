// A meal the user described in words, as `analyze-meal` (describe mode)
// understood it. Contract: docs/MEAL-DESCRIBE.md. Never persisted: the draft
// built from it becomes a normal MealAnalysisResult once the user adds it.

import 'logged_meal.dart';
import 'meal_analysis_result.dart';
import 'model_limits.dart';

/// Whether the user named the amount ("1 Scheibe", "200 g") or the model
/// estimated a typical portion.
enum DescribedGramsSource { stated, estimated }

/// One food of the description, with the model's estimate as a fallback.
class DescribedFoodItem {
  const DescribedFoodItem({
    required this.name,
    required this.searchQuery,
    required this.grams,
    required this.gramsSource,
    this.brand,
    this.amountText,
    this.caloriesKcal,
    this.kcalPer100G,
    this.proteinG,
    this.carbsG,
    this.fatG,
  });

  /// Display name in the app language.
  final String name;

  /// Product search term without amounts.
  final String searchQuery;

  /// Brand or store the user named, if any; a search hint, not a filter.
  final String? brand;

  /// The amount as said ("1 Scheibe"), if any.
  final String? amountText;

  final int grams;
  final DescribedGramsSource gramsSource;

  /// The model's estimate for [grams]; null when it gave none.
  final int? caloriesKcal;
  final double? kcalPer100G;

  /// Macros in grams for [grams]; null means unknown, not 0 g.
  final double? proteinG;
  final double? carbsG;
  final double? fatG;
}

/// The parsed `result` object of a describe-mode response.
class DescribedMeal {
  const DescribedMeal({required this.base, required this.items, this.slotHint});

  /// `result` parsed by [MealAnalysisResult.fromEdgeFunction]: meal name,
  /// confidence, explanation and the model's totals. The draft's result is
  /// derived from it, so every existing invariant of that parser applies.
  final MealAnalysisResult base;

  final List<DescribedFoodItem> items;

  /// Slot named in the sentence, else null.
  final MealSlot? slotHint;

  /// Most items one description keeps; the server's photo path caps the same.
  static const int maxItems = 20;

  /// Parses the `result` object. Throws [FormatException] when it carries no
  /// usable item.
  ///
  /// The server clamps already; the client re-checks every field. An item
  /// needs a name, grams above 0 and some energy statement (`caloriesKcal` or
  /// `kcalPer100G`): without one its estimate would carry no numbers, and a
  /// draft line must never end up without them. Such items are dropped.
  factory DescribedMeal.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = <DescribedFoodItem>[
      if (rawItems is List)
        for (final raw in rawItems.whereType<Map<dynamic, dynamic>>())
          ?_readItem(raw),
    ];
    if (items.isEmpty) {
      throw const FormatException('Described meal without a usable item.');
    }
    return DescribedMeal(
      base: MealAnalysisResult.fromEdgeFunction(json),
      items: List<DescribedFoodItem>.unmodifiable(items.take(maxItems)),
      slotHint: _readSlot(json['slotHint']),
    );
  }

  static DescribedFoodItem? _readItem(Map<dynamic, dynamic> json) {
    final name = _text(json['name'], LoggedMealLimits.mealNameMaxChars);
    final grams = _number(json['grams']);
    if (name == null || grams == null || grams <= 0) return null;

    final calories = _number(json['caloriesKcal']);
    final density = _number(json['kcalPer100G']);
    // Negative is no statement; an implausible density (a kJ figure) is
    // dropped, not clamped, like an Open Food Facts value.
    final caloriesKcal = calories == null || calories < 0
        ? null
        : clampMealCaloriesKcal(calories);
    final kcalPer100G = density == null || !isPlausibleKcalPer100G(density)
        ? null
        : density.toDouble();
    if (caloriesKcal == null && kcalPer100G == null) return null;

    return DescribedFoodItem(
      name: name,
      searchQuery:
          _text(json['searchQuery'], _searchQueryMaxChars) ??
          truncateToChars(name, _searchQueryMaxChars),
      brand: _text(json['brand'], _brandMaxChars),
      amountText: _text(json['amountText'], _amountTextMaxChars),
      grams: clampPortionGrams(grams),
      gramsSource: json['gramsSource'] == 'stated'
          ? DescribedGramsSource.stated
          : DescribedGramsSource.estimated,
      caloriesKcal: caloriesKcal,
      kcalPer100G: kcalPer100G,
      proteinG: _macro(json['proteinG']),
      carbsG: _macro(json['carbsG']),
      fatG: _macro(json['fatG']),
    );
  }

  // Wire bounds of docs/MEAL-DESCRIBE.md.
  static const int _searchQueryMaxChars = 80;
  static const int _brandMaxChars = 60;
  static const int _amountTextMaxChars = 40;

  /// One-line text cut to [maxChars], or null when blank or not text.
  static String? _text(Object? raw, int maxChars) {
    if (raw is! String) return null;
    final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return null;
    return truncateToChars(text, maxChars).trimRight();
  }

  /// A finite number, or a string that is one as a whole; else null.
  static num? _number(Object? raw) {
    final value = raw is num
        ? raw
        : raw is String
        ? double.tryParse(raw.trim().replaceAll(',', '.'))
        : null;
    return value == null || !value.isFinite ? null : value;
  }

  static double? _macro(Object? raw) {
    final value = _number(raw);
    return value == null || value < 0 ? null : clampMealMacroG(value);
  }

  static MealSlot? _readSlot(Object? raw) => switch (raw) {
    'breakfast' => MealSlot.breakfast,
    'lunch' => MealSlot.lunch,
    'dinner' => MealSlot.dinner,
    'snack' => MealSlot.snack,
    _ => null,
  };
}
