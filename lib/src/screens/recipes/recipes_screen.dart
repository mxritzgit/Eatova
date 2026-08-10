/// Rezepte-Tab — als Bibliothek aus mehreren `part`-Dateien zusammengesetzt.
///
/// Rein mechanischer Split der frueheren ~1700-Zeilen-Datei: die kohaerenten
/// Widget-Gruppen liegen in den unten referenzierten `part of`-Dateien.
/// Importe + Sichtbarkeit (library-private `_`-Klassen) bleiben unveraendert,
/// kein Import-Site aendert sich (Einstieg bleibt [RecipesScreen]; der
/// oeffentliche [RecipeDetailScreen] lebt in recipe_detail.dart).
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
  ///
  /// Meldet zurueck, was mit dem Rezept WIRKLICH passiert ist (Luecke E) —
  /// daran haengt der Text der Erfolgsmeldung.
  final Future<SyncDelivery> Function(FitnessRecipe recipe)? onCreateRecipe;

  /// Optionaler Hook zum Loeschen eines Eigen-Rezepts (per slug). Wird vom
  /// Aufrufer an user_recipes.delete weitergereicht. Null → keine Persistenz.
  final Future<SyncDelivery> Function(String slug)? onDeleteRecipe;

  /// Beim Boot aus Supabase geladene Eigen-Rezepte. Werden als Anfangsstand
  /// uebernommen, damit selbst angelegte Rezepte einen Neustart ueberleben.
  final List<FitnessRecipe> initialUserRecipes;

  /// Quelle fuer das Rezept-Foto (Kamera/Galerie). Null → das echte
  /// [DeviceMealPhotoInput], das die Bytes bereits EXIF-frei zurueckgibt.
  /// Der Parameter existiert allein als Test-Naht — genau wie beim Food-Tab.
  final MealPhotoInput? photoInput;

  @override
  State<RecipesScreen> createState() => _RecipesScreenState();
}

class _RecipesScreenState extends State<RecipesScreen> {
  String selectedFilter = 'Alle';

  /// Suchtext. Haengt bewusst an einem eigenen Controller statt am internen
  /// State des [TextField]s (D6, Review 2026-08-08): der Screen ist eine lazy
  /// [ListView], das Suchfeld liegt darin ganz oben. Scrollt der User weit
  /// genug nach unten und ist das Feld nicht mehr fokussiert (die Liste nimmt
  /// den Fokus beim Ziehen selbst weg, `keyboardDismissBehavior`), raeumt die
  /// Liste das Element ab — mit ihm den `EditableText`-State und damit den
  /// getippten Text. Der Filter lief danach weiter, das Feld war aber leer.
  /// Mit eigenem Controller ueberlebt der Text das Recycling; zusammen mit
  /// einem am Leben gehaltenen Teilbaum (IndexedStack der Home-Schale) auch
  /// den Tab-Wechsel.
  final TextEditingController _searchController = TextEditingController();

  /// Spiegel von [_searchController].text, damit [filteredRecipes] den Wert
  /// synchron lesen kann.
  String query = '';

  /// Eigen-Rezepte: beim Boot aus user_recipes geladen + in dieser Session
  /// angelegte. Werden vorn an die Liste gestellt, damit der User sie sofort
  /// findet.
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

  /// Der Controller meldet auch reine Cursor-/Auswahl-Aenderungen — nur echte
  /// Textaenderungen sollen die Liste neu filtern.
  void _onSearchChanged() {
    if (_searchController.text == query) return;
    setState(() => query = _searchController.text);
  }

  @override
  void didUpdateWidget(covariant RecipesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Jeder neue Stand des Aufrufers wird uebernommen. Der Store weist seine
    // Rezeptliste bei jeder Mutation NEU zu, die Identitaetspruefung ist damit
    // ein exakter Fingerabdruck „hat sich etwas geaendert".
    //
    // Hier stand bis Luecke E ein `_locallyMutated`-Riegel: hatte der Nutzer in
    // dieser Sitzung EINMAL etwas angelegt oder geloescht, wurde nie wieder ein
    // Stand von aussen uebernommen. Der Riegel war noetig, solange
    // `_bootFromSupabase` `_userRecipes = loadedRecipes` setzte — ein spaet
    // eintreffender (oder offline leerer) Boot-Stand haette das frisch
    // angelegte Rezept sonst weggeworfen.
    //
    // Seit Luecke C MERGT der Boot, statt zu ersetzen: der nachgereichte Stand
    // enthaelt das eigene Rezept selbst, der Riegel schuetzt also nichts mehr
    // — er richtet Schaden an. Der teuerste Fall ist die Wiedereinblendung
    // nach einer endgueltig gescheiterten Loesch-Op
    // (`_restoreDroppedDeletes`): der Store holt den Eintrag zurueck und
    // meldet „der Eintrag ist wieder da", waehrend genau diese Loeschung den
    // Riegel gesetzt hatte — der Screen zeigte das Rezept nie wieder. Ebenso
    // blieben Rezepte eines ZWEITEN Geraets unsichtbar, sobald man hier einmal
    // etwas angelegt hatte.
    if (!identical(oldWidget.initialUserRecipes, widget.initialUserRecipes)) {
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
  Future<void> _deleteUserRecipe(FitnessRecipe recipe) async {
    setState(() {
      _userRecipes = _userRecipes
          .where((r) => r.slug != recipe.slug)
          .toList(growable: true);
    });
    // Das eigene Foto geht mit. Es ist PII (ein Kuechenfoto zeigt die
    // Wohnung) und haette sonst kein Ende: der Slug ist weg, niemand wuerde
    // die Datei je wieder anfassen. No-Op fuer Bestandsrezepte
    // (Bundle-Asset) und fuer Eigen-Rezepte ohne Bild.
    await RecipeImageStore.instance.deleteFor(recipe.imageAsset);
    final ausgang = await _melde(widget.onDeleteRecipe?.call(recipe.slug));
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

  /// Wartet auf den Ausgang eines Persistenz-Hooks. Ohne Hook (Vorschau/Test)
  /// gibt es nichts zu synchronisieren — dann gilt die Aktion als erledigt.
  Future<SyncDelivery> _melde(Future<SyncDelivery>? hook) async =>
      await hook ?? SyncDelivery.delivered;

  Future<void> _openCreateSheet() async {
    // Bewusst NICHT `showEatovaSheet`: das erzwingt `showDragHandle: true`, und
    // ein Zug AM GRIFF laeuft ueber `BottomSheet._handleDragEnd → Navigator.pop`
    // — also weder durch das `PopScope` noch durch den `_DiscardDragGuard` im
    // builder-Kind. Der D5-Verwerfen-Schutz haette damit ein stilles Loch.
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
    // Luecke E: die Meldung wartet auf den Ausgang, statt ihn zu behaupten.
    // Sie kommt spaetestens nach [kSyncDeliveryWindow] — der Store deckelt die
    // Wartezeit, weil ein Supabase-Write kein Timeout traegt.
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

    // Feste Karussell-Hoehe plus wachsende Schrift ist bei textScaler 2.0 ein
    // garantierter Overflow — dieselbe Technik nutzt `MacroBar` in der
    // Design-Bibliothek.
    final carouselHeight =
        MediaQuery.textScalerOf(context).scale(236).clamp(236.0, 430.0);

    // D6: Der PageStorageKey gibt der Liste eine stabile Identitaet im
    // PageStorage der Route. Die Scrollposition wird damit beim Verlassen des
    // Tabs gesichert und beim Zurueckkehren wiederhergestellt — auch dann,
    // wenn die Home-Schale den Teilbaum komplett neu aufbaut. Er sitzt auf
    // einem KeyedSubtree statt auf der ListView selbst, weil deren
    // ValueKey('screen-recipes') Testeinstieg mehrerer Suiten ist.
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
            title: selectedFilter == 'Alle'
                ? l10n.recipesAllTitle
                : selectedFilter,
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
          // Steht bewusst NACH der Hauptliste: so bleibt die erste Rezept-Kachel
          // im initialen Viewport (Test nutzt ensureVisible ohne vorheriges Scrollen).
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
