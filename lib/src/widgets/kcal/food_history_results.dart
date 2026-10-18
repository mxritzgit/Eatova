import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/favorite_meal.dart';
import '../../models/fitness_recipe.dart';
import '../../models/logged_meal.dart';
import '../../models/meal_analysis_result.dart';
import '../../services/food_history_search.dart';
import '../../theme/app_tokens.dart';
import 'saved_meal_presentation.dart';

/// Hits the "From you" section shows before "Show all": the product hits
/// below stay in reach with the keyboard up.
const int kFoodHistoryVisibleHits = 3;

/// Recents the add sheet shows before "Show all": as many as it showed in
/// total while the store kept only five.
const int kFoodHistoryVisibleRecents = 5;

/// The sheet's item key for [hit] (expanded row, just-added check).
String foodHistoryItemKey(FoodHistoryHit hit) => 'history:${hit.key}';

/// "From you" (E3): the user's own foods matching the search field, above
/// the product database. Local and synchronous, so it answers offline and
/// long before the network search; a short debounce coalesces fast typing.
///
/// Rebuilds only itself per query, never the sheet (perf audit B3). Rows
/// are built by the sheet ([itemBuilder]), which owns the add path.
class FoodHistoryResults extends StatefulWidget {
  const FoodHistoryResults({
    super.key,
    required this.query,
    required this.favorites,
    required this.diary,
    required this.recipes,
    required this.labelBuilder,
    required this.itemBuilder,
    this.expandedKey,
    this.gap = 20,
  });

  /// The search field's value; read on mount, then debounced.
  final ValueListenable<TextEditingValue> query;
  final List<FavoriteMeal> favorites;

  /// The diary rows the store holds (boot window plus loaded days).
  final List<LoggedMeal> diary;
  final List<FitnessRecipe> recipes;
  final Widget Function(String text) labelBuilder;
  final Widget Function(FoodHistoryHit hit, int index) itemBuilder;

  /// The sheet's open row ([foodHistoryItemKey]), for the hairline fade.
  final String? expandedKey;

  /// Space below the section when it shows.
  final double gap;

  /// Local work only, so far shorter than the product search's 1 s.
  static const Duration debounce = Duration(milliseconds: 150);

  @override
  State<FoodHistoryResults> createState() => _FoodHistoryResultsState();
}

class _FoodHistoryResultsState extends State<FoodHistoryResults> {
  late String _query;
  Timer? _debounce;
  bool _showAll = false;

  FoodHistoryIndex? _index;
  List<FavoriteMeal>? _indexedFavorites;
  List<LoggedMeal>? _indexedDiary;
  List<FitnessRecipe>? _indexedRecipes;
  String? _indexedLocale;

  FoodHistoryIndex? _searchedIndex;
  String? _searchedQuery;
  List<FoodHistoryHit> _hits = const <FoodHistoryHit>[];

  /// Recipe snapshots per recipe instance, kept across index rebuilds: an
  /// unchanged recipe hands its row the same result instance, so a typed
  /// portion survives an unrelated store change.
  final Expando<(String, MealAnalysisResult?)> _recipeResults =
      Expando<(String, MealAnalysisResult?)>();

  @override
  void initState() {
    super.initState();
    _query = widget.query.value.text;
    widget.query.addListener(_onQueryChanged);
  }

  @override
  void didUpdateWidget(FoodHistoryResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.query, widget.query)) {
      oldWidget.query.removeListener(_onQueryChanged);
      widget.query.addListener(_onQueryChanged);
      _query = widget.query.value.text;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.query.removeListener(_onQueryChanged);
    super.dispose();
  }

  void _onQueryChanged() {
    // Caret and composing moves notify too; only a text change counts.
    if (widget.query.value.text == _query && _debounce == null) return;
    _debounce?.cancel();
    _debounce = Timer(FoodHistoryResults.debounce, () {
      _debounce = null;
      final next = widget.query.value.text;
      if (!mounted || next == _query) return;
      setState(() {
        _query = next;
        _showAll = false;
      });
    });
  }

  /// Rebuilt only when a source list is replaced (the store reassigns them
  /// per mutation) or the language changes.
  FoodHistoryIndex _currentIndex(AppLocalizations l10n) {
    final index = _index;
    if (index != null &&
        identical(_indexedFavorites, widget.favorites) &&
        identical(_indexedDiary, widget.diary) &&
        identical(_indexedRecipes, widget.recipes) &&
        _indexedLocale == l10n.localeName) {
      return index;
    }
    _indexedFavorites = widget.favorites;
    _indexedDiary = widget.diary;
    _indexedRecipes = widget.recipes;
    _indexedLocale = l10n.localeName;
    return _index = FoodHistoryIndex(
      favorites: widget.favorites,
      diary: widget.diary,
      recipes: widget.recipes,
      recipeResult: (recipe) => _recipeResult(recipe, l10n),
    );
  }

  MealAnalysisResult? _recipeResult(
    FitnessRecipe recipe,
    AppLocalizations l10n,
  ) {
    final cached = _recipeResults[recipe];
    if (cached != null && cached.$1 == l10n.localeName) return cached.$2;
    MealAnalysisResult? result;
    try {
      result = recipe.toMealResultForServings(1, l10n);
    } on FormatException {
      // Nutrition still missing: the recipe cannot be logged from here.
      result = null;
    }
    _recipeResults[recipe] = (l10n.localeName, result);
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final index = _currentIndex(l10n);
    if (!identical(index, _searchedIndex) || _query != _searchedQuery) {
      _searchedIndex = index;
      _searchedQuery = _query;
      _hits = index.search(_query);
    }
    final hits = _hits;
    if (hits.isEmpty) return const SizedBox.shrink();
    final shortened = hits.length > kFoodHistoryVisibleHits;
    final visible = shortened && !_showAll
        ? hits.sublist(0, kFoodHistoryVisibleHits)
        : hits;
    return Column(
      key: const ValueKey('food-history-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.labelBuilder(l10n.foodHistorySectionTitle),
        SavedMealCollection(
          dividerInset: kSavedMealDividerInset,
          expandedIndex: visible.indexWhere(
            (hit) => foodHistoryItemKey(hit) == widget.expandedKey,
          ),
          children: [
            for (var i = 0; i < visible.length; i++)
              widget.itemBuilder(visible[i], i),
          ],
        ),
        if (shortened)
          FoodHistoryShowAllToggle(
            key: const ValueKey('food-history-toggle'),
            count: hits.length,
            expanded: _showAll,
            onTap: () => setState(() => _showAll = !_showAll),
          ),
        SizedBox(height: widget.gap),
      ],
    );
  }
}

/// "Show all N" / "Show fewer" under a shortened list. Bare accent text
/// with a chevron, so it does not compete with the rows; 48 px tall for the
/// touch target, and the text wraps at large sizes instead of overflowing.
class FoodHistoryShowAllToggle extends StatelessWidget {
  const FoodHistoryShowAllToggle({
    super.key,
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  /// All rows of the list, the hidden ones included.
  final int count;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final label = expanded
        ? l10n.foodHistoryShowLess
        : l10n.foodHistoryShowAll(count);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: MergeSemantics(
        child: Semantics(
          button: true,
          expanded: expanded,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(rChip),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          label,
                          style: AppType.ui(
                            13.5,
                            weight: FontWeight.w600,
                            color: t.accentText,
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      ExcludeSemantics(
                        child: Icon(
                          expanded
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 20,
                          color: t.accentText,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
