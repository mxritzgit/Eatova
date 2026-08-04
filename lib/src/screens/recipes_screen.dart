import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/fitness_recipe.dart';
import '../models/logged_meal.dart';
import '../models/macro_progress.dart';
import '../models/meal_analysis_result.dart';
import '../models/user_profile.dart';
import '../theme/app_colors.dart';
import '../theme/meal_slot_style.dart';
import '../widgets/common/app_snack.dart';

class RecipesScreen extends StatefulWidget {
  const RecipesScreen({
    super.key,
    required this.onAddMeal,
    this.remainingMacros,
    this.diet = DietPreference.none,
    this.onCreateRecipe,
    this.onDeleteRecipe,
    this.initialUserRecipes = const <FitnessRecipe>[],
  });

  final void Function(MealAnalysisResult result, MealSlot slot) onAddMeal;

  /// Noch offene Tagesmakros (Ziel minus verbraucht). Wenn gesetzt, blendet
  /// der Screen eine „Passt zu deinem Ziel"-Sektion ein, die die Rezepte nach
  /// Makro-Match rankt. Null → Sektion ausgeblendet (Tests ohne den Param
  /// bleiben grün).
  final MacroProgress? remainingMacros;

  /// Ernährungspräferenz des Users (PROD-6). Filtert die aktiv beworbenen
  /// Listen — Empfehlungs-Carousel + „Passt zu deinem Ziel" — VOR dem
  /// Makro-Ranking, damit kein diät-/präferenz-verletzendes Rezept empfohlen
  /// wird. Die Hauptliste + Kategorie-Filter bleiben unangetastet: der User
  /// kann jedes Rezept weiterhin manuell durchsuchen. Default
  /// [DietPreference.none] (empfiehlt alles → Bestands-Tests bleiben grün).
  final DietPreference diet;

  /// Optionaler Hook, mit dem ein selbst angelegtes Rezept an den
  /// Aufrufer gemeldet wird (persistiert via user_recipes). Null → das
  /// Rezept lebt nur lokal in dieser Session.
  final ValueChanged<FitnessRecipe>? onCreateRecipe;

  /// Optionaler Hook zum Loeschen eines Eigen-Rezepts (per slug). Wird vom
  /// Aufrufer an user_recipes.delete weitergereicht. Null → keine Persistenz.
  final ValueChanged<String>? onDeleteRecipe;

  /// Beim Boot aus Supabase geladene Eigen-Rezepte. Werden als Anfangsstand
  /// uebernommen, damit selbst angelegte Rezepte einen Neustart ueberleben.
  final List<FitnessRecipe> initialUserRecipes;

  @override
  State<RecipesScreen> createState() => _RecipesScreenState();
}

class _RecipesScreenState extends State<RecipesScreen> {
  String selectedFilter = 'Alle';
  String query = '';

  /// Eigen-Rezepte: beim Boot aus user_recipes geladen + in dieser Session
  /// angelegte. Werden vorn an die Liste gestellt, damit der User sie sofort
  /// findet.
  late List<FitnessRecipe> _userRecipes;

  /// True, sobald der User in dieser Session selbst etwas angelegt/geloescht
  /// hat. Dann darf ein spaeter nachgeladener Boot-Stand die lokale Liste
  /// NICHT mehr ueberschreiben.
  bool _locallyMutated = false;

  @override
  void initState() {
    super.initState();
    _userRecipes = List<FitnessRecipe>.of(widget.initialUserRecipes);
  }

  @override
  void didUpdateWidget(covariant RecipesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Boot laedt die Eigen-Rezepte ggf. NACH dem ersten Build nach (async).
    // Solange der User in dieser Session noch nichts selbst geaendert hat,
    // den frisch geladenen Stand uebernehmen; sonst lokale Aenderungen
    // (neu erstellt/geloescht) NICHT ueberschreiben.
    if (!_locallyMutated &&
        !identical(oldWidget.initialUserRecipes, widget.initialUserRecipes)) {
      _userRecipes = List<FitnessRecipe>.of(widget.initialUserRecipes);
    }
  }

  List<FitnessRecipe> get _allRecipes =>
      <FitnessRecipe>[..._userRecipes, ...fitnessRecipes];

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

  /// Aktiv beworbene Rezepte = die volle Liste, vorab nach der
  /// Ernährungspräferenz gefiltert (PROD-6). Speist Empfehlungs-Carousel +
  /// Ziel-Matches; die Hauptliste + Kategorie-Filter bleiben ungefiltert.
  List<FitnessRecipe> get _dietRecipes => _allRecipes
      .where((r) => r.matchesDiet(widget.diet))
      .toList(growable: false);

  /// Bis zu drei Rezepte mit dem höchsten Makro-Match zu den Restmakros.
  /// Nur sinnvolle Treffer (>0) werden aufgenommen. Diät-Vorfilter läuft VOR
  /// dem Makro-Ranking, damit nie ein präferenz-verletzendes Rezept rankt.
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
          // Loeschen nur fuer selbst angelegte Rezepte anbieten.
          onDelete: recipe.userCreated ? () => _deleteUserRecipe(recipe) : null,
        ),
      ),
    );
  }

  /// Loescht ein Eigen-Rezept lokal + (falls verdrahtet) persistent via
  /// onDeleteRecipe(slug). Wird aus dem Detail-Screen heraus aufgerufen.
  void _deleteUserRecipe(FitnessRecipe recipe) {
    setState(() {
      _userRecipes = _userRecipes
          .where((r) => r.slug != recipe.slug)
          .toList(growable: true);
      _locallyMutated = true;
    });
    widget.onDeleteRecipe?.call(recipe.slug);
    if (mounted) {
      showAppSnack(context, '„${recipe.title}" gelöscht.',
          icon: Icons.delete_outline_rounded, accent: danger);
    }
  }

  Future<void> _openCreateSheet() async {
    final recipe = await showModalBottomSheet<FitnessRecipe>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (_) => const _CreateRecipeSheet(),
    );
    if (recipe == null || !mounted) return;
    setState(() {
      _userRecipes.insert(0, recipe);
      _locallyMutated = true;
    });
    widget.onCreateRecipe?.call(recipe);
    showAppSnack(context, '„${recipe.title}" gespeichert.',
        icon: Icons.bookmark_added_rounded, accent: forgeLime);
  }

  @override
  Widget build(BuildContext context) {
    final visibleRecipes = filteredRecipes;
    // Empfehlungs-Carousel: diät-vorgefiltert (PROD-6). Fallback auf die volle
    // Liste, falls die Präferenz keinerlei Kuratier-Rezepte übrig lässt, damit
    // die Sektion nie leer wirkt.
    final recommendedPool =
        _dietRecipes.isEmpty ? _allRecipes : _dietRecipes;
    final recommended = recommendedPool.take(4).toList(growable: false);
    final remaining = widget.remainingMacros;
    final goalMatches = remaining == null
        ? const <FitnessRecipe>[]
        : _goalMatches(remaining);

    return ListView(
      key: const ValueKey('screen-recipes'),
      padding: const EdgeInsets.only(bottom: 28),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        _RecipesHeader(onCreate: _openCreateSheet),
        const SizedBox(height: 18),
        _RecipeSearchField(onChanged: (value) => setState(() => query = value)),
        const SizedBox(height: 16),
        _RecipeFilterChips(
          selected: selectedFilter,
          onSelected: (filter) => setState(() => selectedFilter = filter),
        ),
        const SizedBox(height: 24),
        _SectionHeader(
          title: 'Empfehlungen',
          subtitle: '${_allRecipes.length} Fitness-Gerichte',
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 256,
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
        const SizedBox(height: 26),
        _SectionHeader(
          title: selectedFilter == 'Alle' ? 'Alle Rezepte' : selectedFilter,
          subtitle: '${visibleRecipes.length} Treffer',
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < visibleRecipes.length; i++) ...[
          _RecipeListTile(
            key: ValueKey('recipe-tile-${visibleRecipes[i].slug}'),
            recipe: visibleRecipes[i],
            onTap: () => _openRecipe(visibleRecipes[i]),
          ),
          if (i != visibleRecipes.length - 1) const SizedBox(height: 10),
        ],
        if (visibleRecipes.isEmpty) const _RecipeEmptyState(),
        // Steht bewusst NACH der Hauptliste: so bleibt die erste Rezept-Kachel
        // im initialen Viewport (Test nutzt ensureVisible ohne vorheriges Scrollen).
        if (goalMatches.isNotEmpty) ...[
          const SizedBox(height: 26),
          const _SectionHeader(
            title: 'Passt zu deinem Ziel',
            subtitle: 'nach Restmakros',
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 256,
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
                  badgeText: 'Match',
                  onTap: () => _openRecipe(recipe),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

class _RecipesHeader extends StatelessWidget {
  const _RecipesHeader({this.onCreate});

  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Rezepte',
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 28,
                  height: 1.08,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1.0,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Clean Meals mit echten Bildern und Tracker-Werten.',
                style: TextStyle(
                  color: textMuted.withValues(alpha: 0.92),
                  fontSize: 13,
                  height: 1.45,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        if (onCreate != null)
          InkWell(
            key: const ValueKey('recipe-create-button'),
            onTap: onCreate,
            borderRadius: BorderRadius.circular(rCard),
            child: Container(
              width: 42,
              height: 42,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                color: lime.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(rCard),
                border: Border.all(color: lime.withValues(alpha: 0.36)),
              ),
              child: const Icon(Icons.add_rounded, color: lime, size: 22),
            ),
          ),
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(rCard),
            border: Border.all(color: hairline),
          ),
          child: const Icon(Icons.menu_book_rounded, color: lime, size: 21),
        ),
      ],
    );
  }
}

class _RecipeSearchField extends StatelessWidget {
  const _RecipeSearchField({required this.onChanged});

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: hairline),
      ),
      child: TextField(
        key: const ValueKey('recipes-search-input'),
        cursorOpacityAnimates: false,
        onChanged: onChanged,
        style: const TextStyle(color: textPrimary, fontSize: 14),
        cursorColor: lime,
        decoration: const InputDecoration(
          border: InputBorder.none,
          prefixIcon: Icon(Icons.search_rounded, color: textMuted, size: 20),
          hintText: 'Gericht, Ziel oder Kategorie suchen',
          hintStyle: TextStyle(color: textMuted, fontSize: 13),
          contentPadding: EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }
}

class _RecipeFilterChips extends StatelessWidget {
  const _RecipeFilterChips({
    required this.selected,
    required this.onSelected,
  });

  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: recipeFilters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final filter = recipeFilters[index];
          final active = selected == filter;
          return InkWell(
            key: ValueKey('recipe-filter-$filter'),
            onTap: () => onSelected(filter),
            borderRadius: BorderRadius.circular(rPill),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active ? lime : surface,
                borderRadius: BorderRadius.circular(rPill),
                border: Border.all(color: active ? lime : hairline),
              ),
              child: Text(
                filter,
                style: TextStyle(
                  color: active ? bg : textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              color: textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          subtitle,
          style: const TextStyle(
            color: textMuted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _RecipeHeroCard extends StatelessWidget {
  const _RecipeHeroCard({
    required this.recipe,
    required this.onTap,
    this.badgeText,
  });

  final FitnessRecipe recipe;
  final VoidCallback onTap;

  /// Optionales zweites Badge oben rechts (z.B. „Match" in der Ziel-Sektion).
  final String? badgeText;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(rSheet),
      child: SizedBox(
        width: 200,
        child: Container(
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(rSheet),
            border: Border.all(color: hairline),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  SizedBox(
                    height: 132,
                    width: double.infinity,
                    child: _RecipeImage(recipe: recipe),
                  ),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.55),
                          ],
                          stops: const [0.45, 1.0],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 10,
                    top: 10,
                    child: _GlassBadge(text: '${recipe.caloriesKcal} kcal'),
                  ),
                  if (badgeText != null)
                    Positioned(
                      right: 10,
                      top: 10,
                      child: _MatchBadge(text: badgeText!),
                    ),
                  if (recipe.categories.isNotEmpty)
                    Positioned(
                      left: 10,
                      bottom: 10,
                      child: _CategoryPill(
                        label: recipe.categories.first,
                        onImage: true,
                      ),
                    ),
                ],
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        recipe.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: textPrimary,
                          fontSize: 15,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        recipe.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: textMuted,
                          fontSize: 11.5,
                          height: 1.32,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const Spacer(),
                      _MacroRow(recipe: recipe, compact: true),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecipeListTile extends StatelessWidget {
  const _RecipeListTile({
    super.key,
    required this.recipe,
    required this.onTap,
  });

  final FitnessRecipe recipe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(rCard),
      child: Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(color: hairline),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(rControl),
                  child: SizedBox(
                    width: 84,
                    height: 84,
                    child: _RecipeImage(recipe: recipe),
                  ),
                ),
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: _GlassBadge(text: '${recipe.caloriesKcal} kcal'),
                ),
              ],
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          recipe.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: textPrimary,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.15,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: textMuted,
                        size: 20,
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    recipe.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: textMuted,
                      fontSize: 11.5,
                      height: 1.3,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 9),
                  _MacroRow(recipe: recipe),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RecipeDetailScreen extends StatelessWidget {
  const RecipeDetailScreen({
    super.key,
    required this.recipe,
    required this.onAddMeal,
    this.onDelete,
  });

  final FitnessRecipe recipe;
  final void Function(MealAnalysisResult result, MealSlot slot) onAddMeal;

  /// Optionaler Loeschen-Hook (nur fuer Eigen-Rezepte gesetzt). Schliesst den
  /// Detail-Screen und meldet die Loeschung an den Aufrufer.
  final VoidCallback? onDelete;

  Future<void> _showMealPicker(BuildContext context) async {
    final slot = await showModalBottomSheet<MealSlot>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.62),
      isScrollControlled: true,
      builder: (sheetContext) => _MealSlotPickerSheet(recipe: recipe),
    );
    if (!context.mounted || slot == null) return;
    _add(context, slot);
  }

  void _add(BuildContext context, MealSlot slot) {
    onAddMeal(recipe.toMealResult(), slot);
    showAppSnack(
      context,
      '${recipe.caloriesKcal} kcal zu ${slot.label} hinzugefügt.',
      icon: Icons.check_circle_rounded,
      accent: lime,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          key: const ValueKey('recipe-detail-scroll'),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _RoundIconButton(
                    key: const ValueKey('recipe-detail-back'),
                    icon: Icons.arrow_back_rounded,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const Spacer(),
                  if (onDelete != null) ...[
                    _RoundIconButton(
                      key: const ValueKey('recipe-detail-delete'),
                      icon: Icons.delete_outline_rounded,
                      iconColor: danger,
                      onTap: () {
                        Navigator.of(context).pop();
                        onDelete!();
                      },
                    ),
                    const SizedBox(width: 10),
                  ],
                  _GlassBadge(
                    text: recipe.userCreated ? 'Eigenes Rezept' : 'Eatova Rezept',
                    dark: true,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(rSheet),
                child: SizedBox(
                  height: 258,
                  width: double.infinity,
                  child: _RecipeImage(recipe: recipe),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                recipe.title,
                key: ValueKey('recipe-detail-${recipe.slug}'),
                style: const TextStyle(
                  color: textPrimary,
                  fontSize: 28,
                  height: 1.08,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1.0,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                recipe.description,
                style: const TextStyle(
                  color: textMuted,
                  fontSize: 14,
                  height: 1.45,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (recipe.categories.isNotEmpty) ...[
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final category in recipe.categories)
                      _CategoryPill(label: category),
                  ],
                ),
              ],
              const SizedBox(height: 18),
              _NutritionGrid(recipe: recipe),
              const SizedBox(height: 18),
              _AddToMealCard(
                recipe: recipe,
                onTap: () => _showMealPicker(context),
              ),
              const SizedBox(height: 18),
              _RecipeInfoSection(title: 'Portion', body: recipe.portion),
              _RecipeInfoSection(title: 'Zutaten', body: recipe.ingredients),
              _RecipeInfoSection(title: 'Zubereitung', body: recipe.preparation),
              _RecipeInfoSection(
                title: 'Profi-Hinweis',
                body: recipe.professionalHint,
                accent: lime,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddToMealCard extends StatelessWidget {
  const _AddToMealCard({required this.recipe, required this.onTap});

  final FitnessRecipe recipe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('recipe-add-card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(rSheet),
        border: Border.all(color: lime.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: lime.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(rControl),
                ),
                child: const Icon(Icons.add_rounded, color: lime, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Zum Tracker hinzufügen',
                      style: TextStyle(
                        color: textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${recipe.caloriesKcal} kcal · ${recipe.proteinG} g Protein',
                      style: const TextStyle(
                        color: textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              key: const ValueKey('recipe-add-button'),
              onPressed: onTap,
              style: ElevatedButton.styleFrom(
                backgroundColor: lime,
                foregroundColor: bg,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(rCard),
                ),
              ),
              icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
              label: const Text(
                'Hinzufügen',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.1,
                ),
              ),
            ),
          ),
          const SizedBox(height: 9),
          const Text(
            'Danach wählst du Frühstück, Mittagessen, Abendessen oder Snack.',
            style: TextStyle(color: textMuted, fontSize: 11.5, height: 1.35),
          ),
        ],
      ),
    );
  }
}

class _MealSlotPickerSheet extends StatelessWidget {
  const _MealSlotPickerSheet({required this.recipe});

  final FitnessRecipe recipe;

  @override
  Widget build(BuildContext context) {
    const slots = <MealSlot>[
      MealSlot.breakfast,
      MealSlot.lunch,
      MealSlot.dinner,
      MealSlot.snack,
    ];

    return SafeArea(
      top: false,
      child: Container(
        key: const ValueKey('recipe-meal-picker-sheet'),
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(rSheet),
          border: Border.all(color: hairline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: hairline,
                  borderRadius: BorderRadius.circular(rPill),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(rCard),
                  child: SizedBox(
                    width: 58,
                    height: 58,
                    child: _RecipeImage(recipe: recipe),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Wann eintragen?',
                        style: TextStyle(
                          color: textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${recipe.caloriesKcal} kcal · ${recipe.proteinG} g Protein',
                        style: const TextStyle(
                          color: textMuted,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < slots.length; i++) ...[
              _MealSlotButton(
                slot: slots[i],
                onTap: () => Navigator.of(context).pop(slots[i]),
              ),
              if (i != slots.length - 1) const SizedBox(height: 9),
            ],
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: TextButton(
                key: const ValueKey('recipe-meal-picker-cancel'),
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(
                  foregroundColor: textMuted,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(rCard),
                  ),
                ),
                child: const Text(
                  'Abbrechen',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MealSlotButton extends StatelessWidget {
  const _MealSlotButton({required this.slot, required this.onTap});

  final MealSlot slot;
  final VoidCallback onTap;

  Color get color => slot.accent;

  IconData get icon => slot.icon;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey('recipe-meal-picker-${slot.name}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(rCard),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(color: color.withValues(alpha: 0.36)),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.18),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                slot.label,
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.1,
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: color, size: 20),
          ],
        ),
      ),
    );
  }
}

class _NutritionGrid extends StatelessWidget {
  const _NutritionGrid({required this.recipe});

  final FitnessRecipe recipe;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _NutritionTile(label: 'Kcal', value: '${recipe.caloriesKcal}', color: lime)),
        const SizedBox(width: 8),
        Expanded(child: _NutritionTile(label: 'Protein', value: '${recipe.proteinG} g', color: orange)),
        const SizedBox(width: 8),
        Expanded(child: _NutritionTile(label: 'KH', value: '${recipe.carbsG} g', color: cyan)),
        const SizedBox(width: 8),
        Expanded(child: _NutritionTile(label: 'Fett', value: '${recipe.fatG} g', color: macroFat)),
      ],
    );
  }
}

class _NutritionTile extends StatelessWidget {
  const _NutritionTile({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: hairline),
      ),
      child: Column(
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.25,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: textMuted,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecipeInfoSection extends StatelessWidget {
  const _RecipeInfoSection({
    required this.title,
    required this.body,
    this.accent = cyan,
  });

  final String title;
  final String body;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(rSheet),
          border: Border.all(color: hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    color: textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              body,
              style: const TextStyle(
                color: textMuted,
                fontSize: 13,
                height: 1.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlassBadge extends StatelessWidget {
  const _GlassBadge({required this.text, this.dark = false});

  final String text;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: dark ? surface : Colors.black.withValues(alpha: 0.48),
        borderRadius: BorderRadius.circular(rPill),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: textPrimary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.1,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Lime-getöntes Badge oben rechts auf der „Passt zu deinem Ziel"-Karte.
class _MatchBadge extends StatelessWidget {
  const _MatchBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: lime,
        borderRadius: BorderRadius.circular(rPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.bolt_rounded, color: bg, size: 12),
          const SizedBox(width: 3),
          Text(
            text,
            style: const TextStyle(
              color: bg,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Kompakte Kategorie-Pille. Auf dem Bild (onImage) dunkel-transluzent, sonst
/// lime-getönt — nutzt dieselbe Token-Skala wie der Rest des Screens.
class _CategoryPill extends StatelessWidget {
  const _CategoryPill({required this.label, this.onImage = false});

  final String label;
  final bool onImage;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: onImage
            ? Colors.black.withValues(alpha: 0.5)
            : lime.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(rPill),
        border: Border.all(
          color: onImage
              ? Colors.white.withValues(alpha: 0.18)
              : lime.withValues(alpha: 0.3),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: onImage ? textPrimary : lime,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}

/// Bild für eine Rezept-Karte. Asset-Rezepte zeigen ihr PNG, selbst angelegte
/// Rezepte (ohne Asset) bekommen einen ruhigen lime-getönten Platzhalter.
class _RecipeImage extends StatelessWidget {
  const _RecipeImage({required this.recipe});

  final FitnessRecipe recipe;

  @override
  Widget build(BuildContext context) {
    if (recipe.userCreated || recipe.imageAsset.isEmpty) {
      return Container(
        color: surfaceSoft,
        alignment: Alignment.center,
        child: const Icon(
          Icons.ramen_dining_outlined,
          color: lime,
          size: 30,
        ),
      );
    }
    // Decode-Auflösung an die tatsächliche Slot-Breite koppeln: die Rezept-PNGs
    // sind ~1800px/2.4MB groß und würden sonst voll dekodiert (Hero, Liste,
    // Picker, Detail teilen sich dieses Widget bei sehr unterschiedlicher Größe).
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final logicalWidth =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 400.0;
        return Image.asset(
          recipe.imageAsset,
          fit: BoxFit.cover,
          cacheWidth: (logicalWidth * dpr).round().clamp(1, 1600),
        );
      },
    );
  }
}

class _MacroRow extends StatelessWidget {
  const _MacroRow({required this.recipe, this.compact = false});

  final FitnessRecipe recipe;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final fontSize = compact ? 10.5 : 11.2;
    const tabular = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);
    // FittedBox laesst die Makro-Zeile bei dreistelligen Werten in der schmalen
    // Hero-Kachel proportional schrumpfen statt rechts ueberzulaufen; passt sie,
    // bleibt die Darstellung pixelgenau identisch.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Text(
            '${recipe.proteinG}g P',
            style: tabular.copyWith(
              color: lime,
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${recipe.carbsG}g KH',
            style: tabular.copyWith(
              color: textMuted,
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${recipe.fatG}g F',
            style: tabular.copyWith(
              color: textMuted,
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.iconColor = textPrimary,
  });

  final IconData icon;
  final VoidCallback onTap;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(rCard),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(color: hairline),
        ),
        child: Icon(icon, color: iconColor, size: 20),
      ),
    );
  }
}

class _RecipeEmptyState extends StatelessWidget {
  const _RecipeEmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: hairline),
      ),
      child: const Text(
        'Kein Rezept gefunden. Versuch eine andere Kategorie oder Suche.',
        style: TextStyle(color: textMuted, fontSize: 13, height: 1.4),
      ),
    );
  }
}

/// Bottom-Sheet zum Anlegen eines eigenen Rezepts (Name, Portion, Makros,
/// Zutaten). Gibt beim Speichern ein [FitnessRecipe] via Navigator.pop zurück.
class _CreateRecipeSheet extends StatefulWidget {
  const _CreateRecipeSheet();

  @override
  State<_CreateRecipeSheet> createState() => _CreateRecipeSheetState();
}

class _CreateRecipeSheetState extends State<_CreateRecipeSheet> {
  final _name = TextEditingController();
  final _portion = TextEditingController(text: '1 Portion');
  final _grams = TextEditingController(text: '300');
  final _kcal = TextEditingController();
  final _protein = TextEditingController();
  final _carbs = TextEditingController();
  final _fat = TextEditingController();
  final _ingredients = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _portion.dispose();
    _grams.dispose();
    _kcal.dispose();
    _protein.dispose();
    _carbs.dispose();
    _fat.dispose();
    _ingredients.dispose();
    super.dispose();
  }

  bool get _isValid {
    final kcal = int.tryParse(_kcal.text.trim());
    return _name.text.trim().isNotEmpty && kcal != null && kcal > 0;
  }

  void _save() {
    final name = _name.text.trim();
    final kcal = int.tryParse(_kcal.text.trim()) ?? 0;
    if (name.isEmpty || kcal <= 0) return;
    final grams = int.tryParse(_grams.text.trim()) ?? 0;
    final ingredients = _ingredients.text.trim();
    final portion = _portion.text.trim().isEmpty
        ? '1 Portion'
        : _portion.text.trim();
    final slug = 'user_${DateTime.now().millisecondsSinceEpoch}';

    Navigator.of(context).pop(
      FitnessRecipe(
        slug: slug,
        title: name,
        description: 'Eigenes Rezept',
        portion: portion,
        ingredients: ingredients.isEmpty ? 'Keine Angabe' : ingredients,
        preparation: 'Eigenes Rezept — keine Zubereitung hinterlegt.',
        professionalHint: 'Selbst angelegt. Werte beruhen auf deinen Angaben.',
        imageAsset: '',
        caloriesKcal: kcal,
        proteinG: int.tryParse(_protein.text.trim()) ?? 0,
        carbsG: int.tryParse(_carbs.text.trim()) ?? 0,
        fatG: int.tryParse(_fat.text.trim()) ?? 0,
        estimatedGrams: grams > 0 ? grams : 100,
        categories: const <String>['Eigene'],
        userCreated: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: Container(
        key: const ValueKey('recipe-create-sheet'),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.92,
        ),
        decoration: const BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(rSheet)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: hairline,
                    borderRadius: BorderRadius.circular(rPill),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Eigenes Rezept',
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Name und Kalorien genügen — Makros sind optional.',
                style: TextStyle(
                  color: textMuted,
                  fontSize: 12.5,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 18),
              _Field(
                fieldKey: const ValueKey('recipe-create-name'),
                controller: _name,
                label: 'Name',
                hint: 'z. B. Protein-Bowl',
                onChanged: () => setState(() {}),
              ),
              const SizedBox(height: 12),
              _Field(
                fieldKey: const ValueKey('recipe-create-portion'),
                controller: _portion,
                label: 'Portion',
                hint: '1 Teller',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _Field(
                      fieldKey: const ValueKey('recipe-create-kcal'),
                      controller: _kcal,
                      label: 'Kalorien',
                      suffix: 'kcal',
                      numeric: true,
                      onChanged: () => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Field(
                      fieldKey: const ValueKey('recipe-create-grams'),
                      controller: _grams,
                      label: 'Gewicht',
                      suffix: 'g',
                      numeric: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _Field(
                      fieldKey: const ValueKey('recipe-create-protein'),
                      controller: _protein,
                      label: 'Protein',
                      suffix: 'g',
                      numeric: true,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Field(
                      fieldKey: const ValueKey('recipe-create-carbs'),
                      controller: _carbs,
                      label: 'KH',
                      suffix: 'g',
                      numeric: true,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Field(
                      fieldKey: const ValueKey('recipe-create-fat'),
                      controller: _fat,
                      label: 'Fett',
                      suffix: 'g',
                      numeric: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _Field(
                fieldKey: const ValueKey('recipe-create-ingredients'),
                controller: _ingredients,
                label: 'Zutaten',
                hint: 'Eine Zutat pro Zeile',
                maxLines: 4,
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton.icon(
                  key: const ValueKey('recipe-create-save'),
                  onPressed: _isValid ? _save : null,
                  icon: const Icon(Icons.check_rounded, size: 19),
                  label: const Text(
                    'Rezept speichern',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.1,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: lime,
                    foregroundColor: bg,
                    disabledBackgroundColor: surfaceSoft,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(rControl),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.fieldKey,
    required this.controller,
    required this.label,
    this.hint,
    this.suffix,
    this.numeric = false,
    this.maxLines = 1,
    this.onChanged,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? suffix;
  final bool numeric;
  final int maxLines;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: fieldKey,
      cursorOpacityAnimates: false,
      controller: controller,
      maxLines: maxLines,
      keyboardType: numeric ? TextInputType.number : TextInputType.text,
      inputFormatters:
          numeric ? [FilteringTextInputFormatter.digitsOnly] : null,
      textCapitalization: numeric
          ? TextCapitalization.none
          : TextCapitalization.sentences,
      style: const TextStyle(color: textPrimary, fontSize: 14),
      cursorColor: lime,
      onChanged: onChanged == null ? null : (_) => onChanged!(),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixText: suffix,
      ),
    );
  }
}
