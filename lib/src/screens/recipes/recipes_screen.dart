/// Recipes tab — a library assembled from the `part` files below.
///
/// Mechanical split only; library-private `_` classes keep their visibility.
/// Entry point is [RecipesScreen]; the public [RecipeDetailScreen] lives in
/// recipe_detail.dart.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../l10n/l10n.dart';
import '../../models/fitness_recipe.dart';
import '../../models/logged_meal.dart';
import '../../models/macro_progress.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/number_input.dart';
import '../../models/recipe_pick.dart';
import '../../models/recipe_shelf.dart';
import '../../models/user_profile.dart';
import '../../services/meal_photo_input.dart';
import '../../services/recipe_image_store.dart';
import '../../services/recipe_save_result.dart';
import '../../services/open_food_facts_product_service.dart';
import '../../services/sync_error_messages.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/common/decimal_text.dart';
import '../../widgets/common/lively.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/common/persistence_action.dart';
import '../../widgets/design/design.dart';
import '../../widgets/recipes/recipe_ingredient_editor.dart';
import '../../widgets/recipes/recipe_portion_selector.dart';
import '../../widgets/recipes/recipe_photo.dart';
import '../../widgets/recipes/recipe_pick_actions.dart';

import 'recipe_history_screen.dart';

part 'recipes_header.dart';
part 'recipes_hero.dart';
part 'recipes_shelves.dart';
part 'recipe_glyphs.dart';
part 'recipe_cards.dart';
part 'recipe_detail.dart';
part 'recipe_slot_picker.dart';
part 'recipe_nutrition_basis_sheet.dart';
part 'recipe_create_sheet.dart';
part 'recipe_atoms.dart';

class RecipesScreen extends StatefulWidget {
  const RecipesScreen({
    super.key,
    required this.onAddMeal,
    this.remainingMacros,
    this.diet = DietPreference.none,
    this.onCreateRecipe,
    this.onUpdateRecipe,
    this.onLoadRecipeHistory,
    this.onRestoreRecipe,
    this.isSessionCurrent,
    this.onOpenMealPlan,
    this.onImport,
    this.productService,
    this.onDeleteRecipe,
    this.onDeletePendingChanged,
    this.isDeletePending,
    this.initialUserRecipes = const <FitnessRecipe>[],
    this.userRecipesAuthoritative = false,
    this.recipePhotoReferences = const <String>{},
    this.photoInput,
    this.mealPick,
    this.onAddPickToToday,
    this.onEatPlannedMeal,
    this.onUndoAddedMeal,
    this.isFavorite,
    this.onToggleFavorite,
    this.todayOverBudget = false,
  });

  final FutureOr<void> Function(MealAnalysisResult result, MealSlot slot)
  onAddMeal;

  /// The shared pick for today's next open main meal
  /// (`HomeStore.nextMealPick`), shown as the "Picked for tonight" hero of
  /// For you. Null falls back to the best goal match without the "fits"
  /// claim, or to no hero.
  final RecipePick? mealPick;

  /// Logs a suggested pick into TODAY's [RecipePick.slot] — the pick's day,
  /// whatever day the food tab shows — and returns the new meal's id for the
  /// undo action. Null disables "Add to `<slot>`" for suggestions.
  final Future<String> Function(MealAnalysisResult result, MealSlot slot)?
  onAddPickToToday;

  /// Eats a planned pick (`HomeStore.eatPlannedMeal`: plan and diary in one
  /// step). Null disables "Add to `<slot>`" for planned picks.
  final Future<SyncDelivery> Function(String plannedMealId)? onEatPlannedMeal;

  /// Undo of "Add to `<slot>`": removes the meal [onAddPickToToday] logged.
  final Future<void> Function(String mealId)? onUndoAddedMeal;

  /// Whether a meal is pinned as a favorite, and the pin toggle; the hero's
  /// bookmark. Either null hides the bookmark.
  final bool Function(MealAnalysisResult result)? isFavorite;
  final Future<void> Function(MealAnalysisResult result)? onToggleFavorite;

  /// Today's remaining kcal (budget incl. activity) are used up. Then there
  /// is no pick, and the fallback hero offers no add — only "View recipe".
  final bool todayOverBudget;

  /// Remaining daily macros (target minus consumed). When set, the screen
  /// shows a goal-match section ranking recipes by macro fit; null hides it.
  final MacroProgress? remainingMacros;

  /// Diet preference (PROD-6). Filters the actively promoted lists — the
  /// recommendation carousel and the goal matches — BEFORE the macro ranking,
  /// so no diet-violating recipe is recommended. Main list and category
  /// filters stay untouched. Default [DietPreference.none] recommends
  /// everything.
  final DietPreference diet;

  /// Optional hook reporting a self-created recipe to the caller (persisted
  /// via user_recipes); null keeps the recipe local to this session. Returns
  /// what actually happened (Gap E), which drives the success text.
  final Future<SyncDelivery> Function(FitnessRecipe recipe)? onCreateRecipe;
  final Future<RecipeSaveResult> Function(FitnessRecipe recipe)? onUpdateRecipe;
  final RecipeHistoryLoader? onLoadRecipeHistory;
  final RecipeVersionRestorer? onRestoreRecipe;
  final bool Function()? isSessionCurrent;
  final VoidCallback? onOpenMealPlan;
  final VoidCallback? onImport;
  final ProductLookupService? productService;

  /// Optional hook for deleting a user recipe by slug, forwarded to
  /// user_recipes.delete. Null means no persistence.
  final Future<SyncDelivery> Function(String slug)? onDeleteRecipe;

  /// Optional hook telling the shell that [slug] entered ([pending] true) or
  /// left (undo, commit) its undo window. The shell keeps the row until the
  /// commit but must hide it from every OTHER reader meanwhile
  /// (`HomeStore.visibleUserRecipes`): the coach card derives "Hinzugefügt"
  /// from the live slugs and stayed locked until the toast had gone
  /// (2026-09-02).
  final void Function(String slug, {required bool pending})?
      onDeletePendingChanged;

  /// Reads the current store state, including a new confirmation that has
  /// cancelled a pending delete. A live callback also protects timer callbacks
  /// that run before the next widget rebuild. Null keeps local undo behavior.
  final bool Function(String slug)? isDeletePending;

  /// User recipes loaded from Supabase at boot; taken as the initial state so
  /// self-created recipes survive a restart.
  final List<FitnessRecipe> initialUserRecipes;

  /// Whether [initialUserRecipes] is COMPLETE — the boot load has answered for
  /// user_recipes AND that answer covers the whole collection
  /// (`HomeStore.userRecipesAuthoritative`). False means the list may still
  /// grow, and an entry missing from it says nothing: the answer is still out,
  /// or it filled its page and left the older recipes behind, or a queued
  /// recipe never made it back out of an unreadable outbox slot.
  ///
  /// Only the photo sweep reads this (P3-04b); the display shows whatever is
  /// there, finished or not. Default false: without a store saying otherwise,
  /// no list is authoritative.
  final bool userRecipesAuthoritative;

  /// Complete historical references, loaded before the authority gate opens.
  final Set<String> recipePhotoReferences;

  /// Source for the recipe photo. Null uses the real [DeviceMealPhotoInput],
  /// which already returns EXIF-free bytes. Exists purely as a test seam.
  final MealPhotoInput? photoInput;

  @override
  State<RecipesScreen> createState() => _RecipesScreenState();
}

/// How long a deleted recipe can be brought back: the undo toast's dwell time
/// plus the 400 ms margin `_AutoDismiss` grants before it removes the toast,
/// plus another 400 ms so the commit fires strictly AFTER that removal. The
/// toast's dismiss timer calls `removeCurrentSnackBar` whatever is current,
/// so a follow-up toast shown at the same instant would be eaten by it.
final Duration kRecipeUndoWindow =
    kSnackAction + const Duration(milliseconds: 800);

/// A delete inside its undo window.
class _PendingDelete {
  const _PendingDelete(this.recipe, this.timer);

  final FitnessRecipe recipe;
  final Timer timer;
}

/// How often [_RecipeIndex] actually recomputed something.
///
/// Pure test seam (perf audit 2026-09-01, B4): a memo is invisible from the
/// outside — the same list comes back either way — so counting the recomputes
/// is the only way a test can tell a cache hit from a cache miss. Nothing in
/// production reads these.
@visibleForTesting
abstract final class RecipeMemoStats {
  /// Recipes whose search text was folded (title, description, ingredients and
  /// every category label).
  static int folds = 0;

  /// Passes of the search/filter over the whole recipe set.
  static int filterRuns = 0;

  /// Runs of the diet pre-filter and of the macro ranking on top of it.
  static int dietRuns = 0;
  static int goalRuns = 0;

  /// Indexes built, i.e. how often the recipe set or the language changed.
  static int indexBuilds = 0;

  static void reset() {
    folds = 0;
    filterRuns = 0;
    dietRuns = 0;
    goalRuns = 0;
    indexBuilds = 0;
  }
}

/// One recipe set in one language, plus every list the screen derives from it.
///
/// Perf audit 2026-09-01 (B4): the search used to fold title, description,
/// ingredients and every category — including its LOCALISED label — for every
/// recipe on every build, so every keystroke re-folded the whole catalogue.
/// Measured against the 30 built-in recipes that is 81 us per build, 61 us of
/// it folding, while validating this index costs 0.8 us. The cost grows
/// linearly with the catalogue, so the fold is the part that must not run
/// twice.
///
/// This object IS the cache key for everything below it. It is thrown away
/// exactly when one of its two inputs changes:
///
///   * [localeName] picks the catalogue AND the category labels that go into
///     the folded text. Under `en` the query "fish" matches the label of the
///     `Fisch` tag; under `de` it must not. A cache blind to the language
///     would keep serving the English hits after a language switch.
///   * [userRecipes] are the visible user recipes, compared element by element
///     with `identical` by [_sameRecipes]. [FitnessRecipe] has only final
///     fields and no `==`, so the object is its content.
///
/// Deliberately not a revision counter: a counter has to be bumped at every
/// mutation site (create, delete, undo, commit, didUpdateWidget), and the next
/// site someone adds would silently serve a stale list. Comparing the real
/// list cannot rot.
class _RecipeIndex {
  _RecipeIndex(this.localeName, this.l10n, this.userRecipes)
      : catalog = recipeCatalogForLocale(localeName),
        recipes = <FitnessRecipe>[
          ...userRecipes,
          ...recipeCatalogForLocale(localeName),
        ] {
    RecipeMemoStats.indexBuilds++;
  }

  /// `de`/`en` — the key, because it decides catalogue and labels alike.
  final String localeName;

  /// String source for [localeName]. Not part of the key: the delegate may
  /// hand out a fresh instance for the same language, and that instance says
  /// the same things.
  final AppLocalizations l10n;

  /// The visible user recipes this index was built from, kept for the identity
  /// comparison that decides whether it is still current.
  final List<FitnessRecipe> userRecipes;

  /// Built-in catalogue for [localeName].
  final List<FitnessRecipe> catalog;

  /// User recipes first, then the catalogue — the list the screen shows.
  final List<FitnessRecipe> recipes;

  /// Folded search fields per recipe, filled on first use.
  ///
  /// Lazy on purpose: with an empty query the old code folded nothing at all,
  /// so an eagerly built index would have made the common case slower.
  ///
  /// The fields stay SEPARATE strings instead of one joined haystack, because
  /// a join would let a query match across a field boundary — that changes
  /// results, not just cost.
  final Map<FitnessRecipe, List<String>> _folded =
      HashMap<FitnessRecipe, List<String>>.identity();

  List<String> _fieldsOf(FitnessRecipe recipe) {
    final cached = _folded[recipe];
    if (cached != null) return cached;
    RecipeMemoStats.folds++;
    return _folded[recipe] = <String>[
      foldRecipeSearchText(recipe.title),
      foldRecipeSearchText(recipe.description),
      foldRecipeSearchText(recipe.ingredients),
      for (final ingredient in recipe.structuredIngredients)
        foldRecipeSearchText(ingredient.name),
      // Categories match on the neutral identity AND on the localised label:
      // under `en` the hint promises "category", so "breakfast" must find the
      // recipes tagged "Frühstück".
      for (final category in recipe.categories) ...[
        foldRecipeSearchText(category),
        foldRecipeSearchText(recipeCategoryLabel(category, l10n)),
      ],
    ];
  }

  String? _filterQuery;
  String? _filterName;
  DietPreference? _filterDiet;
  List<FitnessRecipe>? _filtered;

  /// The main list: [recipes] narrowed by the selected chip and by [query],
  /// which arrives already trimmed and folded.
  ///
  /// The chip check now short-circuits the query check. Both are pure, so the
  /// result is the same as the old `matchesFilter && matchesQuery` — it just
  /// stops folding recipes a category filter has already dropped.
  ///
  /// [leanShelfFilter] is the "See all" list of the lean shelf: the shelf is
  /// diet-filtered, so its full list is too, and only then does [diet] join
  /// the key.
  List<FitnessRecipe> filtered({
    required String query,
    required String filter,
    DietPreference diet = DietPreference.none,
  }) {
    final dietKey = filter == leanShelfFilter ? diet : null;
    final cached = _filtered;
    if (cached != null &&
        _filterQuery == query &&
        _filterName == filter &&
        _filterDiet == dietKey) {
      return cached;
    }
    RecipeMemoStats.filterRuns++;
    _filterQuery = query;
    _filterName = filter;
    _filterDiet = dietKey;
    return _filtered = recipes.where((recipe) {
      final matchesFilter = switch (filter) {
        "Alle" => true,
        "Eigene" => recipe.userCreated,
        leanShelfFilter =>
          recipe.matchesDiet(diet) && isLeanHighProtein(recipe),
        lightMealFilter => isUnder600Kcal(recipe),
        _ => recipe.categories.contains(filter),
      };
      if (!matchesFilter) return false;
      return query.isEmpty ||
          _fieldsOf(recipe).any((field) => field.contains(query));
    }).toList(growable: false);
  }

  DietPreference? _dietKey;
  List<FitnessRecipe>? _dietRecipes;

  /// Actively promoted recipes: [recipes] pre-filtered by diet preference
  /// (PROD-6). Feeds the goal matches; the main list stays unfiltered.
  List<FitnessRecipe> forDiet(DietPreference diet) {
    final cached = _dietRecipes;
    if (cached != null && _dietKey == diet) return cached;
    RecipeMemoStats.dietRuns++;
    _dietKey = diet;
    return _dietRecipes =
        recipes.where((r) => r.matchesDiet(diet)).toList(growable: false);
  }

  DietPreference? _poolKey;
  List<FitnessRecipe>? _pool;

  /// Carousel pool: catalogue only (an own recipe with a placeholder stripe is
  /// no "recommendation"), diet pre-filtered with a fallback to the whole
  /// catalogue so the section never looks empty. The day-based ROTATION stays
  /// outside — that one has to keep turning while this list does not.
  List<FitnessRecipe> catalogPool(DietPreference diet) {
    final cached = _pool;
    if (cached != null && _poolKey == diet) return cached;
    _poolKey = diet;
    final matching =
        catalog.where((r) => r.matchesDiet(diet)).toList(growable: false);
    return _pool = matching.isEmpty ? catalog : matching;
  }

  // The macro remainder is keyed by its four VALUES, not by identity:
  // [MacroProgress] declares no `==` and the home shell builds a fresh one out
  // of `goal - progress` on every build, so an identity key would miss every
  // single time and the memo would never pay for itself.
  DietPreference? _goalDiet;
  double? _goalProtein;
  double? _goalCarbs;
  double? _goalFat;
  int? _goalKcal;
  List<FitnessRecipe>? _goalMatches;

  /// Up to three recipes with the highest macro match; only scores above 0
  /// count. The diet pre-filter runs before the ranking.
  List<FitnessRecipe> goalMatches(
    MacroProgress remaining,
    DietPreference diet,
  ) {
    final cached = _goalMatches;
    if (cached != null &&
        _goalDiet == diet &&
        _goalProtein == remaining.proteinG &&
        _goalCarbs == remaining.carbsG &&
        _goalFat == remaining.fatG &&
        _goalKcal == remaining.kcal) {
      return cached;
    }
    RecipeMemoStats.goalRuns++;
    _goalDiet = diet;
    _goalProtein = remaining.proteinG;
    _goalCarbs = remaining.carbsG;
    _goalFat = remaining.fatG;
    _goalKcal = remaining.kcal;
    final scored = forDiet(diet)
        .map((r) => (r, r.matchScore(remaining)))
        .where((pair) => pair.$2 > 0)
        .toList(growable: false)
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return _goalMatches =
        scored.take(3).map((pair) => pair.$1).toList(growable: false);
  }
}

/// Element-wise identity of two recipe lists — the "did the set change" check
/// that no future mutation site can forget to trigger.
bool _sameRecipes(List<FitnessRecipe> a, List<FitnessRecipe> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!identical(a[i], b[i])) return false;
  }
  return true;
}

class _RecipesScreenState extends State<RecipesScreen> {
  String selectedFilter = "Alle";
  bool _forYou = true;

  /// Search text, deliberately on its own controller rather than the
  /// [TextField]'s internal state (D6, Review 2026-08-08): the screen is a
  /// lazy [ListView], so scrolling far enough recycles the unfocused field and
  /// would drop the typed text while the filter kept running.
  final TextEditingController _searchController = TextEditingController();

  /// The page's list; keeps its offset in PageStorage like before. Only the
  /// "See all" links move it (to the top of the list they open).
  final ScrollController _listController = ScrollController();

  /// Mirror of [_searchController].text so [_filteredRecipes] can read it
  /// synchronously.
  String query = '';

  /// User recipes: loaded from user_recipes at boot plus those created in this
  /// session. Placed at the front of the list.
  late List<FitnessRecipe> _userRecipes;

  /// Deletes still inside their undo window, by slug. The recipe stays in
  /// [_userRecipes] (so a store update cannot resurrect it out of order) and
  /// is only hidden until the timer commits or undo cancels it.
  final Map<String, _PendingDelete> _pendingDeletes =
      <String, _PendingDelete>{};

  /// Set at the top of [dispose]: `mounted` is still true while disposing,
  /// but the element is already defunct, so a `setState` would assert.
  bool _disposing = false;

  /// Whether the orphan sweep has run (P3-04). Once per screen lifetime: the
  /// screen stays mounted for the whole session (IndexedStack), so this is one
  /// directory scan per session, and everything a later mutation orphans is
  /// caught by the next start's sweep.
  bool _photoSweepDone = false;

  @override
  void initState() {
    super.initState();
    _userRecipes = List<FitnessRecipe>.of(widget.initialUserRecipes);
    _searchController.addListener(_onSearchChanged);
    // The tab is built lazily (IndexedStack), often only after the boot load
    // has answered — then no [didUpdateWidget] follows and this is the only
    // chance to sweep.
    _sweepOrphanPhotos();
  }

  @override
  void dispose() {
    _disposing = true;
    _searchController.dispose();
    _listController.dispose();
    // The home shell keeps tabs mounted (IndexedStack, D6), so this is not a
    // tab switch but logout or route removal: commit now, silently.
    for (final pending in _pendingDeletes.values.toList(growable: false)) {
      pending.timer.cancel();
      unawaited(_commitDelete(pending.recipe));
    }
    super.dispose();
  }

  /// The controller also reports cursor/selection changes — only real text
  /// changes should re-filter the list.
  void _onSearchChanged() {
    if (_searchController.text == query) return;
    setState(() {
      query = _searchController.text;
      if (query.trim().isNotEmpty) _forYou = false;
    });
  }

  @override
  void didUpdateWidget(covariant RecipesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Every new caller state is adopted. The store reassigns its recipe list
    // on each mutation, so identity is an exact "something changed" check.
    //
    // No local-mutation latch here: the boot now MERGES instead of replacing
    // (Gap C), so a latch would only hide recipes the store brings back or
    // that were created on a second device.
    if (!identical(oldWidget.initialUserRecipes, widget.initialUserRecipes)) {
      _userRecipes = List<FitnessRecipe>.of(widget.initialUserRecipes);
    }
    for (final slug in _pendingDeletes.keys.toList(growable: false)) {
      if (widget.isDeletePending?.call(slug) == false) {
        _pendingDeletes.remove(slug)?.timer.cancel();
      }
    }
    // Outside the identity check on purpose (P3-04b): the sweep hangs off the
    // BOOT being finished, not off a list changing. A fresh identity says only
    // that the store assigned something — hydration assigns a stale-empty
    // cache slot exactly the same way.
    _sweepOrphanPhotos();
  }

  /// Releases recipe photos whose recipe is gone (P3-04).
  ///
  /// The screen drives this because it holds the only complete list of user
  /// recipes; the store's own delete path ([_commitDelete]) covers exactly one
  /// case — this device deleting with an immediate server ack. Everything else
  /// (a delete on device B, an offline delete delivered later, a coach
  /// adoption abandoned after the photo was saved) leaves bytes lying.
  ///
  /// TWO conditions, because a sweep against a list that is not authoritative
  /// deletes every photo the user has:
  ///
  ///   * a real persistence hook — without sync the recipes are session-local
  ///     (preview, tests) and say nothing about the disk;
  ///   * [RecipesScreen.userRecipesAuthoritative], i.e. the boot load has
  ///     ANSWERED for user_recipes.
  ///
  /// The second condition used to be "the store assigned a list" (a fresh list
  /// identity, or a non-empty one in [initState]). That is a proxy, and it
  /// breaks in the one window it has to hold (P3-04b): the cache write is
  /// debounced by 400 ms, so a kill inside that window leaves a stale-EMPTY
  /// recipe slot behind. The next start hydrates `[]` — a fresh identity from
  /// the store, indistinguishable from a real answer — and the sweep would
  /// then delete every `img_*` file while the boot load is still fetching the
  /// recipes those files belong to. The photos exist ONLY on this device, so
  /// the recipe comes back seconds later pointing at nothing.
  ///
  /// An `isNotEmpty` guard would be the wrong repair: "the user deleted all
  /// recipes" is a valid state that MUST collect. Empty is not the problem —
  /// unfinished is. And unfinished has several shapes, all of them behind the
  /// one flag (review 2026-08-31, A): the recipe or the photo-reference
  /// snapshot is still out, or a queued recipe is stuck in an unreadable
  /// outbox slot. The last looks exactly like a finished list from here, which
  /// is why the flag — not this screen — decides.
  ///
  /// [_userRecipes] rather than [_visibleUserRecipes]: a recipe inside its undo
  /// window still needs its bytes.
  void _sweepOrphanPhotos() {
    if (_photoSweepDone ||
        widget.onDeleteRecipe == null ||
        !widget.userRecipesAuthoritative) {
      return;
    }
    _photoSweepDone = true;
    unawaited(
      RecipeImageStore.instance.reconcileRecipePhotos(
        {...widget.recipePhotoReferences, ..._userRecipes.map((r) => r.imageAsset)},
      ),
    );
  }

  /// Memo holder for the current language and recipe set; see [_RecipeIndex]
  /// for what it caches and why that key is complete.
  _RecipeIndex? _index;

  /// The index matching the current build, rebuilt only when the language or
  /// the visible user recipes changed. `context.l10n.localeName` is already
  /// resolved to `de`/`en`, and a language switch rebuilds automatically
  /// (`Localizations` is an InheritedWidget), so reading it here is what makes
  /// the locale part of the key.
  _RecipeIndex _indexFor(AppLocalizations l10n) {
    final visible = _visibleUserRecipes;
    final current = _index;
    if (current != null &&
        current.localeName == l10n.localeName &&
        _sameRecipes(current.userRecipes, visible)) {
      return current;
    }
    return _index = _RecipeIndex(l10n.localeName, l10n, visible);
  }

  /// User recipes minus those inside an undo window.
  List<FitnessRecipe> get _visibleUserRecipes => _userRecipes
      .where((r) => !_pendingDeletes.containsKey(r.slug))
      .toList(growable: false);

  /// "For you": the curated start page; clears the search.
  void _showForYou() {
    _searchController.clear();
    setState(() {
      _forYou = true;
      selectedFilter = "Alle";
    });
  }

  /// A list view: "Alle", "Eigene", a category of [recipeFilters] or
  /// [leanShelfFilter]. The search text stays and narrows it further.
  void _showFilter(String filter) => setState(() {
    _forYou = false;
    selectedFilter = filter;
  });

  /// A "See all" link far down the page: the list it opens starts at the
  /// top, not at the offset the page had.
  void _seeAll(String filter) {
    _showFilter(filter);
    if (_listController.hasClients) _listController.jumpTo(0);
  }

  /// The chip bar, in the design's order: the sections For you, All and My
  /// recipes, then the categories. Exactly one chip is selected, except for
  /// the lean shelf's "See all" list, which has no chip.
  List<_RecipeChip> _chips(AppLocalizations l10n) => <_RecipeChip>[
    _RecipeChip(
      id: 'for-you',
      sectionKey: 'recipes-tab-for-you',
      label: l10n.recipesForYou,
      selected: _forYou,
      onTap: _showForYou,
    ),
    _RecipeChip(
      id: 'all',
      sectionKey: 'recipes-tab-all',
      filterKey: 'recipe-filter-${recipeFilters.first}',
      label: l10n.recipesFilterAll,
      selected: !_forYou && selectedFilter == recipeFilters.first,
      onTap: () => _showFilter(recipeFilters.first),
    ),
    _RecipeChip(
      id: 'own',
      sectionKey: 'recipes-tab-own',
      label: l10n.recipesChipMine,
      selected: !_forYou && selectedFilter == "Eigene",
      onTap: () => _showFilter("Eigene"),
    ),
    // The design's order: High protein, then Under 600 kcal, then the
    // remaining categories.
    for (final filter in <String>[
      recipeFilters[1],
      lightMealFilter,
      ...recipeFilters.skip(2),
    ])
      _RecipeChip(
        id: filter,
        filterKey: 'recipe-filter-$filter',
        label: filter == lightMealFilter
            ? l10n.recipesChipUnder600
            : recipeCategoryLabel(filter, l10n),
        selected: !_forYou && selectedFilter == filter,
        onTap: () => _showFilter(filter),
      ),
  ];

  /// The filter button: every chip in a sheet; applies the tapped one.
  Future<void> _openFilterSheet() async {
    final chips = _chips(context.l10n);
    final picked = await showEatovaSheet<int>(
      context,
      _RecipeFilterSheet(chips: chips),
    );
    if (!mounted || picked == null) return;
    chips[picked].onTap();
  }

  /// The accent "+": the import-or-create choice; with no import wired there
  /// is nothing to choose, so it creates directly.
  Future<void> _openAddChoice() async {
    final import = widget.onImport;
    if (import == null) return _openCreateSheet();
    final choice = await showEatovaSheet<_AddChoice>(
      context,
      const _RecipeAddChoiceSheet(),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case _AddChoice.import:
        import();
      case _AddChoice.create:
        await _openCreateSheet();
    }
  }

  bool get _sessionCurrent =>
      mounted && !_disposing && (widget.isSessionCurrent?.call() ?? true);

  /// The hero: the shared pick or, without one, the best goal match.
  _HeroModel? _heroFor(
    AppLocalizations l10n,
    List<FitnessRecipe> goalMatches,
  ) {
    final pick = widget.mealPick;
    if (pick != null) {
      final planned = pick.source == RecipePickSource.planned;
      final eyebrow = planned
          ? l10n.recipesHeroPlannedEyebrow
          : l10n.recipesHeroPickedEyebrow(pick.slot.name);
      // A planned meal whose nutrition cannot be logged (kcal unknown) gets
      // no add button that could not log: the meal plan, where it can be
      // fixed, or nothing.
      if (planned && (pick.kcal == null || pick.plannedMeal == null)) {
        final openPlan = widget.onOpenMealPlan;
        return _HeroModel(
          recipe: pick.recipe,
          eyebrow: eyebrow,
          fits: false,
          kcal: pick.kcal,
          proteinG: pick.proteinG,
          addLabel: openPlan == null ? null : l10n.recipeEditMealPlan,
          onAdd: openPlan,
          opensPlan: true,
          readOnlyDetail: true,
        );
      }
      final loggable = planned
          ? widget.onEatPlannedMeal != null
          : widget.onAddPickToToday != null;
      return _HeroModel(
        recipe: pick.recipe,
        eyebrow: eyebrow,
        fits: pick.fits,
        kcal: pick.kcal,
        proteinG: pick.proteinG,
        addLabel: l10n.recipesHeroAddToSlot(pick.slot.name),
        onAdd: loggable ? () => _addPick(pick) : null,
        readOnlyDetail: planned,
      );
    }
    if (goalMatches.isEmpty) return null;
    // No pick: a neutral recommendation that never claims to fit, and over
    // budget nothing to add at all (Today and Food show no pick then).
    final recipe = goalMatches.first;
    final nutrition = recipe.displayNutrition;
    final overBudget = widget.todayOverBudget;
    return _HeroModel(
      recipe: recipe,
      eyebrow: l10n.recipesHeroRecommendedEyebrow,
      fits: false,
      kcal: nutrition.caloriesKcal,
      proteinG: nutrition.proteinG,
      addLabel: overBudget ? null : l10n.recipesAddToTrackerTitle,
      onAdd: overBudget ? null : () => _logViaSlotPicker(recipe),
    );
  }

  /// "Add to `<slot>`" of the pick, through the shared [logRecipePick]: a
  /// planned meal is eaten through the meal plan (planned servings, plan and
  /// diary in one step); a suggestion logs `pick.servings` into TODAY's
  /// `pick.slot` with an undo that removes exactly that entry again. A
  /// double tap logs once: the helper ignores a pick whose write is still
  /// in flight.
  Future<void> _addPick(RecipePick pick) async {
    if (!_sessionCurrent) return;
    final l10n = context.l10n;
    MealAnalysisResult? added;
    String? mealId;
    final saved = await logRecipePick(
      context,
      pick,
      owner: this,
      addMeal: (result, slot) async {
        added = result;
        mealId = await widget.onAddPickToToday!(result, slot);
      },
      eatPlannedMeal: (id) async {
        await widget.onEatPlannedMeal!(id);
      },
      openMealPlan: widget.onOpenMealPlan ?? () {},
      isSessionCurrent: () => _sessionCurrent,
    );
    if (!saved || !mounted || !_sessionCurrent) return;
    final undo = widget.onUndoAddedMeal;
    final id = mealId;
    final kcal = added?.caloriesKcal ?? pick.kcal!;
    showAppSnack(
      context,
      l10n.commonKcalAddedToSlot(kcal, pick.slot.label(l10n)),
      icon: Icons.check_circle_rounded,
      // Only a suggestion has an inverse; the plan conversion has none.
      action: added == null || undo == null || id == null
          ? null
          : SnackBarAction(
              label: l10n.commonUndo,
              onPressed: () => unawaited(undo(id)),
            ),
    );
  }


  /// The goal-match hero's add button: the detail's portion and slot sheet,
  /// logging through [RecipesScreen.onAddMeal].
  Future<void> _logViaSlotPicker(FitnessRecipe recipe) async {
    if (!_sessionCurrent) return;
    await showEatovaSheet<({MealSlot slot, double servings})>(
      context,
      _MealSlotPickerSheet(
        recipe: recipe,
        onSave: (slot, servings) => _logFromSlotPicker(recipe, slot, servings),
      ),
      enableDrag: false,
    );
  }

  Future<bool> _logFromSlotPicker(
    FitnessRecipe recipe,
    MealSlot slot,
    double servings,
  ) async {
    if (!_sessionCurrent) return false;
    final l10n = context.l10n;
    final result = recipe.toMealResultForServings(servings, l10n);
    final saved = await tryPersistChange(
      context,
      () => widget.onAddMeal(result, slot),
    );
    if (!saved || !mounted || !_sessionCurrent) return false;
    showAppSnack(
      context,
      l10n.commonKcalAddedToSlot(result.caloriesKcal, slot.label(l10n)),
      icon: Icons.check_circle_rounded,
    );
    return true;
  }

  /// The diary snapshot the favorite pin is keyed on (one portion); null
  /// when the recipe cannot be logged, which hides the bookmark.
  MealAnalysisResult? _favoriteResult(
    FitnessRecipe recipe,
    AppLocalizations l10n,
  ) {
    try {
      return recipe.toMealResultForServings(1, l10n);
    } on FormatException {
      return null;
    }
  }

  Future<void> _toggleFavorite(MealAnalysisResult result) async {
    final toggle = widget.onToggleFavorite;
    if (toggle == null || !_sessionCurrent) return;
    await tryPersistChange(context, () => toggle(result));
  }

  /// Search plus category filter for the current build. Folding the query is
  /// the only work left here; the per-recipe fold and the result itself are
  /// memoised on [_RecipeIndex].
  List<FitnessRecipe> _filteredRecipes(_RecipeIndex index) => index.filtered(
    query: foldRecipeSearchText(query.trim()),
    filter: selectedFilter,
    diet: widget.diet,
  );

  /// [readOnly]: a planned meal's snapshot — viewing only; it is logged by
  /// the hero through the meal plan, and edits belong to the recipe itself.
  void _openRecipe(FitnessRecipe recipe, {bool readOnly = false}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecipeDetailScreen(
          recipe: recipe,
          onAddMeal: widget.onAddMeal,
          showAddAction: !readOnly,
          onEdit: recipe.userCreated && !readOnly ? _editRecipe : null,
          onOpenHistory:
              !readOnly &&
                  recipe.userCreated &&
                  widget.onLoadRecipeHistory != null &&
                  widget.onRestoreRecipe != null
              ? (slug) => _openHistory(slug: slug)
              : null,
          photoInput: widget.photoInput,
          productService: widget.productService,
          isSessionCurrent: () =>
              mounted &&
              !_disposing &&
              (widget.isSessionCurrent?.call() ?? true),
          // Offer delete only for self-created recipes.
          onDelete: recipe.userCreated && !readOnly
              ? (slug) {
                  if (!mounted ||
                      _disposing ||
                      widget.isSessionCurrent?.call() == false) {
                    return;
                  }
                  final current = _userRecipes
                      .where((r) => r.slug == slug)
                      .firstOrNull;
                  if (current != null) _deleteUserRecipe(current);
                }
              : null,
        ),
      ),
    );
  }

  Future<bool> _openHistory({String? slug}) async {
    final load = widget.onLoadRecipeHistory;
    final restore = widget.onRestoreRecipe;
    if (load == null ||
        restore == null ||
        widget.isSessionCurrent?.call() == false) {
      return false;
    }
    final delivery = await Navigator.of(context).push<SyncDelivery>(
      MaterialPageRoute(
        builder: (_) => RecipeHistoryScreen(
          slug: slug,
          loadHistory: load,
          restoreVersion: restore,
          isSessionCurrent: () =>
              mounted &&
              !_disposing &&
              (widget.isSessionCurrent?.call() ?? true),
        ),
      ),
    );
    if (!mounted ||
        delivery == null ||
        widget.isSessionCurrent?.call() == false) {
      return false;
    }
    showAppSnack(
      context,
      deliveryHint(context.l10n.recipeHistoryRestored, delivery, context.l10n),
      icon: Icons.restore_rounded,
    );
    return true;
  }

  Future<RecipeSaveResult> _editRecipe(FitnessRecipe recipe) async {
    if (!mounted || _disposing || !(widget.isSessionCurrent?.call() ?? true)) {
      throw StateError('Recipe session ended');
    }
    final persist = widget.onUpdateRecipe;
    final result = persist != null
        ? await persist(recipe)
        : RecipeSaveResult.detached(
            recipe, await _melde(widget.onCreateRecipe?.call(recipe)));
    if (!mounted || _disposing || !(widget.isSessionCurrent?.call() ?? true)) {
      result.handle.dispose();
      throw StateError('Recipe session ended');
    }
    if (persist == null) {
      setState(() {
        _userRecipes = [
          for (final current in _userRecipes)
            current.slug == recipe.slug ? recipe : current,
        ];
      });
    }
    return result;
  }

  /// Hides a user recipe and opens its undo window. Called from the detail
  /// screen. Nothing is persisted yet: the store hook and the photo deletion
  /// run in [_commitDelete] once the window has passed (or on dispose), so an
  /// undo needs no upsert and the device-only photo bytes never go early.
  void _deleteUserRecipe(FitnessRecipe recipe) {
    _pendingDeletes[recipe.slug]?.timer.cancel();
    setState(() {
      _pendingDeletes[recipe.slug] = _PendingDelete(
        recipe,
        Timer(kRecipeUndoWindow, () => unawaited(_commitDelete(recipe))),
      );
    });
    widget.onDeletePendingChanged?.call(recipe.slug, pending: true);
    final l10n = context.l10n;
    showAppSnack(
      context,
      // Plain sentence form: locally the recipe IS gone. If the commit later
      // only queues the delete, a second toast says so.
      l10n.commonDeliverySuccess(
        l10n.recipesDeletedSuccess(recipe.displayTitle(l10n)),
      ),
      icon: Icons.delete_outline_rounded,
      tone: SnackTone.error,
      action: SnackBarAction(
        label: l10n.commonUndo,
        onPressed: () => _undoDelete(recipe.slug),
      ),
    );
  }

  /// Undo tap inside the window: cancel the timer and show the recipe again.
  /// A no-op once the delete has been committed.
  void _undoDelete(String slug) {
    final pending = _pendingDeletes.remove(slug);
    if (pending == null) return;
    pending.timer.cancel();
    widget.onDeletePendingChanged?.call(slug, pending: false);
    if (mounted) setState(() {});
  }

  /// Persists a delete whose undo window has passed.
  Future<void> _commitDelete(FitnessRecipe recipe) async {
    final pending = _pendingDeletes.remove(recipe.slug);
    if (pending == null) return;
    if (widget.isDeletePending?.call(recipe.slug) == false) {
      if (mounted && !_disposing) setState(() {});
      return;
    }
    _userRecipes = _userRecipes
        .where((r) => r.slug != recipe.slug)
        .toList(growable: true);
    if (mounted && !_disposing) setState(() {});
    // Store first, window flag second: the store drops the row itself, so no
    // reader sees the recipe come back for a frame between the two calls.
    final lieferung = widget.onDeleteRecipe?.call(recipe.slug);
    if (!_disposing) {
      widget.onDeletePendingChanged?.call(recipe.slug, pending: false);
    }
    final ausgang = await _melde(lieferung);
    // A delivered deletion is retained in version history. Its device-local
    // image belongs to that version until a complete reference sweep says
    // otherwise; deleting it here would make restoration lose the photo.
    // Delivered is what the undo toast already implied; only a queued outcome
    // needs the honest follow-up (Gap E).
    if (!mounted || ausgang == SyncDelivery.delivered) return;
    // Hidden tab (the IndexedStack mutes it via TickerMode): a toast nobody
    // can see would only surface later in the wrong place. Stay silent.
    if (!TickerMode.valuesOf(context).enabled) return;
    showAppSnack(
      context,
      deliveryHint(
        context.l10n.recipesDeletedSuccess(recipe.displayTitle(context.l10n)),
        ausgang,
        context.l10n,
      ),
      icon: Icons.delete_outline_rounded,
      tone: SnackTone.error,
    );
  }

  /// Awaits a persistence hook's outcome. Without a hook (preview/test) there
  /// is nothing to sync, so the action counts as done.
  Future<SyncDelivery> _melde(Future<SyncDelivery>? hook) async =>
      await hook ?? SyncDelivery.delivered;

  Future<void> _openCreateSheet() async {
    // Deliberately not `showEatovaSheet`: it forces `showDragHandle: true`,
    // and a drag on the handle goes through `BottomSheet._handleDragEnd →
    // Navigator.pop`, bypassing both `PopScope` and `_DiscardDragGuard` — a
    // silent hole in the D5 discard guard.
    final ergebnis = await showModalBottomSheet<RezeptEntwurfErgebnis>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CreateRecipeSheet(
        photoInput: widget.photoInput ?? DeviceMealPhotoInput(),
        productService: widget.productService,
        onSave: widget.onCreateRecipe,
        isSessionCurrent: () =>
            mounted && !_disposing && (widget.isSessionCurrent?.call() ?? true),
      ),
    );
    if (ergebnis == null || !mounted) return;
    final recipe = ergebnis.rezept;
    setState(
      () => _userRecipes = [
        recipe,
        ..._userRecipes.where((r) => r.slug != recipe.slug),
      ],
    );
    _searchController.clear();
    _showFilter("Eigene");
    // Gap E: the message waits for the outcome instead of asserting it. It
    // arrives after [kSyncDeliveryWindow] at the latest — the store caps the
    // wait because a Supabase write carries no timeout.
    final ausgang = ergebnis.delivery ?? SyncDelivery.delivered;
    if (!mounted) return;
    showAppSnack(
      context,
      deliveryHint(
        // Ehrlich statt beruhigend: ist das Foto unterwegs verloren gegangen,
        // sagt die Meldung das. Frueher zeigte das Sheet dafuer eine eigene
        // Fehlermeldung, die dieser Toast eine Lidschlagszeit spaeter
        // ueberdeckte — der Nutzer las nur "gespeichert".
        ergebnis.fotoFehlgeschlagen
            ? context.l10n.recipesSavedWithoutPhoto(recipe.title)
            : context.l10n.recipesSavedSuccess(recipe.title),
        ausgang,
        context.l10n,
      ),
      icon: Icons.bookmark_added_rounded,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.t;
    final index = _indexFor(l10n);
    final visibleRecipes = _filteredRecipes(index);
    final remaining = widget.remainingMacros;
    final goalMatches = remaining == null
        ? const <FitnessRecipe>[]
        : index.goalMatches(remaining, widget.diet);
    final own = !_forYou && selectedFilter == "Eigene";

    Widget gutter(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: _kGutter),
      child: child,
    );

    List<Widget> rowsOf(List<FitnessRecipe> rows) => [
      for (var i = 0; i < rows.length; i++) ...[
        gutter(
          _RecipeListTile(
            key: ValueKey('recipe-tile-${rows[i].slug}'),
            recipe: rows[i],
            onTap: () => _openRecipe(rows[i]),
          ),
        ),
        if (i < rows.length - 1) gutter(Divider(height: 1, color: t.line)),
      ],
    ];

    final yourRecipes = gutter(
      _YourRecipesCard(onCreate: _openCreateSheet, onImport: widget.onImport),
    );

    final List<Widget> body;
    if (_forYou) {
      final hero = _heroFor(l10n, goalMatches);
      final heroSlug = hero?.recipe.slug;
      final lean = leanHighProteinShelf(
        index.recipes,
        now: clock.now(),
        diet: widget.diet,
        excludeSlug: heroSlug,
      );
      final goalShelf = goalMatches
          .where((recipe) => recipe.slug != heroSlug)
          .toList(growable: false);
      final favorite = hero == null ? null : _favoriteResult(hero.recipe, l10n);
      final isFavorite = widget.isFavorite;
      final canSave =
          favorite != null &&
          isFavorite != null &&
          widget.onToggleFavorite != null;
      body = [
        if (hero != null) ...[
          gutter(
            _RecipeHeroCard(
              model: hero,
              onView: () =>
                  _openRecipe(hero.recipe, readOnly: hero.readOnlyDetail),
              saved: canSave && isFavorite(favorite),
              onToggleSave: canSave ? () => _toggleFavorite(favorite) : null,
            ),
          ),
          // 16 in the design, minus what the shelf link's touch target
          // overhangs its 4 px title padding.
          const SizedBox(height: 16 - (_ShelfHeading.linkOverhang - 4)),
        ],
        if (lean.isNotEmpty) ...[
          _RecipeShelf(
            shelfKey: const ValueKey('recipe-shelf-lean'),
            cardKeyPrefix: 'recipe-shelf-lean-',
            heading: _ShelfHeading(
              title: l10n.recipesShelfLeanTitle,
              actionLabel: l10n.recipesSeeAll,
              actionKey: const ValueKey('recipe-lean-see-all'),
              onAction: () => _seeAll(leanShelfFilter),
            ),
            recipes: lean,
            onOpen: _openRecipe,
          ),
          const SizedBox(height: 16),
        ],
        yourRecipes,
        // Below the design's last card, For you keeps what it had: the
        // recipe list, then the goal matches at its end.
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _kGutter + 4),
          child: _ShelfHeading(
            title: l10n.recipesMoreRecommendations,
            actionLabel: l10n.recipesSeeAll,
            actionKey: const ValueKey('recipes-more-see-all'),
            onAction: () => _seeAll(recipeFilters.first),
          ),
        ),
        const SizedBox(height: 4),
        ...rowsOf(index.catalogPool(widget.diet)),
        if (goalShelf.isNotEmpty) ...[
          const SizedBox(height: 24),
          _RecipeShelf(
            shelfKey: const ValueKey('recipe-goal-matches'),
            cardKeyPrefix: 'recipe-goal-match-',
            heading: _ShelfHeading(
              title: l10n.recipesGoalMatchTitle,
              trailing: l10n.recipesGoalMatchTrailing,
            ),
            recipes: goalShelf,
            onOpen: _openRecipe,
          ),
        ],
      ];
    } else {
      final rows = visibleRecipes;
      body = [
        if (own) ...[
          yourRecipes,
          if (widget.onLoadRecipeHistory != null &&
              widget.onRestoreRecipe != null)
            gutter(
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('recipe-history-open'),
                  onPressed: () => _openHistory(),
                  icon: const Icon(Icons.history_rounded),
                  label: Text(l10n.recipeHistoryTitle),
                ),
              ),
            ),
          const SizedBox(height: 16),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _kGutter + 4),
          child: _ShelfHeading(
            title: own
                ? l10n.recipesChipMine
                : selectedFilter == leanShelfFilter
                ? l10n.recipesShelfLeanTitle
                : selectedFilter == lightMealFilter
                ? l10n.recipesChipUnder600
                : selectedFilter == recipeFilters.first
                ? l10n.recipesAllTitle
                : recipeCategoryLabel(selectedFilter, l10n),
            trailing: l10n.recipesResultsCount(rows.length),
          ),
        ),
        const SizedBox(height: 4),
        ...rowsOf(rows),
        if (rows.isEmpty)
          gutter(_RecipeEmptyState(own: own && query.trim().isEmpty)),
      ];
    }

    final page = KeyedSubtree(
      key: const PageStorageKey<String>('recipes-list'),
      child: ListView(
        key: const ValueKey('screen-recipes'),
        controller: _listController,
        // The tab owns its gutters (chips and shelves run to the screen
        // edge). Top: the shared title origin under the status bar. Bottom:
        // the floating tab bar's band plus the design's 48 px.
        padding: EdgeInsets.only(
          top: TabChrome.topInset(context),
          bottom: 48 + MediaQuery.paddingOf(context).bottom,
        ),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: livelyStagger([
          gutter(
            _RecipesHeader(
              key: TabChrome.headerKey,
              onAdd: _openAddChoice,
              addSemantics: widget.onImport == null
                  ? l10n.recipesCreateSemantics
                  : l10n.recipesAddChoiceSemantics,
              onOpenMealPlan: widget.onOpenMealPlan,
            ),
          ),
          const SizedBox(height: 16),
          gutter(
            _RecipeSearchCapsule(
              controller: _searchController,
              onClear: _searchController.clear,
              onFilters: _openFilterSheet,
            ),
          ),
          // 16 in the design, minus the 1 px the chips' 44 px touch target
          // adds above and below the 42 px pills.
          const SizedBox(height: 15),
          _RecipeChipBar(chips: _chips(l10n)),
          const SizedBox(height: 15),
          ...body,
        ]),
      ),
    );
    // First view of the tab: the sections enter top to bottom, once per
    // session (the shell keeps a visited tab mounted). Rows the lazy list
    // builds later, or a new filter's rows, appear as they are.
    return LivelyStaggerScope(child: page);
  }
}
