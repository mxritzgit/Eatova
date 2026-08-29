/// Recipes tab — a library assembled from the `part` files below.
///
/// Mechanical split only; library-private `_` classes keep their visibility.
/// Entry point is [RecipesScreen]; the public [RecipeDetailScreen] lives in
/// recipe_detail.dart.
library;

import 'dart:async';
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
  /// user_recipes (`HomeStore.userRecipesAuthoritative`). False means the list
  /// may still grow, and an entry missing from it says nothing.
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

class _RecipesScreenState extends State<RecipesScreen> {
  String selectedFilter = "Alle";

  /// Search text, deliberately on its own controller rather than the
  /// [TextField]'s internal state (D6, Review 2026-08-08): the screen is a
  /// lazy [ListView], so scrolling far enough recycles the unfocused field and
  /// would drop the typed text while the filter kept running.
  final TextEditingController _searchController = TextEditingController();

  /// Mirror of [_searchController].text so [filteredRecipes] can read it
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
  /// unfinished is.
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

  /// Built-in catalog for the ACTIVE app language. `context.l10n.localeName`
  /// is already resolved to `de`/`en`, and a language switch rebuilds
  /// automatically (`Localizations` is an InheritedWidget).
  List<FitnessRecipe> get _catalog =>
      recipeCatalogForLocale(context.l10n.localeName);

  /// User recipes minus those inside an undo window.
  List<FitnessRecipe> get _visibleUserRecipes => _userRecipes
      .where((r) => !_pendingDeletes.containsKey(r.slug))
      .toList(growable: false);

  List<FitnessRecipe> get _allRecipes =>
      <FitnessRecipe>[..._visibleUserRecipes, ..._catalog];

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

  List<FitnessRecipe> get filteredRecipes {
    final l10n = context.l10n;
    final normalizedQuery = foldRecipeSearchText(query.trim());
    bool hit(String text) =>
        foldRecipeSearchText(text).contains(normalizedQuery);
    return _allRecipes.where((recipe) {
      final matchesFilter = switch (selectedFilter) {
        "Alle" => true,
        "Eigene" => recipe.userCreated,
        _ => recipe.categories.contains(selectedFilter),
      };
      // Categories match on the neutral identity AND on the localised label:
      // under `en` the hint promises "category", so "breakfast" must find the
      // recipes tagged "Frühstück".
      final matchesQuery = normalizedQuery.isEmpty ||
          hit(recipe.title) ||
          hit(recipe.description) ||
          hit(recipe.ingredients) ||
          recipe.categories.any(
            (category) =>
                hit(category) || hit(recipeCategoryLabel(category, l10n)),
          );
      return matchesFilter && matchesQuery;
    }).toList(growable: false);
  }

  /// Actively promoted recipes: the full list pre-filtered by diet preference
  /// (PROD-6). Feeds carousel and goal matches; the main list stays
  /// unfiltered.
  List<FitnessRecipe> get _dietRecipes => _allRecipes
      .where((r) => r.matchesDiet(widget.diet))
      .toList(growable: false);

  /// Up to three recipes with the highest macro match; only scores above 0
  /// count. The diet pre-filter runs before the ranking.
  List<FitnessRecipe> _goalMatches(MacroProgress remaining) {
    final scored = _dietRecipes
        .map((r) => (r, r.matchScore(remaining)))
        .where((pair) => pair.$2 > 0)
        .toList(growable: false)
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return scored.take(3).map((pair) => pair.$1).toList(growable: false);
  }

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
    final visibleRecipes = filteredRecipes;
    // Recommendation carousel: catalog only (an own recipe with a placeholder
    // stripe is no "recommendation"), diet pre-filtered (PROD-6) with a
    // fallback to the whole catalog so the section never looks empty, and
    // rotated by calendar day so it is not the same four cards forever.
    final catalogPool = _catalog
        .where((r) => r.matchesDiet(widget.diet))
        .toList(growable: false);
    final recommended = rotatedRecommendations(
      catalogPool.isEmpty ? _catalog : catalogPool,
      clock.now(),
    );
    final remaining = widget.remainingMacros;
    final goalMatches = remaining == null
        ? const <FitnessRecipe>[]
        : _goalMatches(remaining);

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
            trailing: l10n.recipesFitnessDishesCount(_allRecipes.length),
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
