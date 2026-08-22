import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../models/macro_progress.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../design/design.dart';

/// Shows the meals already logged for the current slot and day at the top of
/// the add-meal sheet, with an X to remove and (when [onEdit] is wired) a tap
/// to edit.
///
/// The header carries the slot total as kcal AND macros, computed via
/// [MacroProgress] — the same parse/sum logic as the daily rings, never by
/// re-parsing the string fields of `result`.
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
    final accent = slot.accentIn(context);
    final totals = meals.fold<MacroProgress>(
      MacroProgress.empty,
      (sum, m) => sum.add(m.result),
    );
    return AppCard(
      key: const ValueKey('analyse-existing-meals'),
      radius: rCard,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Expanded instead of a bare Text so the all-caps line
                    // wraps at large system font sizes instead of overflowing
                    // the Row.
                    Expanded(
                      child: Text(
                        context.l10n.foodAlreadyAddedEyebrow,
                        style: AppType.eyebrow(t.ink2, size: 11),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _SlotTotalLine(totals: totals),
              ],
            ),
          ),
          for (var i = 0; i < meals.length; i++) ...[
            if (i > 0)
              Divider(
                color: t.line,
                height: 1,
                indent: 14,
                endIndent: 14,
              ),
            _ExistingMealRow(
              meal: meals[i],
              onRemove: onRemove,
              onEdit: onEdit,
            ),
          ],
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
              style: AppType.ui(12, weight: FontWeight.w600, color: t.ink2),
            ),
            Text(
              '${totals.kcal} kcal',
              key: const ValueKey('analyse-existing-total-kcal'),
              style: AppType.display(
                12,
                weight: FontWeight.w700,
                color: t.ink,
              ),
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
          style: AppType.display(
            11.5,
            weight: FontWeight.w500,
            color: t.ink2,
          ),
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
    final macros = MacroProgress.empty.add(meal.result);
    // Unknown macros (parser yields '-', MacroProgress reads 0) get no line,
    // which would fake a measurement. The slot total above is unaffected:
    // there a 0 honestly means "nothing known added".
    final hasMacros =
        macros.proteinG > 0 || macros.carbsG > 0 || macros.fatG > 0;
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  meal.result.mealName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.ui(14, weight: FontWeight.w600, color: t.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  '${meal.result.caloriesKcal} kcal · ${meal.result.estimatedGrams} g',
                  style: AppType.display(
                    11.5,
                    weight: FontWeight.w500,
                    color: t.ink2,
                  ),
                ),
                if (hasMacros) ...[
                  const SizedBox(height: 2),
                  Text(
                    context.l10n.foodMacroSummary(
                      macros.proteinG.round(),
                      macros.carbsG.round(),
                      macros.fatG.round(),
                    ),
                    key: ValueKey('analyse-existing-macros-${meal.id}'),
                    style: AppType.display(
                      11,
                      weight: FontWeight.w500,
                      color: t.ink2,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (onRemove != null)
            IconButton(
              key: ValueKey('analyse-existing-remove-${meal.id}'),
              iconSize: 18,
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: () => onRemove!(meal.id),
              icon: Icon(Icons.close_rounded, color: t.ink2),
              tooltip: context.l10n.foodRemoveTooltip,
            ),
        ],
      ),
    );
    if (onEdit == null) return row;
    // A11y: the row looks like plain display, so announce it as a button —
    // otherwise the edit tap is undiscoverable.
    return Semantics(
      button: true,
      hint: context.l10n.foodEditMealTitle,
      child: InkWell(
        key: ValueKey('analyse-existing-edit-${meal.id}'),
        onTap: () => onEdit!(meal),
        borderRadius: BorderRadius.circular(rControl),
        child: row,
      ),
    );
  }
}
