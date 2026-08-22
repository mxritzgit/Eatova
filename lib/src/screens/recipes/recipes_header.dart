part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Recipe list header: page title + create button, search field and the
// horizontal category filter bar.
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

/// Local rebuild of `SearchBarField`: the design library lacks the widget, and
/// the [ValueKey] must sit DIRECTLY on the [TextField] — test/home_page_tabs
/// _test.dart casts on it.
class _RecipeSearchField extends StatelessWidget {
  const _RecipeSearchField({required this.controller, required this.onClear});

  /// Owned by [_RecipesScreenState]. Without an external controller the text
  /// would live only in `EditableText` state and vanish when the lazy list
  /// disposes the field while scrolling (D6).
  final TextEditingController controller;

  /// Clears the search text and with it the text filter.
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      // Not the template's fixed `height: 48`: fixed height plus growing text
      // is a guaranteed overflow.
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
        // Not the template's `t.forest`: in dark mode that is a dark surface,
        // so the cursor would be invisible on `surf`. `accent` is its ink twin.
        cursorColor: t.accent,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          // Horizontal part taken from the template; without it the text
          // sticks to the magnifier and to the clear button.
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
          prefixIcon: Icon(Icons.search_rounded, size: 18, color: t.ink2),
          prefixIconConstraints: const BoxConstraints(minWidth: 44),
          hintText: context.l10n.recipesSearchHint,
          hintStyle: AppType.ui(14, color: t.ink2),
          // The search text survives scrolling and tab switches, so there must
          // be a visible way to clear it.
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
      // Grows with the text scale instead of breaking at 38 px, capped so
      // double-size text does not eat half the screen.
      height: MediaQuery.textScalerOf(context).scale(38).clamp(38.0, 80.0),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: recipeFilters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final filter = recipeFilters[index];
          // `Center` keeps the chip at its natural size inside the bar's fixed
          // height. Keys and callbacks stay on the neutral `filter` value;
          // only the visible label is localised.
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
