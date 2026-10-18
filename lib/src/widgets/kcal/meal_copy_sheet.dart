import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../screens/today/today_day_strip.dart';
import '../../services/day_math.dart';
import '../../services/kcal_format.dart';
import '../../theme/app_tokens.dart';
import '../common/persistence_action.dart';
import '../design/design.dart';
import 'food_date_picker.dart';
import 'slot_selector.dart';

/// Store callback that copies the logged meals [ids] onto [day], into [slot]
/// or each one's own slot, and returns the ids of the copies.
typedef CopyMeals =
    FutureOr<List<String>> Function(
      List<String> ids, {
      required DateTime day,
      MealSlot? slot,
    });

/// Opens "Copy to…" for [meal]: target day (today preselected, the same
/// bounds as the edit sheet's move) and target slot (the meal's own slot
/// preselected). Resolves true once [onCopy] committed, null when closed.
Future<bool?> showMealCopySheet(
  BuildContext context, {
  required LoggedMeal meal,
  required Future<void> Function(DateTime day, MealSlot slot) onCopy,
}) => showEatovaSheet<bool>(
  context,
  MealCopySheet(meal: meal, onCopy: onCopy),
  // Under a commit guard: Material's handle would pop past it.
  dragHandle: false,
);

class MealCopySheet extends StatefulWidget {
  const MealCopySheet({super.key, required this.meal, required this.onCopy});

  final LoggedMeal meal;
  final Future<void> Function(DateTime day, MealSlot slot) onCopy;

  @override
  State<MealCopySheet> createState() => _MealCopySheetState();
}

class _MealCopySheetState extends State<MealCopySheet> {
  late MealSlot _slot = widget.meal.slot;
  late DateTime _day = startOfDay(clock.now());
  bool _saving = false;

  /// The edit sheet's move bounds: two years back, nothing in the future.
  static DateTime _firstDate(DateTime today) =>
      DateTime(today.year - 2, today.month, today.day);

  /// The calendar for days beyond the strip.
  Future<void> _pickOtherDay() async {
    final today = startOfDay(clock.now());
    final firstDate = _firstDate(today);
    var initial = _day;
    if (initial.isBefore(firstDate)) initial = firstDate;
    if (initial.isAfter(today)) initial = today;
    final picked = await showFoodDatePicker(
      context,
      initialDate: initial,
      firstDate: firstDate,
      today: today,
      confirmLabel: context.l10n.foodDatePickerHelpText,
    );
    if (!mounted || picked == null) return;
    setState(() => _day = startOfDay(picked));
  }

  Future<void> _copy() async {
    if (_saving) return;
    setState(() => _saving = true);
    final copied = await tryPersistChange(
      context,
      () => widget.onCopy(_day, _slot),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (copied) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final result = widget.meal.result;
    final today = startOfDay(clock.now());
    final grams = result.estimatedGrams;
    // No-break spaces keep each number with its unit.
    final kcal =
        '${formatThousands(result.caloriesKcal, l10n.localeName)}\u00a0kcal';
    final summary = grams > 0 ? '$kcal · $grams\u00a0g' : kcal;
    return CommitDismissGuard(
      pending: _saving,
      child: Column(
        key: const ValueKey('meal-copy-sheet'),
        mainAxisSize: MainAxisSize.min,
        children: [
          SheetHandle(onDismiss: () => Navigator.of(context).maybePop()),
          SheetHeader(
            leading: SlotIconTile(slot: _slot, size: 40),
            title: l10n.foodCopySheetTitle,
            subtitle: result.resolvedMealName(l10n),
            subtitleMaxLines: 1,
            onClose: () => Navigator.of(context).maybePop(),
            closeEnabled: !_saving,
            closeKey: const ValueKey('meal-copy-close'),
            closeTooltip: l10n.commonClose,
          ),
          Flexible(
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                key: const ValueKey('meal-copy-scroll'),
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      summary,
                      key: const ValueKey('meal-copy-summary'),
                      style: AppType.display(16, color: t.ink),
                    ),
                    const SizedBox(height: 18),
                    _SectionLabel(l10n.foodSectionDay),
                    const SizedBox(height: 8),
                    TodayDayStrip(
                      key: const ValueKey('meal-copy-day-picker'),
                      selectedDate: _day,
                      today: today,
                      firstDate: _firstDate(today),
                      onSelected: (day) =>
                          setState(() => _day = startOfDay(day)),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: SoftPillButton(
                        key: const ValueKey('meal-copy-calendar'),
                        onTap: _saving ? null : _pickOtherDay,
                        icon: Icons.calendar_month_rounded,
                        label:
                            '${l10n.foodOtherDateLine1} ${l10n.foodOtherDateLine2}',
                        semanticLabel: l10n.foodOtherDateCalendarSemantics,
                        tone: SoftPillTone.neutral,
                      ),
                    ),
                    const SizedBox(height: 18),
                    _SectionLabel(l10n.foodSectionMeal),
                    const SizedBox(height: 8),
                    SlotSelector(
                      key: const ValueKey('meal-copy-slot-select'),
                      selected: _slot,
                      keyPrefix: 'copy-slot-select-',
                      onSelected: (slot) => setState(() => _slot = slot),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      l10n.foodCopyOriginalStays,
                      style: AppType.ui(13, color: t.ink2, height: 1.4),
                    ),
                    const SizedBox(height: 18),
                    PrimaryActionButton(
                      key: const ValueKey('meal-copy-confirm'),
                      onTap: _copy,
                      busy: _saving,
                      icon: Icons.content_copy_rounded,
                      label: l10n.foodCopyConfirm,
                    ),
                  ],
                ),
              ),
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
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    semanticsLabel: text,
    style: AppType.eyebrow(context.t.ink2, size: 11),
  );
}
