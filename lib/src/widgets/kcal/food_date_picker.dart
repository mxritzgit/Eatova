import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../design/design.dart';

/// The app's calendar sheet. [lastDate] defaults to [today] (diary days);
/// [confirmLabel] defaults to the Food tab's "Open day".
Future<DateTime?> showFoodDatePicker(
  BuildContext context, {
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime today,
  DateTime? lastDate,
  String? confirmLabel,
  String? contextLabel,
}) => showEatovaSheet<DateTime>(
  context,
  FoodDatePicker(
    initialDate: initialDate,
    firstDate: firstDate,
    today: today,
    lastDate: lastDate,
    confirmLabel: confirmLabel,
    contextLabel: contextLabel,
  ),
);

/// Calendar changes remain a draft until the diary day is confirmed.
///
/// Calendar only: Material's typed-date mode (an orphaned toggle icon and the
/// stock outlined "Enter date" field) was dropped; the themed month grid and
/// the Today pill cover every reachable day.
class FoodDatePicker extends StatefulWidget {
  const FoodDatePicker({
    super.key,
    required this.initialDate,
    required this.firstDate,
    required this.today,
    this.lastDate,
    this.confirmLabel,
    this.contextLabel,
  });
  final DateTime initialDate, firstDate, today;

  /// Last pickable day; null is [today].
  final DateTime? lastDate;

  /// Label of the confirm button; null is "Open day".
  final String? confirmLabel;

  /// The small line above the chosen date (what the day is for); null is
  /// "Nutrition", the Food tab's diary.
  final String? contextLabel;

  @override
  State<FoodDatePicker> createState() => _FoodDatePickerState();
}

class _FoodDatePickerState extends State<FoodDatePicker> {
  late DateTime _day = DateUtils.dateOnly(widget.initialDate);
  int _calendarVersion = 0;

  void _confirm() => Navigator.of(context).pop(_day);

  void _today() => setState(() {
    _day = DateUtils.dateOnly(widget.today);
    _calendarVersion++;
  });

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final material = MaterialLocalizations.of(context);
    final theme = Theme.of(context);
    final scale = MediaQuery.textScalerOf(context);
    final calendarTheme = DatePickerThemeData(
      weekdayStyle: AppType.ui(12, weight: FontWeight.w600, color: t.ink2),
      dayStyle: AppType.ui(14, weight: FontWeight.w600),
      yearStyle: AppType.ui(16),
      dayShape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(rControl)),
      ),
      dayForegroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? t.ink2.withValues(alpha: .45)
            : states.contains(WidgetState.selected)
            ? t.onLime
            : t.ink,
      ),
      dayBackgroundColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? t.lime : Colors.transparent,
      ),
      todayForegroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? t.onLime : t.accent,
      ),
      todayBackgroundColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? t.lime : t.brandSurface,
      ),
      todayBorder: BorderSide.none,
    );
    return Column(
      key: const ValueKey('food-date-picker'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SheetHeader(
                  title: l10n.foodDatePickerHelpText,
                  onClose: () => Navigator.of(context).pop(),
                  closeKey: const ValueKey('food-date-close'),
                  closeTooltip: l10n.commonClose,
                  padding: const EdgeInsets.fromLTRB(20, 0, 18, 12),
                ),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: t.brandSurface,
                    borderRadius: BorderRadius.circular(rCard),
                  ),
                  child: Row(
                    children: [
                      Text(
                        material.formatDecimal(_day.day),
                        style: AppType.display(48, color: t.onBrandSurface),
                      ),
                      const SizedBox(width: 18),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.contextLabel ?? l10n.foodTitle,
                              style: AppType.ui(12, color: t.ink2),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              material.formatFullDate(_day),
                              key: const ValueKey('food-date-preview'),
                              style: AppType.ui(
                                15,
                                weight: FontWeight.w600,
                                color: t.onBrandSurface,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Theme(
                  data: theme.copyWith(datePickerTheme: calendarTheme),
                  child: SizedBox(
                    height: 350 + (scale.scale(14) - 14).clamp(0, 28) * 5,
                    child: CalendarDatePicker(
                      key: ValueKey('food-calendar-$_calendarVersion'),
                      initialDate: _day,
                      firstDate: widget.firstDate,
                      lastDate: widget.lastDate ?? widget.today,
                      currentDate: widget.today,
                      onDateChanged: (day) =>
                          setState(() => _day = DateUtils.dateOnly(day)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            12,
            20,
            20 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!DateUtils.isSameDay(_day, widget.today)) ...[
                SoftPillButton(
                  key: const ValueKey('food-date-today'),
                  onTap: _today,
                  icon: Icons.today_rounded,
                  label: l10n.foodCalendarToday,
                  tone: SoftPillTone.neutral,
                  expand: true,
                ),
                const SizedBox(height: 10),
              ],
              PrimaryActionButton(
                key: const ValueKey('food-date-confirm'),
                onTap: _confirm,
                label: widget.confirmLabel ?? l10n.foodCalendarOpenDay,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
