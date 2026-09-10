import 'model_limits.dart';

enum IngredientSource { manual, openFoodFacts }

/// Missing nutrition is null; a measured zero remains zero.
class RecipeNutrition {
  const RecipeNutrition({
    this.caloriesKcal,
    this.proteinG,
    this.carbsG,
    this.fatG,
  });

  final double? caloriesKcal, proteinG, carbsG, fatG;

  bool get isComplete =>
      caloriesKcal != null &&
      proteinG != null &&
      carbsG != null &&
      fatG != null;

  RecipeNutrition scaled(double factor) => RecipeNutrition(
    caloriesKcal: caloriesKcal == null ? null : caloriesKcal! * factor,
    proteinG: proteinG == null ? null : proteinG! * factor,
    carbsG: carbsG == null ? null : carbsG! * factor,
    fatG: fatG == null ? null : fatG! * factor,
  );

  Map<String, dynamic> toJson() => {
    'calories_kcal': caloriesKcal,
    'protein_g': proteinG,
    'carbs_g': carbsG,
    'fat_g': fatG,
  };

  factory RecipeNutrition.fromJson(Map<String, dynamic> json) {
    _keys(json, const {'calories_kcal', 'protein_g', 'carbs_g', 'fat_g'});
    return RecipeNutrition(
      caloriesKcal: _optionalNumber(json['calories_kcal'], 900),
      proteinG: _optionalNumber(json['protein_g'], 100),
      carbsG: _optionalNumber(json['carbs_g'], 100),
      fatG: _optionalNumber(json['fat_g'], 100),
    );
  }
}

/// A weighed ingredient and the label/database values used at creation time.
/// No live product reference is needed to recalculate a saved recipe.
class RecipeIngredient {
  RecipeIngredient({
    required String name,
    required this.grams,
    required this.per100g,
    this.source = IngredientSource.manual,
    this.productCode,
  }) : name = name.trim() {
    if (this.name.isEmpty ||
        charLength(this.name) > 160 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(this.name)) {
      throw const FormatException('Invalid ingredient name');
    }
    _number(grams, 0.001, 10000);
    _optionalNumber(per100g.caloriesKcal, 900);
    _optionalNumber(per100g.proteinG, 100);
    _optionalNumber(per100g.carbsG, 100);
    _optionalNumber(per100g.fatG, 100);
    if (productCode != null &&
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(productCode!)) {
      throw const FormatException('Invalid ingredient product code');
    }
    if (source == IngredientSource.manual && productCode != null) {
      throw const FormatException('Manual ingredient has a product code');
    }
  }

  static const maxIngredients = 100;
  final String name;
  final double grams;
  final RecipeNutrition per100g;
  final IngredientSource source;
  final String? productCode;

  /// Exact identity for shopping aggregation; no free-text quantity guessing.
  String get shoppingKey => productCode != null
      ? '${source.name}:$productCode'
      : '${source.name}:${name.toLowerCase().replaceAll(RegExp(r'\s+'), ' ')}';

  RecipeIngredient withGrams(double value) => RecipeIngredient(
    name: name,
    grams: value,
    per100g: per100g,
    source: source,
    productCode: productCode,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'grams': grams,
    'per_100g': per100g.toJson(),
    'source': source.name,
    'product_code': productCode,
  };

  factory RecipeIngredient.fromJson(Map<String, dynamic> json) {
    _keys(json, const {'name', 'grams', 'per_100g', 'source', 'product_code'});
    final name = json['name'];
    final nutrition = json['per_100g'];
    final code = json['product_code'];
    if (name is! String ||
        nutrition is! Map<String, dynamic> ||
        (code != null && code is! String)) {
      throw const FormatException('Invalid ingredient');
    }
    final source = switch (json['source']) {
      'manual' => IngredientSource.manual,
      'openFoodFacts' => IngredientSource.openFoodFacts,
      _ => throw const FormatException('Invalid ingredient source'),
    };
    return RecipeIngredient(
      name: name,
      grams: _number(json['grams'], 0.001, 10000),
      per100g: RecipeNutrition.fromJson(nutrition),
      source: source,
      productCode: code as String?,
    );
  }

  static List<RecipeIngredient> listFromJson(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List || raw.length > maxIngredients) {
      throw const FormatException('Invalid ingredient list');
    }
    return List.unmodifiable(
      raw.map((item) {
        if (item is! Map<String, dynamic>) {
          throw const FormatException('Invalid ingredient');
        }
        return RecipeIngredient.fromJson(item);
      }),
    );
  }
}

/// Direct sums, scaled once after addition; never round individual ingredients.
class RecipeCalculation {
  const RecipeCalculation._(this.nutrition, this.knownNutrition);

  /// A nutrient is null if any ingredient lacks that value.
  final RecipeNutrition nutrition;

  /// Sum of the documented values, for an explicitly incomplete preview.
  final RecipeNutrition knownNutrition;
  bool get isComplete => nutrition.isComplete;

  /// Applies to a per-serving recipe row or the selected diary amount.
  bool get fitsStorageLimits =>
      knownNutrition.caloriesKcal! <= LoggedMealLimits.caloriesKcalMax &&
      knownNutrition.proteinG! <= LoggedMealLimits.macroGMax &&
      knownNutrition.carbsG! <= LoggedMealLimits.macroGMax &&
      knownNutrition.fatG! <= LoggedMealLimits.macroGMax;

  void validateStorageLimits() {
    if (!fitsStorageLimits) {
      throw const FormatException('Recipe nutrition exceeds storage limits');
    }
  }

  factory RecipeCalculation.calculate(
    List<RecipeIngredient> ingredients, {
    required double batchServings,
    double servings = 1,
  }) {
    validateRecipeServings(batchServings);
    validateRecipeServings(servings);
    if (ingredients.isEmpty ||
        ingredients.length > RecipeIngredient.maxIngredients) {
      throw const FormatException('Invalid ingredient count');
    }
    double known(double? Function(RecipeNutrition) get) =>
        ingredients.fold(
          0.0,
          (sum, item) => sum + (get(item.per100g) ?? 0) * item.grams / 100,
        ) *
        servings /
        batchServings;
    double? complete(double? Function(RecipeNutrition) get) =>
        ingredients.every((item) => get(item.per100g) != null)
        ? known(get)
        : null;
    return RecipeCalculation._(
      RecipeNutrition(
        caloriesKcal: complete((n) => n.caloriesKcal),
        proteinG: complete((n) => n.proteinG),
        carbsG: complete((n) => n.carbsG),
        fatG: complete((n) => n.fatG),
      ),
      RecipeNutrition(
        caloriesKcal: known((n) => n.caloriesKcal),
        proteinG: known((n) => n.proteinG),
        carbsG: known((n) => n.carbsG),
        fatG: known((n) => n.fatG),
      ),
    );
  }
}

void validateRecipeServings(double value) => _number(value, 0.1, 100);

double? parseRecipeServings(String text) {
  final value = double.tryParse(text.trim().replaceAll(',', '.'));
  return value != null && value.isFinite && value >= 0.1 && value <= 100
      ? value
      : null;
}

double _number(Object? value, double min, double max) {
  if (value is! num || !value.isFinite || value < min || value > max) {
    throw const FormatException('Invalid ingredient numeric value');
  }
  return value.toDouble();
}

double? _optionalNumber(Object? value, double max) =>
    value == null ? null : _number(value, 0, max);

void _keys(Map<String, dynamic> json, Set<String> allowed) {
  if (json.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('Unknown ingredient field');
  }
}
