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
                style: AppType.ui(
                  12,
                  weight: FontWeight.w700,
                  color: isBarcode ? t.ink2 : t.accent,
                ),
              ),
            ),
            if (widget.onToggleFavorite != null)
              IconButton(
                key: const ValueKey('analyse-favorite-button'),
                onPressed: () => widget.onToggleFavorite!(result),
                tooltip: widget.isFavorite
                    ? l10n.foodRemoveFavoriteTooltip
                    : l10n.foodAddFavoriteTooltip,
                icon: Icon(
                  widget.isFavorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_outline_rounded,
                  color: widget.isFavorite ? t.accent : t.ink2,
                ),
              ),
            IconButton(
              key: const ValueKey('analyse-info-button'),
              onPressed: () => _showInfo(context),
              tooltip: l10n.foodDetailsTooltip,
              icon: Icon(Icons.info_outline_rounded, color: t.ink2),
            ),
          ],
        ),
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

  void _showInfo(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final result = widget.result;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.bg,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(rSheet)),
      ),
      builder: (sheetContext) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                result.resolvedMealName(l10n),
                style: AppType.display(18, color: t.ink),
              ),
              const SizedBox(height: 12),
              if (result.brand != null && result.brand!.isNotEmpty)
                _InfoLine(label: l10n.foodInfoBrandLabel, value: result.brand!),
              if (result.barcode != null && result.barcode!.isNotEmpty)
                _InfoLine(
                  label: l10n.foodInfoBarcodeLabel,
                  value: result.barcode!,
                ),
              _InfoLine(
                label: l10n.foodInfoSourceLabel,
                value: result.resolvedSourceLabel(l10n),
              ),
              _InfoLine(
                label: l10n.foodInfoConfidenceLabel,
                value: result.resolvedConfidence(l10n),
              ),
              const SizedBox(height: 12),
              Text(
                result.resolvedPortionNotes(l10n),
                key: const ValueKey('analyse-portion-notes'),
                style: AppType.ui(
                  13,
                  weight: FontWeight.w500,
                  color: t.ink,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 12),
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
        );
      },
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(
              label,
              style: AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppType.ui(
                13,
                weight: FontWeight.w600,
                color: t.ink,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
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
        TextButton.icon(
          key: const ValueKey('analyse-adjust-button'),
          onPressed: onAdjust,
          icon: const Icon(Icons.tune_rounded, size: 18),
          label: Text(
            l10n.foodAdjustPortionButton,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 6),
        FilledButton.icon(
          key: const ValueKey('analyse-add-daily-button'),
          onPressed: added ? null : onAdd,
          icon: Icon(added ? Icons.check_circle_rounded : Icons.add_rounded),
          label: Text(
            added ? l10n.foodAddedToDailyLabel : l10n.commonAdd,
            textAlign: TextAlign.center,
          ),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          ),
        ),
      ],
    );
  }
}
