import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/day_nutrition.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/lively.dart';
import '../../widgets/common/motion.dart';
import 'today_texts.dart';

/// Three macro tiles (dark redesign): dot and name, eaten against the goal, a
/// 6 px bar and the grams still open.
///
/// The visible names are the compact tile labels ("Carbs" in both languages,
/// as on the goals screens); screen readers hear the full name.
class TodayMacros extends StatelessWidget {
  const TodayMacros({super.key, required this.summary});

  final DayNutritionSummary summary;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final consumed = summary.consumed;
    final tiles = <_MacroSpec>[
      _MacroSpec(
        label: l10n.todayMacroProtein,
        shortLabel: l10n.todayMacroProtein,
        value: consumed.proteinG.round(),
        goal: summary.proteinGoalG,
        left: summary.proteinLeftG,
        color: t.protein,
      ),
      _MacroSpec(
        label: l10n.todayMacroCarbs,
        shortLabel: l10n.foodMacroTileCarbsLabel,
        value: consumed.carbsG.round(),
        goal: summary.carbsGoalG,
        left: summary.carbsLeftG,
        color: t.carbs,
      ),
      _MacroSpec(
        label: l10n.todayMacroFat,
        shortLabel: l10n.todayMacroFat,
        value: consumed.fatG.round(),
        goal: summary.fatGoalG,
        left: summary.fatLeftG,
        color: t.fat,
      ),
    ];
    return Semantics(
      container: true,
      label: l10n.todayMacrosTitle,
      explicitChildNodes: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = 10.0;
          // Tile content width: a third minus the gaps, 12 px padding and the
          // 1 px border on each side.
          final inner = (constraints.maxWidth - 2 * gap) / 3 - 26;
          final scaler = MediaQuery.textScalerOf(context);
          // One decision for all three tiles keeps their heights equal: the
          // tiles share one structure, so equal content gives equal height.
          final stack = tiles.any(
            (s) =>
                _inlineWidth(s, scaler, _valueStyle(t), _goalStyle(t)) > inner,
          );
          return Row(
            key: const ValueKey('today-macros-card'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (var i = 0; i < tiles.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: gap),
                Expanded(
                  child: TodayMacroTile(
                    label: tiles[i].label,
                    shortLabel: tiles[i].shortLabel,
                    value: tiles[i].value,
                    goal: tiles[i].goal,
                    left: tiles[i].left,
                    color: tiles[i].color,
                    stackValue: stack,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  static TextStyle _valueStyle(AppTokens t) => AppType.display(
    24,
    weight: FontWeight.w700,
    color: t.ink,
    letterSpacing: -24 * 0.02,
    height: todayLineHeight,
  );

  static TextStyle _goalStyle(AppTokens t) =>
      AppType.ui(13, color: t.ink3, height: todayLineHeight);

  static double _inlineWidth(
    _MacroSpec spec,
    TextScaler scaler,
    TextStyle value,
    TextStyle goal,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        children: <TextSpan>[
          TextSpan(text: '${spec.value}', style: value),
          TextSpan(text: '/${spec.goal} g', style: goal),
        ],
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    // Plus the 2 px gap between number and goal.
    final width = painter.width + 2;
    painter.dispose();
    return width;
  }
}

/// Values of one tile; `left` is the rounded, never negative grams open.
class _MacroSpec {
  const _MacroSpec({
    required this.label,
    required this.shortLabel,
    required this.value,
    required this.goal,
    required this.left,
    required this.color,
  });

  final String label, shortLabel;
  final int value, goal, left;
  final Color color;
}

class TodayMacroTile extends StatelessWidget {
  const TodayMacroTile({
    super.key,
    required this.label,
    required this.shortLabel,
    required this.value,
    required this.goal,
    required this.left,
    required this.color,
    this.stackValue = false,
  });

  /// Full name for screen readers; [shortLabel] is what the tile shows.
  final String label, shortLabel;

  /// Eaten and goal grams; [left] is rounded and never negative.
  final int value, goal, left;
  final Color color;

  /// Puts "/162 g" under the number when both do not fit side by side.
  final bool stackValue;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final fraction = goal <= 0 ? 0.0 : (value / goal).clamp(0.0, 1.0);
    final over = value - goal;
    final rest = left > 0 || over <= 0
        ? l10n.todayMacroLeft(left)
        : l10n.todayMacroOver(over);
    final number = CountingText(
      value: value.toDouble(),
      format: (v) => '${v.round()}',
      style: TodayMacros._valueStyle(t),
    );
    // No wrap: the parent only keeps it inline when it fits, so a sub-pixel
    // rounding must not push "g" onto a second line.
    final goalText = Text(
      '/$goal g',
      maxLines: 1,
      softWrap: false,
      style: TodayMacros._goalStyle(t),
    );
    return Semantics(
      container: true,
      label: label,
      value: '${l10n.todayMacroProgressValue(value, goal)}, $rest',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
          decoration: BoxDecoration(
            color: t.surf,
            borderRadius: BorderRadius.circular(rTile),
            border: Border.all(color: t.cardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  // One line in every tile, so the three stay level; only a
                  // 2x font on a small phone scales the name down.
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        shortLabel,
                        style: AppType.ui(
                          13,
                          weight: FontWeight.w600,
                          color: t.ink2,
                          height: todayLineHeight,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (stackValue)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[number, goalText],
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: <Widget>[
                    number,
                    const SizedBox(width: 2),
                    Flexible(child: goalText),
                  ],
                ),
              const SizedBox(height: 8),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: fraction),
                duration: motionDuration(context, kMotionValue),
                curve: kMotionCurve,
                builder: (context, value, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: value,
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(3),
                    backgroundColor: t.tile,
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                rest,
                style: AppType.ui(12, color: t.ink3, height: todayLineHeight),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
