import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../../l10n/l10n.dart';
import '../../services/day_math.dart';
import '../../services/local_day.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
import 'today_sections.dart' show TodayTapTarget;
import 'today_texts.dart';

/// The 7-day strip of the dark redesign; it replaces the old previous/next
/// arrows.
///
/// The first window is the design's: the six days before [today] plus today
/// on the right. A horizontal swipe (or the "Earlier days" / "Later days"
/// screen-reader actions) pages by a week, so every past day stays reachable
/// as with the old back arrow; there is no page after today. A selected day
/// outside the shown week (e.g. picked in the Food tab's calendar) brings its
/// week into view.
class TodayDayStrip extends StatefulWidget {
  const TodayDayStrip({
    super.key,
    required this.selectedDate,
    required this.today,
    this.onSelected,
  });

  final DateTime selectedDate, today;
  final ValueChanged<DateTime>? onSelected;

  static const int days = 7;

  @override
  State<TodayDayStrip> createState() => _TodayDayStripState();
}

class _TodayDayStripState extends State<TodayDayStrip> {
  /// Weeks back from the window that ends today; 0 is the design's strip.
  late int _page = _pageOf(widget.selectedDate);
  double _drag = 0;

  int _pageOf(DateTime date) {
    final back = daysBetween(widget.today, date);
    return back <= 0 ? 0 : back ~/ TodayDayStrip.days;
  }

  @override
  void didUpdateWidget(TodayDayStrip old) {
    super.didUpdateWidget(old);
    final moved = daysBetween(old.selectedDate, widget.selectedDate) != 0;
    final rolled = daysBetween(old.today, widget.today) != 0;
    if (moved || rolled) _page = _pageOf(widget.selectedDate);
  }

  void _show(int page) {
    if (page < 0 || page == _page) return;
    setState(() => _page = page);
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    // Swiping right reveals the earlier week, as on a paper calendar.
    if (_drag > 48 || velocity > 400) {
      _show(_page + 1);
    } else if (_drag < -48 || velocity < -400) {
      _show(_page - 1);
    }
    _drag = 0;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final first = addDays(
      startOfDay(widget.today),
      -(_page * TodayDayStrip.days) - (TodayDayStrip.days - 1),
    );
    final cells = Row(
      key: ValueKey<int>(_page),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (var i = 0; i < TodayDayStrip.days; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: _DayCell(
              date: addDays(first, i),
              today: widget.today,
              selected:
                  daysBetween(addDays(first, i), widget.selectedDate) == 0,
              onTap: widget.onSelected == null
                  ? null
                  : () => widget.onSelected!(addDays(first, i)),
            ),
          ),
        ],
      ],
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.todayDayStripLabel,
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        CustomSemanticsAction(label: l10n.todayDayStripEarlier): () =>
            _show(_page + 1),
        if (_page > 0)
          CustomSemanticsAction(label: l10n.todayDayStripLater): () =>
              _show(_page - 1),
      },
      child: GestureDetector(
        key: const ValueKey('today-date-strip'),
        onHorizontalDragStart: (_) => _drag = 0,
        onHorizontalDragUpdate: (details) => _drag += details.primaryDelta ?? 0,
        onHorizontalDragEnd: _onDragEnd,
        child: AnimatedSwitcher(
          duration: motionDuration(context, const Duration(milliseconds: 200)),
          child: cells,
        ),
      ),
    );
  }
}

/// One day: 60 px, radius 18; the selected day is the accent fill with its
/// violet glow, the others sit flat on the page.
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.today,
    required this.selected,
    this.onTap,
  });

  final DateTime date, today;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final isToday = daysBetween(date, today) == 0;
    final radius = BorderRadius.circular(rThumb);
    return Semantics(
      button: onTap != null,
      selected: selected,
      enabled: onTap != null,
      label: todayDayCellLabel(today, date, l10n),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? t.selectedFill : Colors.transparent,
          borderRadius: radius,
          boxShadow: selected
              ? <BoxShadow>[
                  BoxShadow(
                    color: t.accentGlow,
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: TodayTapTarget(
            key: ValueKey<String>('today-day-${localDayKey(date)}'),
            borderRadius: radius,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 60),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Center(
                  // A 2x system font would not fit a 35 px cell on a small
                  // phone; only then does the pair scale down.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: ExcludeSemantics(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            todayWeekdayShort(date, l10n),
                            style: AppType.ui(
                              12,
                              weight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                              color: selected ? t.onAccentMuted : t.ink3,
                              height: todayLineHeight,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${date.day}',
                            style: AppType.ui(
                              16,
                              weight: selected
                                  ? FontWeight.w800
                                  : FontWeight.w700,
                              // Today keeps an accent number when another day
                              // is selected, so "back to today" stays findable.
                              color: selected
                                  ? t.onSelected
                                  : (isToday ? t.accentText : t.inkMuted),
                              height: todayLineHeight,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
