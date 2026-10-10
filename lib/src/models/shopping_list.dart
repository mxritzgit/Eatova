import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../l10n/l10n.dart';
import '../services/local_day.dart';
import 'planned_meal.dart';
import 'recipe_ingredient_projection.dart';

class ShoppingItem {
  const ShoppingItem({
    required this.id,
    required this.name,
    this.grams,
    this.recipeTitle,
    this.servings,
    this.originalQuantities = false,
    this.originalBatchServings,
    this.planId,
    this.lines = const [],
  });
  final String id, name;
  final double? grams;
  final String? recipeTitle;

  /// The planned meal behind a free-text item (its day and slot); display
  /// only, not part of [id].
  final String? planId;
  final double? servings;
  final bool originalQuantities;
  final double? originalBatchServings;

  /// A free-text item's ingredient lines, each checked on its own. Empty for
  /// a weighed item, which is one check itself.
  final List<ShoppingLine> lines;
}

/// One line of a recipe's free-text ingredients.
class ShoppingLine {
  const ShoppingLine({
    required this.id,
    required this.label,
    this.amount,
    this.heading = false,
  });

  /// The line's own check identity.
  final String id;

  /// The ingredient without its leading [amount], or the whole line.
  final String label;

  /// A leading quantity split off for display ("180 g"); never computed with.
  final String? amount;

  /// A section label such as "Topping:": shown, never checked.
  final bool heading;
}

/// Whether [line] of [item] is checked. A line without its own check follows
/// the whole recipe's: a list ticked off before lines had their own checks
/// stays ticked off.
bool shoppingLineChecked(
  Map<String, bool> checks,
  ShoppingItem item,
  ShoppingLine line,
) => checks[line.id] ?? checks[item.id] ?? false;

/// The checks a list offers: one per weighed item, one per free-text line.
({int done, int total}) shoppingProgress(
  List<ShoppingItem> items,
  Map<String, bool> checks,
) {
  var done = 0, total = 0;
  for (final item in items) {
    if (item.grams != null) {
      total++;
      if (checks[item.id] ?? false) done++;
      continue;
    }
    for (final line in item.lines) {
      if (line.heading) continue;
      total++;
      if (shoppingLineChecked(checks, item, line)) done++;
    }
  }
  return (done: done, total: total);
}

/// The meals a week's shopping list covers: planned, not yet eaten.
Iterable<PlannedMeal> shoppingPlans(
  List<PlannedMeal> plans,
  DateTime weekStart,
) {
  final start = localDayKey(weekStart);
  final end = localDayKey(
    DateTime(weekStart.year, weekStart.month, weekStart.day + 7),
  );
  return plans.where(
    (p) =>
        !p.removed &&
        !p.isEaten &&
        p.day.compareTo(start) >= 0 &&
        p.day.compareTo(end) < 0,
  );
}

/// Combines only exact structured identities in grams. Free text retains its
/// recipe and serving context without inferring units or parsing quantities;
/// its lines are split for display and their own checks only.
/// [decimalSeparator] and [l10n] only affect displayed names; ids stay
/// locale-neutral.
List<ShoppingItem> buildShoppingList(
  List<PlannedMeal> plans,
  DateTime weekStart, {
  String decimalSeparator = '.',
  AppLocalizations? l10n,
}) {
  final start = localDayKey(weekStart);
  final groups = <String, ({String name, double grams})>{};
  final sources = <String, Set<String>>{};
  final unquantified = <ShoppingItem>[];
  String identity(Object value) =>
      '$start:${sha256.convert(utf8.encode(jsonEncode(value)))}';
  final sorted = shoppingPlans(plans, weekStart).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  for (final plan in sorted) {
    final recipe = plan.recipe;
    final projection = recipe.ingredientProjectionForServings(plan.servings);
    if (recipe.structuredIngredients.isEmpty ||
        recipe.ingredients.trim().isNotEmpty) {
      final shown = decimalSeparator == '.'
          ? projection.text
          : recipe.ingredientProjectionForServings(plan.servings,
              decimalSeparator: decimalSeparator).text;
      unquantified.add(
        ShoppingItem(
          id: identity(['text', plan.id, projection.text, plan.servings]),
          name: shown,
          originalQuantities: recipe.hasImportedIngredientContext && !projection.isScaled,
          originalBatchServings: recipe.ingredientsBasis == RecipeIngredientsBasis.perRecipe
              ? recipe.batchServings : recipe.ingredientsBasis == RecipeIngredientsBasis.perServing ? 1 : null,
          recipeTitle: l10n == null ? recipe.title : recipe.displayTitle(l10n),
          servings: plan.servings,
          planId: plan.id,
          lines: _shoppingLines(
            projection.text,
            shown,
            (line, occurrence) =>
                identity(['line', plan.id, line, occurrence, plan.servings]),
          ),
        ),
      );
    }
    for (final ingredient in recipe.structuredIngredients) {
      final key = ingredient.shoppingKey;
      (sources[key] ??= {}).add(plan.id);
      final previous = groups[key];
      groups[key] = (
        name:
            previous?.name ??
            (l10n == null ? ingredient.name : ingredient.displayName(l10n)),
        grams:
            (previous?.grams ?? 0) +
            ingredient.grams * plan.servings / recipe.batchServings,
      );
    }
  }
  final quantified =
      groups.entries
          .map(
            (e) => ShoppingItem(
              id: identity([
                'grams',
                e.key,
                e.value.grams.toStringAsFixed(6),
                sources[e.key]!.toList()..sort(),
              ]),
              name: e.value.name,
              grams: e.value.grams,
            ),
          )
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return [...quantified, ...unquantified];
}

/// Free-text ingredient lines without their list markers ("- ", "• ").
List<String> ingredientLines(String text) => [
  for (final line in text.split('\n'))
    if (line.trim().replaceFirst(RegExp(r'^[-–—•*·]+\s*'), '')
        case final clean when clean.isNotEmpty)
      clean,
];

/// A line's id follows its locale-neutral text and how often that text came
/// before, so an edit elsewhere in the recipe keeps the other lines' checks.
List<ShoppingLine> _shoppingLines(
  String neutral,
  String shown,
  String Function(String line, int occurrence) idOf,
) {
  final keys = ingredientLines(neutral);
  var labels = ingredientLines(shown);
  // Both come from the same source lines; a mismatch shows the neutral text.
  if (labels.length != keys.length) labels = keys;
  final seen = <String, int>{};
  return [
    for (var i = 0; i < keys.length; i++)
      _shoppingLine(
        idOf(keys[i], seen[keys[i]] = (seen[keys[i]] ?? -1) + 1),
        labels[i],
      ),
  ];
}

ShoppingLine _shoppingLine(String id, String text) {
  if (text.length <= 48 && text.endsWith(':')) {
    return ShoppingLine(id: id, label: text, heading: true);
  }
  final match = _leadingAmount.firstMatch(text);
  if (match == null) return ShoppingLine(id: id, label: _capitalized(text));
  return ShoppingLine(
    id: id,
    amount: _plainFractions(match[1]!).replaceAll(RegExp(r'\s+'), ' '),
    label: _capitalized(match[2]!),
  );
}

/// "1½" as "1 1/2": the receipt face has no fraction glyphs, and a fallback
/// glyph would print smaller than the digits around it.
String _plainFractions(String amount) => amount.replaceAllMapped(
  RegExp(r'(\d?)\s*([½¼¾⅓⅔⅛⅜⅝⅞])'),
  (m) {
    final fraction = _fractions[m[2]]!;
    return m[1]!.isEmpty ? fraction : '${m[1]} $fraction';
  },
);

const _fractions = {
  '½': '1/2',
  '¼': '1/4',
  '¾': '3/4',
  '⅓': '1/3',
  '⅔': '2/3',
  '⅛': '1/8',
  '⅜': '3/8',
  '⅝': '5/8',
  '⅞': '7/8',
};

/// Only a single-letter capital: "ß" would grow into "SS".
String _capitalized(String text) {
  if (text.isEmpty) return text;
  final first = text[0].toUpperCase();
  return first.length == 1 ? first + text.substring(1) : text;
}

const _amount =
    r'(?:\d+\s+\d+/\d+|\d+/\d+|\d*\s*[½¼¾⅓⅔⅛⅜⅝⅞]|\d+(?:[.,]\d+)?)';
const _unit =
    r'(?:kg|g|mg|ml|cl|dl|l|oz|lbs?|EL|TL|Msp|tbsp|tsp|cups?|Stück|Stk'
    r'|pieces?|pcs|Prisen?|pinch(?:es)?|Dosen?|cans?|Bund|bunch(?:es)?'
    r'|Packung(?:en)?|Pck|packs?|Scheiben?|slices?|Zehen?|cloves?|Becher'
    r'|Gl(?:as|äser)|jars?|Handvoll|handfuls?|Tassen?|Gramm|Liter|Zweige?'
    r'|sprigs?|Esslöffel|Teelöffel)\.?';

/// A leading quantity ("180 g", "1½ EL", "ca. 2–3", "2 x 150 g", "1 Dose")
/// and the rest.
final _leadingAmount = RegExp(
  '^((?:(?:ca\\.|approx\\.|etwa)\\s*)?$_amount(?:\\s*[-–]\\s*$_amount)?'
  '(?:\\s*[x×]\\s*$_amount)?(?:\\s*$_unit(?=\\s))?)\\s+(\\S.*)\$',
  caseSensitive: false,
  unicode: true,
);
