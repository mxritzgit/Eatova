import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
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

/// From 150 % text on, side-by-side tiles break words and numbers mid-way,
/// so the page stacks them instead.
bool _largeText(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(14) > 21;

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
          child: ReadableWidth(
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
      ),
    );
  }

  List<Widget> _buildContent(BuildContext context) {
    final l10n = context.l10n;
    if (_loading) {
      return const [_TrendsSkeleton(key: ValueKey('trends-loading'))];
    }
    if (_error != null) {
      return [_ErrorCard(onRetry: _load)];
    }
    if (_totals.isEmpty) {
      return const [_EmptyCard()];
    }

    final today = clock.now();
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
      _StatPair(
        first: _StatCard(
          key: const ValueKey('trends-avg-kcal'),
          label: l10n.trendsStatAvgKcalLabel,
          value: avgKcal == null
              ? '–'
              : '${formatThousands(avgKcal.round(), l10n.localeName)} kcal',
          sub: avgKcal == null
              ? l10n.trendsNoCompletedDay
              : l10n.trendsStatAvgKcalSub,
        ),
        second: _StatCard(
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
    final large = _largeText(context);
    // Key on the Semantics wrapper so tests keep their finder and the
    // screen reader its descriptive name.
    Widget pill(int days) => Semantics(
      key: ValueKey('trends-range-$days'),
      button: true,
      selected: days == selected,
      label: l10n.trendsRangeSemanticsLabel(days),
      child: FilterChipPill(
        label: l10n.trendsRangeDaysLabel(days),
        selected: days == selected,
        onTap: () => onSelected(days),
        expand: !large,
      ),
    );
    // Equal thirds break "Tage" mid-word at large text; the pills keep their
    // natural width and wrap instead.
    if (large) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [for (final days in ranges) pill(days)],
      );
    }
    return Row(
      children: [
        for (var i = 0; i < ranges.length; i++) ...[
          Expanded(child: pill(ranges[i])),
          if (i != ranges.length - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

class _ChartCard extends StatefulWidget {
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
  State<_ChartCard> createState() => _ChartCardState();
}

/// Stateful only to own the [TrendChartLabels]: they must survive both the
/// animation frames and an unrelated rebuild of the screen.
class _ChartCardState extends State<_ChartCard> {
  TrendChartLabels? _labels;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final labels = _labels = TrendChartLabels.resolve(
      _labels,
      window: widget.window,
      goalPerDay: widget.goalPerDay,
      firstDay: widget.firstDay,
      axisTextColor: t.ink2,
      l10n: l10n,
    );
    // A11y: the chart is only painted, so values go out as speech. [avgKcal]
    // can be null while a bar already shows, so the average clause is dropped
    // rather than announcing a false 0.
    final avg = widget.avgKcal;
    final rangeDays = widget.rangeDays;
    final trackedDays = widget.trackedDays;
    // The announced goal is the one the label shows: today's slot including
    // its step bonus (G M-1), not the base goal.
    final spokenGoal = widget.goalPerDay.isEmpty
        ? widget.kcalGoal
        : widget.goalPerDay.last;
    // The goal line's legend: today's slot including its step bonus. It sits
    // in the header, not on the plot, where it covered the latest bars.
    final legendGoal = widget.goalPerDay.any((g) => g > 0)
        ? widget.goalPerDay.last
        : 0;
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
    final title = Text(
      l10n.trendsChartTitle,
      style: AppType.display(17, weight: FontWeight.w700, color: t.ink),
    );
    final legend = legendGoal > 0
        ? _GoalLegend(
            label: l10n.trendsChartGoalLabel(
              formatThousands(legendGoal, l10n.localeName),
            ),
            lineColor: t.ink.withValues(alpha: 0.6),
          )
        : null;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The range is already the selected pill above the card; the
          // trailing slot carries the goal line's legend instead. At large
          // text the legend moves under the title so neither splits words.
          if (_largeText(context))
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                if (legend != null) ...[const SizedBox(height: 6), legend],
              ],
            )
          else
            Row(
              children: [
                Expanded(child: title),
                if (legend != null)
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(start: 10),
                      child: Align(
                        alignment: AlignmentDirectional.centerEnd,
                        heightFactor: 1,
                        child: legend,
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
                      window: widget.window,
                      goalPerDay: widget.goalPerDay,
                      labels: labels,
                      progress: value,
                      gridColor: t.line,
                      // The accent in dark; a step lighter in light, where
                      // a month of full iris bars weighed on the white card.
                      barColor: t.progressAccent,
                      goalLineColor: t.ink.withValues(alpha: 0.6),
                      bandColor: t.ink.withValues(alpha: 0.05),
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
                  _Caption(
                    trendDayMonthFormat(
                      l10n.localeName,
                    ).format(widget.firstDay),
                  ),
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

/// The goal line's key: a short stroke in the line's colour and its label.
class _GoalLegend extends StatelessWidget {
  const _GoalLegend({required this.label, required this.lineColor});

  final String label;
  final Color lineColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const ValueKey('trends-goal-legend'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 1.4,
          decoration: BoxDecoration(
            color: lineColor,
            borderRadius: BorderRadius.circular(rPill),
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            style: AppType.ui(
              11.5,
              weight: FontWeight.w600,
              color: context.t.ink2,
            ),
          ),
        ),
      ],
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

/// The two stat cards: side by side at equal height, stacked from 150 % text
/// on, where half the width split "2.214" and "Kalorien" mid-way.
class _StatPair extends StatelessWidget {
  const _StatPair({required this.first, required this.second});

  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) {
    if (_largeText(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [first, const SizedBox(height: 12), second],
      );
    }
    // IntrinsicHeight: height is unbounded here, so stretch means Infinity.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: first),
          const SizedBox(width: 12),
          Expanded(child: second),
        ],
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
    final cells = <Widget>[
      _MacroAvg(
        color: t.protein,
        label: l10n.todayMacroProtein,
        value: m == null ? '–' : '${m.proteinG.round()} g',
      ),
      _MacroAvg(
        color: t.carbs,
        label: l10n.todayMacroCarbs,
        value: m == null ? '–' : '${m.carbsG.round()} g',
      ),
      _MacroAvg(
        color: t.fat,
        label: l10n.todayMacroFat,
        value: m == null ? '–' : '${m.fatG.round()} g',
      ),
    ];
    return AppCard(
      key: const ValueKey('trends-avg-macros'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.trendsMacroAvgTitle, style: AppType.eyebrow(t.ink2)),
          const SizedBox(height: 10),
          // Thirds at large text cut the values to "12…"; one per line then.
          if (_largeText(context))
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (i, cell) in cells.indexed) ...[
                  if (i > 0) const SizedBox(height: 10),
                  cell,
                ],
              ],
            )
          else
            Row(children: [for (final cell in cells) Expanded(child: cell)]),
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

/// The first load: the silhouette of the chart card and the two stat cards,
/// so the numbers replace it without a jump. Static; one spoken label.
class _TrendsSkeleton extends StatelessWidget {
  const _TrendsSkeleton({super.key});

  /// Bar heights as fractions of the plot.
  static const List<double> _bars = <double>[
    0.62, 0.74, 0.55, 0.81, 0.68, 0.47, 0.72, 0.6, 0.78, 0.52, 0.7, 0.64,
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    Widget stat() => const AppCard(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBar(widthFactor: 0.62, height: 10),
          SizedBox(height: 12),
          SkeletonBar(widthFactor: 0.74, height: 20),
          SizedBox(height: 10),
          SkeletonBar(widthFactor: 0.5, height: 10),
        ],
      ),
    );
    return Semantics(
      container: true,
      label: context.l10n.trendsLoading,
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppCard(
              // The chart card's insets and plot height.
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SkeletonBar(widthFactor: 0.46, height: 16),
                  const SizedBox(height: 18),
                  SizedBox(
                    height: 200,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (var i = 0; i < _bars.length; i++) ...[
                          if (i > 0) const SizedBox(width: 8),
                          Expanded(
                            child: FractionallySizedBox(
                              heightFactor: _bars[i],
                              alignment: Alignment.bottomCenter,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: t.tile,
                                  borderRadius: BorderRadius.circular(rPill),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  const SkeletonBar(widthFactor: 0.22, height: 10),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: stat()),
                const SizedBox(width: 12),
                Expanded(child: stat()),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return CalmState(
      key: const ValueKey('trends-empty'),
      card: true,
      icon: Icons.query_stats_rounded,
      title: l10n.trendsEmptyTitle,
      text: l10n.trendsEmptyBody,
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return CalmState(
      key: const ValueKey('trends-error'),
      card: true,
      icon: Icons.cloud_off_rounded,
      title: l10n.trendsErrorTitle,
      text: l10n.trendsErrorBody,
      actions: [
        SoftPillButton(
          key: const ValueKey('trends-retry'),
          label: l10n.trendsRetryCta,
          icon: Icons.refresh_rounded,
          onTap: onRetry,
        ),
      ],
    );
  }
}

/// Daily calorie bars (one series, so no legend), growing from the 0
/// baseline; gap days stay gaps, since "not tracked" is not a 0 kcal day.
/// All four colours arrive as fields and are checked in [shouldRepaint].
///
/// Target line and corridor are STEPPED per slot ([goalPerDay], F7-05): on a
/// day with a step bonus the goal sits higher, exactly as the Today tab
/// steered it. Without a bonus every slot carries the base goal and the line
/// is straight, as before.
///
/// The text is NOT built here: [labels] arrives pre-laid-out from the card, so
/// a frame of the build-up costs no `TextPainter.layout`, no `NumberFormat`
/// and no `DateFormat` at all.
class _KcalTrendPainter extends CustomPainter {
  _KcalTrendPainter({
    required this.window,
    required this.goalPerDay,
    required this.labels,
    required this.progress,
    required this.gridColor,
    required this.barColor,
    required this.goalLineColor,
    required this.bandColor,
  }) : assert(goalPerDay.length == window.length);

  final List<TrendDayTotals?> window;

  /// Effective goal per slot, same length as [window].
  final List<int> goalPerDay;

  /// Tick labels and weekday row, plus the axis maximum they were laid out
  /// for. Shared by every frame of one build-up.
  final TrendChartLabels labels;
  final double progress;
  final Color gridColor, barColor, goalLineColor, bandColor;

  @override
  void paint(Canvas canvas, Size size) {
    final showWeekdays = labels.weekdayLabels.isNotEmpty;
    final padding = EdgeInsets.fromLTRB(40, 14, 8, showWeekdays ? 20 : 6);
    final inner = Rect.fromLTWH(
      padding.left,
      padding.top,
      size.width - padding.horizontal,
      size.height - padding.vertical,
    );
    if (inner.width <= 0 || inner.height <= 0) return;

    var tracked = 0;
    for (final day in window) {
      if (day != null) tracked++;
    }
    final niceMax = labels.niceMax;

    // Quiet grid: 4 solid hairlines (0 to niceMax in thirds).
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = inner.bottom - inner.height * (i / 3);
      canvas.drawLine(Offset(inner.left, y), Offset(inner.right, y), gridPaint);
      _paintLabel(
        canvas,
        labels.gridLabels[i],
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

    // Target line: brighter than the grid, solid, stepped per slot. Its
    // legend sits in the card header, so no label covers the latest bars.
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
    }

    // 7-day view: weekday abbreviations under each slot as the x labels.
    for (var i = 0; i < labels.weekdayLabels.length; i++) {
      _paintLabel(
        canvas,
        labels.weekdayLabels[i],
        Offset(inner.left + slotW * i + slotW / 2, inner.bottom + 4),
        centerHorizontally: true,
      );
    }
  }

  /// Positions an already laid-out label around [anchor]. No layout work here
  /// — that is what makes a frame cheap.
  void _paintLabel(
    Canvas canvas,
    TextPainter tp,
    Offset anchor, {
    bool alignRight = false,
    bool centerHorizontally = false,
    bool centerVertically = false,
  }) {
    var dx = anchor.dx;
    if (alignRight) dx -= tp.width;
    if (centerHorizontally) dx -= tp.width / 2;
    var dy = anchor.dy;
    if (centerVertically) dy -= tp.height / 2;
    tp.paint(canvas, Offset(dx, dy));
  }

  void _drawEmptyHint(Canvas canvas, Size size) {
    final tp = labels.emptyHintFor(size.width - 24);
    tp.paint(
      canvas,
      Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2),
    );
  }

  /// Every field that reaches the canvas is compared. The two lists go through
  /// [listEquals] rather than `!=`: the screen rebuilds them from the same
  /// day objects on every `setState`, so identity would report a change that
  /// is not one. [labels] is compared by identity on purpose — it is only ever
  /// replaced when its own signature changed (see [TrendChartLabels.resolve]).
  @override
  bool shouldRepaint(covariant _KcalTrendPainter old) =>
      old.progress != progress ||
      !identical(old.labels, labels) ||
      !listEquals(old.window, window) ||
      !listEquals(old.goalPerDay, goalPerDay) ||
      old.gridColor != gridColor ||
      old.barColor != barColor ||
      old.goalLineColor != goalLineColor ||
      old.bandColor != bandColor;
}

/// One-time init of the `intl` date symbols for the weekday labels; the load
/// is synchronous from a bundled table.
bool _dateSymbolsReady = false;
void _ensureDateSymbols() {
  if (_dateSymbolsReady) return;
  initializeDateFormatting();
  _dateSymbolsReady = true;
}

// ---------------------------------------------------------------------------
// Locale-keyed DateFormat cache
//
// `DateFormat.E`/`DateFormat.Md` parse a skeleton and pull the locale's date
// symbols on construction. The painter built one PER WEEKDAY LABEL PER FRAME
// (seven per frame in the 7-day view), so they are hoisted. Keyed by locale
// rather than a bare global, so switching the app language still yields the
// right pattern; bounded by the supported locales (de/en).
// ---------------------------------------------------------------------------
final Map<String, DateFormat> _weekdayFormats = <String, DateFormat>{};
final Map<String, DateFormat> _dayMonthFormats = <String, DateFormat>{};

/// Weekday abbreviation format ("Mo" / "Mon") for [localeName].
DateFormat trendWeekdayFormat(String localeName) {
  _ensureDateSymbols();
  return _weekdayFormats[localeName] ??= DateFormat.E(localeName);
}

/// Day-and-month format for [localeName] (F7-09: `de` "1.8.", `en` "8/1").
DateFormat trendDayMonthFormat(String localeName) {
  _ensureDateSymbols();
  return _dayMonthFormats[localeName] ??= DateFormat.Md(localeName);
}

/// Empties both format caches so a test can observe a cold build.
@visibleForTesting
void debugClearTrendDateFormats() {
  _weekdayFormats.clear();
  _dayMonthFormats.clear();
}

/// Everything text-shaped in the trend chart, laid out ONCE.
///
/// Tick labels and the weekday row depend on the data,
/// the locale and the label colour — never on the animation progress. The
/// painter used to build them inside `paint()`: up to twelve
/// `TextPainter.layout()` calls plus as many `NumberFormat`s and seven
/// `DateFormat`s on every frame of the 550 ms build-up. [resolve] hands the
/// same instance back while its inputs are unchanged, so a frame only
/// positions and paints.
///
/// The labels are deliberately NOT text-scaled, exactly as before: the axis
/// gutter (40 px) and the chart box (200 px) are fixed, so a scaled 9 pt tick
/// would run into the bars. The ambient text scale therefore does not enter
/// the signature — it cannot change what is laid out here.
class TrendChartLabels {
  TrendChartLabels._(
    this._signature, {
    required this.niceMax,
    required this.gridLabels,
    required this.weekdayLabels,
    required this.emptyHintText,
    required this.emptyHintStyle,
  });

  /// Counts the [TextPainter.layout] calls this class made. Tests assert that
  /// the build-up animation adds none.
  @visibleForTesting
  static int debugLayoutCount = 0;

  /// Axis top, rounded to a value divisible into thirds.
  final int niceMax;

  /// The four tick labels, bottom (0) to top ([niceMax]).
  final List<TextPainter> gridLabels;

  /// Weekday abbreviation per slot — only in the 7-day view, else empty.
  final List<TextPainter> weekdayLabels;

  final String emptyHintText;
  final TextStyle emptyHintStyle;

  /// Structural key over everything the labels are made of. A record, so `==`
  /// compares by value.
  final Object _signature;

  TextPainter? _emptyHint;
  double? _emptyHintWidth;

  /// Returns [previous] unchanged when nothing text-relevant differs,
  /// otherwise lays the labels out anew.
  static TrendChartLabels resolve(
    TrendChartLabels? previous, {
    required List<TrendDayTotals?> window,
    required List<int> goalPerDay,
    required DateTime firstDay,
    required Color axisTextColor,
    required AppLocalizations l10n,
  }) {
    var maxKcal = 0;
    for (final day in window) {
      if (day != null) maxKcal = math.max(maxKcal, day.kcal);
    }
    var maxGoal = 0;
    for (final goal in goalPerDay) {
      maxGoal = math.max(maxGoal, goal);
    }
    final niceMax = _niceMax(math.max(maxKcal, maxGoal));
    final showWeekdays = window.length == 7;
    final signature = (
      locale: l10n.localeName,
      color: axisTextColor,
      niceMax: niceMax,
      // Only the weekday row depends on the date, and only in the 7-day view.
      firstDay: showWeekdays ? firstDay : null,
    );
    if (previous != null && previous._signature == signature) return previous;

    final locale = l10n.localeName;
    final style = AppType.display(
      9,
      weight: FontWeight.w500,
      color: axisTextColor,
    );
    return TrendChartLabels._(
      signature,
      niceMax: niceMax,
      gridLabels: <TextPainter>[
        for (var i = 0; i <= 3; i++)
          _laidOut(formatThousands((niceMax * i / 3).round(), locale), style),
      ],
      weekdayLabels: <TextPainter>[
        if (showWeekdays)
          for (var i = 0; i < window.length; i++)
            // B5: calendar-day shift; a Duration would slip a day across DST.
            _laidOut(
              trendWeekdayFormat(locale).format(addDays(firstDay, i)),
              style,
            ),
      ],
      emptyHintText: l10n.trendsChartEmptyHintPainter,
      emptyHintStyle: AppType.ui(
        12,
        weight: FontWeight.w500,
        color: axisTextColor,
        height: 1.4,
      ),
    );
  }

  /// The "nothing tracked" hint, laid out for [maxWidth]. Its wrap width is
  /// the one thing in the chart that depends on the canvas size, so it is
  /// re-laid out only when that width actually changed.
  TextPainter emptyHintFor(double maxWidth) {
    final hint = _emptyHint ??= TextPainter(
      text: TextSpan(text: emptyHintText, style: emptyHintStyle),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );
    if (_emptyHintWidth != maxWidth) {
      hint.layout(maxWidth: maxWidth);
      _emptyHintWidth = maxWidth;
      debugLayoutCount++;
    }
    return hint;
  }

  static TextPainter _laidOut(String text, TextStyle style) {
    debugLayoutCount++;
    return TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
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
}
