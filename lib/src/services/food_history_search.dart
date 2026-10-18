import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/favorite_meal.dart';
import '../models/fitness_recipe.dart';
import '../models/logged_meal.dart';
import '../models/meal_analysis_result.dart';
import '../models/shopping_ingredient_key.dart' show foldShoppingText;

// The add sheet's "From you" search (E3, 2026-10-18): favorites, recents,
// the diary rows the store holds and own recipes, deduplicated and ranked.
// Pure and synchronous: no I/O, no network, works offline.

/// Most hits one search returns.
const int foodHistoryMaxHits = 30;

/// One own food: the newest entry of every entry with the same name, brand
/// and energy density.
class FoodHistoryHit {
  const FoodHistoryHit({
    required this.key,
    required this.result,
    required this.uses,
    this.lastUsed,
  });

  /// Dedupe key: folded name, folded brand and kcal per 100 g.
  final String key;

  /// The newest entry's result with its portion; the source's own instance,
  /// so rows keep a typed portion across rebuilds.
  final MealAnalysisResult result;

  /// Diary rows in this group, within what the store holds.
  final int uses;

  /// When the newest entry was logged or used; null for a recipe that has
  /// never been logged.
  final DateTime? lastUsed;
}

/// Searchable snapshot of the user's own foods. Build once per change of
/// the source lists, then [search] per query.
///
/// Cost: one fold per distinct name or brand string while building, none
/// per search. Recipes are converted lazily, only when their title matches.
class FoodHistoryIndex {
  FoodHistoryIndex({
    Iterable<FavoriteMeal> favorites = const <FavoriteMeal>[],
    Iterable<LoggedMeal> diary = const <LoggedMeal>[],
    Iterable<FitnessRecipe> recipes = const <FitnessRecipe>[],
    MealAnalysisResult? Function(FitnessRecipe recipe)? recipeResult,
  }) : _recipeResult = recipeResult ?? _defaultRecipeResult {
    for (final favorite in favorites) {
      _add(
        favorite.result,
        favorite.addedAt,
        favorite.pinned ? _rankFavorite : _rankRecent,
        countsAsUse: false,
      );
    }
    for (final meal in diary) {
      _add(meal.result, meal.loggedAt, _rankDiary, countsAsUse: true);
    }
    for (final recipe in recipes) {
      final title = recipe.title.trim();
      if (title.isEmpty) continue;
      _recipes.add(_PendingRecipe(recipe, _fold(title)));
    }
  }

  static const int _rankFavorite = 0;
  static const int _rankRecent = 1;
  static const int _rankDiary = 2;
  static const int _rankRecipe = 3;

  final MealAnalysisResult? Function(FitnessRecipe recipe) _recipeResult;
  final Map<String, _Folded> _folds = <String, _Folded>{};
  final Map<String, _Group> _groups = <String, _Group>{};
  final List<_PendingRecipe> _recipes = <_PendingRecipe>[];

  /// Recipes resolved so far by key: two identical recipes show once.
  final Map<String, _Group> _recipeGroups = <String, _Group>{};

  int _foldCount = 0;

  /// Strings folded so far: the build/search budget the tests pin.
  @visibleForTesting
  int get foldCount => _foldCount;

  /// Groups after deduplication, recipes not included.
  int get groupCount => _groups.length;

  static MealAnalysisResult? _defaultRecipeResult(FitnessRecipe recipe) {
    try {
      return recipe.toMealResultForServings(1);
    } on FormatException {
      return null;
    }
  }

  _Folded _fold(String text) {
    final known = _folds[text];
    if (known != null) return known;
    _foldCount++;
    return _folds[text] = _Folded.of(text);
  }

  /// Rows that could not be logged anyway stay out: the legacy 0-kcal
  /// sentinel (`_handleAdd` blocks it) and nameless rows.
  static bool _loggable(MealAnalysisResult result) =>
      result.mealName.trim().isNotEmpty &&
      (result.caloriesKcal > 0 || result.explicitZeroKcal);

  _Group _groupFor(MealAnalysisResult result) {
    final name = _fold(result.mealName.trim());
    final brand = _fold(result.brand?.trim() ?? '');
    final key = '${name.ae}|${brand.ae}|${_densityKey(result)}';
    return _groups[key] ??= _Group(key, _Fields(name, brand));
  }

  void _add(
    MealAnalysisResult result,
    DateTime usedAt,
    int rank, {
    required bool countsAsUse,
  }) {
    if (!_loggable(result)) return;
    final group = _groupFor(result);
    if (countsAsUse) group.uses++;
    group.offer(result, usedAt, rank);
  }

  /// Hits for [query], best first: whole-name prefix, then word prefix, then
  /// any substring; within a tier more uses first, then the most recent.
  /// Blank queries return nothing.
  List<FoodHistoryHit> search(String query, {int limit = foodHistoryMaxHits}) {
    final q = _Query.of(query);
    if (q == null || limit <= 0) return const <FoodHistoryHit>[];
    _foldCount++;
    final matches = <(int, _Group)>[];
    for (final group in _groups.values) {
      final tier = group.fields.tier(q);
      if (tier != null) matches.add((tier, group));
    }
    for (final pending in _recipes) {
      // Cheap reject on the title before the conversion runs.
      if (!pending.title.containsAll(q)) continue;
      final group = pending.resolve(this);
      if (group == null) continue;
      final tier = group.fields.tier(q);
      if (tier != null) matches.add((tier, group));
    }
    matches.sort((a, b) {
      final byTier = a.$1.compareTo(b.$1);
      if (byTier != 0) return byTier;
      final byUses = b.$2.uses.compareTo(a.$2.uses);
      if (byUses != 0) return byUses;
      final at = a.$2.lastUsed;
      final bt = b.$2.lastUsed;
      if (at != bt) {
        if (at == null) return 1;
        if (bt == null) return -1;
        final byTime = bt.compareTo(at);
        if (byTime != 0) return byTime;
      }
      return a.$2.key.compareTo(b.$2.key);
    });
    return <FoodHistoryHit>[
      for (final (_, group) in matches.take(limit))
        FoodHistoryHit(
          key: group.key,
          result: group.result!,
          uses: group.uses,
          lastUsed: group.lastUsed,
        ),
    ];
  }
}

/// kcal per 100 g, rounded: the same meal keeps its density across
/// portions (`adjustedToGrams` carries it), so 250 g and 300 g of it merge.
/// Without a usable density the portion's own kcal decide.
String _densityKey(MealAnalysisResult result) {
  final density = result.effectiveKcalPer100G;
  if (density != null) return 'd${density.round()}';
  if (result.estimatedGrams > 0 && result.caloriesKcal > 0) {
    return 'd${(result.caloriesKcal * 100 / result.estimatedGrams).round()}';
  }
  return 'k${result.caloriesKcal}';
}

class _Group {
  _Group(this.key, this.fields);

  final String key;
  final _Fields fields;
  MealAnalysisResult? result;
  DateTime? lastUsed;
  int _rank = 99;
  int uses = 0;

  /// The newest entry wins; at the same moment the lower rank (favorite
  /// before recent before diary) wins, so a kept product photo survives.
  void offer(MealAnalysisResult candidate, DateTime? usedAt, int rank) {
    final current = lastUsed;
    final bool newer;
    if (result == null) {
      newer = true;
    } else if (usedAt == null || current == null) {
      newer = current == null && (usedAt != null || rank < _rank);
    } else {
      newer =
          usedAt.isAfter(current) ||
          (usedAt.isAtSameMomentAs(current) && rank < _rank);
    }
    if (!newer) return;
    result = candidate;
    lastUsed = usedAt;
    _rank = rank;
  }
}

class _PendingRecipe {
  _PendingRecipe(this.recipe, this.title);

  final FitnessRecipe recipe;
  final _Folded title;
  bool _resolved = false;
  _Group? _group;

  /// The recipe as a standalone group, or null when it cannot be logged or
  /// an own entry or recipe of the same name and density stands for it.
  _Group? resolve(FoodHistoryIndex index) {
    if (_resolved) return _group;
    _resolved = true;
    final result = index._recipeResult(recipe);
    if (result == null || !FoodHistoryIndex._loggable(result)) return null;
    final name = index._fold(result.mealName.trim());
    final brand = index._fold(result.brand?.trim() ?? '');
    final key = '${name.ae}|${brand.ae}|${_densityKey(result)}';
    if (index._groups.containsKey(key) ||
        index._recipeGroups.containsKey(key)) {
      return null;
    }
    return _group = index._recipeGroups[key] = _Group(key, _Fields(name, brand))
      ..offer(result, null, FoodHistoryIndex._rankRecipe);
  }
}

/// A text in two folds: `ae` spells umlauts out (ä -> ae, like the recipe
/// and shopping search), `loose` drops their dots (ä -> a). A term matches
/// when either fold matches, so "kaese", "käse" and "kase" all find "Käse".
class _Folded {
  _Folded(this.ae, this.loose)
    : aeWords = _words(ae),
      looseWords = _words(loose);

  factory _Folded.of(String text) =>
      _Folded(foldShoppingText(text), foldShoppingText(_dropUmlautDots(text)));

  final String ae;
  final String loose;
  final List<String> aeWords;
  final List<String> looseWords;

  static final RegExp _separator = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

  static List<String> _words(String text) =>
      text.split(_separator).where((w) => w.isNotEmpty).toList(growable: false);

  bool containsAll(_Query q) {
    for (var i = 0; i < q.aeTerms.length; i++) {
      if (!ae.contains(q.aeTerms[i]) && !loose.contains(q.looseTerms[i])) {
        return false;
      }
    }
    return true;
  }
}

class _Fields {
  _Fields(this.name, this.brand);

  final _Folded name;
  final _Folded brand;

  /// 0 = the name starts with the query, 1 = every term starts a word of
  /// name or brand, 2 = every term occurs in name or brand; null = no match.
  int? tier(_Query q) {
    var wordPrefixes = true;
    for (var i = 0; i < q.aeTerms.length; i++) {
      final ae = q.aeTerms[i];
      final loose = q.looseTerms[i];
      if (!name.ae.contains(ae) &&
          !name.loose.contains(loose) &&
          !brand.ae.contains(ae) &&
          !brand.loose.contains(loose)) {
        return null;
      }
      if (wordPrefixes &&
          !_startsWord(name, ae, loose) &&
          !_startsWord(brand, ae, loose)) {
        wordPrefixes = false;
      }
    }
    if (name.ae.startsWith(q.ae) || name.loose.startsWith(q.loose)) return 0;
    return wordPrefixes ? 1 : 2;
  }

  static bool _startsWord(_Folded field, String ae, String loose) =>
      field.aeWords.any((w) => w.startsWith(ae)) ||
      field.looseWords.any((w) => w.startsWith(loose));
}

class _Query {
  _Query(this.ae, this.loose, this.aeTerms, this.looseTerms);

  final String ae;
  final String loose;
  final List<String> aeTerms;
  final List<String> looseTerms;

  static final RegExp _space = RegExp(r'\s+');

  static _Query? of(String raw) {
    final text = raw.trim().replaceAll(_space, ' ');
    if (text.isEmpty) return null;
    final ae = foldShoppingText(text);
    final loose = foldShoppingText(_dropUmlautDots(text));
    final aeTerms = ae.split(' ').where((t) => t.isNotEmpty).toList();
    final looseTerms = loose.split(' ').where((t) => t.isNotEmpty).toList();
    // Folding never adds or removes a space, so both lists line up.
    if (aeTerms.isEmpty || aeTerms.length != looseTerms.length) return null;
    return _Query(ae, loose, aeTerms, looseTerms);
  }
}

/// "Käse" -> "Kase"; precomposed and decomposed umlauts alike.
String _dropUmlautDots(String text) => text
    .replaceAll('̈', '')
    .replaceAll('ä', 'a')
    .replaceAll('ö', 'o')
    .replaceAll('ü', 'u')
    .replaceAll('Ä', 'A')
    .replaceAll('Ö', 'O')
    .replaceAll('Ü', 'U');
