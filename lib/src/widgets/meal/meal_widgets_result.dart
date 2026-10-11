part of 'meal_widgets.dart';

class MealResultCard extends StatefulWidget {
  const MealResultCard({
    super.key,
    required this.result,
    required this.addedToDailyTotal,
    required this.onAdjustRequested,
    required this.onAddToDailyRequested,
    this.isFavorite = false,
    this.showActions = true,
    this.previewImage,
    this.onToggleFavorite,
  });

  final Uint8List? previewImage;
  final bool showActions;
  final MealAnalysisResult result;
  final bool addedToDailyTotal;
  final VoidCallback onAdjustRequested;
  final VoidCallback onAddToDailyRequested;

  /// Whether this meal is currently marked as a favourite (filled heart).
  final bool isFavorite;

  /// Optional favourite toggle; null hides the heart button.
  final ValueChanged<MealAnalysisResult>? onToggleFavorite;

  @override
  State<MealResultCard> createState() => _MealResultCardState();
}

class _MealResultCardState extends State<MealResultCard> {
  int _previousKcal = 0;

  @override
  void didUpdateWidget(covariant MealResultCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result.caloriesKcal != widget.result.caloriesKcal) {
      _previousKcal = oldWidget.result.caloriesKcal;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final result = widget.result;
    final isBarcode =
        MealResultSource.resolve(result.sourceLabel) ==
        MealResultSource.openFoodFacts;

    return Column(
      key: const ValueKey('analyse-result-card'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.previewImage != null) ...[
          MealPreviewCard(imageBytes: widget.previewImage),
          const SizedBox(height: 16),
        ],
        Row(
          children: [
            Expanded(
              child: Text(
                result.resolvedSourceLabel(l10n),
                // accentText, not the accent fill: small type.
                style: AppType.ui(
                  12,
                  weight: FontWeight.w700,
                  color: isBarcode ? t.ink2 : t.accentText,
                ),
              ),
            ),
            // The app's round icon buttons (the Food header's calendar, the
            // sheets' close ring), not bare Material glyphs.
            if (widget.onToggleFavorite != null) ...[
              const SizedBox(width: 8),
              // The spoken name says the state, as the tooltip did before.
              Tooltip(
                message: widget.isFavorite
                    ? l10n.foodRemoveFavoriteTooltip
                    : l10n.foodAddFavoriteTooltip,
                excludeFromSemantics: true,
                child: HeaderIconButton.custom(
                  key: const ValueKey('analyse-favorite-button'),
                  semanticLabel: widget.isFavorite
                      ? l10n.foodRemoveFavoriteTooltip
                      : l10n.foodAddFavoriteTooltip,
                  onTap: () => widget.onToggleFavorite!(result),
                  child: Icon(
                    widget.isFavorite
                        ? Icons.favorite_rounded
                        : Icons.favorite_outline_rounded,
                    color: widget.isFavorite ? t.accentText : null,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 8),
            Tooltip(
              message: l10n.foodDetailsTooltip,
              excludeFromSemantics: true,
              child: HeaderIconButton(
                key: const ValueKey('analyse-info-button'),
                icon: Icons.info_outline_rounded,
                semanticLabel: l10n.foodDetailsTooltip,
                onTap: () => _showInfo(context),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          result.resolvedMealName(l10n),
          key: const ValueKey('analyse-meal-name'),
          style: AppType.display(26, color: t.ink, height: 1.15),
        ),
        const SizedBox(height: 18),
        Container(
          key: const ValueKey('analyse-nutrition-hero'),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: t.brandSurface,
            borderRadius: BorderRadius.circular(rHero),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.foodAnalysisNutrition,
                style: AppType.ui(12, weight: FontWeight.w600, color: t.ink2),
              ),
              const SizedBox(height: 10),
              _AnimatedKcal(from: _previousKcal, to: result.caloriesKcal),
              const SizedBox(height: 10),
              _PortionLine(result: result),
              const SizedBox(height: 6),
              Text(
                result.kcalPer100Label,
                key: const ValueKey('analyse-kcal-per-100'),
                style: AppType.ui(12, color: t.ink2),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final stacked =
                constraints.maxWidth < 290 ||
                MediaQuery.textScalerOf(context).scale(14) > 21;
            final tiles = [
              MacroTile(
                label: l10n.todayMacroProtein,
                value: result.resolvedProtein(l10n),
                color: t.protein,
                surface: t.proteinSurface,
              ),
              MacroTile(
                label: l10n.foodMacroTileCarbsLabel,
                value: result.resolvedCarbs(l10n),
                color: t.carbs,
                surface: t.carbsSurface,
              ),
              MacroTile(
                label: l10n.todayMacroFat,
                value: result.resolvedFat(l10n),
                color: t.fat,
                surface: t.fatSurface,
              ),
            ];
            return stacked
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final tile in tiles) ...[
                        tile,
                        const SizedBox(height: 8),
                      ],
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < tiles.length; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        Expanded(child: tiles[i]),
                      ],
                    ],
                  );
          },
        ),
        if (result.hasItemizedBreakdown) ...[
          const SizedBox(height: 24),
          FieldLabel(l10n.foodIngredientsCountLabel(result.items.length)),
          const SizedBox(height: 8),
          _ItemBreakdownList(result: result),
        ],
        if (widget.showActions) ...[
          const SizedBox(height: 18),
          MealResultActions(
            added: widget.addedToDailyTotal,
            onAdjust: widget.onAdjustRequested,
            onAdd: widget.onAddToDailyRequested,
          ),
        ],
      ],
    );
  }

  /// The (i) details: the shared sheet shell (scrim, edge, keyboard inset,
  /// height cap) and the shared header with its close button.
  void _showInfo(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final result = widget.result;
    // Blank values (legacy rows, previews) drop their row or block instead
    // of showing a bare label or an empty gap.
    final source = result.resolvedSourceLabel(l10n).trim();
    final confidence = result.resolvedConfidence(l10n).trim();
    final notes = result.resolvedPortionNotes(l10n).trim();
    showEatovaSheet<void>(
      context,
      Builder(
        builder: (sheetContext) => SingleChildScrollView(
          key: const ValueKey('analyse-info-sheet'),
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            28 + MediaQuery.viewPaddingOf(sheetContext).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SheetHeader(
                title: result.resolvedMealName(l10n),
                onClose: () => Navigator.of(sheetContext).maybePop(),
                closeKey: const ValueKey('analyse-info-close'),
                closeTooltip: l10n.commonClose,
                padding: const EdgeInsets.only(bottom: 8),
              ),
              _InfoLines(
                lines: [
                  if (result.brand != null && result.brand!.isNotEmpty)
                    (l10n.foodInfoBrandLabel, result.brand!),
                  if (result.barcode != null && result.barcode!.isNotEmpty)
                    (l10n.foodInfoBarcodeLabel, result.barcode!),
                  if (source.isNotEmpty) (l10n.foodInfoSourceLabel, source),
                  if (confidence.isNotEmpty)
                    (l10n.foodInfoConfidenceLabel, confidence),
                ],
              ),
              const SizedBox(height: 12),
              if (notes.isNotEmpty) ...[
                Text(
                  notes,
                  key: const ValueKey('analyse-portion-notes'),
                  style: AppType.ui(
                    13,
                    weight: FontWeight.w500,
                    color: t.ink,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: t.surf2,
                  borderRadius: BorderRadius.circular(rControl),
                ),
                child: Text(
                  l10n.foodEstimateDisclaimer,
                  style: AppType.ui(
                    12,
                    weight: FontWeight.w500,
                    color: t.ink2,
                    height: 1.4,
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

/// Label/value pairs of the details sheet. The label column is as wide as
/// its widest label (at least 86), so the values still line up; a fixed 86
/// broke "Confidence" mid-word at 2x text on a 320 px phone. Where even that
/// leaves the values too little room, each label stacks above its value.
class _InfoLines extends StatelessWidget {
  const _InfoLines({required this.lines});

  final List<(String, String)> lines;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final labelStyle = AppType.ui(12, weight: FontWeight.w500, color: t.ink2);
    final valueStyle = AppType.ui(
      13,
      weight: FontWeight.w600,
      color: t.ink,
      height: 1.3,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        var labelWidth = 86.0;
        for (final (label, _) in lines) {
          final painter = TextPainter(
            text: TextSpan(text: label, style: labelStyle),
            textDirection: Directionality.of(context),
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          final width = painter.width.ceilToDouble();
          if (width > labelWidth) labelWidth = width;
          painter.dispose();
        }
        const gap = 12.0;
        if (labelWidth + gap > constraints.maxWidth * 0.45) {
          return Column(
            key: const ValueKey('analyse-info-lines'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (label, value) in lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: labelStyle),
                      const SizedBox(height: 2),
                      Text(value, style: valueStyle),
                    ],
                  ),
                ),
            ],
          );
        }
        return Column(
          key: const ValueKey('analyse-info-lines'),
          children: [
            for (final (label, value) in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: labelWidth + gap,
                      child: Text(label, style: labelStyle),
                    ),
                    Expanded(child: Text(value, style: valueStyle)),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _PortionLine extends StatelessWidget {
  const _PortionLine({required this.result});

  final MealAnalysisResult result;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final String label;
    if (result.hasItemizedBreakdown) {
      label = result.isAdjusted
          ? l10n.foodPortionItemizedAdjusted(result.estimatedGrams)
          : l10n.foodPortionItemized(
              result.items.length,
              result.estimatedGrams,
            );
    } else if (result.isAdjusted) {
      label = l10n.foodPortionManuallyAdjusted(result.estimatedGrams);
    } else {
      label = l10n.foodPortionLabelPrefixed(result.resolvedPortionLabel(l10n));
    }
    return Padding(
      key: const ValueKey('analyse-portion-confirm-box'),
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        label,
        style: AppType.display(12, weight: FontWeight.w500, color: t.ink2),
      ),
    );
  }
}

class _AnimatedKcal extends StatelessWidget {
  const _AnimatedKcal({required this.from, required this.to});

  final int from;
  final int to;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: from.toDouble(), end: to.toDouble()),
      duration: motionDuration(context, const Duration(milliseconds: 520)),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) {
        return Text(
          '${value.round()} kcal',
          key: const ValueKey('analyse-kcal-range'),
          style: AppType.display(42, color: t.ink, height: 1.1),
        );
      },
    );
  }
}

class _ItemBreakdownList extends StatelessWidget {
  const _ItemBreakdownList({required this.result});

  final MealAnalysisResult result;

  @override
  Widget build(BuildContext context) {
    final items = result.items;
    return Column(
      key: const ValueKey('analyse-item-breakdown'),
      // Stretched: centred, each row shrank to the width of its own text.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < items.length; index++) ...[
          _ItemBreakdownRow(
            item: items[index],
            name: result.resolvedItemName(items[index], context.l10n),
            index: index,
          ),
          if (index < items.length - 1) const SizedBox(height: 6),
        ],
      ],
    );
  }
}

class _ItemBreakdownRow extends StatelessWidget {
  const _ItemBreakdownRow({
    required this.item,
    required this.name,
    required this.index,
  });

  final MealComponent item;
  final String name;
  final int index;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      key: ValueKey('analyse-item-row-$index'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name,
            style: AppType.ui(14, weight: FontWeight.w600, color: t.ink),
          ),
          const SizedBox(height: 5),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(item.gramsLabel, style: AppType.ui(12, color: t.ink2)),
              Text(
                item.caloriesLabel,
                style: AppType.ui(12, weight: FontWeight.w600, color: t.ink),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class MacroTile extends StatelessWidget {
  const MacroTile({
    super.key,
    required this.label,
    required this.value,
    required this.color,
    this.surface,
  });

  final String label;
  final String value;

  /// Nutrient tone for the MARKER only, never for the number — and here not
  /// even raw. Unlike the plan hero and the recipe tiles this one sits on
  /// `surf2`, one step darker than `surf`, and that half point is the whole
  /// difference: in light mode the raw tones drop to protein 4.68:1, fat
  /// 3.04:1 and carbs 2.77:1, so the number misses text AA (4.5:1) and the
  /// DOT misses even the 3:1 WCAG 1.4.11 asks of a graphical object.
  /// [AppTokens.readableOnTint] is the app's correction for exactly that case
  /// and lifts the three to 5.76 … 7.93:1 (hell) / 8.16 … 10.05:1 (dunkel),
  /// hue intact, without a brightness branch.
  final Color color;
  final Color? surface;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: surface ?? t.surf2,
        borderRadius: BorderRadius.circular(rControl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Beside the LABEL, not the number: three tiles share a phone width
          // and the number is the one line that may not be pushed into its
          // ellipsis. The label wraps, so the dot costs no height.
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: t.readableOnTint(color),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: AppType.ui(
                    11,
                    weight: FontWeight.w500,
                    color: t.ink2,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: AppType.display(20, weight: FontWeight.w700, color: t.ink),
          ),
        ],
      ),
    );
  }
}

/// Shared actions can sit in the sheet footer or scroll with large text.
class MealResultActions extends StatelessWidget {
  const MealResultActions({
    super.key,
    required this.added,
    required this.onAdjust,
    required this.onAdd,
  });
  final bool added;
  final VoidCallback onAdjust;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SoftPillButton(
          key: const ValueKey('analyse-adjust-button'),
          onTap: onAdjust,
          icon: Icons.tune_rounded,
          label: l10n.foodAdjustPortionButton,
          expand: true,
        ),
        const SizedBox(height: 10),
        PrimaryActionButton(
          key: const ValueKey('analyse-add-daily-button'),
          onTap: added ? null : onAdd,
          icon: added ? Icons.check_circle_rounded : Icons.add_rounded,
          label: added ? l10n.foodAddedToDailyLabel : l10n.commonAdd,
        ),
      ],
    );
  }
}
