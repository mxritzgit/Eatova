import 'package:flutter/material.dart';

import '../common/lively.dart';
import '../common/persistence_action.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../../l10n/l10n.dart';
import '../../models/day_nutrition.dart';
import '../../models/logged_meal.dart';
import '../../models/macro_progress.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/recipe_pick.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../../services/kcal_format.dart';
import '../design/design.dart';
import '../recipes/recipe_photo.dart';
import 'edit_meal_sheet.dart';
import 'food_glyphs.dart';
import 'food_page_chrome.dart' show foodText;

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

/// Left edge of a card's rows: the 44 px slot tile plus its 12 px gap.
const double _rowInset = 56;

/// The card's inner padding (design: 14 px on top and at the sides).
const double _cardPad = 14;

/// A meal slot of the Food diary (dark redesign): slot tile, name and
/// "time · N items", the slot total, every entry as a row and an
/// `Add to <slot>` row. An empty slot shows its suggested kcal band and, when
/// the day's recipe pick targets it, the pick row.
///
/// Tapping a filled slot's header shows or hides the details the compact
/// rows leave out: the slot's P/C/F sum, each entry's P/C/F and logged time.
class DiaryMealCard extends StatefulWidget {
  const DiaryMealCard({
    super.key,
    required this.slot,
    required this.entries,
    this.suggestedRange,
    this.pick,
    this.onOpenPick,
    this.onAddToSlot,
    this.onMealTap,
    this.onRemoveMeal,
  });

  final MealSlot slot;

  /// The slot's entries in display order (oldest first).
  final List<DiaryEntry> entries;

  /// "Suggested 550–700 kcal" for an empty slot; null shows the empty text.
  final KcalRange? suggestedRange;

  /// The day's recipe pick, only passed to the slot it targets.
  final RecipePick? pick;
  final VoidCallback? onOpenPick;

  final ValueChanged<MealSlot>? onAddToSlot, onMealTap;
  final PersistValueChanged<String>? onRemoveMeal;

  @override
  State<DiaryMealCard> createState() => _DiaryMealCardState();
}

class _DiaryMealCardState extends State<DiaryMealCard> {
  bool _showMacros = false;

  /// Entries that were not in the previous build (a new log, a move into
  /// this slot, an undo); they grow in instead of popping. Empty on the first
  /// build and for another day, whose cards mount fresh.
  Set<String> _fresh = const <String>{};

  @override
  void didUpdateWidget(DiaryMealCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = {for (final e in oldWidget.entries) e.meal.id};
    _fresh = {
      for (final e in widget.entries)
        if (!before.contains(e.meal.id)) e.meal.id,
    };
  }

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
    final range = widget.suggestedRange;
    final String meta;
    if (empty) {
      meta = range == null
          ? l10n.todayMealSlotEmpty
          : l10n.foodSlotSuggested(
              formatThousands(range.minKcal, l10n.localeName),
              formatThousands(range.maxKcal, l10n.localeName),
            );
    } else {
      final first = entries
          .map((e) => e.meal.loggedAt)
          .reduce((a, b) => b.isBefore(a) ? b : a);
      meta = l10n.foodSlotMeta(formatMealTime(first), entries.length);
    }
    final showMacros = _showMacros && !empty;

    final header = _SlotHeader(
      slot: slot,
      meta: meta,
      kcal: empty ? null : total.kcal,
    );
    final pick = widget.pick;
    return Material(
      key: ValueKey('food-slot-card-${slot.name}'),
      color: t.surf,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rCard),
        side: BorderSide(color: t.cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (empty)
            Padding(
              key: ValueKey('food-slot-empty-${slot.name}'),
              padding: const EdgeInsets.fromLTRB(
                _cardPad,
                _cardPad,
                _cardPad,
                12,
              ),
              child: header,
            )
          else
            Semantics(
              button: true,
              expanded: showMacros,
              hint: showMacros
                  ? l10n.foodSlotHideMacros
                  : l10n.foodSlotShowMacros,
              child: InkWell(
                key: ValueKey('food-slot-toggle-${slot.name}'),
                onTap: () => setState(() => _showMacros = !_showMacros),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    _cardPad,
                    _cardPad,
                    _cardPad,
                    10,
                  ),
                  child: header,
                ),
              ),
            ),
          if (showMacros)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                _cardPad + _rowInset,
                0,
                _cardPad,
                10,
              ),
              child: Text(
                _macroLine(l10n, total),
                key: ValueKey('food-slot-macros-${slot.name}'),
                style: foodText(12, weight: FontWeight.w600, color: t.ink2),
              ),
            ),
          for (final entry in entries)
            LivelyInsert(
              key: ValueKey('food-entry-insert-${entry.meal.id}'),
              animate: _fresh.contains(entry.meal.id),
              child: _SlidableEntry(
                key: ValueKey(entry.meal.id),
                entry: entry,
                showMacros: showMacros,
                onMealTap: widget.onMealTap,
                onRemoveMeal: widget.onRemoveMeal,
              ),
            ),
          if (empty && pick != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                _cardPad + _rowInset,
                0,
                _cardPad,
                12,
              ),
              child: FoodPickRow(pick: pick, onTap: widget.onOpenPick),
            ),
          if (widget.onAddToSlot != null)
            _AddRow(slot: slot, onTap: () => widget.onAddToSlot!(slot)),
          if (widget.onAddToSlot == null) const SizedBox(height: _cardPad),
        ],
      ),
    );
  }
}

/// Slot tile, name and meta line, and the slot total on the right.
class _SlotHeader extends StatelessWidget {
  const _SlotHeader({required this.slot, required this.meta, this.kcal});

  final MealSlot slot;
  final String meta;

  /// The slot total; it counts to a new value when an entry changes.
  final int? kcal;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final total = kcal == null
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              CountingText(
                value: kcal!.toDouble(),
                format: (v) => formatThousands(v.round(), l10n.localeName),
                textKey: ValueKey('food-slot-kcal-${slot.name}'),
                style: foodText(
                  18,
                  weight: FontWeight.w800,
                  color: t.ink,
                ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              const SizedBox(width: 3),
              Text('kcal', style: foodText(12, color: t.ink3)),
            ],
          );
    final stacked = MediaQuery.textScalerOf(context).scale(14) > 21;
    final copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        HeadingSemantics(
          level: 2,
          child: Text(
            slot.label(l10n),
            style: foodText(17, weight: FontWeight.w700, color: t.ink),
          ),
        ),
        const SizedBox(height: 2),
        Text(meta, style: foodText(13, color: t.ink3)),
        if (stacked && total != null) ...[
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: total,
          ),
        ],
      ],
    );
    return Row(
      children: [
        SlotIconTile(slot: slot),
        const SizedBox(width: 12),
        Expanded(child: copy),
        if (!stacked && total != null) ...[const SizedBox(width: 10), total],
      ],
    );
  }
}

/// `+ Add to <slot>`: 48 px row in accent text above a faint rule.
class _AddRow extends StatelessWidget {
  const _AddRow({required this.slot, required this.onTap});

  final MealSlot slot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(_cardPad + _rowInset, 0, _cardPad, 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: t.line)),
        ),
        child: Semantics(
          button: true,
          child: InkWell(
            key: ValueKey('food-slot-add-${slot.name}'),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    FoodGlyphIcon(
                      FoodGlyph.plus,
                      size: 16,
                      color: t.accentText,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        l10n.foodSlotAddLabel(slot.label(l10n)),
                        style: foodText(
                          14,
                          weight: FontWeight.w700,
                          color: t.accentText,
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

/// The recipe pick in an empty slot ("FITS TONIGHT · 610 KCAL" + title):
/// thumbnail, eyebrow and title on the raised well, chevron at the end.
class FoodPickRow extends StatelessWidget {
  const FoodPickRow({super.key, required this.pick, this.onTap});

  final RecipePick pick;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final eyebrow = foodPickEyebrow(pick, l10n);
    return Semantics(
      button: true,
      hint: l10n.recipesViewRecipe,
      child: PressScale(
        enabled: onTap != null,
        scale: kPressScaleCard,
        child: Material(
          color: t.surfRaised,
          borderRadius: BorderRadius.circular(rControl),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey('food-pick-row'),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(rChip),
                    child: SizedBox.square(
                      dimension: 40,
                      child: ExcludeSemantics(
                        child: RecipePhoto(recipe: pick.recipe),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          eyebrow.toUpperCase(),
                          semanticsLabel: eyebrow,
                          style: foodText(
                            11,
                            weight: FontWeight.w700,
                            color: t.accentText,
                            letterSpacing: 11 * 0.06,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          pick.recipe.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: foodText(
                            14,
                            weight: FontWeight.w600,
                            color: t.ink,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  FoodGlyphIcon(
                    FoodGlyph.chevronRight,
                    size: 16,
                    color: t.ink3,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Eyebrow of [FoodPickRow]: a planned meal says so; a suggestion "fits
/// tonight" for dinner and "fits your day" for the other slots.
String foodPickEyebrow(RecipePick pick, AppLocalizations l10n) {
  final kcal = pick.kcal;
  if (pick.source == RecipePickSource.planned || kcal == null) {
    return kcal == null
        ? l10n.foodPickPlannedNoKcal
        : l10n.foodPickPlanned(formatThousands(kcal, l10n.localeName));
  }
  final value = formatThousands(kcal, l10n.localeName);
  return pick.slot == MealSlot.dinner
      ? l10n.foodPickFitsTonight(value)
      : l10n.foodPickFitsDay(value);
}

String _macroLine(AppLocalizations l10n, MacroProgress m) =>
    l10n.foodMacroSummary(m.proteinG.round(), m.carbsG.round(), m.fatG.round());

/// A diary row's amount: grams, marked "~" when they are an AI estimate.
String diaryAmountLabel(MealAnalysisResult result, AppLocalizations l10n) {
  final grams = result.estimatedGrams;
  if (grams <= 0) return l10n.foodPortionFallback;
  final estimate = switch (MealResultSource.resolve(result.sourceLabel)) {
    MealResultSource.photoAi || MealResultSource.aiEstimate => true,
    _ => false,
  };
  return estimate ? '~$grams g' : '$grams g';
}

/// Share of the row width taken by the revealed delete action, and the window
/// of the reveal animation: the controller runs from 0 to exactly this value
/// while opening (and on to 1 on dismiss).
const double _deleteExtent = 0.26;

class _SlidableEntry extends StatefulWidget {
  const _SlidableEntry({
    super.key,
    required this.entry,
    required this.showMacros,
    required this.onMealTap,
    required this.onRemoveMeal,
  });

  final DiaryEntry entry;
  final bool showMacros;
  final ValueChanged<MealSlot>? onMealTap;
  final PersistValueChanged<String>? onRemoveMeal;

  @override
  State<_SlidableEntry> createState() => _SlidableEntryState();
}

class _SlidableEntryState extends State<_SlidableEntry> {
  bool _deleting = false;
  final _rowKey = GlobalKey();

  Future<void> _delete(BuildContext actionContext) async {
    if (_deleting) return;
    _deleting = true;
    await tryPersistChange(context, () async {
      await widget.onRemoveMeal?.call(widget.entry.meal.id);
    });
    _deleting = false;
    if (actionContext.mounted) await Slidable.of(actionContext)?.close();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final onMealTap = widget.onMealTap;
    final onRemoveMeal = widget.onRemoveMeal;
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
      tap = () => onMealTap(meal.slot);
    } else {
      tap = null;
    }

    final row = _HistoryEntry(
      key: ValueKey('food-history-entry-${entry.index}'),
      meal: meal,
      showMacros: widget.showMacros,
      onTap: tap,
    );

    // The rows start under the slot name; the rule above each row too.
    Widget inset(Widget child) => Padding(
      padding: const EdgeInsets.fromLTRB(_cardPad + _rowInset, 0, _cardPad, 0),
      child: child,
    );

    // Without a delete callback: a plain row, no swipe.
    if (onRemoveMeal == null) return inset(row);

    // Commit before removing the row. A failed write closes the action pane
    // and keeps the existing entry available for retry.
    return inset(
      ClipRect(
        key: ValueKey('food-history-clip-${meal.id}'),
        child: Slidable(
          key: ValueKey('slide-${meal.id}'),
          groupTag: 'food-history',
          endActionPane: ActionPane(
            motion: const ScrollMotion(),
            extentRatio: _deleteExtent,
            dismissible: DismissiblePane(
              confirmDismiss: () async {
                await _delete(_rowKey.currentContext ?? context);
                // The committed store change owns removal from the list.
                return false;
              },
              onDismissed: () {},
            ),
            children: <Widget>[
              _DeleteMealAction(
                key: ValueKey('food-history-delete-${entry.index}'),
                onDelete: _delete,
              ),
            ],
          ),
          child: Builder(key: _rowKey, builder: (_) => row),
        ),
      ),
    );
  }
}

class _DeleteMealAction extends StatelessWidget {
  const _DeleteMealAction({super.key, required this.onDelete});

  final Future<void> Function(BuildContext) onDelete;

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
      // Keep the row visible while its durable deletion is pending.
      autoClose: false,
      onPressed: (actionContext) async {
        HapticFeedback.mediumImpact();
        await onDelete(actionContext);
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
              width: 44,
              height: 44,
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

/// One entry: name over its amount, kcal on the right; with the slot's macro
/// details open, the entry's own P/C/F line joins the amount and its logged
/// time the kcal.
class _HistoryEntry extends StatelessWidget {
  const _HistoryEntry({
    super.key,
    required this.meal,
    required this.showMacros,
    required this.onTap,
  });

  final LoggedMeal meal;
  final bool showMacros;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final macros = MacroProgress.empty.add(meal.result);
    final hasMacros =
        macros.proteinG > 0 || macros.carbsG > 0 || macros.fatG > 0;
    final kcalNumber = formatThousands(
      meal.result.caloriesKcal,
      l10n.localeName,
    );
    final kcalText = Text(
      kcalNumber,
      // The unit is implicit on screen only.
      semanticsLabel: '$kcalNumber kcal',
      style: foodText(
        14,
        weight: FontWeight.w600,
        color: t.ink2,
      ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
    );
    // With the details open, the logged time joins the kcal (as the rows
    // before the redesign showed it).
    final kcal = showMacros
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              kcalText,
              const SizedBox(height: 1),
              Text(
                formatMealTime(meal.loggedAt),
                key: ValueKey('food-entry-time-${meal.id}'),
                style: foodText(12, color: t.ink3),
              ),
            ],
          )
        : kcalText;
    // Opaque row: it slides over the delete action.
    return Semantics(
      button: onTap != null,
      hint: onTap == null ? null : l10n.foodEditMealTitle,
      child: Material(
        color: t.surf,
        child: InkWell(
          onTap: onTap,
          // A Container: the 1 px rule takes layout space, as in the design.
          child: Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: t.line)),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            meal.result.resolvedMealName(l10n),
                            style: foodText(
                              14,
                              weight: FontWeight.w600,
                              color: t.ink,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            diaryAmountLabel(meal.result, l10n),
                            style: foodText(12, color: t.ink3),
                          ),
                          if (showMacros && hasMacros)
                            Text(
                              _macroLine(l10n, macros),
                              style: foodText(12, color: t.ink3),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    kcal,
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
