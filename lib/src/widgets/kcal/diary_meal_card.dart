import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../models/macro_progress.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../../services/kcal_format.dart';
import '../common/motion.dart';
import '../design/design.dart';
import 'edit_meal_sheet.dart';

/// One diary entry with its index in the DAY list.
///
/// The index comes from a single day-wide list sorted by `loggedAt`
/// descending, not per card — only that keeps `food-history-entry-0` the
/// newest entry of the day, which several flow tests rely on.
@immutable
class DiaryEntry {
  const DiaryEntry(this.meal, this.index);

  final LoggedMeal meal;

  /// Position in the day list (0 = newest meal of the day).
  final int index;
}

/// An open meal section: compact overview first, individual entries on demand.
class DiaryMealCard extends StatefulWidget {
  const DiaryMealCard({
    super.key,
    required this.slot,
    required this.entries,
    this.onAddToSlot,
    this.onMealTap,
    this.onRemoveMeal,
  });

  final MealSlot slot;
  final List<DiaryEntry> entries;
  final ValueChanged<MealSlot>? onAddToSlot, onMealTap;
  final ValueChanged<String>? onRemoveMeal;

  @override
  State<DiaryMealCard> createState() => _DiaryMealCardState();
}

class _DiaryMealCardState extends State<DiaryMealCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final slot = widget.slot;
    final entries = widget.entries;
    final empty = entries.isEmpty;
    final total = entries.fold<MacroProgress>(
      MacroProgress.empty,
      (sum, e) => sum.add(e.meal.result),
    );
    final title = empty
        ? l10n.todayMealSlotEmpty
        : entries.length == 1
        ? entries.single.meal.result.mealName
        : l10n.foodDiaryEntryCount(entries.length);
    final detail = empty
        ? l10n.foodSlotAddLabel(slot.label(l10n))
        : entries.length == 1
        ? formatMealTime(entries.single.meal.loggedAt)
        : entries.take(2).map((e) => e.meal.result.mealName).join(', ');
    final summary = LayoutBuilder(
      builder: (context, constraints) {
        final stacked =
            constraints.maxWidth < 290 ||
            MediaQuery.textScalerOf(context).scale(14) > 21;
        final kcal = empty
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    formatThousands(total.kcal, l10n.localeName),
                    style: AppType.display(22, color: t.ink, height: 1.05),
                  ),
                  const SizedBox(height: 4),
                  Text('kcal', style: AppType.ui(12, color: t.ink2)),
                ],
              );
        final copy = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HeadingSemantics(
              level: 2,
              child: Text(
                slot.label(l10n),
                style: AppType.ui(
                  11,
                  weight: FontWeight.w600,
                  color: t.accent,
                  letterSpacing: 0.7,
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              title,
              maxLines: empty || stacked ? null : 2,
              overflow: empty || stacked ? null : TextOverflow.ellipsis,
              style: AppType.ui(
                16,
                weight: empty ? FontWeight.w400 : FontWeight.w600,
                color: t.ink,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              detail,
              maxLines: stacked ? null : 2,
              overflow: stacked ? null : TextOverflow.ellipsis,
              style: AppType.ui(12, color: t.ink2, height: 1.35),
            ),
            if (stacked && kcal != null) ...[const SizedBox(height: 10), kcal],
          ],
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ExcludeSemantics(
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: slot.diarySurface(t),
                  borderRadius: BorderRadius.circular(rCard),
                ),
                child: Icon(
                  slot.diaryIcon,
                  color: slot == MealSlot.snack ? t.accent : slot.accentOn(t),
                  size: 26,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(child: copy),
            if (!stacked && kcal != null) ...[const SizedBox(width: 14), kcal],
            const SizedBox(width: 10),
            AnimatedRotation(
              turns: _expanded && !empty ? 0.25 : 0,
              duration: motionDuration(
                context,
                const Duration(milliseconds: 180),
              ),
              child: Icon(Icons.chevron_right_rounded, size: 20, color: t.ink2),
            ),
          ],
        );
      },
    );
    return Material(
      color: t.surf,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: empty ? null : _expanded,
            hint: empty
                ? l10n.foodSlotAddLabel(slot.label(l10n))
                : (_expanded ? l10n.foodDiaryCollapse : l10n.foodDiaryExpand),
            child: InkWell(
              key: ValueKey(
                empty
                    ? 'food-slot-add-${slot.name}'
                    : 'food-slot-toggle-${slot.name}',
              ),
              onTap: empty
                  ? (widget.onAddToSlot == null
                        ? null
                        : () => widget.onAddToSlot!(slot))
                  : () => setState(() => _expanded = !_expanded),
              child: Padding(
                key: empty ? ValueKey('food-slot-empty-${slot.name}') : null,
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: summary,
              ),
            ),
          ),
          if (_expanded && !empty) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _macroLine(l10n, total),
                key: ValueKey('food-slot-macros-${slot.name}'),
                style: AppType.ui(12, weight: FontWeight.w600, color: t.ink2),
              ),
            ),
            for (final entry in entries)
              _SlidableEntry(
                key: ValueKey(entry.meal.id),
                entry: entry,
                accent: slot.accentOn(t),
                onMealTap: widget.onMealTap,
                onRemoveMeal: widget.onRemoveMeal,
              ),
            if (widget.onAddToSlot != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: TextButton.icon(
                  key: ValueKey('food-slot-add-${slot.name}'),
                  onPressed: () => widget.onAddToSlot!(slot),
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: Text(l10n.foodSlotAddLabel(slot.label(l10n))),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 48),
                    foregroundColor: t.accent,
                  ),
                ),
              ),
          ],
          if (slot != MealSlot.snack) Divider(height: 1, color: t.line),
        ],
      ),
    );
  }
}

String _macroLine(AppLocalizations l10n, MacroProgress m) =>
    l10n.foodMacroSummary(m.proteinG.round(), m.carbsG.round(), m.fatG.round());

/// Share of the row width taken by the revealed delete action, and the window
/// of the reveal animation: the controller runs from 0 to exactly this value
/// while opening (and on to 1 on dismiss).
const double _deleteExtent = 0.26;

class _SlidableEntry extends StatelessWidget {
  const _SlidableEntry({
    super.key,
    required this.entry,
    required this.accent,
    required this.onMealTap,
    required this.onRemoveMeal,
  });

  final DiaryEntry entry;
  final Color accent;
  final ValueChanged<MealSlot>? onMealTap;
  final ValueChanged<String>? onRemoveMeal;

  @override
  Widget build(BuildContext context) {
    final meal = entry.meal;
    // Edit sheet when the home shell provides a MealEditScope: a tap edits
    // THIS meal. Without a scope (preview/standalone) a tap opens the slot's
    // add sheet.
    final editScope = MealEditScope.maybeOf(context);
    final VoidCallback? tap;
    if (editScope != null) {
      tap = () => showEditMealSheet(
        context,
        meal: meal,
        onUpdateMeal: editScope.onUpdateMeal,
        onRemoveMeal: editScope.onRemoveMeal,
      );
    } else if (onMealTap != null) {
      tap = () => onMealTap!(meal.slot);
    } else {
      tap = null;
    }

    final row = _HistoryEntry(
      key: ValueKey('food-history-entry-${entry.index}'),
      meal: meal,
      accent: accent,
      index: entry.index,
      onTap: tap,
    );

    // Without a delete callback: a plain row, no swipe.
    if (onRemoveMeal == null) return row;

    // Swipe left: row and delete button move together (ScrollMotion). A full
    // swipe deletes directly; a tap on the button animates the row out first.
    return ClipRect(
      key: ValueKey('food-history-clip-${meal.id}'),
      child: Slidable(
        key: ValueKey('slide-${meal.id}'),
        groupTag: 'food-history',
        endActionPane: ActionPane(
          motion: const ScrollMotion(),
          extentRatio: _deleteExtent,
          dismissible: DismissiblePane(
            onDismissed: () => onRemoveMeal!(meal.id),
          ),
          children: <Widget>[
            _DeleteMealAction(
              key: ValueKey('food-history-delete-${entry.index}'),
              onDelete: () => onRemoveMeal!(meal.id),
            ),
          ],
        ),
        child: row,
      ),
    );
  }
}

class _DeleteMealAction extends StatelessWidget {
  const _DeleteMealAction({super.key, required this.onDelete});

  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final controller = Slidable.of(context);
    final reveal = controller == null
        ? const AlwaysStoppedAnimation<double>(1)
        : CurvedAnimation(
            parent: controller.animation,
            curve: const Interval(
              0.0,
              _deleteExtent,
              curve: Curves.easeOutCubic,
            ),
          );
    return CustomSlidableAction(
      // No autoClose: it would fire close() right after the tap and kill the
      // dismiss() animation, so onDelete would never run.
      autoClose: false,
      onPressed: (actionContext) {
        HapticFeedback.mediumImpact();
        final slidable = Slidable.of(actionContext);
        if (slidable == null) {
          onDelete();
          return;
        }
        // Slide the row out and collapse the gap before deleting, otherwise
        // the list jumps when the store rebuilds.
        //
        // Deliberately NOT via `motionDuration`: with `Duration.zero`
        // flutter_slidable's resize controller is already `completed` in the
        // next build and its debug assert about a dismissed Slidable fires
        // before `onDelete` removed the row from the tree.
        slidable.dismiss(
          ResizeRequest(const Duration(milliseconds: 220), onDelete),
        );
      },
      backgroundColor: Colors.transparent,
      foregroundColor: t.danger,
      padding: EdgeInsets.zero,
      child: FadeTransition(
        opacity: reveal,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.6, end: 1).animate(reveal),
          child: Semantics(
            button: true,
            label: context.l10n.foodEntryDeleteSemantics,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: t.danger.withValues(alpha: 0.16),
                shape: BoxShape.circle,
                border: Border.all(color: t.danger.withValues(alpha: 0.25)),
              ),
              child: Icon(
                Icons.delete_outline_rounded,
                color: t.danger,
                size: 20,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryEntry extends StatelessWidget {
  const _HistoryEntry({
    super.key,
    required this.meal,
    required this.accent,
    required this.index,
    required this.onTap,
  });

  final LoggedMeal meal;
  final Color accent;
  final int index;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final grams = meal.result.estimatedGrams;
    final amount = grams > 0 ? '~$grams g' : l10n.foodPortionFallback;
    final macros = MacroProgress.empty.add(meal.result);
    final hasMacros =
        macros.proteinG > 0 || macros.carbsG > 0 || macros.fatG > 0;
    return Semantics(
      button: onTap != null,
      hint: onTap == null ? null : l10n.foodEditMealTitle,
      child: Material(
        color: t.surf,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final stacked =
                    constraints.maxWidth < 290 ||
                    MediaQuery.textScalerOf(context).scale(14) > 21;
                final details = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      meal.result.mealName,
                      style: AppType.ui(
                        14,
                        weight: FontWeight.w600,
                        color: t.ink,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${meal.slot.label(l10n)} · $amount',
                      style: AppType.ui(12, color: t.ink2),
                    ),
                    if (hasMacros) ...[
                      const SizedBox(height: 4),
                      Text(
                        _macroLine(l10n, macros),
                        style: AppType.ui(12, color: t.ink2, height: 1.35),
                      ),
                    ],
                  ],
                );
                final energy = Column(
                  crossAxisAlignment: stacked
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${meal.result.caloriesKcal} kcal',
                      style: AppType.display(14, color: t.ink),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      formatMealTime(meal.loggedAt),
                      style: AppType.ui(12, color: t.ink2),
                    ),
                  ],
                );
                return DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(left: BorderSide(color: accent, width: 2)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: stacked
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              details,
                              const SizedBox(height: 8),
                              energy,
                            ],
                          )
                        : Row(
                            children: [
                              Expanded(child: details),
                              const SizedBox(width: 16),
                              energy,
                            ],
                          ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Local wall-clock time `HH:mm` of a meal for the history row.
String formatMealTime(DateTime dt) {
  final local = dt.toLocal();
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  return '$h:$m';
}
