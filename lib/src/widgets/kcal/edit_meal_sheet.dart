import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/meal_component.dart';
import '../../services/day_math.dart';
import '../../services/local_day.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../common/motion.dart';
import '../design/design.dart';
import '../meal/meal_widgets.dart';
import 'slot_selector.dart';

/// Store callback for the edit sheet: changes portion/components, slot and/or
/// day of a logged meal (null = unchanged) and returns the new state, or null
/// if the id no longer exists.
typedef UpdateMealDetails =
    LoggedMeal? Function(
      String id, {
      MealAnalysisResult? result,
      MealSlot? slot,
      DateTime? day,
    });

/// Provides the HomeStore edit callbacks below the food tab.
///
/// The diary slot cards and the AddMealSheet live under
/// `MealAnalysisScreen`, whose signature stays untouched, so the scope routes
/// the callbacks past the screen straight to the widgets that open the edit
/// sheet. Without the scope (previews, standalone tests) those widgets fall
/// back to their previous behaviour.
class MealEditScope extends InheritedWidget {
  const MealEditScope({
    super.key,
    required this.onUpdateMeal,
    required this.onRemoveMeal,
    required super.child,
  });

  final UpdateMealDetails onUpdateMeal;
  final ValueChanged<String> onRemoveMeal;

  /// Deliberately without dependency registration (getInherited…): the
  /// callbacks are stable store tear-offs and the lookup also happens outside
  /// build (sheet openers).
  static MealEditScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<MealEditScope>();

  @override
  bool updateShouldNotify(MealEditScope oldWidget) =>
      onUpdateMeal != oldWidget.onUpdateMeal ||
      onRemoveMeal != oldWidget.onRemoveMeal;
}

/// Edit-sheet result for callers holding a local list copy (AddMealSheet):
/// the saved new state or a deletion. A null future result means closed
/// without changes.
class MealEditOutcome {
  const MealEditOutcome.saved(LoggedMeal this.meal) : deleted = false;
  const MealEditOutcome.deleted() : meal = null, deleted = true;

  final LoggedMeal? meal;
  final bool deleted;
}

/// Opens the edit sheet for a logged meal. A null [onRemoveMeal] means no
/// delete button, e.g. when the caller has no remove path wired up.
Future<MealEditOutcome?> showEditMealSheet(
  BuildContext context, {
  required LoggedMeal meal,
  required UpdateMealDetails onUpdateMeal,
  ValueChanged<String>? onRemoveMeal,
}) {
  return showModalBottomSheet<MealEditOutcome>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // Deliberately not a token: the scrim must darken in both themes.
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (sheetContext) {
      return EditMealSheet(
        meal: meal,
        onUpdateMeal: onUpdateMeal,
        onRemoveMeal: onRemoveMeal,
      );
    },
  );
}

/// Shared "discard changes?" confirmation for every way of closing a dirty
/// sheet.
///
/// `barrierDismissible: true` is intentional: a tap beside the dialog means
/// cancel, the harmless answer. The dialog sits on the root navigator above
/// the sheet route, so its own barrier swallows that tap and the sheet below
/// never sees it.
///
/// Returns true to discard, false to keep the sheet open.
Future<bool> _confirmDiscardChanges(BuildContext context) async {
  final t = context.t;
  final l10n = context.l10n;
  final verwerfen = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('discard-changes-dialog'),
      backgroundColor: t.surf,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rSheet),
      ),
      title: Text(
        l10n.foodDiscardChangesTitle,
        style: AppType.display(19, color: t.ink),
      ),
      content: Text(
        l10n.foodDiscardChangesBody,
        style: AppType.ui(13, color: t.ink2, height: 1.4),
      ),
      actions: [
        TextButton(
          key: const ValueKey('discard-changes-cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.foodDiscardChangesKeepEditing),
        ),
        TextButton(
          key: const ValueKey('discard-changes-confirm'),
          style: TextButton.styleFrom(foregroundColor: t.danger),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.foodDiscardChangesConfirm),
        ),
      ],
    ),
  );
  return verwerfen ?? false;
}

/// Intercepts the drag-down dismissal of a modal bottom sheet.
///
/// `PopScope` only covers half of it: a barrier tap goes through
/// `Navigator.maybePop` and asks the pop disposition, but a drag goes
/// `BottomSheet._handleDragEnd` -> `onClosing` -> `Navigator.pop` and never
/// does. The only lever from inside the sheet is the gesture arena: a vertical
/// drag recognizer in the builder child sits below
/// `_BottomSheetGestureDetector` and wins, the same way a ScrollView swallows
/// the drag. Scrollable areas sit deeper still and stay unaffected.
///
/// With [active] false no recognizer is registered at all, so a clean sheet
/// drags away as usual.
class _DiscardDragGuard extends StatefulWidget {
  const _DiscardDragGuard({
    required this.active,
    required this.onDismissAttempt,
    required this.child,
  });

  final bool active;
  final VoidCallback onDismissAttempt;
  final Widget child;

  @override
  State<_DiscardDragGuard> createState() => _DiscardDragGuardState();
}

class _DiscardDragGuardState extends State<_DiscardDragGuard> {
  /// Minimum downward distance counted as close intent. Small on purpose: the
  /// guard swallows the gesture either way, this only decides whether the user
  /// gets an answer.
  static const double _closeIntentPx = 32;

  /// Fling threshold, mirroring `_kMinFlingVelocity` from bottom_sheet.dart.
  static const double _flingVelocity = 700;

  double _dy = 0;

  void _onStart(DragStartDetails details) => _dy = 0;

  void _onUpdate(DragUpdateDetails details) => _dy += details.primaryDelta ?? 0;

  void _onEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (_dy > _closeIntentPx || velocity > _flingVelocity) {
      widget.onDismissAttempt();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    return GestureDetector(
      // Without translucent, gaps between children stay uncovered.
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _onStart,
      onVerticalDragUpdate: _onUpdate,
      onVerticalDragEnd: _onEnd,
      child: widget.child,
    );
  }
}

class EditMealSheet extends StatefulWidget {
  const EditMealSheet({
    super.key,
    required this.meal,
    required this.onUpdateMeal,
    this.onRemoveMeal,
  });

  final LoggedMeal meal;
  final UpdateMealDetails onUpdateMeal;
  final ValueChanged<String>? onRemoveMeal;

  @override
  State<EditMealSheet> createState() => _EditMealSheetState();
}

class _EditMealSheetState extends State<EditMealSheet> {
  /// Days back from today in the chip picker; matches the 35-day boot window
  /// of MealsSync.loadLoggedMeals. Older targets go through the calendar
  /// entry: the row stays on the server and the food tab loads that day on
  /// demand, so a moved meal is outside the boot window, not gone.
  static const int _pickerDays = 35;

  late MealAnalysisResult _result;
  bool _resultChanged = false;
  late MealSlot _slot;
  late DateTime _day;

  @override
  void initState() {
    super.initState();
    _result = widget.meal.result;
    _slot = widget.meal.slot;
    // effectiveLocalDay ('YYYY-MM-DD') parses as local midnight, the same day
    // anchor the bucketing uses.
    _day = DateUtils.dateOnly(DateTime.parse(widget.meal.effectiveLocalDay));
  }

  bool get _slotChanged => _slot != widget.meal.slot;

  bool get _dayChanged => localDayKey(_day) != widget.meal.effectiveLocalDay;

  bool get _dirty => _resultChanged || _slotChanged || _dayChanged;

  /// Adjusts portion/components through the existing
  /// showWeightAdjustmentSheet editor. Same pattern as
  /// MealAnalysisSheet._adjustPortion, but without an immediate save: the
  /// change only lands on "save".
  Future<void> _adjustPortion() async {
    final adjustment = await showWeightAdjustmentSheet(context, _result);
    if (!mounted || adjustment == null) return;

    MealAnalysisResult? candidate;
    if (adjustment is int && adjustment > 0) {
      candidate = _result.adjustedToGrams(adjustment);
    } else if (adjustment is List<MealComponent>) {
      candidate = _result.adjustedToItems(adjustment);
    }
    if (candidate == null) return;
    setState(() {
      _result = candidate!;
      _resultChanged = true;
    });
  }

  /// Calendar for targets beyond the chips, rendered in the active app
  /// language. Same bounds as the food-tab calendar: two years back, nothing
  /// in the future. Feeds the same _day state as the chips; saving still runs
  /// only through updateLoggedMealDetails.
  Future<void> _pickOtherDay() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final firstDate = DateTime(today.year - 2, today.month, today.day);
    var initial = _day;
    if (initial.isBefore(firstDate)) initial = firstDate;
    if (initial.isAfter(today)) initial = today;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: firstDate,
      lastDate: today,
      helpText: context.l10n.foodDatePickerHelpText,
    );
    if (!mounted || picked == null) return;
    setState(() => _day = DateUtils.dateOnly(picked));
  }

  void _save() {
    final updated = widget.onUpdateMeal(
      widget.meal.id,
      result: _resultChanged ? _result : null,
      slot: _slotChanged ? _slot : null,
      day: _dayChanged ? _day : null,
    );
    if (!mounted) return;
    Navigator.of(
      context,
    ).pop(updated == null ? null : MealEditOutcome.saved(updated));
  }

  void _delete() {
    widget.onRemoveMeal?.call(widget.meal.id);
    if (!mounted) return;
    Navigator.of(context).pop(const MealEditOutcome.deleted());
  }

  /// Runs for every intercepted dismiss attempt: barrier tap, system back and
  /// the close button arrive via [PopScope], dragging via
  /// [_DiscardDragGuard]. Repeat attempts do not stack dialogs.
  bool _discardDialogOpen = false;

  Future<void> _askDiscard() async {
    if (_discardDialogOpen) return;
    _discardDialogOpen = true;
    final verwerfen = await _confirmDiscardChanges(context);
    _discardDialogOpen = false;
    if (!mounted || !verwerfen) return;
    // The dialog is already popped, so the sheet is the top route again.
    // Deliberately without a result: discarded is not saved.
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    // Safe-area aware instead of a fixed 92 %: the sheet must never reach
    // under the status bar or Dynamic Island.
    final maxHeight = sheetMaxHeightOf(context);

    return PopScope<MealEditOutcome?>(
      // Only while something is actually unsaved; a clean sheet closes at once.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _askDiscard();
      },
      child: _DiscardDragGuard(
        active: _dirty,
        onDismissAttempt: _askDiscard,
        child: _buildSheet(mediaQuery, maxHeight),
      ),
    );
  }

  Widget _buildSheet(MediaQueryData mediaQuery, double maxHeight) {
    final t = context.t;
    final l10n = context.l10n;
    // No SheetScaffold: fixed header over a capped scroll area with two footer
    // actions, and `edit-meal-save-button` must stay a FilledButton because
    // tests read its `onPressed`.
    return Container(
      key: const ValueKey('edit-meal-sheet'),
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(rSheet),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SheetHandle(),
          _Header(
            slot: _slot,
            mealName: _result.mealName,
            onClose: () => Navigator.of(context).maybePop(),
          ),
          Flexible(
            child: SingleChildScrollView(
              key: const ValueKey('edit-meal-sheet-scroll'),
              padding: EdgeInsets.fromLTRB(
                20,
                4,
                20,
                24 + mediaQuery.viewPadding.bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SummaryCard(result: _result, adjusted: _resultChanged),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      key: const ValueKey('edit-meal-adjust-button'),
                      onPressed: _adjustPortion,
                      icon: const Icon(Icons.tune_rounded, size: 17),
                      label: Text(
                        l10n.foodAdjustPortionButton,
                        style: AppType.ui(13.5, weight: FontWeight.w600),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: t.ink,
                        side: BorderSide(color: t.line),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(rControl),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  _SectionLabel(l10n.foodSectionMeal),
                  const SizedBox(height: 8),
                  SlotSelector(
                    key: const ValueKey('edit-meal-slot-select'),
                    selected: _slot,
                    keyPrefix: 'edit-slot-select-',
                    onSelected: (slot) => setState(() => _slot = slot),
                  ),
                  const SizedBox(height: 18),
                  _SectionLabel(l10n.foodSectionDay),
                  const SizedBox(height: 8),
                  _DayPicker(
                    selected: _day,
                    pastDays: _pickerDays,
                    onSelected: (day) => setState(() => _day = day),
                    onCalendarTap: _pickOtherDay,
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const ValueKey('edit-meal-save-button'),
                      onPressed: _dirty ? _save : null,
                      icon: const Icon(Icons.check_rounded, size: 17),
                      label: Text(
                        l10n.commonSave,
                        style: AppType.ui(14, weight: FontWeight.w600),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: t.forest,
                        foregroundColor: t.onForest,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(rControl),
                        ),
                      ),
                    ),
                  ),
                  if (widget.onRemoveMeal != null) ...[
                    const SizedBox(height: 6),
                    Center(
                      child: TextButton.icon(
                        key: const ValueKey('edit-meal-delete-button'),
                        onPressed: _delete,
                        style: TextButton.styleFrom(foregroundColor: t.danger),
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 16,
                        ),
                        label: Text(
                          l10n.foodDeleteMealButton,
                          style: AppType.ui(13, weight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: context.t.line,
          borderRadius: BorderRadius.circular(rPill),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.slot,
    required this.mealName,
    required this.onClose,
  });

  final MealSlot slot;
  final String mealName;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final color = slot.accentIn(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 8, 12),
      child: Row(
        children: [
          MealAvatar(letter: slot.initial(l10n), color: color, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.foodEditMealTitle,
                  style: AppType.display(18, color: t.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  mealName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.ui(
                    12,
                    weight: FontWeight.w500,
                    color: t.ink2,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('edit-meal-sheet-close'),
            onPressed: onClose,
            tooltip: l10n.commonClose,
            icon: Icon(Icons.close_rounded, color: t.ink2),
          ),
        ],
      ),
    );
  }
}

/// Compact live summary of the (possibly already adjusted) values.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.result, required this.adjusted});

  final MealAnalysisResult result;
  final bool adjusted;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AppCard(
      key: const ValueKey('edit-meal-summary'),
      radius: rCard,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(
            Icons.local_fire_department_outlined,
            color: t.accent,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${result.caloriesKcal} kcal · ${result.estimatedGrams} g',
              style: AppType.display(16, color: t.ink),
            ),
          ),
          Text(
            adjusted
                ? context.l10n.foodAdjustedLabel
                : result.resolvedSourceLabel(context.l10n),
            style: AppType.ui(
              11,
              weight: FontWeight.w600,
              color: adjusted ? t.ink : t.ink2,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: AppType.eyebrow(context.t.ink2, size: 11),
    );
  }
}

/// One-time init of the `intl` date symbols — the same bool guard as in
/// `meal_analysis_screen.dart`/`today_texts.dart`, which are file-private and
/// therefore not reusable.
bool _dateSymbolsReady = false;
void _ensureDateSymbols() {
  if (_dateSymbolsReady) return;
  initializeDateFormatting();
  _dateSymbolsReady = true;
}

/// The chip picker's days: [count] calendar days down from [today] (today
/// first), plus [selected] if it falls outside that window.
///
/// Calendar arithmetic, not `Duration`: across a DST switch a 23-hour day
/// makes `subtract(Duration(days: 1))` land on the previous day at 23:00, so
/// one date became unreachable and a meal moved to it was stored a day early.
///
/// [count] is the NUMBER of days, not the offset to the oldest;
/// [recentDaysDescending] takes the count directly and cannot miscount.
@visibleForTesting
List<DateTime> editMealPickerDays({
  required DateTime today,
  required int count,
  DateTime? selected,
}) {
  final days = List<DateTime>.of(
    recentDaysDescending(today: today, count: count),
  );
  if (selected != null && !days.any((d) => DateUtils.isSameDay(d, selected))) {
    days.add(startOfDay(selected));
  }
  return days;
}

/// Label of a day chip.
///
/// [daysBetween] works on `(y, m, d)` triples in UTC, so DST cannot make
/// yesterday read as "today" (a 23-hour gap gives `inDays == 0`).
///
/// Uses `intl`'s `EE` skeleton, mirroring
/// `meal_analysis_screen.dart:foodDateChipLabel` (not importable: screens/
/// imports widgets/, not the other way round). German CLDR abbreviations
/// carry a trailing period, stripped so `de` stays byte-identical.
@visibleForTesting
String editMealDayChipLabel({
  required DateTime today,
  required DateTime date,
  required AppLocalizations l10n,
}) {
  final offset = daysBetween(today, date);
  if (offset == 0) return l10n.todayDateToday;
  if (offset == 1) return l10n.todayDateYesterday;
  _ensureDateSymbols();
  return DateFormat('EE', l10n.localeName).format(date).replaceAll('.', '');
}

/// Horizontal chip picker over the last [pastDays] days (today first),
/// mirroring the food tab's date chips. The last entry ([onCalendarTap])
/// opens showDatePicker for targets beyond the chips.
class _DayPicker extends StatelessWidget {
  const _DayPicker({
    required this.selected,
    required this.pastDays,
    required this.onSelected,
    required this.onCalendarTap,
  });

  final DateTime selected;
  final int pastDays;
  final ValueChanged<DateTime> onSelected;
  final VoidCallback onCalendarTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final today = startOfDay(DateTime.now());
    // Calendar arithmetic, not absolute time — see [editMealPickerDays].
    final days = editMealPickerDays(
      today: today,
      count: pastDays,
      selected: selected,
    );

    // A horizontal ListView gives children a tight cross axis, so this is also
    // each chip's height. Fixed, the padding left 40 px for two scaling text
    // lines and chips overflowed around 1.4x system text. Same technique as
    // [MacroBar]: scale along, capped so the strip does not eat half the sheet
    // at 2.0. At normal text size it stays exactly 58.
    final scaler = MediaQuery.textScalerOf(context);
    final hoehe = scaler.scale(58).clamp(58.0, 100.0);

    return SizedBox(
      key: const ValueKey('edit-meal-day-picker'),
      height: hoehe,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        // +1 for the calendar entry at the end.
        itemCount: days.length + 1,
        separatorBuilder: (context, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          if (index == days.length) {
            return _CalendarChip(onTap: onCalendarTap);
          }
          final date = days[index];
          final isSelected = DateUtils.isSameDay(date, selected);
          // Same a11y pattern as the food-tab date chips: button + state.
          return Semantics(
            button: true,
            selected: isSelected,
            child: InkWell(
              key: ValueKey('edit-day-chip-$index'),
              onTap: () => onSelected(date),
              borderRadius: BorderRadius.circular(rControl),
              child: AnimatedContainer(
                duration:
                    motionDuration(context, const Duration(milliseconds: 160)),
                curve: Curves.easeOut,
                width: 64,
                padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
                decoration: BoxDecoration(
                  color: isSelected ? t.forest : t.surf,
                  borderRadius: BorderRadius.circular(rControl),
                  border: Border.all(
                    color: isSelected ? Colors.transparent : t.line,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      editMealDayChipLabel(today: today, date: date, l10n: l10n),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.ui(
                        10.5,
                        weight: FontWeight.w700,
                        color: isSelected ? t.lime : t.ink2,
                        letterSpacing: 0.1,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${date.day}.${date.month}.',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.display(
                        11.5,
                        weight: FontWeight.w700,
                        color: isSelected ? t.onForest : t.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Trailing entry of the day picker: same chip shape, opens the calendar for
/// targets beyond the 35 days.
class _CalendarChip extends StatelessWidget {
  const _CalendarChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // A11y: the two-line label reads chopped up, so announce one button with
    // a clear action.
    final l10n = context.l10n;
    return Semantics(
      button: true,
      label: l10n.foodOtherDateCalendarSemantics,
      child: InkWell(
        key: const ValueKey('edit-day-calendar'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(rControl),
        child: Container(
          width: 72,
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
          decoration: BoxDecoration(
            color: t.surf,
            borderRadius: BorderRadius.circular(rControl),
            border: Border.all(color: t.line),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.foodOtherDateLine1,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.ui(
                  10.5,
                  weight: FontWeight.w700,
                  color: t.ink2,
                  letterSpacing: 0.1,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                l10n.foodOtherDateLine2,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.display(
                  11.5,
                  weight: FontWeight.w700,
                  color: t.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
