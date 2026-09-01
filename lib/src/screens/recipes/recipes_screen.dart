/// Recipes tab — a library assembled from the `part` files below.
///
/// Mechanical split only; library-private `_` classes keep their visibility.
/// Entry point is [RecipesScreen]; the public [RecipeDetailScreen] lives in
/// recipe_detail.dart.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../l10n/l10n.dart';
import '../../models/fitness_recipe.dart';
import '../../models/logged_meal.dart';
import '../../models/macro_progress.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/user_profile.dart';
import '../../services/meal_photo_input.dart';
import '../../services/recipe_image_store.dart';
import '../../services/sync_error_messages.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/design/design.dart';

part 'recipes_header.dart';
part 'recipe_cards.dart';
part 'recipe_detail.dart';
part 'recipe_slot_picker.dart';
part 'recipe_create_sheet.dart';
part 'recipe_atoms.dart';

class RecipesScreen extends StatefulWidget {
  const RecipesScreen({
    super.key,
    required this.onAddMeal,
    this.remainingMacros,
    this.diet = DietPreference.none,
    this.onCreateRecipe,
    this.onDeleteRecipe,
    this.initialUserRecipes = const <FitnessRecipe>[],
    this.userRecipesAuthoritative = false,
    this.photoInput,
  });

  final void Function(MealAnalysisResult result, MealSlot slot) onAddMeal;

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

  /// Optional hook for deleting a user recipe by slug, forwarded to
  /// user_recipes.delete. Null means no persistence.
  final Future<SyncDelivery> Function(String slug)? onDeleteRecipe;

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
  List<FitnessRecipe>? _filtered;

  /// The main list: [recipes] narrowed by the selected chip and by [query],
  /// which arrives already trimmed and folded.
  ///
  /// The chip check now short-circuits the query check. Both are pure, so the
  /// result is the same as the old `matchesFilter && matchesQuery` — it just
  /// stops folding recipes a category filter has already dropped.
  List<FitnessRecipe> filtered({required String query, required String filter}) {
    final cached = _filtered;
    if (cached != null && _filterQuery == query && _filterName == filter) {
      return cached;
    }
    RecipeMemoStats.filterRuns++;
    _filterQuery = query;
    _filterName = filter;
    return _filtered = recipes.where((recipe) {
      final matchesFilter = switch (filter) {
        "Alle" => true,
        "Eigene" => recipe.userCreated,
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
  List<FitnessRecipe> goalMatches(MacroProgress remaining, DietPreference diet) {
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

  /// Search text, deliberately on its own controller rather than the
  /// [TextField]'s internal state (D6, Review 2026-08-08): the screen is a
  /// lazy [ListView], so scrolling far enough recycles the unfocused field and
  /// would drop the typed text while the filter kept running.
  final TextEditingController _searchController = TextEditingController();

  /// Mirror of [_searchController].text so [_filteredRecipes] can read it
  /// synchronously.
  String query = '';

  /// User recipes: loaded from user_recipes at boot plus those created in this
  /// session. Placed at the front of the list.
  late List<FitnessRecipe> _userRecipes;

  /// Deletes still inside their undo window, by slug. The recipe stays in
  /// [_userRecipes] (so a store update cannot resurrect it out of order) and
  /// is only hidden until the timer commits or undo cancels it.
  final Map<String, _PendingDelete> _pendingDeletes = <String, _PendingDelete>{};

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
    setState(() => query = _searchController.text);
  }

  @override
  void didUpdateWidget(covariant RecipesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Every new caller state is adopted. The store reassigns its recipe list
    // on each mutation, so identity is an exact "something changed" check.
    //
    // No local-mutation latch here: the boot now MERGES instead of replacing
    // (Gap C), so a latch would only hide recipes restored by
    // `_restoreDroppedDeletes` or created on a second device.
    if (!identical(oldWidget.initialUserRecipes, widget.initialUserRecipes)) {
      _userRecipes = List<FitnessRecipe>.of(widget.initialUserRecipes);
      _dropOwnFilterIfEmpty();
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
  /// unfinished is. And unfinished has three shapes, all of them behind the
  /// one flag (review 2026-08-31, A): the answer is still out, the answer
  /// filled its page and stops at the newest `userRecipesLimit` recipes, or a
  /// queued recipe is stuck in an unreadable outbox slot. The last two look
  /// exactly like a finished list from here, which is why the flag — not this
  /// screen — decides.
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
    unawaited(RecipeImageStore.instance.reconcileRecipePhotos(
      _userRecipes.map((r) => r.imageAsset).toList(growable: false),
    ));
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

  /// Filter strip: "Eigene" sits right after "Alle" and only exists while
  /// there is something to show under it. The literals are logic identity
  /// (see [recipeCategoryLabel]), hence double-quoted.
  List<String> get _filters => <String>[
        recipeFilters.first,
        if (_visibleUserRecipes.isNotEmpty) "Eigene",
        ...recipeFilters.skip(1),
      ];

  /// The "Eigene" chip disappears with its last recipe; the selection must
  /// not point at a chip that no longer exists.
  void _dropOwnFilterIfEmpty() {
    if (selectedFilter == "Eigene" && _visibleUserRecipes.isEmpty) {
      selectedFilter = "Alle";
    }
  }

  /// Search plus category filter for the current build. Folding the query is
  /// the only work left here; the per-recipe fold and the result itself are
  /// memoised on [_RecipeIndex].
  List<FitnessRecipe> _filteredRecipes(_RecipeIndex index) => index.filtered(
        query: foldRecipeSearchText(query.trim()),
        filter: selectedFilter,
      );

  void _openRecipe(FitnessRecipe recipe) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecipeDetailScreen(
          recipe: recipe,
          onAddMeal: widget.onAddMeal,
          // Offer delete only for self-created recipes.
          onDelete: recipe.userCreated ? () => _deleteUserRecipe(recipe) : null,
        ),
      ),
    );
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
      _dropOwnFilterIfEmpty();
    });
    final l10n = context.l10n;
    showAppSnack(
      context,
      // Plain sentence form: locally the recipe IS gone. If the commit later
      // only queues the delete, a second toast says so.
      l10n.commonDeliverySuccess(l10n.recipesDeletedSuccess(recipe.title)),
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
    if (mounted) setState(() {});
  }

  /// Persists a delete whose undo window has passed.
  Future<void> _commitDelete(FitnessRecipe recipe) async {
    _pendingDeletes.remove(recipe.slug);
    _userRecipes =
        _userRecipes.where((r) => r.slug != recipe.slug).toList(growable: true);
    if (mounted && !_disposing) setState(() {});
    final ausgang = await _melde(widget.onDeleteRecipe?.call(recipe.slug));
    // The photo goes too, but only once the delete is actually delivered: a
    // dropped delete makes `_restoreDroppedDeletes` bring the recipe back, and
    // the device-only bytes would already be gone. No-op for catalog recipes
    // and user recipes without an image.
    //
    // The price is the other direction: a delete the outbox delivers LATER
    // leaves the file behind, since neither store nor screen hears about it.
    // `RecipeImageStore.clear()` on logout cleans that up.
    if (ausgang == SyncDelivery.delivered) {
      await RecipeImageStore.instance.deleteFor(recipe.imageAsset);
    }
    // Delivered is what the undo toast already implied; only a queued outcome
    // needs the honest follow-up (Gap E).
    if (!mounted || ausgang == SyncDelivery.delivered) return;
    // Hidden tab (the IndexedStack mutes it via TickerMode): a toast nobody
    // can see would only surface later in the wrong place. Stay silent.
    if (!TickerMode.valuesOf(context).enabled) return;
    showAppSnack(
      context,
      deliveryHint(
        context.l10n.recipesDeletedSuccess(recipe.title),
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
    final recipe = await showModalBottomSheet<FitnessRecipe>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CreateRecipeSheet(
        photoInput: widget.photoInput ?? DeviceMealPhotoInput(),
      ),
    );
    if (recipe == null || !mounted) return;
    setState(() => _userRecipes.insert(0, recipe));
    // Gap E: the message waits for the outcome instead of asserting it. It
    // arrives after [kSyncDeliveryWindow] at the latest — the store caps the
    // wait because a Supabase write carries no timeout.
    final ausgang = await _melde(widget.onCreateRecipe?.call(recipe));
    if (!mounted) return;
    showAppSnack(
      context,
      deliveryHint(
        context.l10n.recipesSavedSuccess(recipe.title),
        ausgang,
        context.l10n,
      ),
      icon: Icons.bookmark_added_rounded,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final index = _indexFor(l10n);
    final visibleRecipes = _filteredRecipes(index);
    // Recommendation carousel: the diet-filtered catalog pool (PROD-6),
    // rotated by calendar day so it is not the same four cards forever. Only
    // the pool is memoised — the rotation has to keep turning.
    final recommended =
        rotatedRecommendations(index.catalogPool(widget.diet), clock.now());
    final remaining = widget.remainingMacros;
    final goalMatches = remaining == null
        ? const <FitnessRecipe>[]
        : index.goalMatches(remaining, widget.diet);

    // A fixed carousel height plus growing text overflows at textScaler 2.0;
    // same technique as `MacroBar` in the design library.
    final carouselHeight =
        MediaQuery.textScalerOf(context).scale(236).clamp(236.0, 430.0);

    // D6: the PageStorageKey gives the list a stable identity in the route's
    // PageStorage, so the scroll position survives a tab switch. It sits on a
    // KeyedSubtree rather than the ListView because the latter's
    // ValueKey('screen-recipes') is the entry point of several test suites.
    return KeyedSubtree(
      key: const PageStorageKey<String>('recipes-list'),
      child: ListView(
        key: const ValueKey('screen-recipes'),
        padding: const EdgeInsets.only(bottom: 28),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          _RecipesHeader(onCreate: _openCreateSheet),
          const SizedBox(height: 14),
          _RecipeSearchField(
            controller: _searchController,
            onClear: _searchController.clear,
          ),
          const SizedBox(height: 12),
          _RecipeFilterChips(
            filters: _filters,
            selected: selectedFilter,
            onSelected: (filter) => setState(() => selectedFilter = filter),
          ),
          const SizedBox(height: 18),
          SectionHeading(
            title: l10n.recipesRecommendedTitle,
            trailing: l10n.recipesFitnessDishesCount(index.recipes.length),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: carouselHeight,
            child: ListView.separated(
              key: const ValueKey('recipe-recommended'),
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              itemCount: recommended.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final recipe = recommended[index];
                return _RecipeHeroCard(
                  key: ValueKey('recipe-recommended-${recipe.slug}'),
                  recipe: recipe,
                  onTap: () => _openRecipe(recipe),
                );
              },
            ),
          ),
          const SizedBox(height: 22),
          SectionHeading(
            // `selectedFilter` stays the neutral logic identity (filter
            // comparison, chip ValueKeys); the heading shows its ARB display
            // form, like the chip itself. The "Alle" case keeps its own,
            // longer title.
            title: selectedFilter == "Alle"
                ? l10n.recipesAllTitle
                : recipeCategoryLabel(selectedFilter, l10n),
            trailing: l10n.recipesResultsCount(visibleRecipes.length),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < visibleRecipes.length; i++) ...[
            _RecipeListTile(
              key: ValueKey('recipe-tile-${visibleRecipes[i].slug}'),
              recipe: visibleRecipes[i],
              onTap: () => _openRecipe(visibleRecipes[i]),
            ),
            if (i != visibleRecipes.length - 1) const SizedBox(height: 12),
          ],
          if (visibleRecipes.isEmpty) const _RecipeEmptyState(),
          // Deliberately after the main list, so the first recipe tile stays
          // in the initial viewport.
          if (goalMatches.isNotEmpty) ...[
            const SizedBox(height: 22),
            SectionHeading(
              title: l10n.recipesGoalMatchTitle,
              trailing: l10n.recipesGoalMatchTrailing,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: carouselHeight,
              child: ListView.separated(
                key: const ValueKey('recipe-goal-matches'),
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                itemCount: goalMatches.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final recipe = goalMatches[index];
                  return _RecipeHeroCard(
                    recipe: recipe,
                    badgeText: l10n.recipesGoalMatchBadge,
                    onTap: () => _openRecipe(recipe),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}
