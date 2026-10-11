import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../common/motion.dart';
import '../design/design.dart';
import 'food_glyphs.dart';

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
/// stock outlined "Enter date" field) was dropped; the app's month grid
/// ([FoodMonthCalendar]) and the Today pill cover every reachable day.
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
                  child: _DayPreview(
                    day: _day,
                    contextLabel: widget.contextLabel ?? l10n.foodTitle,
                  ),
                ),
                const SizedBox(height: 16),
                FoodMonthCalendar(
                  key: ValueKey('food-calendar-$_calendarVersion'),
                  selected: _day,
                  firstDate: widget.firstDate,
                  lastDate: widget.lastDate ?? widget.today,
                  today: widget.today,
                  onSelected: (day) => setState(() => _day = day),
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

/// The chosen day on the brand panel: the big day number beside what the
/// day is for and its full date. At large text the number sits above the
/// date, which then keeps the panel's width ("Tuesday" broke into
/// "Tuesda/y" beside it at 2x on a 320 px phone); the number, a display
/// echo of the date below, grows at most by half.
class _DayPreview extends StatelessWidget {
  const _DayPreview({required this.day, required this.contextLabel});

  final DateTime day;
  final String contextLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final material = MaterialLocalizations.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final stacked = scaler.scale(14) > 21;
    final number = Text(
      material.formatDecimal(day.day),
      textScaler: scaler.clamp(maxScaleFactor: 1.5),
      style: AppType.display(48, color: t.onBrandSurface),
    );
    final copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(contextLabel, style: AppType.ui(12, color: t.ink2)),
        const SizedBox(height: 5),
        Text(
          material.formatFullDate(day),
          key: const ValueKey('food-date-preview'),
          style: AppType.ui(
            15,
            weight: FontWeight.w600,
            color: t.onBrandSurface,
            height: 1.4,
          ),
        ),
      ],
    );
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [number, const SizedBox(height: 6), copy],
      );
    }
    return Row(
      children: [number, const SizedBox(width: 18), Expanded(child: copy)],
    );
  }
}

/// The app's month grid (replaces Material's CalendarDatePicker): a month
/// title with two round chevron buttons, the locale's weekday row (its own
/// first weekday) and the days. The picked day is the accent pill, today
/// carries an accent ring, days outside [firstDate]..[lastDate] are dimmed
/// and do nothing. Only the weeks the month needs are drawn, so a five-week
/// month leaves no empty band.
///
/// A swipe sideways pages too. Every day is a button with its full date as
/// its spoken name ("today" added), and a keyboard focus draws a ring. The
/// arrow keys move a day or a week and page on past the month's edge, as
/// Material's picker did; Page Up/Down page a month, keeping the day.
/// Chevrons, swipe and arrows follow the text direction.
class FoodMonthCalendar extends StatefulWidget {
  const FoodMonthCalendar({
    super.key,
    required this.selected,
    required this.firstDate,
    required this.lastDate,
    required this.today,
    required this.onSelected,
  });

  final DateTime selected, firstDate, lastDate, today;
  final ValueChanged<DateTime> onSelected;

  @override
  State<FoodMonthCalendar> createState() => _FoodMonthCalendarState();
}

class _FoodMonthCalendarState extends State<FoodMonthCalendar> {
  /// First day of the month on screen.
  late DateTime _month = _monthOf(_clamp(widget.selected));

  /// +1 paging forward, -1 back: the direction the new month slides in from.
  int _direction = 0;

  /// One node per day the grid has shown, so a key that pages can put the
  /// focus on a day of the new month. Kept until the calendar goes away.
  final Map<DateTime, FocusNode> _dayFocus = <DateTime, FocusNode>{};

  FocusNode _focusFor(DateTime day) =>
      _dayFocus.putIfAbsent(day, () => FocusNode(debugLabel: 'day $day'));

  @override
  void dispose() {
    for (final node in _dayFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  static DateTime _monthOf(DateTime day) => DateTime(day.year, day.month);

  DateTime get _first => DateUtils.dateOnly(widget.firstDate);
  DateTime get _last => DateUtils.dateOnly(widget.lastDate);

  DateTime _clamp(DateTime day) {
    final date = DateUtils.dateOnly(day);
    if (date.isBefore(_first)) return _first;
    if (date.isAfter(_last)) return _last;
    return date;
  }

  bool get _canGoBack => _month.isAfter(_monthOf(_first));
  bool get _canGoForward => _month.isBefore(_monthOf(_last));

  void _page(int delta) {
    if (delta < 0 ? !_canGoBack : !_canGoForward) return;
    setState(() {
      _direction = delta;
      _month = DateTime(_month.year, _month.month + delta);
    });
  }

  bool get _rtl => Directionality.of(context) == TextDirection.rtl;

  /// The day that has the keyboard focus, if any.
  DateTime? get _focusedDay {
    for (final MapEntry(key: day, value: node) in _dayFocus.entries) {
      if (node.hasPrimaryFocus) return day;
    }
    return null;
  }

  /// Focuses [day], paging to its month first when it is not on screen.
  void _focusDay(DateTime day) {
    final month = _monthOf(day);
    if (month == _month) {
      _focusFor(day).requestFocus();
      return;
    }
    setState(() {
      _direction = month.isAfter(_month) ? 1 : -1;
      _month = month;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusFor(day).requestFocus();
    });
  }

  /// An arrow key: a day sideways, a week up or down, across the month's
  /// edge too; nothing past the pickable range.
  void _arrow(DirectionalFocusIntent intent) {
    final from = _focusedDay;
    if (from == null) return;
    final step = switch (intent.direction) {
      TraversalDirection.up => -DateTime.daysPerWeek,
      TraversalDirection.down => DateTime.daysPerWeek,
      TraversalDirection.left => _rtl ? 1 : -1,
      TraversalDirection.right => _rtl ? -1 : 1,
    };
    final target = DateTime(from.year, from.month, from.day + step);
    if (target.isBefore(_first) || target.isAfter(_last)) return;
    _focusDay(target);
  }

  /// Page Up/Down: the neighbouring month, on the same day where it has one.
  void _pageByKey(int delta) {
    if (delta < 0 ? !_canGoBack : !_canGoForward) return;
    final from = _focusedDay ?? DateUtils.dateOnly(widget.selected);
    final month = DateTime(_month.year, _month.month + delta);
    final day = math.min(
      from.day,
      DateUtils.getDaysInMonth(month.year, month.month),
    );
    _focusDay(_clamp(DateTime(month.year, month.month, day)));
  }

  /// The day keys on the grid: arrows (past the month's edge too) and Page
  /// Up/Down instead of the default geometric focus traversal.
  Widget _keyboard(Widget grid) => CallbackShortcuts(
    bindings: <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.pageUp): () => _pageByKey(-1),
      const SingleActivator(LogicalKeyboardKey.pageDown): () => _pageByKey(1),
    },
    child: Actions(
      actions: <Type, Action<Intent>>{
        DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
          onInvoke: _arrow,
        ),
      },
      child: grid,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final material = MaterialLocalizations.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final duration = motionDuration(context, kMotionEnter);
    final header = Padding(
      // Title on the 20 px gutter; the 44 px rings sit in 48 px targets, so
      // 18 puts the last ring on the gutter too (as SheetHeader does).
      padding: const EdgeInsets.fromLTRB(20, 0, 18, 0),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              // Paging changes the title; a screen reader hears the month.
              liveRegion: true,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final title = material.formatMonthYear(_month);
                  final style = AppType.display(
                    17,
                    weight: FontWeight.w700,
                    color: t.ink,
                  );
                  // Large text never splits "September" mid-word.
                  return Text(
                    title,
                    key: const ValueKey('food-date-month-title'),
                    textScaler: AppType.wholeWordScaler(
                      context,
                      text: title,
                      style: style,
                      scaler: scaler,
                      maxWidth: constraints.maxWidth,
                      minScaleFactor: 1,
                    ),
                    style: style,
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 8),
          _MonthArrow(
            buttonKey: const ValueKey('food-date-month-previous'),
            glyph: _rtl ? FoodGlyph.chevronRight : FoodGlyph.chevronLeft,
            tooltip: material.previousMonthTooltip,
            onTap: _canGoBack ? () => _page(-1) : null,
          ),
          const SizedBox(width: 4),
          _MonthArrow(
            buttonKey: const ValueKey('food-date-month-next'),
            glyph: _rtl ? FoodGlyph.chevronLeft : FoodGlyph.chevronRight,
            tooltip: material.nextMonthTooltip,
            onTap: _canGoForward ? () => _page(1) : null,
          ),
        ],
      ),
    );

    // The locale's narrow weekday names, starting on its first weekday.
    final firstWeekday = material.firstDayOfWeekIndex;
    final weekdays = [
      for (var i = 0; i < 7; i++)
        material.narrowWeekdays[(firstWeekday + i) % 7],
    ];
    final weekdayRow = ExcludeSemantics(
      child: Row(
        children: [
          for (final day in weekdays)
            Expanded(
              child: Center(
                child: Text(
                  day,
                  style: AppType.ui(12, weight: FontWeight.w600, color: t.ink3),
                ),
              ),
            ),
        ],
      ),
    );

    // Rows grow with the text, never below the 48 px touch floor.
    final rowHeight = math.max(48.0, scaler.scale(14) * 1.25 + 14);
    final grid = KeyedSubtree(
      key: ValueKey(_month),
      child: _keyboard(
        _MonthGrid(
          month: _month,
          firstWeekday: firstWeekday,
          rowHeight: rowHeight,
          selected: DateUtils.dateOnly(widget.selected),
          today: DateUtils.dateOnly(widget.today),
          first: _first,
          last: _last,
          focusFor: _focusFor,
          onSelected: widget.onSelected,
        ),
      ),
    );
    // Toward the next month: leftwards in LTR, rightwards in RTL.
    final forward = _rtl ? -1.0 : 1.0;

    return Column(
      key: const ValueKey('food-date-calendar-grid'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        header,
        const SizedBox(height: 12),
        Padding(
          // 14 + half the slack of a 52 px column puts the first day's pill
          // on the 20 px gutter at the reference width.
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: GestureDetector(
            // A sideways swipe pages, like the stock calendar did. Screen
            // readers page with the two arrow buttons; the drag offers them
            // no working action.
            excludeFromSemantics: true,
            onHorizontalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (velocity.abs() < 300) return;
              _page(velocity * forward < 0 ? 1 : -1);
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                weekdayRow,
                const SizedBox(height: 6),
                maybeAnimatedSize(
                  context,
                  duration: duration,
                  curve: kMotionCurve,
                  alignment: Alignment.topCenter,
                  child: AnimatedSwitcher(
                    duration: duration,
                    switchInCurve: kMotionCurve,
                    switchOutCurve: kMotionCurve,
                    // The month that leaves fades in place; the new one
                    // slides in a little from the side it came from.
                    transitionBuilder: (child, animation) {
                      final incoming = child.key == ValueKey(_month);
                      final offset = Tween<Offset>(
                        begin: Offset(
                          incoming ? 0.08 * _direction * forward : 0,
                          0,
                        ),
                        end: Offset.zero,
                      ).animate(animation);
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(position: offset, child: child),
                      );
                    },
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.topCenter,
                      children: [
                        // The leaving month takes no taps.
                        for (final child in previous)
                          IgnorePointer(child: ExcludeSemantics(child: child)),
                        ?current,
                      ],
                    ),
                    child: grid,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A month header chevron: the sheets' 44 px ring (surf, lineStrong edge) in
/// a 48 px target, dimmed where the range ends.
class _MonthArrow extends StatelessWidget {
  const _MonthArrow({
    required this.buttonKey,
    required this.glyph,
    required this.tooltip,
    required this.onTap,
  });

  final Key buttonKey;
  final FoodGlyph glyph;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return IconButton(
      key: buttonKey,
      onPressed: onTap,
      tooltip: tooltip,
      style: IconButton.styleFrom(
        backgroundColor: t.surf,
        foregroundColor: t.inkMuted,
        disabledBackgroundColor: t.surf,
        disabledForegroundColor: t.inkDisabled,
        fixedSize: const Size.square(44),
        minimumSize: const Size.square(44),
        padding: EdgeInsets.zero,
        shape: CircleBorder(side: BorderSide(color: t.lineStrong)),
      ),
      icon: FoodGlyphIcon(glyph, size: 20),
    );
  }
}

/// The weeks of one month: blank cells before the first day, then the days.
class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.firstWeekday,
    required this.rowHeight,
    required this.selected,
    required this.today,
    required this.first,
    required this.last,
    required this.focusFor,
    required this.onSelected,
  });

  final DateTime month;
  final int firstWeekday;
  final double rowHeight;
  final DateTime selected, today, first, last;
  final FocusNode Function(DateTime day) focusFor;
  final ValueChanged<DateTime> onSelected;

  @override
  Widget build(BuildContext context) {
    // DateTime.weekday: Monday 1 .. Sunday 7; the localizations count from
    // Sunday 0.
    final leading = (DateTime(month.year, month.month).weekday % 7 -
            firstWeekday +
            7) %
        7;
    final days = DateUtils.getDaysInMonth(month.year, month.month);
    final weeks = ((leading + days) / 7).ceil();
    return FocusTraversalGroup(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var week = 0; week < weeks; week++)
            SizedBox(
              height: rowHeight,
              child: Row(
                children: [
                  for (var column = 0; column < 7; column++)
                    Expanded(
                      child: _cell(week * 7 + column - leading + 1, days),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _cell(int day, int days) {
    if (day < 1 || day > days) return const SizedBox.shrink();
    final date = DateTime(month.year, month.month, day);
    final enabled = !date.isBefore(first) && !date.isAfter(last);
    return _DayCell(
      key: ValueKey('food-date-day-${date.year}-${date.month}-${date.day}'),
      date: date,
      focusNode: focusFor(date),
      selected: DateUtils.isSameDay(date, selected),
      isToday: DateUtils.isSameDay(date, today),
      onTap: enabled ? () => onSelected(date) : null,
    );
  }
}

class _DayCell extends StatefulWidget {
  const _DayCell({
    super.key,
    required this.date,
    required this.focusNode,
    required this.selected,
    required this.isToday,
    required this.onTap,
  });

  final DateTime date;
  final FocusNode focusNode;
  final bool selected;
  final bool isToday;

  /// Null: outside the pickable range.
  final VoidCallback? onTap;

  @override
  State<_DayCell> createState() => _DayCellState();
}

class _DayCellState extends State<_DayCell> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final material = MaterialLocalizations.of(context);
    final enabled = widget.onTap != null;
    final selected = widget.selected;
    // Picked: the accent pill. Today: an accent ring and accent digits.
    // Out of range: the disabled ink of the Food tab's day arrows.
    final Color ink = selected
        ? t.onSelected
        : !enabled
        ? t.inkDisabled
        : widget.isToday
        ? t.accentText
        : t.ink;
    // Only a keyboard focus draws the ring; a touch never shows it.
    final focusRing =
        _focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final label = StringBuffer()
      ..write(material.formatDecimal(widget.date.day))
      ..write(', ')
      ..write(material.formatFullDate(widget.date));
    if (widget.isToday) label.write(', ${material.currentDateLabel}');
    return LayoutBuilder(
      builder: (context, constraints) {
        // The pill fits the column with air on both sides; the focus ring
        // sits 3 px outside it.
        final pill = math.min(
          40.0,
          math.min(constraints.maxWidth, constraints.maxHeight) - 6,
        );
        return Semantics(
          // One node per day, so each reads on its own.
          container: true,
          button: true,
          selected: selected,
          enabled: enabled,
          label: label.toString(),
          excludeSemantics: true,
          onTap: widget.onTap,
          child: Center(
            child: SizedBox.square(
              dimension: pill + 6,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: focusRing ? t.ink : Colors.transparent,
                    width: 2,
                  ),
                ),
                padding: const EdgeInsets.all(1),
                child: Material(
                  color: selected ? t.selectedFill : Colors.transparent,
                  shape: CircleBorder(
                    side: widget.isToday && !selected
                        ? BorderSide(color: t.accent, width: 1.5)
                        : BorderSide.none,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    focusNode: widget.focusNode,
                    onTap: widget.onTap,
                    onFocusChange: (focused) =>
                        setState(() => _focused = focused),
                    customBorder: const CircleBorder(),
                    // Scales down rather than clipping a digit where 2x
                    // text meets a 320 px phone.
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            material.formatDecimal(widget.date.day),
                            maxLines: 1,
                            softWrap: false,
                            style: AppType.ui(
                              14,
                              weight: selected || widget.isToday
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                              color: ink,
                            ).copyWith(
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
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
          ),
        );
      },
    );
  }
}
