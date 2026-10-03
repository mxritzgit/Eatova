part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Top of the Recipes tab (dark redesign 2026-09-28): title with the meal-plan
// and add buttons, the search capsule with its filter button, and the one
// chip bar that holds the sections (For you, All, My recipes) and the
// category filters. Chip and filter sheets live at the end of this file.
// ---------------------------------------------------------------------------

/// Horizontal gutter of the tab; horizontal scrollers run to the screen edge
/// and pad themselves by it.
const double _kGutter = 20;

class _RecipesHeader extends StatelessWidget {
  const _RecipesHeader({
    super.key,
    required this.onAdd,
    required this.addSemantics,
    this.onOpenMealPlan,
  });

  final VoidCallback onAdd;
  final String addSemantics;
  final VoidCallback? onOpenMealPlan;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final buttons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onOpenMealPlan != null) ...[
          HeaderIconButton.custom(
            key: const ValueKey('recipe-meal-plan-button'),
            semanticLabel: l10n.recipeEditMealPlan,
            onTap: onOpenMealPlan,
            child: const _GlyphIcon(_RecipeGlyph.calendar, strokeWidth: 1.9),
          ),
          const SizedBox(width: 8),
        ],
        HeaderIconButton.custom(
          key: const ValueKey('recipe-add-choice-button'),
          tone: HeaderIconTone.primary,
          semanticLabel: addSemantics,
          onTap: onAdd,
          child: const _GlyphIcon(_RecipeGlyph.plus, strokeWidth: 2.4),
        ),
      ],
    );
    final titleStyle = AppType.pageTitle(t.ink);
    final scaler = AppType.pageTitleScaler(context);
    final title = HeadingSemantics(
      level: 1,
      child: Text(l10n.navRecipes, style: titleStyle, textScaler: scaler),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final titleWidth = _textWidth(
          context,
          l10n.navRecipes,
          titleStyle,
          scaler,
        );
        const buttonsWidth = HeaderIconButton.size * 2 + 8;
        // Large text on a narrow phone: the title keeps its line and the
        // buttons move below instead of breaking the word.
        if (titleWidth + 12 + buttonsWidth > constraints.maxWidth) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [title, const SizedBox(height: 12), buttons],
          );
        }
        // Title on the row's top edge, not centred on the 44 px buttons: it
        // shares its origin with the other tabs' titles (page chrome rule).
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: title),
            const SizedBox(width: 12),
            buttons,
          ],
        );
      },
    );
  }
}

/// Width of [text] on one line as a [Text] with [style] renders it here
/// (merged over the ambient [DefaultTextStyle]), for the side-by-side-or-
/// stacked decisions.
double _textWidth(
  BuildContext context,
  String text,
  TextStyle style,
  TextScaler scaler,
) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: DefaultTextStyle.of(context).style.merge(style),
    ),
    textScaler: scaler,
    textDirection: Directionality.of(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// The search capsule: magnifier, the field and the filter button.
///
/// Borderless like every input of the app (standing preference): `field` at
/// rest, `fieldFocus` while the field has focus, where the design draws a
/// white hairline. The [ValueKey] sits DIRECTLY on the [TextField]; other
/// suites cast on it.
class _RecipeSearchCapsule extends StatelessWidget {
  const _RecipeSearchCapsule({
    required this.controller,
    required this.onClear,
    required this.onFilters,
  });

  /// Owned by [_RecipesScreenState]. Without an external controller the text
  /// would live only in `EditableText` state and vanish when the lazy list
  /// disposes the field while scrolling (D6).
  final TextEditingController controller;

  /// Clears the search text and with it the text filter.
  final VoidCallback onClear;

  /// Opens the filter sheet.
  final VoidCallback onFilters;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    // The `Focus` ancestor only observes: `Focus.of` rebuilds the builder
    // whenever the inner field gains or loses focus.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return AnimatedContainer(
            duration: motionDuration(
              context,
              const Duration(milliseconds: 160),
            ),
            curve: Curves.easeOut,
            // Min height, not the template's fixed 52: growing text would
            // overflow a fixed box.
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.only(left: 16, right: 4),
            decoration: BoxDecoration(
              color: focused ? t.fieldFocus : t.field,
              borderRadius: BorderRadius.circular(rThumb),
              boxShadow: softShadow(t),
            ),
            child: Row(
              children: [
                _GlyphIcon(_RecipeGlyph.search, color: t.ink2),
                const SizedBox(width: 10),
                Expanded(
                  child: Semantics(
                    label: l10n.recipesSearchSemantics,
                    child: TextField(
                      key: const ValueKey('recipes-search-input'),
                      controller: controller,
                      cursorOpacityAnimates: false,
                      style: AppType.ui(16, color: t.ink),
                      cursorColor: t.accent,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        isDense: true,
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 14,
                        ),
                        hintText: l10n.recipesSearchPlaceholder,
                        // ink2, not the design's ink3: ink3 misses 4.5:1 on
                        // the field capsule.
                        hintStyle: AppType.ui(16, color: t.ink2),
                      ),
                    ),
                  ),
                ),
                // The search text survives scrolling and tab switches, so
                // there must be a visible way to clear it.
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) {
                    if (value.text.isEmpty) return const SizedBox(width: 6);
                    return IconButton(
                      key: const ValueKey('recipes-search-clear'),
                      onPressed: onClear,
                      tooltip: l10n.recipesSearchClearTooltip,
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
                _FilterButton(onTap: onFilters),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The design's 40 px filter square inside a 44 px touch target.
class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: true,
      label: context.l10n.recipesFiltersButton,
      child: PressScale(
        child: SizedBox.square(
          dimension: 44,
          child: Center(
            child: Material(
              color: t.surf2,
              borderRadius: BorderRadius.circular(rControl),
              child: InkWell(
                key: const ValueKey('recipes-filter-button'),
                onTap: onTap,
                borderRadius: BorderRadius.circular(rControl),
                child: SizedBox.square(
                  dimension: 40,
                  child: Center(
                    child: _GlyphIcon(
                      _RecipeGlyph.sliders,
                      size: 18,
                      color: t.inkMuted,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One chip of the bar: a section (For you, All, My recipes) or a category.
///
/// Sections keep their `recipes-tab-*` key on a [Semantics] wrapper (suites
/// read its `selected` flag); categories and "All" keep `recipe-filter-*` on
/// the pill.
class _RecipeChip {
  const _RecipeChip({
    required this.id,
    required this.label,
    required this.selected,
    required this.onTap,
    this.sectionKey,
    this.filterKey,
  });

  /// Stable identity for the filter sheet's keys.
  final String id;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? sectionKey;
  final String? filterKey;

  /// The design's 42 px pill inside a 44 px touch target, as ONE semantics
  /// node (button, label, selected state and tap) per chip.
  Widget pill({String? keyPrefix}) {
    // Typed keys: a `ValueKey(String?)` would be a `ValueKey<String?>` and
    // never equal the `ValueKey<String>` the suites look for.
    final filterKey = this.filterKey, sectionKey = this.sectionKey;
    final chip = FilterChipPill(
      key: keyPrefix != null
          ? ValueKey<String>('$keyPrefix$id')
          : filterKey == null
          ? null
          : ValueKey<String>(filterKey),
      label: label,
      selected: selected,
      onTap: onTap,
    );
    return Semantics(
      key: keyPrefix == null && sectionKey != null
          ? ValueKey<String>(sectionKey)
          : null,
      container: true,
      button: true,
      selected: selected,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: _kChipTarget),
          child: Center(widthFactor: 1, heightFactor: 1, child: chip),
        ),
      ),
    );
  }
}

/// Touch target of a chip. [FilterChipPill] is 44 px on its own since
/// 2026-10-03; the wrapper stays as the bar's floor.
const double _kChipTarget = 44;

/// The horizontal chip bar. Runs to the screen edge and scrolls; the design's
/// selected chip is the accent pill ([FilterChipPill]).
class _RecipeChipBar extends StatelessWidget {
  const _RecipeChipBar({required this.chips});

  final List<_RecipeChip> chips;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: context.l10n.recipesFilterGroupLabel,
      child: SizedBox(
        // Grows with the text scale, capped so double-size text does not eat
        // half the screen.
        height: MediaQuery.textScalerOf(
          context,
        ).scale(42).clamp(_kChipTarget, 84.0),
        // Own PageStorage slot, apart from the page's vertical offset.
        child: KeyedSubtree(
          key: const PageStorageKey<String>('recipes-chip-bar-scroll'),
          child: ListView.separated(
            key: const ValueKey('recipes-chip-bar'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: _kGutter),
            itemCount: chips.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            // `Center` keeps the chip at its natural height inside the bar.
            itemBuilder: (context, index) => Center(child: chips[index].pill()),
          ),
        ),
      ),
    );
  }
}

/// Every chip of the bar at once; returns the tapped chip's index.
class _RecipeFilterSheet extends StatelessWidget {
  const _RecipeFilterSheet({required this.chips});

  final List<_RecipeChip> chips;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SingleChildScrollView(
      key: const ValueKey('recipe-filter-sheet'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          HeadingSemantics(
            level: 1,
            child: Text(
              context.l10n.recipesFiltersButton,
              style: AppType.display(24, color: t.ink, height: 1.15),
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 10,
            children: [
              for (var i = 0; i < chips.length; i++)
                _RecipeChip(
                  id: chips[i].id,
                  label: chips[i].label,
                  selected: chips[i].selected,
                  onTap: () => Navigator.of(context).pop(i),
                ).pill(keyPrefix: 'recipe-filter-option-'),
            ],
          ),
        ],
      ),
    );
  }
}

enum _AddChoice { import, create }

/// The accent "+": import a recipe or create one.
class _RecipeAddChoiceSheet extends StatelessWidget {
  const _RecipeAddChoiceSheet();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return SingleChildScrollView(
      key: const ValueKey('recipe-add-choice-sheet'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          HeadingSemantics(
            level: 1,
            child: Text(
              l10n.recipesAddChoiceTitle,
              style: AppType.display(24, color: t.ink, height: 1.15),
            ),
          ),
          const SizedBox(height: 18),
          _AddChoiceRow(
            key: const ValueKey('recipe-add-choice-import'),
            glyph: _RecipeGlyph.download,
            title: l10n.recipeImportTitle,
            body: l10n.recipesAddChoiceImportBody,
            onTap: () => Navigator.of(context).pop(_AddChoice.import),
          ),
          const SizedBox(height: 10),
          _AddChoiceRow(
            key: const ValueKey('recipe-add-choice-create'),
            glyph: _RecipeGlyph.pencil,
            title: l10n.recipesCreateSemantics,
            body: l10n.recipesAddChoiceCreateBody,
            onTap: () => Navigator.of(context).pop(_AddChoice.create),
          ),
        ],
      ),
    );
  }
}

class _AddChoiceRow extends StatelessWidget {
  const _AddChoiceRow({
    super.key,
    required this.glyph,
    required this.title,
    required this.body,
    required this.onTap,
  });

  final _RecipeGlyph glyph;
  final String title, body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: Material(
          color: t.surf,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rCard),
            side: BorderSide(color: t.cardBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: t.accentTint,
                      borderRadius: BorderRadius.circular(rControl),
                    ),
                    child: Center(
                      child: _GlyphIcon(glyph, color: t.accentText),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: AppType.ui(
                            16,
                            weight: FontWeight.w700,
                            color: t.ink,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          body,
                          style: AppType.ui(13, color: t.ink2, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right_rounded, color: t.ink2, size: 22),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
