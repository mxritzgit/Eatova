import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/meal_analysis_result.dart';
import '../../theme/app_tokens.dart';
import '../common/lively.dart';
import '../common/motion.dart';
import '../design/text_scale.dart';
import 'diary_meal_card.dart' show diaryAmountLabel;

// The row language of the add-meal sheet (design polish 2026-10-02): every
// favorite, recent and product hit reads like a Food diary row — a leading
// tile, the name in semibold ink, one muted line below, the kcal right-aligned
// with a small unit — and rows sit in ONE card with hairline dividers.

/// Left inset of the hairline between rows: row margin and padding (6 + 10,
/// so the tile sits 16 in like the entry-method rows) plus tile plus gap,
/// so the line starts under the text like in the Food diary card.
const double kMealRowDividerInset = 6 + 10 + kMealRowTileSize + 12;

/// Side of the leading tile.
const double kMealRowTileSize = 40;

/// Side of a saved favorite's tile: large enough to recognize a packshot.
const double kSavedMealTileSize = 48;

/// [kMealRowDividerInset] for rows with a [kSavedMealTileSize] tile.
const double kSavedMealDividerInset = 6 + 10 + kSavedMealTileSize + 12;

/// One shared surface makes saved meals read as a collection, not search hits.
class SavedMealCollection extends StatelessWidget {
  const SavedMealCollection({
    super.key,
    required this.children,
    this.dividerInset = kMealRowDividerInset,
  });

  final List<Widget> children;

  /// Where the hairline starts: under the text of the rows' tile size.
  final double dividerInset;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: t.surf,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rCard),
        side: BorderSide(color: t.cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              children[i],
              if (i < children.length - 1)
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: dividerInset,
                  endIndent: 14,
                  color: t.line,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Name without a trailing " · Brand" (product names carry it) plus the brand.
(String title, String? brand) mealTitleAndBrand(
  MealAnalysisResult result,
  AppLocalizations l10n,
) {
  final name = result.resolvedMealName(l10n);
  final brand = result.brand?.trim();
  if (brand == null || brand.isEmpty) return (name, null);
  final suffix = ' · $brand';
  return (
    name.endsWith(suffix) ? name.substring(0, name.length - suffix.length) : name,
    brand,
  );
}

/// The diary row shared by favorites, recents and product hits.
///
/// [value] sits right-aligned; at large text it moves below the copy so the
/// name keeps its width. [actions] are icon buttons with their own tap
/// targets; a tap anywhere else calls [onTap] (expand / collapse).
class MealItemRow extends StatelessWidget {
  const MealItemRow({
    super.key,
    required this.leading,
    required this.title,
    required this.onTap,
    required this.expanded,
    this.secondary,
    this.value,
    this.actions = const <Widget>[],
  });

  final Widget leading;
  final String title;
  final Widget? secondary;
  final Widget? value;
  final List<Widget> actions;
  final VoidCallback onTap;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final stacked = MediaQuery.textScalerOf(context).scale(14) > 21;
    final copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: stacked ? null : 2,
          overflow: stacked ? null : TextOverflow.ellipsis,
          style: AppType.ui(15, weight: FontWeight.w600, color: t.ink),
        ),
        if (secondary != null) ...[
          const SizedBox(height: 2),
          DefaultTextStyle.merge(
            style: AppType.ui(12.5, weight: FontWeight.w500, color: t.ink3),
            child: secondary!,
          ),
        ],
        if (stacked && value != null) ...[const SizedBox(height: 4), value!],
      ],
    );
    // The row itself opens the portion panel; say so, since nothing on it
    // looks like a button.
    return Semantics(
      button: true,
      expanded: expanded,
      hint: context.l10n.foodFavoritePortionAction,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: EdgeInsets.fromLTRB(10, 10, actions.isEmpty ? 14 : 4, 10),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 12),
                Expanded(child: copy),
                if (!stacked && value != null) ...[
                  const SizedBox(width: 10),
                  value!,
                ],
                if (actions.isNotEmpty) const SizedBox(width: 2),
                ...actions,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "412 kcal": the number in ink, the unit small and muted. One [Text], so
/// its plain text is the familiar string.
class MealKcalValue extends StatelessWidget {
  const MealKcalValue({super.key, required this.number});

  final String number;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: number,
            style: AppType.ui(15, weight: FontWeight.w700, color: t.ink)
                .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
          TextSpan(
            text: ' kcal',
            style: AppType.ui(
              12,
              weight: FontWeight.w500,
              color: t.ink3,
            ),
          ),
        ],
      ),
      textAlign: TextAlign.right,
    );
  }
}

/// The kcal of a whole meal, or "Unknown" for the legacy 0 sentinel.
Widget mealKcalOrUnknown(BuildContext context, MealAnalysisResult result) {
  final known = result.caloriesKcal > 0 || result.explicitZeroKcal;
  if (known) return MealKcalValue(number: '${result.caloriesKcal}');
  return Text(
    context.l10n.ingredientUnknown,
    style: AppType.ui(12.5, weight: FontWeight.w600, color: context.t.ink3),
  );
}

/// Leading tile: product photo, else the name's first letter on a quiet tint.
/// Right after an add it turns into the accent check for a moment.
class MealItemTile extends StatelessWidget {
  const MealItemTile({
    super.key,
    required this.name,
    required this.justAdded,
    this.imageUrl,
    this.size = kMealRowTileSize,
  });

  final String name;
  final bool justAdded;
  final String? imageUrl;

  /// Side at 1x text; it grows with the text scale by up to 12.
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final side = scaledWidth(context, size, max: size + 12);
    final radius = BorderRadius.circular(rChip);
    final letter = name.trim().isEmpty
        ? '·'
        : name.trim().characters.first.toUpperCase();
    // Decorative: the name is announced by the row. Rich text keeps the
    // row's first plain Text the name (tests read it that way).
    final letterTile = Container(
      decoration: BoxDecoration(color: t.tile, borderRadius: radius),
      alignment: Alignment.center,
      child: Text.rich(
        TextSpan(text: letter),
        textScaler: TextScaler.noScaling,
        style: AppType.display(side * 0.42, color: t.inkMuted, height: 1),
      ),
    );
    final url = imageUrl;
    final Widget idle = url == null || url.isEmpty
        ? letterTile
        : ClipRRect(
            borderRadius: radius,
            child: ColoredBox(
              color: t.surfWell,
              child: Image.network(
                url,
                fit: BoxFit.cover,
                // OpenFoodFacts sends full-resolution packshots; decode at
                // the tile size.
                cacheWidth: (side * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                errorBuilder: (_, __, ___) => letterTile,
              ),
            ),
          );
    final done = TweenAnimationBuilder<double>(
      key: const ValueKey('meal-item-added-check'),
      tween: Tween<double>(begin: 0, end: 1),
      duration: motionDuration(context, kMotionEnter),
      curve: kMotionCurve,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.scale(scale: 0.6 + 0.4 * v, child: child),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: t.accentFill,
          borderRadius: BorderRadius.circular(side / 2),
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.check_rounded,
          size: side * 0.55,
          color: t.onAccentFill,
        ),
      ),
    );
    // The check pops in; after its dwell the tile simply returns. Only the
    // check speaks ("Added"); the letter or photo is decoration.
    final tile = SizedBox.square(
      dimension: side,
      child: justAdded ? done : idle,
    );
    return justAdded
        ? Semantics(
            label: context.l10n.foodFavoriteAdded,
            child: ExcludeSemantics(child: tile),
          )
        : ExcludeSemantics(child: tile);
  }
}

/// Header row of a saved (pinned) favorite (lively list, 2026-10-03): the
/// product photo, the name, "Brand · 60 g · 212 kcal" and the macro dots,
/// with the heart over a one-tap "+" for the saved portion.
class SavedMealHeader extends StatelessWidget {
  const SavedMealHeader({
    super.key,
    required this.result,
    required this.expanded,
    required this.justAdded,
    required this.onTap,
    required this.isFavorite,
    this.onToggleFavorite,
    this.favoriteButtonKey,
    this.onQuickAdd,
    this.quickAddSlotLabel,
    this.quickAddKey,
  });

  final MealAnalysisResult result;
  final bool expanded, justAdded, isFavorite;
  final VoidCallback onTap;
  final VoidCallback? onToggleFavorite;
  final Key? favoriteButtonKey;

  /// Logs the saved portion; null hides the "+" (an open row adds from its
  /// panel instead).
  final VoidCallback? onQuickAdd;

  /// The meal an add lands in, for the "+" label ("… to Lunch").
  final String? quickAddSlotLabel;
  final Key? quickAddKey;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final (title, brand) = mealTitleAndBrand(result, l10n);
    final portion = mealAmountLabel(result, l10n);
    final kcalKnown = result.caloriesKcal > 0 || result.explicitZeroKcal;
    final muted = AppType.ui(12.5, weight: FontWeight.w500, color: t.ink3);
    final summary = Text.rich(
      TextSpan(
        children: [
          TextSpan(text: brand == null ? '$portion · ' : '$brand · $portion · '),
          if (kcalKnown) ...[
            TextSpan(
              text: '${result.caloriesKcal}',
              style: AppType.ui(13, weight: FontWeight.w700, color: t.ink)
                  .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            const TextSpan(text: ' kcal'),
          ] else
            TextSpan(text: l10n.ingredientUnknown),
        ],
      ),
      style: muted,
    );
    final slot = quickAddSlotLabel;
    final quickAdd = onQuickAdd;
    return MealItemRow(
      leading: MealItemTile(
        name: title,
        imageUrl: result.imageUrl,
        justAdded: justAdded,
        size: kSavedMealTileSize,
      ),
      title: title,
      secondary: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          summary,
          // An open row shows the live macros of its panel instead.
          if (!expanded) ...[
            const SizedBox(height: 4),
            SavedMealNutrients(result: result),
          ],
        ],
      ),
      onTap: onTap,
      expanded: expanded,
      actions: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onToggleFavorite != null)
              MealFavoriteButton(
                key: favoriteButtonKey,
                isFavorite: isFavorite,
                onPressed: onToggleFavorite!,
              ),
            if (quickAdd != null && slot != null)
              MealQuickAddButton(
                key: quickAddKey,
                onPressed: quickAdd,
                semanticLabel: kcalKnown
                    ? l10n.foodFavoriteQuickAdd(title, result.caloriesKcal, slot)
                    : l10n.foodFavoriteQuickAddUnknown(title, slot),
              ),
          ],
        ),
      ],
    );
  }
}

/// The round tinted "+" of a saved favorite: logs its saved portion at once.
/// A 36 px disc in a 48 px target, with the press dip.
class MealQuickAddButton extends StatelessWidget {
  const MealQuickAddButton({
    super.key,
    required this.onPressed,
    required this.semanticLabel,
  });

  final VoidCallback onPressed;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      container: true,
      button: true,
      label: semanticLabel,
      onTap: onPressed,
      excludeSemantics: true,
      // The whole 48 px square takes the tap; the disc is drawn with Ink so
      // the ripple shows on top of it.
      child: SizedBox.square(
        dimension: 48,
        child: PressScale(
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onPressed,
              customBorder: const CircleBorder(),
              child: Center(
                child: Ink(
                  width: 36,
                  height: 36,
                  // Tinted, not filled: the open panel's filled "+" stays the
                  // primary add, a list of rows does not shout.
                  decoration: ShapeDecoration(
                    color: t.accentTint,
                    shape: const CircleBorder(),
                  ),
                  child: Icon(
                    Icons.add_rounded,
                    size: 22,
                    color: t.accentText,
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

/// The heart: accent when pinned, muted outline when not. 48 pt target.
class MealFavoriteButton extends StatelessWidget {
  const MealFavoriteButton({
    super.key,
    required this.isFavorite,
    required this.onPressed,
  });

  final bool isFavorite;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return IconButton(
      onPressed: onPressed,
      tooltip: isFavorite
          ? l10n.foodRemoveFavoriteTooltip
          : l10n.foodAddFavoriteTooltip,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      icon: AnimatedSwitcher(
        duration: motionDuration(context, kMotionPressOut),
        transitionBuilder: (child, animation) =>
            ScaleTransition(scale: animation, child: child),
        child: Icon(
          isFavorite ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
          key: ValueKey(isFavorite),
          size: 20,
          color: isFavorite ? t.accent : t.ink3,
        ),
      ),
    );
  }
}

/// Macro legend for the current portion, from the same result as Add:
/// "P 30 g  C 40 g  F 12 g", each after a dot in its macro color. A [Wrap]
/// of whole entries, so a line break never splits a value. Empty (a "P 0 g"
/// would fake a measurement) when no macro is known.
class SavedMealNutrients extends StatelessWidget {
  const SavedMealNutrients({super.key, required this.result, this.legendKey});

  final MealAnalysisResult result;

  /// Key of the legend itself (the live preview's `live-preview-macros`).
  final Key? legendKey;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final parts = <(Color, String)>[
      if (_known(result.protein))
        (t.protein, l10n.foodMacroProteinShort(result.resolvedProtein(l10n))),
      if (_known(result.carbs))
        (t.carbs, l10n.foodMacroCarbsShort(result.resolvedCarbs(l10n))),
      if (_known(result.fat))
        (t.fat, l10n.foodMacroFatShort(result.resolvedFat(l10n))),
    ];
    if (parts.isEmpty) return SizedBox.shrink(key: legendKey);
    final label = AppType.ui(12.5, weight: FontWeight.w600, color: t.ink2);
    return Wrap(
      key: legendKey,
      spacing: 12,
      runSpacing: 2,
      children: [
        for (final (color, text) in parts)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 5),
              Flexible(child: Text(text, style: label)),
            ],
          ),
      ],
    );
  }
}

bool _known(String value) => value != '-' && value.trim().isNotEmpty;

/// Diary-style amount for a recent ("250 g", "~250 g" for AI estimates).
String mealAmountLabel(MealAnalysisResult result, AppLocalizations l10n) =>
    result.isRecipeWithoutCookedWeight
    ? l10n.recipeCalcSavedPortion
    : diaryAmountLabel(result, l10n);
