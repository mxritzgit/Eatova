part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Kopfbereich der Rezeptliste: Titel + Anlegen-Button, Suchfeld,
// Kategorie-Filter-Chips und die wiederverwendete Sektions-Überschrift.
// ---------------------------------------------------------------------------
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
  const _RecipeSearchField({required this.controller, required this.onClear});

  /// Gehoert dem [_RecipesScreenState] (dort erzeugt und entsorgt). Ohne
  /// eigenen Controller laege der Text nur im `EditableText`-State und waere
  /// weg, sobald die lazy Liste das Feld beim Scrollen abraeumt (D6).
  final TextEditingController controller;

  /// Leert Suchtext und damit den Textfilter.
  final VoidCallback onClear;

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
        controller: controller,
        cursorOpacityAnimates: false,
        style: const TextStyle(color: textPrimary, fontSize: 14),
        cursorColor: lime,
        decoration: InputDecoration(
          border: InputBorder.none,
          prefixIcon:
              const Icon(Icons.search_rounded, color: textMuted, size: 20),
          hintText: 'Gericht, Ziel oder Kategorie suchen',
          hintStyle: const TextStyle(color: textMuted, fontSize: 13),
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
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
                tooltip: 'Suche leeren',
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(
                  minWidth: 44,
                  minHeight: 44,
                ),
                icon: const Icon(
                  Icons.close_rounded,
                  color: textMuted,
                  size: 18,
                ),
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
