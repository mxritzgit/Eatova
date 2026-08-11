part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Kopfbereich der Rezeptliste: Seitentitel + Anlegen-Knopf, Suchfeld und die
// waagerechte Kategorie-Filter-Leiste.
// ---------------------------------------------------------------------------
class _RecipesHeader extends StatelessWidget {
  const _RecipesHeader({this.onCreate});

  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ScreenTitle(
      title: l10n.navRecipes,
      subtitle: l10n.recipesSubtitle,
      trailing: onCreate == null
          ? null
          : SquareIconButton(
              key: const ValueKey('recipe-create-button'),
              icon: Icons.add_rounded,
              onTap: onCreate,
              semanticLabel: l10n.recipesCreateSemantics,
            ),
    );
  }
}

/// Suchkapsel in der Sprache der Vorlage (`SearchBarField`), hier lokal
/// nachgebaut: die Design-Bibliothek hat das Widget (noch) nicht, und der
/// [ValueKey] muss zwingend DIREKT auf dem [TextField] sitzen —
/// test/home_page_tabs_test.dart castet darauf.
class _RecipeSearchField extends StatelessWidget {
  const _RecipeSearchField({required this.controller, required this.onClear});

  /// Gehoert dem [_RecipesScreenState] (dort erzeugt und entsorgt). Ohne
  /// eigenen Controller laege der Text nur im `EditableText`-State und waere
  /// weg, sobald die lazy Liste das Feld beim Scrollen abraeumt (D6).
  final TextEditingController controller;

  /// Leert Suchtext und damit den Textfilter.
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      // Abweichung von der Vorlage (`height: 48`): eine feste Hoehe plus
      // wachsende Schrift ist ein garantierter Overflow.
      constraints: const BoxConstraints(minHeight: 48),
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.line),
      ),
      child: TextField(
        key: const ValueKey('recipes-search-input'),
        controller: controller,
        cursorOpacityAnimates: false,
        style: AppType.ui(14, color: t.ink),
        // Abweichung von der Vorlage (`cursorColor: t.forest`): `forest` ist
        // im Dunkelmodus eine dunkle FLAECHE — der Cursor waere auf `surf`
        // praktisch unsichtbar. `accent` ist der Tinten-Zwilling dazu.
        cursorColor: t.accent,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          // Waagerechter Anteil 1:1 aus der Vorlage — ohne ihn klebte der Text
          // an der Lupe und (mit Loesch-X) am rechten Rand.
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
          prefixIcon: Icon(Icons.search_rounded, size: 18, color: t.ink2),
          prefixIconConstraints: const BoxConstraints(minWidth: 44),
          hintText: context.l10n.recipesSearchHint,
          hintStyle: AppType.ui(14, color: t.ink2),
          // Der Suchtext bleibt jetzt ueber Scrollen und Tab-Wechsel stehen —
          // dann muss der User ihn auch sichtbar wieder loswerden koennen.
          // (Der Kategorie-Filter hat dafuer seinen „Alle"-Chip.)
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              if (value.text.isEmpty) return const SizedBox.shrink();
              return IconButton(
                key: const ValueKey('recipes-search-clear'),
                onPressed: onClear,
                tooltip: context.l10n.recipesSearchClearTooltip,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(
                  minWidth: 44,
                  minHeight: 44,
                ),
                icon: Icon(Icons.close_rounded, color: t.ink2, size: 18),
              );
            },
          ),
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
    final l10n = context.l10n;
    return SizedBox(
      // Die Leiste waechst mit der Schrift mit, statt bei 38 px zu reissen.
      // Gedeckelt, damit sie bei doppelter Schrift nicht den halben Screen
      // frisst.
      height: MediaQuery.textScalerOf(context).scale(38).clamp(38.0, 80.0),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: recipeFilters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final filter = recipeFilters[index];
          // Die Leiste gibt ihren Kindern eine feste Hoehe; `Center` laesst
          // dem Chip seine natuerliche Groesse und haelt ihn mittig.
          // `key`/`onTap`/`selected` haengen weiter am NEUTRALEN `filter`-
          // Wert (Logik-Identitaet); nur das sichtbare `label` laeuft ueber
          // die ARB (recipeCategoryLabel, Inhalte-PR).
          return Center(
            child: FilterChipPill(
              key: ValueKey('recipe-filter-$filter'),
              label: recipeCategoryLabel(filter, l10n),
              selected: selected == filter,
              onTap: () => onSelected(filter),
            ),
          );
        },
      ),
    );
  }
}
