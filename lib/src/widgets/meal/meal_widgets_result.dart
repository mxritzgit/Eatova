part of 'meal_widgets.dart';

class MealResultCard extends StatefulWidget {
  const MealResultCard({
    super.key,
    required this.result,
    required this.addedToDailyTotal,
    required this.onAdjustRequested,
    required this.onAddToDailyRequested,
    this.isFavorite = false,
    this.onToggleFavorite,
  });

  final MealAnalysisResult result;
  final bool addedToDailyTotal;
  final VoidCallback onAdjustRequested;
  final VoidCallback onAddToDailyRequested;

  /// Ob diese Mahlzeit aktuell als Favorit markiert ist (Herz gefüllt).
  final bool isFavorite;

  /// Optionaler Toggle für den Favoriten-Herz-Button. Null → Button wird
  /// ausgeblendet (bestehende Aufrufer ohne Verdrahtung bleiben unverändert).
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
    final isBarcode = result.sourceLabel == 'OpenFoodFacts';

    return AppCard(
      key: const ValueKey('analyse-result-card'),
      radius: rCard,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Die Quelle ist kein Naehrwert und kein Zustand: sie traegt
              // deshalb den Marken-Akzent bzw. den gedaempften Ton, nicht
              // eine Makro-Farbe (Farb-Schloss aus dem Token-Vertrag).
              StatusPill(
                label: result.sourceLabel,
                color: isBarcode ? t.ink2 : t.accent,
              ),
              const Spacer(),
              if (widget.onToggleFavorite != null)
                IconButton(
                  key: const ValueKey('analyse-favorite-button'),
                  onPressed: () => widget.onToggleFavorite!(result),
                  tooltip: widget.isFavorite
                      ? l10n.foodRemoveFavoriteTooltip
                      : l10n.foodAddFavoriteTooltip,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    widget.isFavorite
                        ? Icons.favorite_rounded
                        : Icons.favorite_outline_rounded,
                    size: 19,
                    color: widget.isFavorite ? t.accent : t.ink2,
                  ),
                ),
              IconButton(
                key: const ValueKey('analyse-info-button'),
                onPressed: () => _showInfo(context),
                tooltip: l10n.foodDetailsTooltip,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.info_outline_rounded,
                  size: 18,
                  color: t.ink2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            result.mealName,
            key: const ValueKey('analyse-meal-name'),
            style: AppType.display(20, color: t.ink, height: 1.15),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: _AnimatedKcal(
                  from: _previousKcal,
                  to: result.caloriesKcal,
                ),
              ),
              Text(
                result.kcalPer100Label,
                key: const ValueKey('analyse-kcal-per-100'),
                style: AppType.display(
                  12,
                  weight: FontWeight.w500,
                  color: t.ink2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _PortionLine(result: result),
          if (result.hasItemizedBreakdown) ...[
            const SizedBox(height: 14),
            FieldLabel(l10n.foodIngredientsCountLabel(result.items.length)),
            const SizedBox(height: 6),
            _ItemBreakdownList(items: result.items),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: MacroTile(
                  label: l10n.todayMacroProtein,
                  value: result.protein,
                  color: t.protein,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: MacroTile(
                  label: l10n.foodMacroTileCarbsLabel,
                  value: result.carbs,
                  color: t.carbs,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: MacroTile(
                  label: l10n.todayMacroFat,
                  value: result.fat,
                  color: t.fat,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              SizedBox(
                width: 56,
                child: OutlinedButton(
                  key: const ValueKey('analyse-adjust-button'),
                  onPressed: widget.onAdjustRequested,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: t.ink,
                    side: BorderSide(color: t.line),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(rControl),
                    ),
                  ),
                  child: const Icon(Icons.tune_rounded, size: 18),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('analyse-add-daily-button'),
                  onPressed: widget.addedToDailyTotal
                      ? null
                      : widget.onAddToDailyRequested,
                  icon: Icon(
                    widget.addedToDailyTotal
                        ? Icons.check_circle_rounded
                        : Icons.add_circle_outline_rounded,
                    size: 18,
                  ),
                  label: Text(
                    widget.addedToDailyTotal
                        ? l10n.foodAddedToDailyLabel
                        : l10n.commonAdd,
                    style: AppType.ui(14, weight: FontWeight.w700),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: t.forest,
                    foregroundColor: t.onForest,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(rControl),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
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
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                result.mealName,
                style: AppType.display(18, color: t.ink),
              ),
              const SizedBox(height: 12),
              if (result.brand != null && result.brand!.isNotEmpty)
                _InfoLine(label: l10n.foodInfoBrandLabel, value: result.brand!),
              if (result.barcode != null && result.barcode!.isNotEmpty)
                _InfoLine(
                    label: l10n.foodInfoBarcodeLabel, value: result.barcode!),
              _InfoLine(
                label: l10n.foodInfoSourceLabel,
                value: result.sourceLabel,
              ),
              _InfoLine(
                label: l10n.foodInfoConfidenceLabel,
                value: result.confidence,
              ),
              const SizedBox(height: 12),
              Text(
                result.portionNotes,
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
          : l10n.foodPortionItemized(result.items.length, result.estimatedGrams);
    } else if (result.isAdjusted) {
      label = l10n.foodPortionManuallyAdjusted(result.estimatedGrams);
    } else {
      label = l10n.foodPortionLabelPrefixed(result.portionLabel);
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
          style: AppType.display(28, color: t.ink, height: 1.0),
        );
      },
    );
  }
}

class _ItemBreakdownList extends StatelessWidget {
  const _ItemBreakdownList({required this.items});

  final List<MealComponent> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('analyse-item-breakdown'),
      children: [
        for (var index = 0; index < items.length; index++) ...[
          _ItemBreakdownRow(item: items[index], index: index),
          if (index < items.length - 1) const SizedBox(height: 6),
        ],
      ],
    );
  }
}

class _ItemBreakdownRow extends StatelessWidget {
  const _ItemBreakdownRow({required this.item, required this.index});

  final MealComponent item;
  final int index;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      key: ValueKey('analyse-item-row-$index'),
      padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
      decoration: BoxDecoration(
        color: t.surf2,
        borderRadius: BorderRadius.circular(rControl),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              item.name,
              style: AppType.ui(13, weight: FontWeight.w600, color: t.ink),
            ),
          ),
          Text(
            item.gramsLabel,
            style: AppType.display(12, weight: FontWeight.w500, color: t.ink2),
          ),
          const SizedBox(width: 10),
          Text(
            item.caloriesLabel,
            style: AppType.display(13, weight: FontWeight.w600, color: t.ink),
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
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: t.surf2,
        borderRadius: BorderRadius.circular(rControl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: AppType.ui(
              11,
              weight: FontWeight.w500,
              color: t.ink2,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: AppType.display(13, weight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
  }
}
