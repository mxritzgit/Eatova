import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../models/macro_progress.dart';
import '../../theme/app_tokens.dart';
import '../design/design.dart';
import 'diary_meal_card.dart' show diaryAmountLabel;

/// Left edge of the rows: card padding + slot tile + gap, as in the Food
/// diary card, so names line up under the header text.
const double _rowInset = 14 + 40 + 12;

/// Shows the meals already logged for the current slot and day at the top of
/// the add-meal sheet, with an X to remove and (when [onEdit] is wired) a tap
/// to edit.
///
/// Built like the Food diary's slot card: slot tile, header, then hairline
/// rows with the kcal right-aligned. The header carries the slot total as
/// kcal AND macros, computed via [MacroProgress] — the same parse/sum logic
/// as the daily rings, never by re-parsing the string fields of `result`.
class ExistingMealsList extends StatelessWidget {
  const ExistingMealsList({
    super.key,
    required this.meals,
    required this.slot,
    required this.onRemove,
    this.onEdit,
  });

  final List<LoggedMeal> meals;
  final MealSlot slot;
  final ValueChanged<String>? onRemove;

  /// A row tap opens the edit sheet. Null makes the row non-tappable.
  final ValueChanged<LoggedMeal>? onEdit;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final eyebrow = context.l10n.foodAlreadyAddedEyebrow;
    final totals = meals.fold<MacroProgress>(
      MacroProgress.empty,
      (sum, m) => sum.add(m.result),
    );
    return Material(
      key: const ValueKey('analyse-existing-meals'),
      color: t.surf,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rCard),
        side: BorderSide(color: t.cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            child: Row(
              children: [
                SlotIconTile(slot: slot, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        eyebrow.toUpperCase(),
                        semanticsLabel: eyebrow,
                        style: AppType.sectionEyebrow(t.ink3, size: 11),
                      ),
                      const SizedBox(height: 3),
                      _SlotTotalLine(totals: totals),
                    ],
                  ),
                ),
              ],
            ),
          ),
          for (final meal in meals)
            _ExistingMealRow(meal: meal, onRemove: onRemove, onEdit: onEdit),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// The slot total line: label + kcal, then the macros.
///
/// A [Wrap] of two blocks rather than one string: at 390 pt and text scale
/// 1.3 the whole line no longer fits, and a single Text would break mid-macro
/// or leave a separator dangling. The kcal number stays its own Text widget
/// with the existing wording, because flow tests search for exactly it.
class _SlotTotalLine extends StatelessWidget {
  const _SlotTotalLine({required this.totals});

  final MacroProgress totals;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Wrap(
      key: const ValueKey('analyse-existing-total'),
      spacing: 10,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // Label+kcal is a Wrap too: at the 2.0 text-scale cap the label and
        // the number no longer fit side by side in 390 pt, so a Row would
        // overflow while the Wrap puts the number below the label.
        Wrap(
          spacing: 6,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              l10n.foodSlotTotalLabel,
              key: const ValueKey('analyse-existing-total-label'),
              style: AppType.ui(13, weight: FontWeight.w500, color: t.ink3),
            ),
            Text(
              '${totals.kcal} kcal',
              key: const ValueKey('analyse-existing-total-kcal'),
              style: AppType.ui(15, weight: FontWeight.w700, color: t.ink)
                  .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ],
        ),
        Text(
          l10n.foodMacroSummary(
            totals.proteinG.round(),
            totals.carbsG.round(),
            totals.fatG.round(),
          ),
          key: const ValueKey('analyse-existing-total-macros'),
          style: AppType.ui(12.5, weight: FontWeight.w500, color: t.ink3),
        ),
      ],
    );
  }
}

class _ExistingMealRow extends StatelessWidget {
  const _ExistingMealRow({
    required this.meal,
    required this.onRemove,
    required this.onEdit,
  });

  final LoggedMeal meal;
  final ValueChanged<String>? onRemove;
  final ValueChanged<LoggedMeal>? onEdit;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final macros = MacroProgress.empty.add(meal.result);
    // Unknown macros (parser yields '-', MacroProgress reads 0) get no line,
    // which would fake a measurement. The slot total above is unaffected:
    // there a 0 honestly means "nothing known added".
    final hasMacros =
        macros.proteinG > 0 || macros.carbsG > 0 || macros.fatG > 0;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: EdgeInsets.fromLTRB(0, 8, onRemove == null ? 4 : 0, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    meal.result.resolvedMealName(l10n),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.ui(14, weight: FontWeight.w600, color: t.ink),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    diaryAmountLabel(meal.result, l10n),
                    style: AppType.ui(12, color: t.ink3),
                  ),
                  if (hasMacros)
                    Text(
                      l10n.foodMacroSummary(
                        macros.proteinG.round(),
                        macros.carbsG.round(),
                        macros.fatG.round(),
                      ),
                      key: ValueKey('analyse-existing-macros-${meal.id}'),
                      style: AppType.ui(12, color: t.ink3),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '${meal.result.caloriesKcal}',
              // The unit is implicit on screen only.
              semanticsLabel: '${meal.result.caloriesKcal} kcal',
              style: AppType.ui(14, weight: FontWeight.w600, color: t.ink2)
                  .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            if (onRemove != null)
              IconButton(
                key: ValueKey('analyse-existing-remove-${meal.id}'),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () => onRemove!(meal.id),
                icon: Icon(Icons.close_rounded, size: 18, color: t.ink3),
                tooltip: l10n.foodRemoveTooltip,
              ),
          ],
        ),
      ),
    );
    // Hairline on top of every row, starting under the text like the diary.
    final lined = Padding(
      padding: const EdgeInsets.only(left: _rowInset, right: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: t.line)),
        ),
        child: row,
      ),
    );
    if (onEdit == null) return lined;
    // A11y: the row looks like plain display, so announce it as a button —
    // otherwise the edit tap is undiscoverable.
    return Semantics(
      button: true,
      hint: l10n.foodEditMealTitle,
      child: InkWell(
        key: ValueKey('analyse-existing-edit-${meal.id}'),
        onTap: () => onEdit!(meal),
        child: lined,
      ),
    );
  }
}
