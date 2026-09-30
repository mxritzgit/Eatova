import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/day_nutrition.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/lively.dart';
import '../../widgets/design/design.dart';
import 'today_progress.dart';
import 'today_texts.dart';

/// The calorie card of the dark redesign: "Calories" with the eaten share,
/// the 270° arc with the kcal left in its centre, and Eaten / Goal / Activity
/// below a hairline.
///
/// All numbers come from one [DayNutritionSummary] (budget = raw goal +
/// activity credit), the same rule every tab uses. The goal stays the raw
/// profile value and the activity credit its own stat, so the arithmetic
/// remains traceable; without a credit the Activity stat is left out rather
/// than claiming "+0".
class TodayCalorieCard extends StatelessWidget {
  const TodayCalorieCard({
    super.key,
    required this.summary,
    this.isToday = true,
  });

  final DayNutritionSummary summary;

  /// Archive days say "that day" instead of "today".
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final remaining = summary.remainingKcal;
    final over = remaining < 0;
    final percent = (summary.eatenFraction * 100).round();
    final budget = kcalThousands(summary.budgetKcal, l10n);
    final eyebrow = switch ((isToday, over)) {
      (true, false) => l10n.todayArcLeftToday,
      (true, true) => l10n.todayArcOverToday,
      (false, false) => l10n.todayArcLeftArchive,
      (false, true) => l10n.todayArcOverArchive,
    };

    return Container(
      key: const ValueKey('today-kcal-hero'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rHero),
        border: Border.all(color: t.cardBorder),
      ),
      child: Stack(
        children: <Widget>[
          // The design's violet glow behind the arc: 300x260, 40 px down.
          Positioned(
            top: 40,
            left: 0,
            right: 0,
            height: 260,
            child: IgnorePointer(
              child: Center(
                child: SizedBox(
                  width: 300,
                  height: 260,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        colors: <Color>[
                          t.arcStart.withValues(alpha: 0.22),
                          t.arcStart.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // Title left, pill right; with large text the pill moves
                // under the title instead of overflowing.
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 6,
                  children: <Widget>[
                    HeadingSemantics(
                      level: 2,
                      child: Text(
                        l10n.todayCaloriesTitle,
                        style: AppType.ui(
                          15,
                          weight: FontWeight.w700,
                          color: t.ink,
                          height: todayLineHeight,
                        ),
                      ),
                    ),
                    // The arc node below reads the same share aloud.
                    ExcludeSemantics(child: _EatenPill(percent: percent)),
                  ],
                ),
                const SizedBox(height: 4),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = math.min(
                      TodayCalorieArc.designWidth,
                      constraints.maxWidth,
                    );
                    return Center(
                      child: _ArcWithCentre(
                        width: width,
                        percent: percent,
                        progress: summary.eatenFraction,
                        eyebrow: eyebrow,
                        remaining: remaining.abs(),
                        budgetLine: over
                            ? l10n.todayArcBudgetOver(budget)
                            : l10n.todayArcBudget(budget),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 4),
                _Stats(summary: summary),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EatenPill extends StatelessWidget {
  const _EatenPill({required this.percent});
  final int percent;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      constraints: const BoxConstraints(minHeight: 26),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: t.accentTint,
        borderRadius: BorderRadius.circular(13),
      ),
      // Hugs the text (an `alignment` would stretch the pill across the
      // header's Wrap and push it onto a line of its own).
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: CountingText(
          value: percent.toDouble(),
          format: (v) => context.l10n.todayEatenPercent(v.round()),
          textKey: const ValueKey('today-kcal-percent'),
          style: AppType.ui(
            13,
            weight: FontWeight.w700,
            color: t.accentText,
            height: todayLineHeight,
          ),
        ),
      ),
    );
  }
}

/// The arc plus the "LEFT TODAY / 902 / kcal of 2,123" block centred in its
/// 240 px circle. The block scales down (never up) to stay inside the ring
/// at large system text; the stats below keep the full text size.
class _ArcWithCentre extends StatelessWidget {
  const _ArcWithCentre({
    required this.width,
    required this.percent,
    required this.progress,
    required this.eyebrow,
    required this.remaining,
    required this.budgetLine,
  });

  final double width;
  final int percent;
  final double progress;

  /// Kcal left (or over), counted up in step with the arc.
  final int remaining;
  final String eyebrow, budgetLine;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final scale = width / TodayCalorieArc.designWidth;
    return SizedBox(
      key: const ValueKey('today-kcal-ring'),
      width: width,
      height:
          width * TodayCalorieArc.designHeight / TodayCalorieArc.designWidth,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: Semantics(
              container: true,
              label: l10n.todaySemanticsCalorieProgress,
              value: l10n.todaySemanticsCalorieProgressValue(percent),
              child: ExcludeSemantics(
                child: TodayCalorieArc(progress: progress, width: width),
              ),
            ),
          ),
          // Centred on the circle (a 240 px square), not on the shorter box.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: width,
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 168 * scale,
                  maxHeight: 150 * scale,
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        eyebrow.toUpperCase(),
                        semanticsLabel: eyebrow,
                        style: AppType.ui(
                          12,
                          weight: FontWeight.w700,
                          color: t.ink2,
                          letterSpacing: 12 * 0.08,
                          height: todayLineHeight,
                        ),
                      ),
                      CountingText(
                        value: remaining.toDouble(),
                        format: (v) => kcalThousands(v.round(), l10n),
                        textKey: const ValueKey('today-kcal-remaining'),
                        style: AppType.display(
                          58,
                          color: t.ink,
                          letterSpacing: -58 * 0.04,
                          height: 1.05,
                        ),
                      ),
                      Text(
                        budgetLine,
                        key: const ValueKey('today-kcal-budget'),
                        style: AppType.ui(
                          14,
                          weight: FontWeight.w500,
                          color: t.ink2,
                          height: todayLineHeight,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Eaten / Goal / Activity. Side by side like the design while every value
/// fits its column; otherwise stacked label-left, value-right rows, so large
/// system text keeps its size instead of being shrunk (review F8-09).
class _Stats extends StatelessWidget {
  const _Stats({required this.summary});
  final DayNutritionSummary summary;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final burned = summary.burnedKcal;
    final stats = <_Stat>[
      _Stat(
        'today-stat-eaten',
        l10n.todayStatEatenLabel,
        kcalThousands(summary.consumedKcal, l10n),
        t.ink,
        count: summary.consumedKcal,
        format: (v) => kcalThousands(v.round(), l10n),
      ),
      _Stat(
        'today-kcal-goal',
        l10n.todayStatGoalLabel,
        kcalThousands(summary.goalKcal, l10n),
        t.ink,
      ),
      if (burned > 0)
        _Stat(
          'today-stat-burned',
          l10n.todayStatActivityLabel,
          '+${kcalThousands(burned, l10n)}',
          t.activityInk,
          count: burned,
          format: (v) => '+${kcalThousands(v.round(), l10n)}',
        ),
    ];
    final labelStyle = AppType.ui(
      12,
      weight: FontWeight.w600,
      color: t.ink3,
      height: todayLineHeight,
    );
    TextStyle valueStyle(Color color) => AppType.ui(
      17,
      weight: FontWeight.w700,
      color: color,
      height: todayLineHeight,
    ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

    return Container(
      padding: const EdgeInsets.only(top: 14),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.line)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = 8.0;
          final column =
              (constraints.maxWidth - gap * (stats.length - 1)) / stats.length;
          final scaler = MediaQuery.textScalerOf(context);
          final fits = stats.every(
            (s) =>
                _widthOf(s.label, labelStyle, scaler) <= column &&
                _widthOf(s.value, valueStyle(s.color), scaler) <= column,
          );
          if (fits) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (var i = 0; i < stats.length; i++) ...<Widget>[
                  if (i > 0) const SizedBox(width: gap),
                  Expanded(
                    child: Column(
                      children: <Widget>[
                        Text(stats[i].label, style: labelStyle),
                        const SizedBox(height: 2),
                        stats[i].text(style: valueStyle(stats[i].color)),
                      ],
                    ),
                  ),
                ],
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (var i = 0; i < stats.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: <Widget>[
                    Expanded(child: Text(stats[i].label, style: labelStyle)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: stats[i].text(
                        style: valueStyle(stats[i].color),
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  static double _widthOf(String text, TextStyle style, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}

class _Stat {
  const _Stat(
    this.key,
    this.label,
    this.value,
    this.color, {
    this.count,
    this.format,
  });

  /// [value] is the resting text; it also decides the layout.
  final String key, label, value;
  final Color color;

  /// With both set, the value counts to [count] (a static goal does not).
  final int? count;
  final String Function(double)? format;

  Widget text({required TextStyle style, TextAlign? textAlign}) {
    final count = this.count, format = this.format;
    if (count == null || format == null) {
      return Text(
        value,
        key: ValueKey<String>(key),
        textAlign: textAlign,
        style: style,
      );
    }
    return CountingText(
      value: count.toDouble(),
      format: format,
      textKey: ValueKey<String>(key),
      textAlign: textAlign,
      style: style,
    );
  }
}
