import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/day_math.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import 'today_texts.dart';

/// Slim date strip of the "Heute" tab: step back, day name, step forward.
///
/// Not the Food tab's 30-day bar — browsing belongs in the diary — but shares
/// [todayDateLabel] so both tabs name a day alike. [today] is injected so the
/// screen is the only place that reads the clock.
class TodayDayStrip extends StatelessWidget {
  const TodayDayStrip({
    super.key,
    required this.selectedDate,
    required this.today,
    this.onSelected,
  });

  final DateTime selectedDate;
  final DateTime today;
  final ValueChanged<DateTime>? onSelected;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;

    // Forward stops at today: an empty future day looks like a load error.
    // Computed via day_math, never Duration (B5).
    final vorwaertsGesperrt = daysBetween(today, selectedDate) <= 0;

    void springe(int tage) =>
        onSelected?.call(addDays(startOfDay(selectedDate), tage));

    return Row(
      key: const ValueKey('today-date-strip'),
      children: <Widget>[
        SquareIconButton(
          key: const ValueKey('today-date-prev'),
          icon: Icons.chevron_left_rounded,
          // Umlauts, not "ue": a semantics label is spoken text.
          semanticLabel: l10n.todaySemanticsDatePrev,
          onTap: () => springe(-1),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            // minHeight, not a fixed 34: at textScaler 2.0 the label is taller.
            constraints: const BoxConstraints(minHeight: 34),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: t.forest,
              // rChip, not a literal 11: stays in step with the buttons.
              borderRadius: BorderRadius.circular(rChip),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: t.lime,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    todayDateLabel(today, selectedDate, l10n),
                    key: const ValueKey('today-date-selected-label'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.ui(
                      12.5,
                      weight: FontWeight.w600,
                      color: t.onForest,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Opacity(
          opacity: vorwaertsGesperrt ? 0.45 : 1,
          child: SquareIconButton(
            key: const ValueKey('today-date-next'),
            icon: Icons.chevron_right_rounded,
            semanticLabel: l10n.todaySemanticsDateNext,
            onTap: vorwaertsGesperrt ? null : () => springe(1),
          ),
        ),
      ],
    );
  }
}
