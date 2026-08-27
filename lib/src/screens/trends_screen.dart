import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../l10n/l10n.dart';
import '../services/day_math.dart';
import '../services/kcal_format.dart';
import '../services/trend_service.dart';
import '../theme/app_tokens.dart';
import '../widgets/common/lively.dart';
import '../widgets/common/motion.dart';
import '../widgets/design/design.dart';

/// No step bonus: the trend goal is the base goal on every day.
int noTrendStepBonus(DateTime _) => 0;

/// Long-term trend view: daily calorie bars with target line and corridor, a
/// 7/30/90-day range switch, and metrics. Data comes from the injected
/// [TrendTotalsLoader], INDEPENDENT of HomeStore's 35-day window.
class TrendsScreen extends StatefulWidget {
  const TrendsScreen({
    super.key,
    required this.kcalGoal,
    required this.loadTotals,
    this.burnedKcalFor = noTrendStepBonus,
  });

  /// Daily target in kcal, passed through from the profile.
  final int kcalGoal;

  final TrendTotalsLoader loadTotals;

  /// Step bonus per local calendar day (`HomeStore.burnedKcalForFoodDate`).
  /// The Today tab steers by goal + bonus (model B), so the hit rate, the
  /// corridor and the target line use the same per-day goal (F7-05). The
  /// default [noTrendStepBonus] keeps the corridor on the base goal.
  final int Function(DateTime day) burnedKcalFor;

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends State<TrendsScreen> {
  static const List<int> _ranges = [7, 30, 90];

  int _rangeDays = 30;
  bool _loading = true;
  Object? _error;
  List<TrendDayTotals> _totals = const [];

  @override
  void initState() {
    super.initState();
    // No setState needed: _loading starts true and _fetch only setStates
    // after an await.
    _fetch();
  }

  /// Retry entry point: back to the loading state, then reload.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _fetch();
  }

  Future<void> _fetch() async {
    try {
      // Future.sync: a synchronously throwing loader becomes a future error,
      // never a setState during the first build.
      final totals = await Future.sync(widget.loadTotals);
      if (!mounted) return;
      setState(() {
        _totals = totals;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      // The service already logged; never leak a raw exception to the UI.
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      body: SafeArea(
        child: LivelyEntrance(
          // Column, not ListView: every metric must be in the element tree.
          child: SingleChildScrollView(
            key: const ValueKey('screen-trends'),
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PageHeader(
                  title: l10n.trendsTitle,
                  backKey: const ValueKey('trends-close'),
                ),
                const SizedBox(height: 14),
                _RangeSelector(
                  ranges: _ranges,
                  selected: _rangeDays,
                  onSelected: (days) => setState(() => _rangeDays = days),
                ),
                const SizedBox(height: 14),
                ..._buildContent(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildContent(BuildContext context) {
    final l10n = context.l10n;
    if (_loading) {
      return const [
        SizedBox(
          key: ValueKey('trends-loading'),
          height: 260,
          child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
        ),
      ];
    }
    if (_error != null) {
      return [_ErrorCard(onRetry: _load)];
    }
    if (_totals.length < 2) {
      return const [_EmptyCard()];
    }

    final today = DateTime.now();
    final window = denseTrendWindow(_totals, today: today, days: _rangeDays);
    // B6: the CHART includes today; the METRICS exclude it, or a partial day
    // would count as a full one.
    final completed = completedDaysOf(window);
    final avgKcal = averageKcalOf(completed);
    final hits = goalHitsOf(
      completed,
      goalKcal: widget.kcalGoal,
      burnedKcalFor: widget.burnedKcalFor,
    );
    final macros = averageMacrosOf(completed);
    // B5: calendar arithmetic (DST-safe), as in denseTrendWindow.
    final firstDay = addDays(startOfDay(today), -(_rangeDays - 1));
    // Per-slot goal for the chart: base plus that day's step bonus (F7-05).
    final goalPerDay = <int>[
      for (var i = 0; i < window.length; i++)
        widget.kcalGoal + widget.burnedKcalFor(addDays(firstDay, i)),
    ];
    final hatBonus = goalPerDay.any((g) => g != widget.kcalGoal);

    return [
      _ChartCard(
        window: window,
        rangeDays: _rangeDays,
        kcalGoal: widget.kcalGoal,
        goalPerDay: goalPerDay,
        avgKcal: avgKcal,
        // Counts drawn bars so the a11y announcement matches the chart.
        trackedDays: trackedDaysOf(window),
        firstDay: firstDay,
      ),
      const SizedBox(height: 14),
      // IntrinsicHeight: height is unbounded here, so stretch means Infinity.
      IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _StatCard(
                key: const ValueKey('trends-avg-kcal'),
                label: l10n.trendsStatAvgKcalLabel,
                value: avgKcal == null
                    ? '–'
                    : '${formatThousands(avgKcal.round(), l10n.localeName)} kcal',
                sub: avgKcal == null
                    ? l10n.trendsNoCompletedDay
                    : l10n.trendsStatAvgKcalSub,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                key: const ValueKey('trends-goal-rate'),
                label: l10n.trendsStatGoalRateLabel,
                // tracked == 0 is the only 0/0 route; keeps NaN out.
                value: hits.tracked == 0
                    ? '–'
                    : '${(hits.hit / hits.tracked * 100).round()} %',
                sub: hits.tracked == 0
                    ? l10n.trendsNoCompletedDay
                    : l10n.trendsStatGoalRateSub(hits.hit, hits.tracked),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      _MacroAveragesCard(macros: macros),
      const SizedBox(height: 10),
      // B6: the label must match the maths, which excludes the current day.
      _MetricsNote(showBonusNote: hatBonus),
    ];
  }
}

/// Footnote saying the current day is excluded from the averages and hit
/// rate (B6). One line for all three tiles, since the sublabels would wrap it
/// three times. With a step bonus in the window a second line explains the
/// per-day goal (F7-05).
class _MetricsNote extends StatelessWidget {
  const _MetricsNote({required this.showBonusNote});

  final bool showBonusNote;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final style = AppType.ui(
      11,
      weight: FontWeight.w500,
      color: context.t.ink2,
      height: 1.4,
    );
    return Padding(
      key: const ValueKey('trends-metrics-note'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.trendsMetricsNote, style: style),
          if (showBonusNote) ...[
            const SizedBox(height: 6),
            Text(
              l10n.trendsGoalBonusNote,
              key: const ValueKey('trends-goal-bonus-note'),
              style: style,
            ),
          ],
        ],
      ),
    );
  }
}

/// Range switch: three equally wide filter pills.
class _RangeSelector extends StatelessWidget {
  const _RangeSelector({
    required this.ranges,
    required this.selected,
    required this.onSelected,
  });

  final List<int> ranges;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      children: [
        for (var i = 0; i < ranges.length; i++) ...[
          Expanded(
            // Key on the Semantics wrapper so tests keep their finder and
            // the screen reader its descriptive name.
            child: Semantics(
              key: ValueKey('trends-range-${ranges[i]}'),
              button: true,
              selected: ranges[i] == selected,
              label: l10n.trendsRangeSemanticsLabel(ranges[i]),
              child: FilterChipPill(
                label: l10n.trendsRangeDaysLabel(ranges[i]),
                selected: ranges[i] == selected,
                onTap: () => onSelected(ranges[i]),
              ),
            ),
          ),
          if (i != ranges.length - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.window,
    required this.rangeDays,
    required this.kcalGoal,
    required this.goalPerDay,
    required this.avgKcal,
    required this.trackedDays,
    required this.firstDay,
  });

  final List<TrendDayTotals?> window;
  final int rangeDays;

  /// Base goal — what the a11y announcement names.
  final int kcalGoal;

  /// Effective goal per window slot (base + step bonus), what the painter
  /// draws as a stepped line and corridor.
  final List<int> goalPerDay;
  final double? avgKcal;
  final int trackedDays;
  final DateTime firstDay;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    _ensureDateSymbols();
    // A11y: the chart is only painted, so values go out as speech. [avgKcal]
    // can be null while a bar already shows, so the average clause is dropped
    // rather than announcing a false 0.
    final avg = avgKcal;
    // The announced goal is the one the label shows: today's slot including
    // its step bonus (G M-1), not the base goal.
    final spokenGoal = goalPerDay.isEmpty ? kcalGoal : goalPerDay.last;
    final semanticsValue = trackedDays == 0
        ? l10n.trendsChartSemanticsEmpty
        : avg == null
        ? l10n.trendsChartSemanticsNoAvg(trackedDays, rangeDays, spokenGoal)
        : l10n.trendsChartSemanticsWithAvg(
            trackedDays,
            rangeDays,
            avg.round(),
            spokenGoal,
          );
    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  l10n.trendsChartTitle,
                  style: AppType.display(
                    17,
                    weight: FontWeight.w700,
                    color: t.ink,
                  ),
                ),
              ),
              Flexible(
                child: Text(
                  l10n.trendsRangeDaysLabel(rangeDays),
                  textAlign: TextAlign.right,
                  style: AppType.ui(
                    11.5,
                    weight: FontWeight.w600,
                    color: t.ink2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 200,
            child: Semantics(
              label: l10n.trendsChartSemanticsLabel,
              value: semanticsValue,
              child: RepaintBoundary(
                child: TweenAnimationBuilder<double>(
                  // Key per range so the build-up replays on switching.
                  key: ValueKey('trends-chart-anim-$rangeDays'),
                  tween: Tween(begin: 0, end: 1),
                  duration: motionDuration(
                    context,
                    const Duration(milliseconds: 550),
                  ),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, _) => CustomPaint(
                    key: const ValueKey('trends-chart'),
                    painter: _KcalTrendPainter(
                      window: window,
                      goalPerDay: goalPerDay,
                      firstDay: firstDay,
                      progress: value,
                      gridColor: t.line,
                      barColor: t.accent,
                      goalLineColor: t.ink.withValues(alpha: 0.6),
                      bandColor: t.ink.withValues(alpha: 0.05),
                      axisTextColor: t.ink2,
                      l10n: l10n,
                    ),
                    size: Size.infinite,
                  ),
                ),
              ),
            ),
          ),
          if (rangeDays > 7) ...[
            const SizedBox(height: 6),
            Padding(
              // Same lateral anchors as the painter's canvas.
              padding: const EdgeInsets.only(left: 40, right: 8),
              child: Row(
                children: [
                  // Locale-aware day.month (F7-09): `de` "1.8.", `en` "8/1".
                  _Caption(DateFormat.Md(l10n.localeName).format(firstDay)),
                  const Spacer(),
                  _Caption(l10n.todayDateToday),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppType.ui(
        11,
        weight: FontWeight.w500,
        color: context.t.ink2,
        letterSpacing: 0.2,
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    super.key,
    required this.label,
    required this.value,
    required this.sub,
  });

  final String label;
  final String value;
  final String sub;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppType.eyebrow(t.ink2)),
          const SizedBox(height: 6),
          Text(value, style: AppType.display(20, color: t.ink)),
          const SizedBox(height: 2),
          Text(
            sub,
            style: AppType.ui(11, weight: FontWeight.w500, color: t.ink2),
          ),
        ],
      ),
    );
  }
}

class _MacroAveragesCard extends StatelessWidget {
  const _MacroAveragesCard({required this.macros});

  final ({double proteinG, double carbsG, double fatG})? macros;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final m = macros;
    return AppCard(
      key: const ValueKey('trends-avg-macros'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.trendsMacroAvgTitle, style: AppType.eyebrow(t.ink2)),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _MacroAvg(
                  color: t.protein,
                  label: l10n.todayMacroProtein,
                  value: m == null ? '–' : '${m.proteinG.round()} g',
                ),
              ),
              Expanded(
                child: _MacroAvg(
                  color: t.carbs,
                  label: l10n.todayMacroCarbs,
                  value: m == null ? '–' : '${m.carbsG.round()} g',
                ),
              ),
              Expanded(
                child: _MacroAvg(
                  color: t.fat,
                  label: l10n.todayMacroFat,
                  value: m == null ? '–' : '${m.fatG.round()} g',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One macro metric: a coloured dot next to text in text tokens, since the
/// macro colour has too little contrast to carry text.
class _MacroAvg extends StatelessWidget {
  const _MacroAvg({
    required this.color,
    required this.label,
    required this.value,
  });

  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        // At 200% font the longest macro label would blow out its third.
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.ui(11, weight: FontWeight.w500, color: t.ink2),
              ),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.display(
                  14,
                  weight: FontWeight.w700,
                  color: t.ink,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return AppCard(
      key: const ValueKey('trends-empty'),
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
      child: Column(
        children: [
          Icon(Icons.query_stats_rounded, color: t.ink2, size: 32),
          const SizedBox(height: 12),
          Text(
            l10n.trendsEmptyTitle,
            style: AppType.display(17, weight: FontWeight.w700, color: t.ink),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.trendsEmptyBody,
            textAlign: TextAlign.center,
            style: AppType.ui(
              12,
              weight: FontWeight.w500,
              color: t.ink2,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return AppCard(
      key: const ValueKey('trends-error'),
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
      child: Column(
        children: [
          Icon(Icons.cloud_off_rounded, color: t.ink2, size: 32),
          const SizedBox(height: 12),
          Text(
            l10n.trendsErrorTitle,
            textAlign: TextAlign.center,
            style: AppType.display(17, weight: FontWeight.w700, color: t.ink),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.trendsErrorBody,
            textAlign: TextAlign.center,
            style: AppType.ui(
              12,
              weight: FontWeight.w500,
              color: t.ink2,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          PrimaryActionButton(
            key: const ValueKey('trends-retry'),
            label: l10n.trendsRetryCta,
            height: 46,
            onTap: onRetry,
          ),
        ],
      ),
    );
  }
}

/// Daily calorie bars (one series, so no legend), growing from the 0
/// baseline; gap days stay gaps, since "not tracked" is not a 0 kcal day.
/// All five colours arrive as fields and are checked in [shouldRepaint].
///
/// Target line and corridor are STEPPED per slot ([goalPerDay], F7-05): on a
/// day with a step bonus the goal sits higher, exactly as the Today tab
/// steered it. Without a bonus every slot carries the base goal and the line
/// is straight, as before.
class _KcalTrendPainter extends CustomPainter {
  _KcalTrendPainter({
    required this.window,
    required this.goalPerDay,
    required this.firstDay,
    required this.progress,
    required this.gridColor,
    required this.barColor,
    required this.goalLineColor,
    required this.bandColor,
    required this.axisTextColor,
    required this.l10n,
  }) : assert(goalPerDay.length == window.length);

  final List<TrendDayTotals?> window;

  /// Effective goal per slot, same length as [window].
  final List<int> goalPerDay;
  final DateTime firstDay;
  final double progress;
  final Color gridColor, barColor, goalLineColor, bandColor, axisTextColor;

  /// A `CustomPainter` has no BuildContext, so localization is a parameter
  /// rather than a global lookup (docs/I18N_PAKETE.md §3).
  final AppLocalizations l10n;

  @override
  void paint(Canvas canvas, Size size) {
    _ensureDateSymbols();
    final showWeekdays = window.length == 7;
    final padding = EdgeInsets.fromLTRB(40, 14, 8, showWeekdays ? 20 : 6);
    final inner = Rect.fromLTWH(
      padding.left,
      padding.top,
      size.width - padding.horizontal,
      size.height - padding.vertical,
    );
    if (inner.width <= 0 || inner.height <= 0) return;

    var maxKcal = 0;
    var tracked = 0;
    for (final day in window) {
      if (day == null) continue;
      tracked++;
      maxKcal = math.max(maxKcal, day.kcal);
    }
    var maxGoal = 0;
    for (final g in goalPerDay) {
      maxGoal = math.max(maxGoal, g);
    }

    final base = math.max(maxKcal, maxGoal);
    final niceMax = _niceMax(base);

    // Quiet grid: 4 solid hairlines (0 to niceMax in thirds).
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = inner.bottom - inner.height * (i / 3);
      canvas.drawLine(Offset(inner.left, y), Offset(inner.right, y), gridPaint);
      _drawText(
        canvas,
        formatThousands((niceMax * i / 3).round(), l10n.localeName),
        Offset(inner.left - 6, y),
        alignRight: true,
        centerVertically: true,
      );
    }

    if (tracked == 0) {
      _drawEmptyHint(canvas, size);
      return;
    }

    final n = window.length;
    final slotW = inner.width / n;
    double yOf(num kcal) => (inner.bottom - (kcal / niceMax) * inner.height)
        .clamp(inner.top, inner.bottom)
        .toDouble();

    // Target corridor (±10 %) as a quiet area behind the bars, per slot.
    final bandPaint = Paint()..color = bandColor;
    for (var i = 0; i < n; i++) {
      final goal = goalPerDay[i];
      if (goal <= 0) continue;
      final band = Rect.fromLTRB(
        inner.left + slotW * i,
        yOf(goal * (1 + trendGoalTolerance)),
        inner.left + slotW * (i + 1),
        yOf(goal * (1 - trendGoalTolerance)),
      );
      canvas.drawRect(band, bandPaint);
    }

    // Rounded at the data end, square at the base; height from [progress].
    final gapW = slotW >= 8 ? 2.0 : 1.0;
    final barW = math.min(24.0, math.max(slotW - gapW, slotW * 0.55));
    final barPaint = Paint()..color = barColor.withValues(alpha: 0.92);
    for (var i = 0; i < n; i++) {
      final day = window[i];
      if (day == null || day.kcal <= 0) continue;
      final h = (day.kcal / niceMax) * inner.height * progress;
      final x = inner.left + slotW * i + (slotW - barW) / 2;
      final r = math.min(3.0, barW / 2);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(x, inner.bottom - h, barW, h),
          topLeft: Radius.circular(r),
          topRight: Radius.circular(r),
        ),
        barPaint,
      );
    }

    // Target line: brighter than the grid, solid, stepped per slot, labelled
    // at the right end with the LAST slot's goal (today's, incl. bonus).
    final lastGoal = goalPerDay.isEmpty ? 0 : goalPerDay.last;
    if (goalPerDay.any((g) => g > 0)) {
      final goalPaint = Paint()
        ..color = goalLineColor
        ..strokeWidth = 1.4;
      final path = Path();
      var offen = false;
      for (var i = 0; i < n; i++) {
        final goal = goalPerDay[i];
        if (goal <= 0) {
          offen = false;
          continue;
        }
        final y = yOf(goal);
        final x0 = inner.left + slotW * i;
        final x1 = inner.left + slotW * (i + 1);
        if (!offen) {
          path.moveTo(x0, y);
          offen = true;
        } else {
          // Vertical riser between two different goals — a step, not a ramp.
          path.lineTo(x0, y);
        }
        path.lineTo(x1, y);
      }
      canvas.drawPath(path, goalPaint..style = PaintingStyle.stroke);
      if (lastGoal > 0) {
        _drawText(
          canvas,
          l10n.trendsChartGoalLabel(formatThousands(lastGoal, l10n.localeName)),
          Offset(inner.right, yOf(lastGoal) - 4),
          alignRight: true,
          above: true,
        );
      }
    }

    // 7-day view: weekday abbreviations under each slot as the x labels.
    if (showWeekdays) {
      for (var i = 0; i < n; i++) {
        // B5: calendar-day shift; a Duration would slip a day across DST.
        final day = addDays(firstDay, i);
        _drawText(
          canvas,
          DateFormat.E(l10n.localeName).format(day),
          Offset(inner.left + slotW * i + slotW / 2, inner.bottom + 4),
          centerHorizontally: true,
        );
      }
    }
  }

  /// Rounds the axis top to a clean value divisible into thirds
  /// (ticks like 0 / 1,000 / 2,000 / 3,000).
  static int _niceMax(int base) {
    if (base <= 0) return 300;
    const steps = [100, 200, 250, 500, 1000, 2000, 2500, 5000];
    final rawStep = base * 1.05 / 3;
    for (final step in steps) {
      if (step >= rawStep) return step * 3;
    }
    final step = (rawStep / 5000).ceil() * 5000;
    return step * 3;
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset anchor, {
    bool alignRight = false,
    bool centerHorizontally = false,
    bool centerVertically = false,
    bool above = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: AppType.display(9, weight: FontWeight.w500, color: axisTextColor),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = anchor.dx;
    if (alignRight) dx -= tp.width;
    if (centerHorizontally) dx -= tp.width / 2;
    var dy = anchor.dy;
    if (centerVertically) dy -= tp.height / 2;
    if (above) dy -= tp.height;
    tp.paint(canvas, Offset(dx, dy));
  }

  void _drawEmptyHint(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: TextSpan(
        text: l10n.trendsChartEmptyHintPainter,
        style: AppType.ui(
          12,
          weight: FontWeight.w500,
          color: axisTextColor,
          height: 1.4,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 24);
    tp.paint(
      canvas,
      Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _KcalTrendPainter old) =>
      old.window != window ||
      !listEquals(old.goalPerDay, goalPerDay) ||
      old.firstDay != firstDay ||
      old.progress != progress ||
      old.gridColor != gridColor ||
      old.barColor != barColor ||
      old.goalLineColor != goalLineColor ||
      old.bandColor != bandColor ||
      old.axisTextColor != axisTextColor ||
      old.l10n != l10n;
}

/// One-time init of the `intl` date symbols for the weekday labels; the load
/// is synchronous from a bundled table.
bool _dateSymbolsReady = false;
void _ensureDateSymbols() {
  if (_dateSymbolsReady) return;
  initializeDateFormatting();
  _dateSymbolsReady = true;
}
