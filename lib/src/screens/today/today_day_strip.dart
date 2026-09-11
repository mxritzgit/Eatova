import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/day_math.dart';
import '../../theme/app_tokens.dart';
import 'today_texts.dart';

/// Date navigation stays visible without a second filled header panel.
class TodayDayStrip extends StatelessWidget {
  const TodayDayStrip({
    super.key,
    required this.selectedDate,
    required this.today,
    this.onSelected,
  });

  final DateTime selectedDate, today;
  final ValueChanged<DateTime>? onSelected;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final canGoNext = daysBetween(today, selectedDate) > 0;
    return Row(
      key: const ValueKey('today-date-strip'),
      children: [
        Expanded(
          child: Semantics(
            label: todayDateLabel(today, selectedDate, l10n),
            child: Text(
              todayCalendarDate(selectedDate, l10n),
              key: const ValueKey('today-date-selected-label'),
              style: AppType.ui(14, color: t.ink2, height: 1.35),
            ),
          ),
        ),
        IconButton(
          key: const ValueKey('today-date-prev'),
          tooltip: l10n.todaySemanticsDatePrev,
          onPressed: onSelected == null
              ? null
              : () => onSelected!(addDays(startOfDay(selectedDate), -1)),
          icon: const Icon(Icons.chevron_left_rounded, size: 20),
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          padding: EdgeInsets.zero,
        ),
        IconButton(
          key: const ValueKey('today-date-next'),
          tooltip: l10n.todaySemanticsDateNext,
          onPressed: onSelected == null || !canGoNext
              ? null
              : () => onSelected!(addDays(startOfDay(selectedDate), 1)),
          icon: const Icon(Icons.chevron_right_rounded, size: 20),
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          padding: EdgeInsets.zero,
        ),
      ],
    );
  }
}
