part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// "Picked for tonight" hero of the Recipes tab (dark redesign 2026-09-28),
// the design's pill buttons and the glowing placeholder art for recipes
// without a photo.
// ---------------------------------------------------------------------------

/// What the hero shows: the shared recipe pick ([RecipePick]) or, without
/// one, the best goal match.
class _HeroModel {
  const _HeroModel({
    required this.recipe,
    required this.eyebrow,
    required this.fits,
    required this.kcal,
    required this.proteinG,
    required this.addLabel,
    required this.onAdd,
    this.opensPlan = false,
    this.readOnlyDetail = false,
  });

  final FitnessRecipe recipe;
  final String eyebrow;

  /// "Fits your day" ([RecipePick.fits]); never claimed without a pick.
  final bool fits;

  /// What the add button would log; null prints a dash.
  final num? kcal, proteinG;

  /// Null: no primary button at all (a planned meal that cannot be logged
  /// and no meal plan to fix it in).
  final String? addLabel;

  /// Null disables the add button (no hook).
  final VoidCallback? onAdd;

  /// The primary button opens the meal plan instead of adding: a planned
  /// meal whose nutrition cannot be logged is fixed there.
  final bool opensPlan;

  /// "View recipe" shows a planned meal's snapshot without its own add
  /// action; the plan entry is logged by the hero only.
  final bool readOnlyDetail;
}

/// Crop anchor of the hero photo. Above centre on purpose: the catalog photos
/// carry a burnt-in "AI Generated" mark in their bottom right corner, and on
/// phone widths this crop keeps it out of the 200 px band, so the overlay
/// label is the only one.
const Alignment _kHeroPhotoAlignment = Alignment(0, -0.4);

class _RecipeHeroCard extends StatelessWidget {
  const _RecipeHeroCard({
    required this.model,
    required this.onView,
    this.saved = false,
    this.onToggleSave,
  });

  final _HeroModel model;
  final VoidCallback onView;

  /// Whether the recipe is pinned as a favorite meal.
  final bool saved;

  /// Null hides the bookmark (no favorites hook, or nothing loggable).
  final VoidCallback? onToggleSave;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final recipe = model.recipe;
    return Container(
      key: const ValueKey('recipe-hero'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rHero),
        border: Border.all(color: t.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 200,
            child: Stack(
              fit: StackFit.expand,
              children: [
                RecipePhoto(
                  key: ValueKey('recipe-hero-photo-${recipe.slug}'),
                  recipe: recipe,
                  alignment: _kHeroPhotoAlignment,
                  placeholder: (_) => _RecipeArt(recipe: recipe, iconSize: 56),
                ),
                if (RecipePhoto.isAiGenerated(recipe))
                  Positioned(
                    left: 12,
                    right: 68,
                    bottom: 12,
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: _GlassPill(
                        key: const ValueKey('recipe-hero-ai-label'),
                        child: Text(
                          l10n.recipesAiImageLabel,
                          style: AppType.ui(
                            11,
                            weight: FontWeight.w700,
                            color: t.inkSoft,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (onToggleSave != null)
                  Positioned(
                    top: 12,
                    right: 12,
                    child: _BookmarkButton(saved: saved, onTap: onToggleSave!),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      Text(
                        model.eyebrow.toUpperCase(),
                        key: const ValueKey('recipe-hero-eyebrow'),
                        semanticsLabel: model.eyebrow,
                        style: AppType.sectionEyebrow(
                          t.accentText,
                        ).copyWith(letterSpacing: 12 * 0.08, height: 1.2),
                      ),
                      if (model.fits) const _FitsBadge(),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                HeadingSemantics(
                  level: 2,
                  child: Text(
                    recipe.displayTitle(l10n),
                    key: const ValueKey('recipe-hero-title'),
                    style: AppType.display(
                      24,
                      weight: FontWeight.w700,
                      color: t.ink,
                      letterSpacing: -24 * 0.02,
                      height: 1.12,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _MetaChip(
                      key: const ValueKey('recipe-hero-kcal'),
                      number: _nutritionNumber(model.kcal?.toDouble(), l10n),
                      unit: 'kcal',
                      gap: 4,
                    ),
                    _MetaChip(
                      key: const ValueKey('recipe-hero-protein'),
                      number:
                          '${_nutritionNumber(model.proteinG?.toDouble(), l10n)} g',
                      unit: l10n.recipesHeroProteinUnit,
                      dot: t.protein,
                      gap: 6,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (model.addLabel == null)
                  SizedBox(
                    width: double.infinity,
                    child: _Pill(
                      key: const ValueKey('recipe-hero-view'),
                      label: l10n.recipesViewRecipe,
                      onTap: onView,
                    ),
                  )
                else
                  _PillPair(
                    first: _Pill(
                      key: ValueKey(
                        model.opensPlan
                            ? 'recipe-hero-open-plan'
                            : 'recipe-hero-add',
                      ),
                      label: model.addLabel!,
                      glyph: model.opensPlan
                          ? _RecipeGlyph.calendar
                          : _RecipeGlyph.plus,
                      glyphStroke: model.opensPlan ? 1.9 : 2.6,
                      primary: true,
                      grow: true,
                      horizontalPadding: 16,
                      onTap: model.onAdd,
                    ),
                    second: _Pill(
                      key: const ValueKey('recipe-hero-view'),
                      label: l10n.recipesViewRecipe,
                      onTap: onView,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FitsBadge extends StatelessWidget {
  const _FitsBadge();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      key: const ValueKey('recipe-hero-fits'),
      constraints: const BoxConstraints(minHeight: 28),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        // The design's rgba(29,176,113,.14): the protein green as a tint.
        color: t.protein.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(rPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _GlyphIcon(
            _RecipeGlyph.check,
            size: 14,
            strokeWidth: 2.8,
            color: t.success,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              context.l10n.recipesHeroFitsDay,
              style: AppType.ui(13, weight: FontWeight.w700, color: t.success),
            ),
          ),
        ],
      ),
    );
  }
}

/// Number-and-unit chip under the hero title ("610 kcal", "● 58 g protein").
/// A [Wrap], so at large text the unit moves under the number instead of
/// overflowing the chip.
class _MetaChip extends StatelessWidget {
  const _MetaChip({
    super.key,
    required this.number,
    required this.unit,
    required this.gap,
    this.dot,
  });

  final String number, unit;
  final double gap;

  /// The macro dot in front of the number.
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      constraints: const BoxConstraints(minHeight: 30),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: t.surf2,
        borderRadius: BorderRadius.circular(rPill),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: gap,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (dot != null) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                number,
                style: AppType.ui(13, weight: FontWeight.w700, color: t.ink),
              ),
            ],
          ),
          Text(
            unit,
            style: AppType.ui(13, weight: FontWeight.w500, color: t.ink2),
          ),
        ],
      ),
    );
  }
}

/// Frosted dark pill laid over a photo (the "AI-generated image" label).
class _GlassPill extends StatelessWidget {
  const _GlassPill({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(rPill),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          constraints: const BoxConstraints(minHeight: 24),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          color: context.t.bg.withValues(alpha: 0.72),
          // Centres the label in the 24 px minimum without widening the pill.
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [child],
          ),
        ),
      ),
    );
  }
}

/// Round frosted bookmark on the hero photo; pins the recipe as a favorite
/// meal (the app's existing favorite/pin).
class _BookmarkButton extends StatelessWidget {
  const _BookmarkButton({required this.saved, required this.onTap});

  final bool saved;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Semantics(
      button: true,
      toggled: saved,
      label: saved
          ? l10n.foodRemoveFavoriteTooltip
          : l10n.foodAddFavoriteTooltip,
      child: PressScale(
        child: ClipOval(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Material(
              color: t.bg.withValues(alpha: 0.6),
              child: InkWell(
                key: const ValueKey('recipe-hero-save'),
                onTap: onTap,
                customBorder: const CircleBorder(),
                child: SizedBox.square(
                  dimension: 44,
                  child: Center(
                    child: _GlyphIcon(
                      _RecipeGlyph.bookmark,
                      color: t.onImage,
                      filled: saved,
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

/// The design's round button: accent fill ([primary]) or the secondary
/// `surf2` pill. `onTap == null` shows the dimmed disabled state.
class _Pill extends StatelessWidget {
  const _Pill({
    super.key,
    required this.label,
    required this.onTap,
    this.glyph,
    this.glyphStroke = 2,
    this.primary = false,
    this.grow = false,
    this.height = 50,
    this.fontSize = 15,
    this.horizontalPadding = 20,
  });

  final String label;
  final VoidCallback? onTap;
  final _RecipeGlyph? glyph;
  final double glyphStroke;
  final bool primary;

  /// Takes the free width of a side-by-side [_PillPair].
  final bool grow;

  final double height, fontSize, horizontalPadding;

  static const double _glyphSize = 18;
  static const double _glyphGap = 8;

  FontWeight get _weight => primary ? FontWeight.w800 : FontWeight.w700;

  /// Width the pill needs on one line.
  double naturalWidth(BuildContext context) =>
      horizontalPadding * 2 +
      (glyph == null ? 0 : _glyphSize + _glyphGap) +
      _textWidth(
        context,
        label,
        AppType.ui(fontSize, weight: _weight),
        MediaQuery.textScalerOf(context),
      ) +
      1;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final enabled = onTap != null;
    final fill = (primary ? t.accentFill : t.surf2).withValues(
      alpha: enabled ? 1 : kDisabledFillAlpha,
    );
    final ink = (primary ? t.onAccentFill : t.ink).withValues(
      alpha: enabled ? 1 : 0.8,
    );
    return Semantics(
      button: true,
      enabled: enabled,
      child: PressScale(
        enabled: enabled,
        child: Material(
          color: fill,
          borderRadius: BorderRadius.circular(rPill),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(rPill),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: height),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: horizontalPadding,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (glyph != null) ...[
                      _GlyphIcon(
                        glyph!,
                        size: _glyphSize,
                        strokeWidth: glyphStroke,
                        color: ink,
                      ),
                      const SizedBox(width: _glyphGap),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        style: AppType.ui(
                          fontSize,
                          weight: _weight,
                          color: ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Two pills side by side (the growing one takes the free width, or both
/// share it with [equal]); stacked full width once their labels no longer
/// fit on one line (large text, narrow phones, long German labels).
class _PillPair extends StatelessWidget {
  const _PillPair({
    required this.first,
    required this.second,
    this.equal = false,
  });

  final _Pill first, second;

  /// Both pills take half the row (the design's Import/Create pair).
  final bool equal;

  static const double _gap = 10;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final a = first.naturalWidth(context);
        final b = second.naturalWidth(context);
        final fits = equal
            ? (a > b ? a : b) * 2 + _gap <= constraints.maxWidth
            : a + _gap + b <= constraints.maxWidth;
        if (!fits) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              first,
              const SizedBox(height: _gap),
              second,
            ],
          );
        }
        // A pill that does not grow gets its measured width: its label is
        // Flexible and needs a bounded row.
        return Row(
          children: [
            if (equal || first.grow)
              Expanded(child: first)
            else
              SizedBox(width: a, child: first),
            const SizedBox(width: _gap),
            if (equal || second.grow)
              Expanded(child: second)
            else
              SizedBox(width: b, child: second),
          ],
        );
      },
    );
  }
}

/// Icon and glow of the placeholder art, from the recipe's categories: fish
/// dishes get the fish, vegetarian and vegan ones the leaf, the rest the bowl.
enum _ArtKind { bowl, fish, leaf }

_ArtKind _artKindFor(FitnessRecipe recipe) {
  // Double-quoted: category identities are matching data, not UI text.
  if (recipe.categories.contains("Fisch")) return _ArtKind.fish;
  if (recipe.categories.contains("Vegetarisch") ||
      recipe.categories.contains("Vegan")) {
    return _ArtKind.leaf;
  }
  return _ArtKind.bowl;
}

/// The design's glowing icon for a recipe without a photo: a radial glow on
/// the quiet well, the icon in the matching ink.
///
/// The design's three hues are the macro fills and inks (blue, orange, green);
/// they are reused here as decoration because the art carries no data and has
/// no tokens of its own.
class _RecipeArt extends StatelessWidget {
  const _RecipeArt({required this.recipe, this.iconSize = 44});

  final FitnessRecipe recipe;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final kind = _artKindFor(recipe);
    final (glow, alpha, ink, glyph) = switch (kind) {
      _ArtKind.bowl => (t.carbs, 0.32, t.carbsInk, _RecipeGlyph.bowl),
      _ArtKind.fish => (t.fat, 0.34, t.fatInk, _RecipeGlyph.fish),
      _ArtKind.leaf => (t.protein, 0.32, t.proteinInk, _RecipeGlyph.leaf),
    };
    return ColoredBox(
      key: ValueKey('recipe-art-${kind.name}'),
      color: t.surfWell,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth, h = constraints.maxHeight;
          // CSS `radial-gradient(circle at 50% 55%, c 0%, transparent 65%)`
          // runs to the farthest corner; Flutter's radius is a fraction of
          // the shortest side.
          final dx = w / 2, dy = h * 0.55 > h * 0.45 ? h * 0.55 : h * 0.45;
          final shortest = w < h ? w : h;
          final radius = shortest <= 0
              ? 1.0
              : math.sqrt(dx * dx + dy * dy) / shortest;
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, 0.1),
                radius: radius,
                colors: [
                  glow.withValues(alpha: alpha),
                  glow.withValues(alpha: 0),
                ],
                stops: const [0, 0.65],
              ),
            ),
            child: Center(
              child: _GlyphIcon(
                glyph,
                size: iconSize,
                strokeWidth: 1.4,
                color: ink,
              ),
            ),
          );
        },
      ),
    );
  }
}
