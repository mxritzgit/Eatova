/// Rezepte-Tab — als Bibliothek aus mehreren `part`-Dateien zusammengesetzt.
///
/// Rein mechanischer Split der frueheren ~1700-Zeilen-Datei: die kohaerenten
/// Widget-Gruppen liegen in den unten referenzierten `part of`-Dateien.
/// Importe + Sichtbarkeit (library-private `_`-Klassen) bleiben unveraendert,
/// kein Import-Site aendert sich (Einstieg bleibt [RecipesScreen]; der
/// oeffentliche [RecipeDetailScreen] lebt in recipe_detail.dart).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/fitness_recipe.dart';
import '../../models/logged_meal.dart';
import '../../models/macro_progress.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/user_profile.dart';
import '../../theme/app_colors.dart';
import '../../theme/meal_slot_style.dart';
import '../../widgets/common/app_snack.dart';

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
