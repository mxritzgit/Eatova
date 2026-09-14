import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../design/sheets.dart';

Future<DateTime?> showFoodDatePicker(
  BuildContext context, {
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime today,
}) => showEatovaSheet<DateTime>(
  context,
  FoodDatePicker(initialDate: initialDate, firstDate: firstDate, today: today),
);

/// Calendar changes remain a draft until the diary day is confirmed.
class FoodDatePicker extends StatefulWidget {
  const FoodDatePicker({
    super.key,
    required this.initialDate,
    required this.firstDate,
    required this.today,
  });
  final DateTime initialDate, firstDate, today;

  @override
  State<FoodDatePicker> createState() => _FoodDatePickerState();
}

class _FoodDatePickerState extends State<FoodDatePicker> {
  late DateTime _day = DateUtils.dateOnly(widget.initialDate);
  bool _input = false;
  int _calendarVersion = 0;
  final _form = GlobalKey<FormState>();

  void _confirm() {
    if (_input) {
      if (!_form.currentState!.validate()) return;
      _form.currentState!.save();
    }
    Navigator.of(context).pop(_day);
  }

  void _today() => setState(() {
    _day = DateUtils.dateOnly(widget.today);
    _input = false;
    _calendarVersion++;
  });

  void _toggleInput() {
    if (_input && _form.currentState!.validate()) {
      _form.currentState!.save();
    }
    setState(() => _input = !_input);
  }

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
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.foodDatePickerHelpText,
                          style: AppType.display(24, color: t.ink),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('food-date-close'),
                        tooltip: l10n.commonClose,
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
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
                              l10n.foodTitle,
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
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    key: const ValueKey('food-date-input-toggle'),
                    tooltip: _input
                        ? material.calendarModeButtonLabel
                        : material.inputDateModeButtonLabel,
                    onPressed: _toggleInput,
                    icon: Icon(
                      _input
                          ? Icons.calendar_month_rounded
                          : Icons.edit_calendar_outlined,
                    ),
                  ),
                ),
                if (_input)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                    child: Form(
                      key: _form,
                      child: InputDatePickerFormField(
                        initialDate: _day,
                        firstDate: widget.firstDate,
                        lastDate: widget.today,
                        autofocus: true,
                        onDateSaved: (day) => _day = DateUtils.dateOnly(day),
                        onDateSubmitted: (day) {
                          _day = DateUtils.dateOnly(day);
                          _confirm();
                        },
                      ),
                    ),
                  )
                else
                  Theme(
                    data: theme.copyWith(datePickerTheme: calendarTheme),
                    child: SizedBox(
                      height: 350 + (scale.scale(14) - 14).clamp(0, 28) * 5,
                      child: CalendarDatePicker(
                        key: ValueKey('food-calendar-$_calendarVersion'),
                        initialDate: _day,
                        firstDate: widget.firstDate,
                        lastDate: widget.today,
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
              if (!DateUtils.isSameDay(_day, widget.today))
                TextButton.icon(
                  key: const ValueKey('food-date-today'),
                  onPressed: _today,
                  icon: const Icon(Icons.today_rounded, size: 18),
                  label: Text(l10n.foodCalendarToday),
                ),
              FilledButton(
                key: const ValueKey('food-date-confirm'),
                onPressed: _confirm,
                child: Text(l10n.foodCalendarOpenDay),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
