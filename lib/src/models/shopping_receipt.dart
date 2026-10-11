// The week's shopping as one receipt: the same ingredient from several
// planned meals is one row with the summed amount, and spices and pantry
// staples gather in their own section instead of flooding the list.
//
// Built on top of [buildShoppingList], whose items and line ids stay as they
// are: a row of one part keeps that part's id, so checks made on an earlier
// receipt still apply.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../l10n/l10n.dart';
import '../services/local_day.dart';
import 'fitness_recipe.dart';
import 'logged_meal.dart';
import 'persisted_labels.dart';
import 'planned_meal.dart';
import 'shopping_amount.dart';
import 'shopping_ingredient_key.dart';
import 'shopping_list.dart';

export 'shopping_amount.dart';
export 'shopping_ingredient_key.dart'
    show ShoppingIngredientKey, ShoppingStaple;

/// How a [ShoppingUse]'s amount relates to the planned servings.
enum ShoppingScale {
  /// For the planned servings: converted, or written for them.
  planned,

  /// The recipe's own amount for [ShoppingUse.batchServings] servings; it
  /// could not be converted.
  batch,

  /// The recipe's own amount; its serving basis is unknown.
  unknown,
}

/// One planned meal's share of a receipt row.
class ShoppingUse {
  const ShoppingUse({
    required this.planId,
    required this.day,
    required this.slot,
    this.amount,
    this.text,
    this.scale = ShoppingScale.planned,
    this.batchServings,
    ShoppingAmount? original,
  }) : _original = original;

  final String planId;

  /// The planned day, `yyyy-MM-dd`.
  final String day;
  final MealSlot slot;

  /// Counted in [ShoppingRow.total]. Null when the line has no amount, the
  /// amount did not parse, or it is not for the planned servings.
  final ShoppingAmount? amount;

  /// The amount as written when it is not [amount]: unparsed ("2 Stangen"),
  /// or the recipe's own amount when [scale] is not planned.
  final String? text;
  final ShoppingScale scale;

  /// The recipe's servings for [ShoppingScale.batch].
  final double? batchServings;

  /// An unconverted amount, parsed: it still tells spoons from kilos.
  final ShoppingAmount? _original;

  bool get unscaled => scale != ShoppingScale.planned;
}

/// One requirement behind a row: a weighed item, an ingredient line, or one
/// item of a line that lists several ("Salz, Pfeffer").
class ShoppingPart {
  const ShoppingPart({
    required this.id,
    required this.label,
    required this.key,
    required this.uses,
    this.legacyIds = const [],
    ShoppingUnit? unit,
  }) : _unit = unit;

  /// The part's own check id: the weighed item's or the line's id, or a
  /// split id for an item of a listed line.
  final String id;

  /// Checks of earlier receipts this part honours when it has none of its
  /// own, in order: the line before it was split, then the whole recipe; a
  /// weighed item's id without the meals eaten since.
  final List<String> legacyIds;

  /// The label as the recipe writes it, without its amount.
  final String label;
  final ShoppingIngredientKey key;
  final List<ShoppingUse> uses;

  /// The unit [key] was read with.
  final ShoppingUnit? _unit;

  bool isChecked(Map<String, bool> checks) {
    final own = checks[id];
    if (own != null) return own;
    for (final legacy in legacyIds) {
      final value = checks[legacy];
      if (value != null) return value;
    }
    return false;
  }
}

/// One row of the receipt: one ingredient for the whole week.
class ShoppingRow {
  ShoppingRow._({
    required this.id,
    required this.label,
    required this.parts,
    required this.pantry,
  }) : uses = [for (final part in parts) ...part.uses]..sort(_byPlan),
       total = sumShoppingAmounts([
         for (final part in parts)
           for (final use in part.uses)
             if (use.amount case final amount?) amount,
       ]),
       texts = [
         for (final part in parts)
           for (final use in part.uses)
             if (use.amount == null &&
                 use.text != null &&
                 use.scale == ShoppingScale.planned)
               use.text!,
       ];

  /// The check id. A row of one part keeps that part's id; a merged row's id
  /// follows its ingredient and every part, so a new meal needing it again
  /// is a fresh, unchecked requirement. Parts of meals eaten since count
  /// too: eating a meal keeps what was bought ticked off.
  final String id;

  /// The name to show: one part's label as written, or for a merged row the
  /// shortest name, preferring one in the app language.
  final String label;
  final List<ShoppingPart> parts;

  /// In the "Gewürze & Vorrat" section rather than the main list.
  final bool pantry;

  /// Every planned meal's share, by day and slot.
  final List<ShoppingUse> uses;

  /// The planned amounts summed per unit, in [ShoppingUnit] order.
  final List<ShoppingAmount> total;

  /// Planned amounts that did not parse, as written ("2 Stangen").
  final List<String> texts;

  bool get merged => parts.length > 1;

  /// A share is the recipe's own amount, not converted to the plan.
  bool get hasUnscaled => uses.any((u) => u.unscaled);

  /// Worth a detail line with the days: several meals or an unconverted
  /// amount.
  bool get showsDetail => uses.length > 1 || hasUnscaled;

  /// The row's own check, else every part by its own or earlier checks: a
  /// line ticked off on an earlier receipt stays ticked off.
  bool isChecked(Map<String, bool> checks) =>
      checks[id] ?? parts.every((part) => part.isChecked(checks));

  /// The one check a tap writes.
  ShoppingCheck toggle(Map<String, bool> checks) =>
      ShoppingCheck(id: id, checked: !isChecked(checks));
}

/// A planned recipe without ingredient lines: nothing to merge, worth a note.
class ShoppingEmptyRecipe {
  const ShoppingEmptyRecipe({
    required this.title,
    required this.planId,
    required this.day,
    required this.slot,
  });

  final String title, planId;

  /// The planned day, `yyyy-MM-dd`.
  final String day;
  final MealSlot slot;
}

/// The week's receipt.
class ShoppingReceipt {
  const ShoppingReceipt({
    required this.rows,
    required this.pantry,
    required this.emptyRecipes,
  });

  /// The main list, by name.
  final List<ShoppingRow> rows;

  /// Spices and staples, by name.
  final List<ShoppingRow> pantry;

  /// Planned recipes without ingredient lines, by day and slot.
  final List<ShoppingEmptyRecipe> emptyRecipes;

  bool get isEmpty => rows.isEmpty && pantry.isEmpty && emptyRecipes.isEmpty;

  /// Ticked-off main rows; the pantry does not count.
  ({int done, int total}) progress(Map<String, bool> checks) =>
      _progress(rows, checks);

  ({int done, int total}) pantryProgress(Map<String, bool> checks) =>
      _progress(pantry, checks);

  static ({int done, int total}) _progress(
    List<ShoppingRow> rows,
    Map<String, bool> checks,
  ) => (
    done: rows.where((row) => row.isChecked(checks)).length,
    total: rows.length,
  );
}

/// The receipt for the week from [weekStart]: the same meals as
/// [buildShoppingList], merged by ingredient. [decimalSeparator] and [l10n]
/// only affect what is shown; ids stay locale-neutral.
ShoppingReceipt buildShoppingReceipt(
  List<PlannedMeal> plans,
  DateTime weekStart, {
  String decimalSeparator = '.',
  AppLocalizations? l10n,
}) {
  final week = localDayKey(weekStart);
  String identity(Object value) =>
      '$week:${sha256.convert(utf8.encode(jsonEncode(value)))}';
  // Ids follow the week's meals including the eaten ones: eating a meal
  // lowers what is needed and must not reopen what was already bought. Only
  // meals not yet eaten add amounts and rows.
  final items = buildShoppingList(
    plans,
    weekStart,
    decimalSeparator: decimalSeparator,
    l10n: l10n,
    includeEaten: true,
  );
  final planned = {
    for (final p in shoppingPlans(plans, weekStart, includeEaten: true))
      p.id: p,
  };
  // A weighed item's id without the eaten meals, as an earlier receipt
  // ticked it off.
  final openWeighed = planned.values.any((p) => p.isEaten)
      ? {
          for (final item in buildShoppingList(plans, weekStart))
            if (item.shoppingKey case final key?) key: item.id,
        }
      : const <String, String>{};
  final parts = <ShoppingPart>[];
  // Parts only of eaten meals: they keep their rows' ids, nothing else.
  final eaten = <ShoppingPart>{};
  final empty = <ShoppingEmptyRecipe>[];

  for (final item in items) {
    if (item.grams != null) {
      final open = openWeighed[item.shoppingKey];
      final part = ShoppingPart(
        id: item.id,
        legacyIds: [if (open != null && open != item.id) open],
        label: item.name,
        key: _weighedKey(item),
        unit: ShoppingUnit.mass,
        uses: [
          for (final MapEntry(key: planId, value: grams)
              in item.planGrams.entries)
            if (planned[planId] case final plan? when !plan.isEaten)
              _use(plan, amount: ShoppingAmount(ShoppingUnit.mass, grams)),
        ],
      );
      parts.add(part);
      if (part.uses.isEmpty) eaten.add(part);
      continue;
    }
    final plan = planned[item.planId];
    if (plan == null) continue;
    final lines = item.lines.where((line) => !line.heading).toList();
    if (lines.isEmpty) {
      if (plan.isEaten) continue;
      empty.add(
        ShoppingEmptyRecipe(
          title: item.recipeTitle ?? plan.recipe.title,
          planId: plan.id,
          day: plan.day,
          slot: plan.slot,
        ),
      );
      continue;
    }
    final scaling = _Scaling.of(plan, item, decimalSeparator);
    final first = parts.length;
    for (final line in lines) {
      final written = line.amount == null
          ? line.label
          : '${line.amount} ${line.label}';
      // A caption's bullet ("✅ 150 g Hähnchenbrust") is not the name.
      final text = written.replaceFirst(_bullet, '');
      final components = _components(text);
      if (components == null) {
        final split = splitShoppingAmount(text);
        parts.add(
          _linePart(
            id: line.id,
            legacyIds: [item.id],
            label: split.amount == line.amount && text == written
                ? line.label
                : _capitalized(split.label),
            amount: split.amount,
            plan: plan,
            scaling: scaling,
          ),
        );
        continue;
      }
      final seasoning = components.any(
        (c) => shoppingIngredientKey(c.label).staple == ShoppingStaple.always,
      );
      for (var i = 0; i < components.length; i++) {
        parts.add(
          _linePart(
            id: identity(['split', line.id, i]),
            legacyIds: [line.id, item.id],
            label: _capitalized(components[i].label),
            amount: components[i].amount,
            plan: plan,
            scaling: scaling,
            seasoning: seasoning,
          ),
        );
      }
    }
    if (plan.isEaten) eaten.addAll(parts.skip(first));
  }

  final groups = <String, List<ShoppingPart>>{};
  for (final part in parts) {
    var key = part.key.id;
    // A listed line that could not be split merges only with itself, and
    // not at all if it carries more amounts ("1 Zwiebel, 1 Zehe, Xyz"). A
    // name holding an amount the receipt could not read merges with
    // nothing: its amount would go missing from the total.
    if ((key.startsWith('~') && RegExp(r'\d').hasMatch(part.label)) ||
        (part.uses.every((u) => u.amount == null && u.text == null) &&
            _hasUnreadAmount(part.label))) {
      key = '$key#${part.id}';
    }
    (groups[key] ??= []).add(part);
  }
  final language = l10n?.localeName;
  final rows = <ShoppingRow>[];
  for (final MapEntry(:key, value: all) in groups.entries) {
    final members = [
      for (final part in all)
        if (!eaten.contains(part)) part,
    ];
    if (members.isEmpty) continue;
    final staple = members.first.key.staple;
    if (staple == ShoppingStaple.water) continue;
    rows.add(
      ShoppingRow._(
        id: all.length == 1
            ? all.single.id
            : identity([
                'merged',
                key,
                [for (final part in all) part.id]..sort(),
              ]),
        label: members.length == 1
            ? members.single.label
            : _mergedLabel(members, language),
        parts: members,
        pantry: _isPantry(staple, members),
      ),
    );
  }
  final names = {for (final row in rows) row.id: foldShoppingText(row.label)};
  rows.sort((a, b) {
    final byName = names[a.id]!.compareTo(names[b.id]!);
    return byName != 0 ? byName : a.id.compareTo(b.id);
  });
  empty.sort(
    (a, b) => _byMeal((a.day, a.slot, a.planId), (b.day, b.slot, b.planId)),
  );
  return ShoppingReceipt(
    rows: [
      for (final row in rows)
        if (!row.pantry) row,
    ],
    pantry: [
      for (final row in rows)
        if (row.pantry) row,
    ],
    emptyRecipes: empty,
  );
}

/// By day, slot, then plan id.
int _byMeal((String, MealSlot, String) a, (String, MealSlot, String) b) =>
    a.$1 != b.$1
    ? a.$1.compareTo(b.$1)
    : a.$2 != b.$2
    ? a.$2.index.compareTo(b.$2.index)
    : a.$3.compareTo(b.$3);

int _byPlan(ShoppingUse a, ShoppingUse b) =>
    _byMeal((a.day, a.slot, a.planId), (b.day, b.slot, b.planId));

ShoppingUse _use(
  PlannedMeal plan, {
  ShoppingAmount? amount,
  String? text,
  ShoppingScale scale = ShoppingScale.planned,
  double? batchServings,
  ShoppingAmount? original,
}) => ShoppingUse(
  planId: plan.id,
  day: plan.day,
  slot: plan.slot,
  amount: amount,
  text: text,
  scale: scale,
  batchServings: batchServings,
  original: original,
);

/// How a free-text recipe's amounts reach the planned servings.
class _Scaling {
  const _Scaling({
    this.factor,
    this.fallback = ShoppingScale.planned,
    this.batch,
    this.decimalSeparator,
  });

  /// Per-line factor to the planned servings; null when the amounts are used
  /// as they are (or cannot be converted at all: [fallback] unknown).
  final double? factor;

  /// What an amount that cannot be converted is.
  final ShoppingScale fallback;
  final double? batch;

  /// Set when every number is computed with this separator, so "1,125" is
  /// a decimal and not a thousand.
  final String? decimalSeparator;

  bool get unknown => factor == null && fallback == ShoppingScale.unknown;

  /// What an amount kept as written is ("Reis (300 g gekocht)"); null when
  /// it is for the planned servings anyway.
  ShoppingScale? get asWritten => switch (factor) {
    null => unknown ? ShoppingScale.unknown : null,
    final factor when (factor - 1).abs() < 1e-9 => null,
    _ => fallback,
  };

  static _Scaling of(PlannedMeal plan, ShoppingItem item, String separator) {
    final recipe = plan.recipe;
    final servings = plan.servings;
    if (recipe.hasImportedIngredientContext) {
      if (!item.originalQuantities) {
        // The projection converted every line, unless nothing had to change.
        final basis =
            recipe.ingredientsBasis == RecipeIngredientsBasis.perRecipe
            ? recipe.batchServings
            : 1;
        return _Scaling(
          decimalSeparator: servings / basis == 1 ? null : separator,
        );
      }
      final batch = item.originalBatchServings;
      return batch == null
          ? const _Scaling(fallback: ShoppingScale.unknown)
          : _Scaling(
              factor: servings / batch,
              fallback: ShoppingScale.batch,
              batch: batch,
            );
    }
    // Catalog recipes are written for one serving of their batch.
    if (_catalogTexts.contains((recipe.slug, recipe.ingredients))) {
      final factor = servings / recipe.batchServings;
      return factor == 1
          ? const _Scaling()
          : _Scaling(
              factor: factor,
              fallback: ShoppingScale.batch,
              batch: recipe.batchServings,
            );
    }
    // An own or Coach recipe has no confirmed basis: as written for one
    // serving, unconverted for more.
    return servings == 1
        ? const _Scaling()
        : const _Scaling(fallback: ShoppingScale.unknown);
  }
}

final Set<(String, String)> _catalogTexts = {
  for (final recipe in [...recipeCatalogDe, ...recipeCatalogEn])
    (recipe.slug, recipe.ingredients),
};

ShoppingPart _linePart({
  required String id,
  required List<String> legacyIds,
  required String label,
  required String? amount,
  required PlannedMeal plan,
  required _Scaling scaling,
  bool seasoning = false,
}) {
  // "Hähnchenbrust 150g", "Skyr: 150 g": the amount after the name.
  if (amount == null) {
    if (splitTrailingShoppingAmount(label) case final trailing?) {
      amount = trailing.amount;
      label = _capitalized(trailing.label.replaceFirst(RegExp(r'[,;]$'), ''));
    }
  }
  // "Ein Schuss", "A splash": the capital was the line's, not the word's.
  amount = amount?.replaceAllMapped(
    RegExp(r'\b\p{Lu}\p{Ll}*\b', unicode: true),
    (m) => _lowerAmountWords.contains(m[0]!.toLowerCase())
        ? m[0]!.toLowerCase()
        : m[0]!,
  );
  var parsed = amount == null
      ? null
      : parseShoppingAmount(amount, decimalSeparator: scaling.decimalSeparator);
  // "2 Knoblauchzehen" counts cloves; "2 Tomaten mit Knoblauchzehe" counts
  // tomatoes.
  if (parsed != null &&
      parsed.unit == ShoppingUnit.piece &&
      _cloveNoun.hasMatch(foldShoppingText(label).split(_headEnd).first)) {
    parsed = ShoppingAmount(
      ShoppingUnit.clove,
      parsed.low,
      high: parsed.high,
      approx: parsed.approx,
    );
  }
  final ShoppingUse use;
  if (amount == null) {
    // An amount left in the name is as the recipe writes it.
    final scale = _hasUnreadAmount(label) ? scaling.asWritten : null;
    use = scale == null
        ? _use(plan)
        : _use(plan, scale: scale, batchServings: scaling.batch);
  } else if (scaling.unknown) {
    use = _use(
      plan,
      text: amount,
      scale: ShoppingScale.unknown,
      original: parsed,
    );
  } else if (scaling.factor case final factor?) {
    use = parsed == null
        ? _use(
            plan,
            text: amount,
            scale: scaling.fallback,
            batchServings: scaling.batch,
          )
        : _use(plan, amount: parsed.scaled(factor));
  } else {
    use = parsed == null
        ? _use(plan, text: amount)
        : _use(plan, amount: parsed);
  }
  // An amount that did not parse is still an amount, not a spoon.
  final unit = parsed?.unit ?? (amount == null ? null : ShoppingUnit.piece);
  return ShoppingPart(
    id: id,
    legacyIds: legacyIds,
    label: label,
    key: shoppingIngredientKey(label, unit: unit, seasoning: seasoning),
    uses: [use],
    unit: unit,
  );
}

final _cloveNoun = RegExp(
  r'(?:^|\s)(?:knoblauchzehen?|zehen?|garlic cloves?|cloves? of garlic)\b',
);

/// Where a name's head ends: the rest describes it or names another item.
final _headEnd = RegExp(r'[,;(]|\s(?:mit|with|und|and|oder|or)\s');

/// Written numbers and English unit words that a line's capital turned into
/// a capital ("A splash", "1 Dash"); German nouns keep theirs.
const _lowerAmountWords = {
  "ein", "eine", "einen", "einem", "einer", "a", "an", "one", "two", //
  "three", "four", "five", "six", "seven", "eight", "nine", "ten", //
  "twelve", "half", "dash", "dashes", "splash", "splashes", "drizzle", //
  "drizzles", "drop", "drops", "pinch", "pinches", "handful", "handfuls", //
  "cup", "cups", "bunch", "bunches", "sprig", "sprigs", "clove", "cloves", //
  "slice", "slices", "can", "cans", "jar", "jars", "pack", "packs", //
  "packet", "packets", "bag", "bags", "stalk", "stalks", "stick", "sticks", //
  "head", "heads", "bulb", "bulbs", "bottle", "bottles", "sheet", "sheets", //
  "tablespoon", "tablespoons", "teaspoon", "teaspoons", "piece", "pieces",
};

/// A caption's bullet or emoji before the line ("✅", "🔸", "▪️").
final _bullet = RegExp(r'^[^\p{L}\p{N}~(]+', unicode: true);

/// Digits in a name besides a fat level or flour type: an amount the
/// receipt could not read ("Reis (300 g gekocht)").
bool _hasUnreadAmount(String label) => RegExp(r'\d').hasMatch(
  foldShoppingText(label)
      .replaceAll(RegExp(r'\d+(?:[.,]\d+)?\s*%'), '')
      .replaceAll(RegExp(r'\b(?:type|typ|tipo)\s*\d+'), '')
      .replaceAll(RegExp(r'\b00\s+(?=(?:mehl|flour|farina)\b)'), ''),
);

/// The key of a weighed item, from its stored name so it does not follow
/// the app language. A product without a name is only itself.
ShoppingIngredientKey _weighedKey(ShoppingItem item) {
  final stored = item.storedName ?? item.name;
  final key = item.shoppingKey;
  const product = 'openFoodFacts:';
  if (key != null && key.startsWith(product)) {
    final fallback = PersistedLabels.productName(key.substring(product.length));
    if (stored == fallback || stored.startsWith('$fallback · ')) {
      return ShoppingIngredientKey(id: '#$key', staple: ShoppingStaple.none);
    }
  }
  return shoppingIngredientKey(stored, unit: ShoppingUnit.mass);
}

class _Component {
  const _Component(this.amount, this.label);
  final String? amount;
  final String label;
}

/// A line that lists several ingredients, as its items: "1/2 Zwiebel, 1
/// Knoblauchzehe", "Salz, Pfeffer, Petersilie nach Geschmack". Every item
/// needs its own amount or must be a known ingredient; descriptions ("roh",
/// "ca. 50 g", "optional") stay with the item before. Null when the line is
/// one ingredient or cannot be split safely.
List<_Component>? _components(String text) {
  if (text.contains(':')) return null;
  final hasAmount = splitShoppingAmount(text).amount != null;
  final pieces = _topLevelSplit(text, hasAmount);
  if (pieces.length < 2) return null;
  final components = <_Component>[];
  for (final piece in pieces) {
    final split = splitShoppingAmount(piece);
    // "z. B. Spaghetti", "oder Quinoa": the item before, described.
    if (_alternative.hasMatch(foldShoppingText(piece))) {
      if (components.isEmpty) return null;
      final last = components.removeLast();
      components.add(_Component(last.amount, '${last.label}, $piece'));
    } else if (split.amount != null && !isShoppingModifier(split.label)) {
      components.add(_Component(split.amount, split.label));
    } else if (isShoppingModifier(piece) ||
        parseShoppingAmount(piece) != null) {
      if (components.isEmpty) return null;
      final last = components.removeLast();
      components.add(_Component(last.amount, '${last.label}, $piece'));
    } else if (shoppingIngredientKey(piece).known) {
      components.add(_Component(null, piece));
    } else {
      return null;
    }
  }
  return components.length >= 2 ? components : null;
}

final _alternative = RegExp(
  r'^(?:z\.?\s?b\.?|zb|e\.?\s?g\.?|bspw\.?|beispielsweise|such as|like|wie'
  r'|oder|or|bzw\.?|alternativ\w*|ersatzweise|statt|instead)(?=\s|$)',
);

/// [text] split at commas and semicolons outside parentheses; a line
/// without an amount also at "und", "and", "&" and "sowie".
List<String> _topLevelSplit(String text, bool hasAmount) {
  // "1,5 EL" is one number.
  final separator = hasAmount
      ? RegExp(r'(?<!\d),|,(?!\d)|;')
      : RegExp(
          r'(?<!\d),|,(?!\d)|[;&]|\s(?:und|and|sowie)\s',
          caseSensitive: false,
        );
  final pieces = <String>[];
  var depth = 0, start = 0, scanned = 0;
  for (final match in separator.allMatches(text)) {
    for (; scanned < match.start; scanned++) {
      if (text[scanned] == '(' || text[scanned] == '[') depth++;
      if ((text[scanned] == ')' || text[scanned] == ']') && depth > 0) depth--;
    }
    if (depth > 0) continue;
    pieces.add(text.substring(start, match.start).trim());
    start = match.end;
  }
  pieces.add(text.substring(start).trim());
  return [
    for (final piece in pieces)
      if (piece.isNotEmpty) piece,
  ];
}

/// A merged row's name: the shortest, preferring the app language and an
/// unambiguous word ("Paprikapulver" over "Paprika"), cut at the first comma
/// or parenthesis unless that drops what makes the product ("Kartoffeln,
/// festkochend").
String _mergedLabel(List<ShoppingPart> parts, String? language) {
  final bases = {for (final part in parts) part: _baseLabel(part)};
  // The language of the name as written ("Sesam" is German, "sesame"
  // English), else of the synonym it matched.
  int rank(ShoppingPart part) {
    final languages = shoppingNameLanguages(bases[part]!) ?? part.key.languages;
    return (language != null && languages.contains(language) ? 0 : 2) +
        (part.key.ambiguous ? 1 : 0);
  }

  final best = parts.map(rank).reduce((a, b) => a < b ? a : b);
  final names = <String>{
    for (final part in parts)
      if (rank(part) == best) bases[part]!,
  }.toList();
  names.sort((a, b) {
    final byLength = a.length.compareTo(b.length);
    return byLength != 0
        ? byLength
        : foldShoppingText(a).compareTo(foldShoppingText(b));
  });
  return names.first;
}

String _baseLabel(ShoppingPart part) {
  // Also before an alternative another part may not have ("Cilantro or
  // parsley").
  final base = part.label
      .split(
        RegExp(
          r'(?<!\d),|,(?!\d)|\(|(?<!\d)/(?!\d)|\s(?:oder|or)\s',
          caseSensitive: false,
        ),
      )
      .first
      .replaceFirst(_trailingOptional, '')
      .trim();
  if (base.isEmpty) return part.label;
  // The unit may say what the name then no longer does ("1 Dose" of
  // "Tomaten, stückig" next to "400 g" of it): both must agree.
  final same =
      shoppingIngredientKey(base, unit: part._unit).id == part.key.id &&
      shoppingIngredientKey(base).id == shoppingIngredientKey(part.label).id;
  return _capitalized(
    same ? base : part.label.replaceFirst(_trailingOptional, '').trim(),
  );
}

final _trailingOptional = RegExp(
  r'[\s,]+(?:optional|nach Geschmack|nach Belieben|to taste)\s*$',
  caseSensitive: false,
);

/// Pantry or main list, decided on the week's total.
bool _isPantry(ShoppingStaple staple, List<ShoppingPart> parts) {
  switch (staple) {
    case ShoppingStaple.none || ShoppingStaple.water:
      return false;
    case ShoppingStaple.always:
      return true;
    case ShoppingStaple.small || ShoppingStaple.oil:
      final limit = staple == ShoppingStaple.oil ? 100 : 50;
      var mass = 0.0, volume = 0.0;
      for (final part in parts) {
        for (final use in part.uses) {
          final amount = use.amount ?? use._original;
          if (amount == null) {
            // Unparsed: could be a kilo; a splash is not.
            if (use.text case final text? when !_smallMeasure.hasMatch(text)) {
              return false;
            }
            if (use.text == null && _hasUnreadAmount(part.label)) return false;
            continue;
          }
          switch (amount.unit) {
            case ShoppingUnit.mass:
              mass += amount.high;
            case ShoppingUnit.volume:
              volume += amount.high;
            case ShoppingUnit.tbsp || ShoppingUnit.tsp || ShoppingUnit.pinch:
              break;
            default:
              return false;
          }
        }
      }
      return mass <= limit && volume <= limit;
  }
}

/// "1 Schuss", "ein Spritzer", "a splash": measured like a spoon.
final _smallMeasure = RegExp(
  r'^(?:(?:ca\.?|etwa|about)\s*)?'
  r'(?:\d+(?:[.,]\d+)?|ein(?:e[nmr]?)?|an?|one|two|three|zwei|drei'
  r'|einige[nr]?|ein paar|a few|some|etwas)?'
  r'\s*(?:schuss|spritzer|tropfen|dash(?:es)?|splash(?:es)?|drops?'
  r'|drizzles?)\.?$',
  caseSensitive: false,
);

/// Only a single-letter capital: "ß" would grow into "SS".
String _capitalized(String text) {
  if (text.isEmpty) return text;
  final first = text[0].toUpperCase();
  return first.length == 1 ? first + text.substring(1) : text;
}
