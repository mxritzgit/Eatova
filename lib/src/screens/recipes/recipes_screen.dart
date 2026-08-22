/// Recipes tab — a library assembled from the `part` files below.
///
/// Mechanical split only; library-private `_` classes keep their visibility.
/// Entry point is [RecipesScreen]; the public [RecipeDetailScreen] lives in
/// recipe_detail.dart.
library;

import 'dart:io';

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

  /// Source for the recipe photo. Null uses the real [DeviceMealPhotoInput],
  /// which already returns EXIF-free bytes. Exists purely as a test seam.
  final MealPhotoInput? photoInput;

  @override
  State<RecipesScreen> createState() => _RecipesScreenState();
}

class _RecipesScreenState extends State<RecipesScreen> {
  String selectedFilter = 'Alle';

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

  @override
  void initState() {
    super.initState();
    _userRecipes = List<FitnessRecipe>.of(widget.initialUserRecipes);
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
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
    }
  }

  /// Built-in catalog for the ACTIVE app language. `context.l10n.localeName`
  /// is already resolved to `de`/`en`, and a language switch rebuilds
  /// automatically (`Localizations` is an InheritedWidget).
  List<FitnessRecipe> get _catalog =>
      recipeCatalogForLocale(context.l10n.localeName);

  List<FitnessRecipe> get _allRecipes =>
      <FitnessRecipe>[..._userRecipes, ..._catalog];

  List<FitnessRecipe> get filteredRecipes {
    final normalizedQuery = query.trim().toLowerCase();
    return _allRecipes.where((recipe) {
      final matchesFilter = selectedFilter == 'Alle' ||
          recipe.categories.contains(selectedFilter);
      final matchesQuery = normalizedQuery.isEmpty ||
          recipe.title.toLowerCase().contains(normalizedQuery) ||
          recipe.description.toLowerCase().contains(normalizedQuery) ||
          recipe.categories.any(
            (category) => category.toLowerCase().contains(normalizedQuery),
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

  /// Deletes a user recipe locally and, if wired, persistently via
  /// onDeleteRecipe(slug). Called from the detail screen.
  Future<void> _deleteUserRecipe(FitnessRecipe recipe) async {
    setState(() {
      _userRecipes = _userRecipes
          .where((r) => r.slug != recipe.slug)
          .toList(growable: true);
    });
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
    if (!mounted) return;
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
    // Recommendation carousel: diet pre-filtered (PROD-6), falling back to the
    // full list so the section never looks empty.
    final recommendedPool =
        _dietRecipes.isEmpty ? _allRecipes : _dietRecipes;
    final recommended = recommendedPool.take(4).toList(growable: false);
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
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              itemCount: recommended.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final recipe = recommended[index];
                return _RecipeHeroCard(
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
            title: selectedFilter == 'Alle'
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
