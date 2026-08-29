import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../models/macro_progress.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
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

/// A diary slot card: avatar, slot name, summary line, a plus button opening
/// the add sheet for THIS slot, and the entries as swipeable rows below.
class DiaryMealCard extends StatelessWidget {
  const DiaryMealCard({
    super.key,
    required this.slot,
    required this.entries,
    this.onAddToSlot,
    this.onMealTap,
    this.onRemoveMeal,
  });

  final MealSlot slot;

  /// The entries of this slot with their day index.
  final List<DiaryEntry> entries;

  /// Plus button and empty add slot: opens the add sheet in [slot].
  final ValueChanged<MealSlot>? onAddToSlot;

  /// Fallback for a row tap when no [MealEditScope] sits above the card
  /// (preview/standalone).
  final ValueChanged<MealSlot>? onMealTap;

  final ValueChanged<String>? onRemoveMeal;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final color = slot.accentIn(context);
    // Slot kcal AND macros from one sum — the same number base as the daily
    // balance (MacroProgress), instead of re-parsing gram strings here.
    final total = entries.fold<MacroProgress>(
      MacroProgress.empty,
      (sum, e) => sum.add(e.meal.result),
    );

    return AppCard(
      radius: rCard,
      clip: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            // The plus button wears 6 pt of transparent tap margin around its
            // 32 pt chip. The header gives those 6 pt back on the right (and
            // the gap before it gives back the same 6), so chip, text column
            // and avatar keep the pixel positions they had at 15/8. Without a
            // plus button there is no margin to compensate.
            //
            // Vertically the target is not free: a card WITHOUT entries has a
            // 40 pt header row at text scale 1.0 and grows to the button's 44.
            // Every card with entries, and every scale from 1.3 up, is taller
            // than that anyway and does not move.
            padding: EdgeInsets.fromLTRB(
              15,
              14,
              onAddToSlot == null ? 15 : 15 - _addTapBleed,
              14,
            ),
            child: Row(
              children: <Widget>[
                MealAvatar(letter: slot.initial(l10n), color: color, size: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        slot.label(l10n),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.ui(
                          14.5,
                          weight: FontWeight.w700,
                          color: t.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entries.isEmpty
                            ? l10n.todayMealSlotEmpty
                            : l10n.foodDiarySlotSummary(
                                total.kcal,
                                entries.length,
                              ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.display(11.5, color: t.ink2),
                      ),
                      // Slot macros as their own line below the summary; the
                      // summary line itself stays unchanged (tests read it as
                      // a whole).
                      if (entries.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 1),
                        Text(
                          _macroLine(l10n, total),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.display(11, color: t.ink2),
                        ),
                      ],
                    ],
                  ),
                ),
                if (onAddToSlot != null) ...<Widget>[
                  const SizedBox(width: 8 - _addTapBleed),
                  _SlotAddButton(
                    slot: slot,
                    onTap: () => onAddToSlot!(slot),
                  ),
                ],
              ],
            ),
          ),
          for (final entry in entries)
            _SlidableEntry(
              entry: entry,
              accent: color,
              onMealTap: onMealTap,
              onRemoveMeal: onRemoveMeal,
            ),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(15, 0, 15, 14),
              child: DottedAddSlot(
                key: ValueKey('food-slot-empty-${slot.name}'),
                label: l10n.foodSlotAddLabel(slot.label(l10n)),
                onTap: onAddToSlot == null ? null : () => onAddToSlot!(slot),
              ),
            ),
        ],
      ),
    );
  }
}

/// Rounded grams from a [MacroProgress] sum. Used for both the slot header
/// (all entries) and each history row (one entry) so they never drift apart.
String _macroLine(AppLocalizations l10n, MacroProgress m) =>
    l10n.foodMacroSummary(m.proteinG.round(), m.carbsG.round(), m.fatG.round());

/// Drawn size of the plus chip — what the eye sees, not what the finger hits.
const double _addChipSize = 32;

/// The project's tap-target floor (`AppToggle`, `SquareIconButton`, the
/// favorites search clear key). WCAG 2.5.8 would already be happy at 24.
const double _addTapTarget = 44;

/// Transparent tap margin the floor adds on each side of the chip. The card
/// header hands these pixels back so the chip does not move (see [build]).
const double _addTapBleed = (_addTapTarget - _addChipSize) / 2;

/// The forest-coloured plus button of the slot card.
///
/// 32 pt visible, 44 pt tappable — the extra area is transparent and sits
/// outside the drawn chip, exactly like `SquareIconButton`.
class _SlotAddButton extends StatelessWidget {
  const _SlotAddButton({required this.slot, required this.onTap});

  final MealSlot slot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Semantics(
      button: true,
      label: l10n.foodSlotAddLabel(slot.label(l10n)),
      child: SizedBox(
        key: ValueKey('food-slot-add-${slot.name}'),
        width: _addTapTarget,
        height: _addTapTarget,
        child: Material(
          // Transparent, so the tap area reaches the full 44 pt while the
          // forest surface below stays 32 pt.
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(rChip),
            child: Center(
              child: Container(
                width: _addChipSize,
                height: _addChipSize,
                decoration: BoxDecoration(
                  color: t.forest,
                  borderRadius: BorderRadius.circular(rChip),
                ),
                child: Icon(Icons.add_rounded, size: 17, color: t.lime),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Share of the row width taken by the revealed delete action, and the window
/// of the reveal animation: the controller runs from 0 to exactly this value
/// while opening (and on to 1 on dismiss).
const double _deleteExtent = 0.26;

class _SlidableEntry extends StatelessWidget {
  const _SlidableEntry({
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

class _HistoryEntry extends StatefulWidget {
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
  State<_HistoryEntry> createState() => _HistoryEntryState();
}

class _HistoryEntryState extends State<_HistoryEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  late final CurvedAnimation _in = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  bool _gestartet = false;

  // The entrance depends on MediaQuery (reduce motion) and therefore starts
  // here, not in initState, where no InheritedWidget may be read yet.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_gestartet) return;
    _gestartet = true;

    _controller.duration =
        motionDuration(context, const Duration(milliseconds: 280));
    // Gentle stagger while the list builds. The id keys of the Slidable
    // wrappers keep per-meal state, so deleting one does not replay others.
    final delay = motionDelay(
      context,
      Duration(milliseconds: 40 * math.min(widget.index, 5)),
    );
    if (delay == Duration.zero) {
      // No timer detour: under reduced motion the row is there in the first
      // frame, so tests need not pump for it.
      _controller.forward();
      return;
    }
    Future<void>.delayed(delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _in.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final meal = widget.meal;
    final grams = meal.result.estimatedGrams;
    final amount = grams > 0 ? '~$grams g' : l10n.foodPortionFallback;
    // No macro line when all three are unknown (legacy rows without
    // nutrition): all-zero grams would look like a measurement. Same rule as
    // ExistingMealsList; the slot header always shows its sum.
    final rowMacros = MacroProgress.empty.add(meal.result);
    final hasMacros =
        rowMacros.proteinG > 0 || rowMacros.carbsG > 0 || rowMacros.fatG > 0;

    return FadeTransition(
      opacity: _in,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.20),
          end: Offset.zero,
        ).animate(_in),
        // A11y: the row opens the edit sheet, so announce it as a button with
        // a hint (only when a tap is wired up at all).
        child: Semantics(
          button: widget.onTap != null,
          hint: widget.onTap == null ? null : l10n.foodEditMealTitle,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: t.surf,
              border: Border(top: BorderSide(color: t.line)),
            ),
            child: InkWell(
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 15,
                  vertical: 11,
                ),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 3,
                      height: 26,
                      decoration: BoxDecoration(
                        color: widget.accent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            meal.result.mealName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.ui(
                              13,
                              weight: FontWeight.w600,
                              color: t.ink,
                            ),
                          ),
                          const SizedBox(height: 1),
                          // The slot is repeated here so the row stays
                          // self-explanatory outside its card; a test reads
                          // exactly this format as ONE Text widget.
                          Text(
                            '${meal.slot.label(l10n)} · $amount',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.ui(11, color: t.ink2),
                          ),
                          // Macros as a THIRD line, not beside slot/amount:
                          // at 390 pt and text scale 1.3 only ~110 pt remain
                          // next to the kcal column and the line would clip.
                          if (hasMacros) ...<Widget>[
                            const SizedBox(height: 2),
                            Text(
                              _macroLine(l10n, rowMacros),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.display(11, color: t.ink2),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          '${meal.result.caloriesKcal} kcal',
                          style: AppType.display(
                            12.5,
                            weight: FontWeight.w700,
                            color: t.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          formatMealTime(meal.loggedAt),
                          style: AppType.display(11, color: t.ink2),
                        ),
                      ],
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

/// Local wall-clock time `HH:mm` of a meal for the history row.
String formatMealTime(DateTime dt) {
  final local = dt.toLocal();
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  return '$h:$m';
}
