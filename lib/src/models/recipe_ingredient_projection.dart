import 'recipe_ingredient.dart' show validateRecipeServings;

/// Describes raw source quantities, independently of the nutrition basis.
enum RecipeIngredientsBasis { perRecipe, perServing, unspecified }

const recipeIngredientsBasisPrefix = 'Ingredients basis: ';

class RecipeIngredientProjection {
  const RecipeIngredientProjection(this.text, {this.isScaled = false});
  final String text;

  /// Every quantified line is expressed for the requested servings.
  final bool isScaled;
}

/// Bounded, all-or-original projection. Never edits the persisted source.
/// Unsupported prose, package sizes or multiple quantities remain reviewable.
/// [decimalSeparator] applies only to computed amounts; source text is kept.
RecipeIngredientProjection projectRecipeIngredients(
  String source, {
  required RecipeIngredientsBasis basis,
  required double? batchServings,
  double servings = 1,
  String decimalSeparator = '.',
}) {
  validateRecipeServings(servings);
  if (basis == RecipeIngredientsBasis.unspecified ||
      (basis == RecipeIngredientsBasis.perRecipe && batchServings == null) ||
      source.length > 20000) {
    return RecipeIngredientProjection(source);
  }
  if (batchServings != null) validateRecipeServings(batchServings);
  final factor =
      servings /
      (basis == RecipeIngredientsBasis.perRecipe ? batchServings! : 1);
  if (factor == 1) return RecipeIngredientProjection(source, isScaled: true);
  final result = <String>[];
  for (final line in source.split('\n')) {
    if (_writtenAmount.hasMatch(line)) {
      return RecipeIngredientProjection(source);
    }
    if (!_numberLike.hasMatch(line)) {
      final unquantified = line.trim().replaceFirst(RegExp(r'^[-•*]\s+'), '');
      // Unparsed prose can contain written amounts in any source language.
      // Only known quantity-free seasonings and section labels are invariant.
      if (unquantified.isNotEmpty &&
          !_sectionHeading.hasMatch(unquantified) &&
          !_seasoning.hasMatch(unquantified)) {
        return RecipeIngredientProjection(source);
      }
      result.add(line);
      continue;
    }
    final measured = _quantity.firstMatch(line);
    final match = measured ?? _countQuantity.firstMatch(line);
    if (match == null) return RecipeIngredientProjection(source);
    final amount = _parseAmount(match[2]!);
    final upper = match[3] == null ? null : _parseAmount(match[3]!);
    final rest = match[5]!;
    // Percentages describe the food, not its amount. All other later numbers
    // could be another quantity, package size, temperature or instruction.
    if (_numberLike.hasMatch(rest.replaceAll(_percentage, '')) ||
        (measured != null && rest.trim().isEmpty) ||
        amount == null ||
        (match[3] != null && (upper == null || upper < amount))) {
      return RecipeIngredientProjection(source);
    }
    final lowerText = _formatAmount(amount * factor, decimalSeparator);
    final upperText = upper == null
        ? null
        : _formatAmount(upper * factor, decimalSeparator);
    if (lowerText == null || (upper != null && upperText == null)) {
      return RecipeIngredientProjection(source);
    }
    result.add(
      '${match[1]}$lowerText${upperText == null ? '' : '–$upperText'}${match[4]}$rest',
    );
  }
  return RecipeIngredientProjection(result.join('\n'), isScaled: true);
}

const _fractionValues = {
  '½': .5,
  '¼': .25,
  '¾': .75,
  '⅓': 1 / 3,
  '⅔': 2 / 3,
  '⅛': .125,
  '⅜': .375,
  '⅝': .625,
  '⅞': .875,
};
final _numberLike = RegExp(r'\p{N}', unicode: true);
final _sectionHeading = RegExp(
  r'^(?:Zutaten|ingredients|Teig|dough|Füllung|filling|Sauce|Soße|Sosse|topping|Belag|Garnitur|garnish):$',
  caseSensitive: false,
);
final _seasoning = RegExp(
  r'^(?:salt|pepper|Salz|Pfeffer)(?:\s*(?:,|und|and|&)\s*(?:salt|pepper|Salz|Pfeffer))*(?:\s+(?:to taste|nach Geschmack))?[.!]?$',
  caseSensitive: false,
);
final _writtenAmount = RegExp(
  r'\b(?:one|two|three|four|five|six|seven|eight|nine|ten|half|a|an|ein|eine|einen|einem|einer|zwei|drei|vier|fünf|sechs|sieben|acht|neun|zehn|halbe?[nmr]?)\s+(?:\w+)',
  caseSensitive: false,
);
final _percentage = RegExp(r'\b\d+(?:[.,]\d+)?\s*%');
const _amountPattern =
    r'(?:\d+\s+\d+/\d+|\d+/\d+|\d*\s*[½¼¾⅓⅔⅛⅜⅝⅞]|\d+(?:[.,]\d+)?)';
final _quantity = RegExp(
  '^([ \\t]*(?:-\\s+|[•*]\\s*)?(?:(?:ca\\.|approx\\.)\\s*)?)'
  '($_amountPattern)(?:\\s*[-–]\\s*($_amountPattern))?'
  r'(\s*(?:kg|g|mg|ml|cl|dl|l|oz|lbs?|EL|TL|tbsp|tsp|cups?|Stück|pieces?)\.?\s+)(.+)$',
  caseSensitive: false,
);

// Count only an explicit, bounded food vocabulary. Arbitrary numeric names are
// not quantities (e.g. "7 spice mix"), and package multipliers are unsupported.
final _countQuantity = RegExp(
  '^([ \\t]*(?:-\\s+|[•*]\\s*)?(?:(?:ca\\.|approx\\.)\\s*)?)'
  '($_amountPattern)(?:\\s*[-–]\\s*($_amountPattern))?'
  r'(\s+(?:eggs?|Eier|Ei|tortillas?|wraps?|Zwiebeln?|onions?|tomatoes|tomato|Tomaten?|Knoblauchzehen?|garlic cloves?)\b)(.*)$',
  caseSensitive: false,
);

double? _parseAmount(String input) {
  final text = input.trim();
  final fraction = _fractionValues[text.substring(text.length - 1)];
  if (fraction != null) {
    final whole = text.substring(0, text.length - 1).trim();
    return (whole.isEmpty ? 0 : double.tryParse(whole) ?? double.nan) +
        fraction;
  }
  if (text.contains('/')) {
    final pieces = text.split(RegExp(r'\s+'));
    final ratio = pieces.last.split('/');
    final denominator = double.parse(ratio[1]);
    if (denominator == 0) return null;
    return (pieces.length == 2 ? double.parse(pieces.first) : 0) +
        double.parse(ratio[0]) / denominator;
  }
  // A three-digit suffix might be a thousands separator in another locale.
  if (RegExp(r'[.,]\d{3}$').hasMatch(text)) return null;
  return double.tryParse(text.replaceAll(',', '.'));
}

String? _formatAmount(double value, String decimalSeparator) {
  if (!value.isFinite ||
      value < 0 ||
      value > 10000000 ||
      (value > 0 && value < .001)) {
    return null;
  }
  return value
      .toStringAsFixed(3)
      .replaceFirst(RegExp(r'\.?0+$'), '')
      .replaceFirst('.', decimalSeparator);
}
