// Matches a described meal against the user's foods and the product
// database, and the editable draft the review step shows.
// Contract: docs/MEAL-DESCRIBE.md.

import 'dart:math' as math;

import '../models/described_meal.dart';
import '../models/favorite_meal.dart';
import '../models/fitness_recipe.dart' show foldRecipeSearchText;
import '../models/logged_meal.dart';
import '../models/meal_analysis_result.dart';
import '../models/meal_component.dart';
import '../models/model_limits.dart';
import 'eatova_http.dart' show ChainDeadline;
import 'open_food_facts_product_service.dart';

/// Where a draft line's numbers come from.
enum DraftItemOrigin { favorite, product, estimate }

/// One food a draft line can use. Values are per 100 g so the line can be
/// re-portioned without asking the source again.
class DraftCandidate {
  const DraftCandidate({
    required this.origin,
    required this.title,
    required this.kcalPer100G,
    this.brand,
    this.proteinPer100G,
    this.carbsPer100G,
    this.fatPer100G,
    this.servingGrams,
    this.barcode,
  });

  final DraftItemOrigin origin;

  /// Products and favorites carry their diary name, which for products
  /// already includes the brand ("Nutella · Ferrero").
  final String title;
  final String? brand;
  final double kcalPer100G;

  /// Null means unknown, not 0 g.
  final double? proteinPer100G;
  final double? carbsPer100G;
  final double? fatPer100G;

  /// One serving or piece in grams, when the source states it.
  final int? servingGrams;

  /// Product barcode, for products and product favorites only.
  final String? barcode;
}

/// One line of the draft: the described food, the chosen candidate and the
/// alternatives the user can switch to.
class DraftFoodItem {
  const DraftFoodItem({
    required this.described,
    required this.selected,
    required this.candidates,
    required this.grams,
  });

  final DescribedFoodItem described;
  final DraftCandidate selected;

  /// Best first, at most four, always including the model's estimate, so a
  /// line never ends up without numbers.
  final List<DraftCandidate> candidates;

  final int grams;

  bool get isEstimate => selected.origin == DraftItemOrigin.estimate;

  int get caloriesKcal =>
      clampMealCaloriesKcal(selected.kcalPer100G * grams / 100);

  /// Macros in grams for [grams]; null means unknown, not 0 g.
  double? get proteinG => _forGrams(selected.proteinPer100G);
  double? get carbsG => _forGrams(selected.carbsPer100G);
  double? get fatG => _forGrams(selected.fatPer100G);

  double? _forGrams(double? per100G) =>
      per100G == null ? null : clampMealMacroG(per100G * grams / 100);

  /// The same line with another portion.
  DraftFoodItem withGrams(int grams) => DraftFoodItem(
    described: described,
    selected: selected,
    candidates: candidates,
    grams: clampPortionGrams(grams, fallback: this.grams),
  );

  /// The same line with another candidate. A stated countable amount ("1
  /// Scheibe") follows the new candidate's serving size when it has one.
  DraftFoodItem withCandidate(DraftCandidate candidate) => DraftFoodItem(
    described: described,
    selected: candidate,
    candidates: candidates,
    grams: portionGramsFor(described, candidate) ?? grams,
  );

  /// The diary component; the brand joins the name unless already in it.
  MealComponent toComponent() {
    final brand = selected.brand?.trim();
    final title = selected.title.trim();
    final named =
        brand == null ||
            brand.isEmpty ||
            title.toLowerCase().contains(brand.toLowerCase())
        ? title
        : '$title ($brand)';
    return MealComponent(
      name: clampMealName(named, fallback: described.name),
      grams: grams,
      caloriesKcal: caloriesKcal,
      kcalPer100G: selected.kcalPer100G,
      proteinG: proteinG,
      carbsG: carbsG,
      fatG: fatG,
    );
  }
}

/// Grams for [item] when it uses [candidate]: a stated countable amount
/// times the candidate's serving size, else null (keep the current grams).
/// The estimate's serving is the model's own reading of the amount, so it
/// returns the model's grams.
int? portionGramsFor(DescribedFoodItem item, DraftCandidate candidate) {
  if (item.gramsSource != DescribedGramsSource.stated) return null;
  final count = countableAmount(item.amountText);
  if (count == null) return null;
  if (candidate.origin == DraftItemOrigin.estimate) return item.grams;
  final serving = candidate.servingGrams;
  if (serving == null) return null;
  return clampPortionGrams(serving * count);
}

/// The count of a countable amount ("1 Scheibe", "zwei Stück", "½ Portion"),
/// or null for weights and volumes ("200 g", "300 ml").
double? countableAmount(String? amountText) {
  final text = amountText?.trim().toLowerCase();
  if (text == null || text.isEmpty) return null;
  final match = _countable.firstMatch(text);
  if (match == null) return null;
  final number = match.group(1)!.replaceAll(',', '.');
  return _countWords[number] ?? double.tryParse(number);
}

final RegExp _countable = RegExp(
  r'^(\d+(?:[.,]\d+)?|½|ein|eine|einen|einem|einer|zwei|drei|vier|fünf|'
  r'halbe?|a|an|one|two|three|four|five|half)\s+'
  r'(scheiben?|stücke?|stück|portionen?|gläser|glas|becher|riegel|tassen?|'
  r'eier|ei|brötchen|äpfel|apfel|bananen?|dosen?|packungen?|'
  r'slices?|pieces?|servings?|portions?|glass(?:es)?|cups?|bars?|eggs?|'
  r'rolls?|apples?|bananas?|cans?|packs?)(?=[\s.,;()]|$)',
  unicode: true,
);

const Map<String, double> _countWords = {
  '½': .5,
  'halb': .5,
  'halbe': .5,
  'half': .5,
  'ein': 1,
  'eine': 1,
  'einen': 1,
  'einem': 1,
  'einer': 1,
  'a': 1,
  'an': 1,
  'one': 1,
  'zwei': 2,
  'two': 2,
  'drei': 3,
  'three': 3,
  'vier': 4,
  'four': 4,
  'fünf': 5,
  'five': 5,
};

/// The model's estimate for [item] as a candidate; always has numbers.
///
/// The model's calories for its grams are authoritative, as everywhere in
/// the app: the density is derived from them and only replaced by the
/// stated one when the derivation is physically impossible. Macros per
/// 100 g come from the item's grams; an impossible one is unknown.
DraftCandidate estimateCandidateFor(DescribedFoodItem item) {
  final grams = item.grams;
  double? per100(double? forGrams) {
    if (forGrams == null || grams <= 0) return null;
    final value = forGrams * 100 / grams;
    return value.isFinite && value <= PlausibilityLimits.macroPer100GMax
        ? value
        : null;
  }

  return DraftCandidate(
    origin: DraftItemOrigin.estimate,
    title: item.name,
    kcalPer100G: _estimateDensity(item),
    proteinPer100G: per100(item.proteinG),
    carbsPer100G: per100(item.carbsG),
    fatPer100G: per100(item.fatG),
  );
}

double _estimateDensity(DescribedFoodItem item) {
  final calories = item.caloriesKcal;
  final stated = item.kcalPer100G;
  if (calories != null && calories > 0 && item.grams > 0) {
    final derived = calories * 100 / item.grams;
    if (isPlausibleKcalPer100G(derived)) return derived;
    return stated != null && stated > 0 ? stated : clampKcalPer100G(derived);
  }
  return stated != null && isPlausibleKcalPer100G(stated) ? stated : 0;
}

/// The editable result of a match; immutable, every edit returns a copy.
class MealDescriptionDraft {
  const MealDescriptionDraft({required this.meal, required this.items});

  final DescribedMeal meal;
  final List<DraftFoodItem> items;

  MealSlot? get slotHint => meal.slotHint;

  int get caloriesKcal =>
      items.fold<int>(0, (sum, item) => sum + item.caloriesKcal);

  /// Whether [toResult] passes the log guards (`caloriesKcal > 0`). A draft
  /// of only zero-energy lines (water) is not loggable, like a scan of it.
  bool get isLoggable => items.isNotEmpty && caloriesKcal > 0;

  MealDescriptionDraft replaceItem(int index, DraftFoodItem item) =>
      MealDescriptionDraft(
        meal: meal,
        items: [
          for (var i = 0; i < items.length; i++) i == index ? item : items[i],
        ],
      );

  MealDescriptionDraft removeItem(int index) => MealDescriptionDraft(
    meal: meal,
    items: [
      for (var i = 0; i < items.length; i++)
        if (i != index) items[i],
    ],
  );

  /// The loggable result: one component per line, calories and grams summed
  /// from them, macros only when every line knows them (else unknown, see
  /// [MealAnalysisResult.adjustedToItems]).
  ///
  /// * Source "OpenFoodFacts" and confidence "database" only when every line
  ///   is product-backed (a product, or a favorite with a barcode); otherwise
  ///   "AI estimate" and the model's own confidence. Never "Photo AI": there
  ///   is no photo.
  /// * The portion note is the components note: the user confirmed the
  ///   lines and the totals are their sum, which stays true whichever
  ///   candidates were picked. The model's explanation would describe its
  ///   estimate, not the chosen products.
  /// * Not marked adjusted: a fresh description is not a change to an
  ///   earlier result, so the portion line reads "N items · X g".
  MealAnalysisResult toResult() {
    final summed = meal.base.adjustedToItems([
      for (final item in items) item.toComponent(),
    ]);
    final productBacked =
        items.isNotEmpty && items.every((item) => _isProductBacked(item));
    return MealAnalysisResult(
      mealName: summed.mealName,
      caloriesKcal: summed.caloriesKcal,
      estimatedGrams: summed.estimatedGrams,
      kcalPer100G: summed.kcalPer100G,
      protein: summed.protein,
      carbs: summed.carbs,
      fat: summed.fat,
      confidence: productBacked
          ? MealResultConfidence.database.code
          : summed.confidence,
      portionNotes: summed.portionNotes,
      items: summed.items,
      sourceLabel: productBacked
          ? MealResultSource.openFoodFacts.code
          : MealResultSource.aiEstimate.code,
    );
  }

  static bool _isProductBacked(DraftFoodItem item) =>
      switch (item.selected.origin) {
        DraftItemOrigin.product => true,
        DraftItemOrigin.favorite => item.selected.barcode != null,
        DraftItemOrigin.estimate => false,
      };
}

/// Builds the draft for a described meal.
abstract class MealDescriptionMatcher {
  Future<MealDescriptionDraft> match(DescribedMeal meal);
}

/// Production matcher: favorites and recents first, then
/// [ProductLookupService.searchProducts], all lines in parallel under one
/// time budget. A search that fails or runs out of time leaves the line on
/// its estimate; the match itself never fails because of a search.
///
/// Per line, at most [maxCandidates] candidates, best first: candidates that
/// may be auto-selected (a loggable kcal/100 g within [maxDensityRatio] of
/// the estimate), then the estimate, then the rest as alternatives. Among
/// the selectable ones a named brand ranks first, then favorites, then the
/// title closest to the query, then the source's own order.
class ProductMealDescriptionMatcher implements MealDescriptionMatcher {
  const ProductMealDescriptionMatcher({
    required this.products,
    required this.favorites,
    this.budget = defaultBudget,
  });

  static const Duration defaultBudget = Duration(seconds: 8);
  static const int maxCandidates = 4;

  /// How far a product's kcal/100 g may sit from the estimate (either way)
  /// and still be picked without the user. Within [_densitySlack] kcal/100 g
  /// counts as close whatever the ratio (water, tea, light drinks).
  static const double maxDensityRatio = 2.5;
  static const double _densitySlack = 20;

  /// Hits checked for the named brand before a second, branded query.
  static const int _topHits = 5;

  final ProductLookupService products;

  /// The add sheet's favorites and recents (pinned and auto), read at match
  /// time so the newest count.
  final List<FavoriteMeal> Function() favorites;

  /// Ceiling over every search of one match, all lines together.
  final Duration budget;

  @override
  Future<MealDescriptionDraft> match(DescribedMeal meal) async {
    final saved = _readFavorites();
    final deadline = ChainDeadline(budget, operation: 'describe.match');
    try {
      final lines = await Future.wait([
        for (final item in meal.items) _matchLine(item, saved, deadline),
      ]);
      return MealDescriptionDraft(meal: meal, items: lines);
    } finally {
      deadline.dispose();
    }
  }

  List<FavoriteMeal> _readFavorites() {
    try {
      return favorites();
    } on Object {
      return const <FavoriteMeal>[];
    }
  }

  /// Never throws: whatever goes wrong, the line keeps its estimate.
  Future<DraftFoodItem> _matchLine(
    DescribedFoodItem item,
    List<FavoriteMeal> saved,
    ChainDeadline deadline,
  ) async {
    final estimate = estimateCandidateFor(item);
    try {
      final hits = await _search(item, deadline);
      return _buildLine(item, estimate, saved, hits);
    } on Object {
      return DraftFoodItem(
        described: item,
        selected: estimate,
        candidates: List<DraftCandidate>.unmodifiable([estimate]),
        grams: item.grams,
      );
    }
  }

  /// The hits for [item]; empty when the search failed or ran out of time.
  /// One more query with the brand in front when a brand was named and no
  /// top hit carries it.
  Future<List<ProductSearchResult>> _search(
    DescribedFoodItem item,
    ChainDeadline deadline,
  ) async {
    final first = await _searchOnce(item.searchQuery, deadline);
    if (first == null) return const <ProductSearchResult>[];
    final brand = item.brand;
    if (brand == null ||
        first
            .take(_topHits)
            .any((hit) => _brandMatches(brand, hit.result.brand, hit.title))) {
      return first;
    }
    final branded = await _searchOnce('$brand ${item.searchQuery}', deadline);
    return [...first, ...?branded];
  }

  Future<List<ProductSearchResult>?> _searchOnce(
    String query,
    ChainDeadline deadline,
  ) async {
    if (deadline.isExpired) return null;
    try {
      return await deadline.guard(
        Future<List<ProductSearchResult>>.sync(
          () => products.searchProducts(query),
        ),
      );
    } on Object {
      return null;
    }
  }

  DraftFoodItem _buildLine(
    DescribedFoodItem item,
    DraftCandidate estimate,
    List<FavoriteMeal> saved,
    List<ProductSearchResult> hits,
  ) {
    final query = _mainTokens(item.searchQuery);
    final named = _mainTokens(item.name);
    final ranked = <_Ranked>[];
    final barcodes = <String>{};

    final recentFirst = [...saved]
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    for (var i = 0; i < recentFirst.length; i++) {
      final favorite = recentFirst[i];
      final result = favorite.result;
      if (!_favoriteMatches(result, query) &&
          !_favoriteMatches(result, named)) {
        continue;
      }
      final candidate = _favoriteCandidate(result);
      if (candidate == null) continue;
      final barcode = candidate.barcode;
      if (barcode != null) barcodes.add(barcode);
      ranked.add(
        _rank(item, candidate, estimate, query, order: i, usual: result),
      );
    }

    final seen = <String>{};
    for (var i = 0; i < hits.length; i++) {
      final hit = hits[i];
      final key = hit.code.isNotEmpty ? hit.code : '#${_fold(hit.title)}';
      if (barcodes.contains(hit.code) || !seen.add(key)) continue;
      if (!_covers(query, _haystack(_tokens(hit.title)))) continue;
      final candidate = _productCandidate(hit);
      if (candidate == null) continue;
      ranked.add(_rank(item, candidate, estimate, query, order: i));
    }

    ranked.sort(_Ranked.compare);
    final selectable = ranked.where((r) => r.selectable);
    final alternatives = ranked.where((r) => !r.selectable);
    final best = selectable.isEmpty ? null : selectable.first;
    final candidates = List<DraftCandidate>.unmodifiable(
      [
        ...selectable.take(maxCandidates - 1).map((r) => r.candidate),
        estimate,
        ...alternatives.map((r) => r.candidate),
      ].take(maxCandidates),
    );
    final selected = candidates.first;
    return DraftFoodItem(
      described: item,
      selected: selected,
      candidates: candidates,
      grams: _initialGrams(item, selected, best?.usualGrams),
    );
  }

  _Ranked _rank(
    DescribedFoodItem item,
    DraftCandidate candidate,
    DraftCandidate estimate,
    Set<String> query, {
    required int order,
    MealAnalysisResult? usual,
  }) {
    final brand = item.brand;
    final usualGrams = usual?.estimatedGrams;
    return _Ranked(
      candidate: candidate,
      selectable:
          isLoggableKcalPer100G(candidate.kcalPer100G) &&
          _closeDensity(candidate.kcalPer100G, estimate.kcalPer100G),
      brandMatch:
          brand != null &&
          _brandMatches(brand, candidate.brand, candidate.title),
      favorite: candidate.origin == DraftItemOrigin.favorite,
      extras: _extraTokens(query, candidate.title, candidate.brand),
      order: order,
      usualGrams: usualGrams != null && isPlausiblePortionGrams(usualGrams)
          ? usualGrams
          : null,
    );
  }

  /// A stated countable amount follows the serving size; an estimated amount
  /// with a favorite takes its usual grams; anything else keeps the model's.
  static int _initialGrams(
    DescribedFoodItem item,
    DraftCandidate selected,
    int? usualGrams,
  ) {
    final portion = portionGramsFor(item, selected);
    if (portion != null) return portion;
    if (selected.origin == DraftItemOrigin.favorite &&
        item.gramsSource == DescribedGramsSource.estimated &&
        usualGrams != null) {
      return usualGrams;
    }
    return item.grams;
  }

  static bool _closeDensity(double candidate, double estimate) {
    if ((candidate - estimate).abs() <= _densitySlack) return true;
    final low = math.min(candidate, estimate);
    final high = math.max(candidate, estimate);
    return low > 0 && high / low <= maxDensityRatio;
  }
}

class _Ranked {
  const _Ranked({
    required this.candidate,
    required this.selectable,
    required this.brandMatch,
    required this.favorite,
    required this.extras,
    required this.order,
    this.usualGrams,
  });

  final DraftCandidate candidate;
  final bool selectable;
  final bool brandMatch;
  final bool favorite;

  /// Title words the query does not explain; fewer is closer.
  final int extras;

  /// Recency for favorites, the source's ranking for products.
  final int order;

  /// A favorite's usual portion.
  final int? usualGrams;

  static int compare(_Ranked a, _Ranked b) {
    if (a.selectable != b.selectable) return a.selectable ? -1 : 1;
    if (a.brandMatch != b.brandMatch) return a.brandMatch ? -1 : 1;
    if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
    final extras = a.extras.compareTo(b.extras);
    return extras != 0 ? extras : a.order.compareTo(b.order);
  }
}

// ---------------------------------------------------------------------------
// Candidates from favorites and products
// ---------------------------------------------------------------------------

/// A favorite or recent as a candidate, or null without a usable density.
DraftCandidate? _favoriteCandidate(MealAnalysisResult result) {
  final density =
      result.effectiveKcalPer100G ??
      (result.explicitZeroKcal && result.kcalPer100G == 0 ? 0.0 : null);
  if (density == null) return null;
  final grams = result.estimatedGrams;
  return DraftCandidate(
    origin: DraftItemOrigin.favorite,
    title: result.mealName,
    brand: result.brand,
    kcalPer100G: density,
    proteinPer100G: _per100FromText(result.protein, grams),
    carbsPer100G: _per100FromText(result.carbs, grams),
    fatPer100G: _per100FromText(result.fat, grams),
    servingGrams: _servingGrams(result),
    barcode: _nonEmpty(result.barcode),
  );
}

/// A search hit as a candidate, or null when its energy is unknown. A
/// measured 0 (water) stays as an alternative; it is never auto-selected.
DraftCandidate? _productCandidate(ProductSearchResult hit) {
  final result = hit.result;
  final density = hit.kcalPer100G;
  if (!isLoggableKcalPer100G(density) &&
      !(density == 0 && result.explicitZeroKcal)) {
    return null;
  }
  final per100 = hit.ingredientNutritionPer100g;
  final grams = result.estimatedGrams;
  return DraftCandidate(
    origin: DraftItemOrigin.product,
    title: hit.title,
    brand: result.brand,
    kcalPer100G: density,
    proteinPer100G: per100?.proteinG ?? _per100FromText(result.protein, grams),
    carbsPer100G: per100?.carbsG ?? _per100FromText(result.carbs, grams),
    fatPer100G: per100?.fatG ?? _per100FromText(result.fat, grams),
    servingGrams: _servingGrams(result),
    barcode: _nonEmpty(hit.code),
  );
}

/// One piece or serving of an Open Food Facts product, from the serving its
/// note records. `fromOpenFoodFacts` sets the portion to that serving, or to
/// the 100 g base without one; a serving text with a count ("2 Scheiben
/// (50 g)") is divided by it. A bare 100 g is the reference amount, not a
/// piece, so it gives none.
int? _servingGrams(MealAnalysisResult result) {
  final serving = MealResultOffNote.resolve(result.portionNotes)?.serving;
  final grams = result.estimatedGrams;
  if (serving == null || !isPlausiblePortionGrams(grams)) return null;
  final count = countableAmount(serving);
  if (count != null && count > 0) return clampPortionGrams(grams / count);
  return grams == 100 ? null : grams;
}

/// A stored macro text ("12,5 g", "-") per 100 g of [grams], or null.
double? _per100FromText(String text, int grams) {
  if (grams <= 0) return null;
  final match = RegExp(r'\d+(?:[.,]\d+)?').firstMatch(text);
  if (match == null) return null;
  final value = double.tryParse(match.group(0)!.replaceAll(',', '.'));
  if (value == null) return null;
  final per100 = value * 100 / grams;
  return per100.isFinite && per100 <= PlausibilityLimits.macroPer100GMax
      ? per100
      : null;
}

String? _nonEmpty(String? value) =>
    value == null || value.trim().isEmpty ? null : value;

// ---------------------------------------------------------------------------
// Text matching
// ---------------------------------------------------------------------------

String _fold(String text) => foldRecipeSearchText(text);

final RegExp _separators = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final RegExp _digitsOnly = RegExp(r'^\d+$');

/// Words that say nothing about the food. Double-quoted: matching data, not
/// UI text.
final Set<String> _stopWords =
    ("mit und von vom der die das den dem des ein eine einer einem einen "
            "zum zur im in auf with and of the a an on")
        .split(' ')
        .toSet();

/// Endings stripped once so "Bananen" finds "Banane".
const List<String> _inflections = ["en", "er", "es", "e", "n", "s"];

List<String> _tokens(String text) =>
    _fold(text).split(_separators).where((token) => token.isNotEmpty).toList();

/// The words that identify a food: no stop words, amounts or [brand] words.
Set<String> _mainTokens(String text, {String? brand}) {
  final brandTokens = brand == null ? const <String>{} : _tokens(brand).toSet();
  return {
    for (final token in _tokens(text))
      if (token.length >= 2 &&
          !_stopWords.contains(token) &&
          !_digitsOnly.hasMatch(token) &&
          !brandTokens.contains(token))
        token,
  };
}

/// [tokens] as words for whole-word matches, then as one run so "Hafer
/// Drink" also holds "haferdrink".
String _haystack(Iterable<String> tokens) =>
    '${tokens.join(' ')} ${tokens.join()}';

/// Whether every token of [query] appears in [haystack]. Short tokens ("ei")
/// must match a whole word, else they sit inside half the catalog.
bool _covers(Set<String> query, String haystack) =>
    query.isNotEmpty && query.every((token) => _coveredBy(token, haystack));

bool _coveredBy(String token, String haystack) {
  if (token.length < 4) {
    return RegExp(
      '(^| )${RegExp.escape(token)}(e|n|en|er)?( |\$)',
    ).hasMatch(haystack);
  }
  if (haystack.contains(token)) return true;
  for (final ending in _inflections) {
    if (token.length - ending.length >= 4 &&
        token.endsWith(ending) &&
        haystack.contains(token.substring(0, token.length - ending.length))) {
      return true;
    }
  }
  return false;
}

/// Products and product favorites cover the query; a scan, recipe or manual
/// favorite must name the same food both ways ("Toast Hawaii" is not
/// "Toast").
bool _favoriteMatches(MealAnalysisResult favorite, Set<String> query) {
  if (query.isEmpty) return false;
  final own = _mainTokens(favorite.mealName, brand: favorite.brand);
  if (!_covers(query, _haystack(own))) return false;
  final isProduct = _nonEmpty(favorite.barcode) != null;
  return isProduct || _covers(own, _haystack(query));
}

bool _brandMatches(String brand, String? candidateBrand, String title) =>
    _covers(
      _mainTokens(brand),
      _haystack(_tokens('${candidateBrand ?? ''} $title')),
    );

/// Title words outside the query, the candidate's brand and stop words.
int _extraTokens(Set<String> query, String title, String? brand) =>
    _mainTokens(title, brand: brand)
        .where(
          (token) => !query.any((q) => q.contains(token) || token.contains(q)),
        )
        .length;
