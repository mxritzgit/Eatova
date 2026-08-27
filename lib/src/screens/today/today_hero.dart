import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import 'today_texts.dart';

/// The forest surface at the top of "Today" and sole home of this calculation:
/// `goal + burned` feeds `remaining` and `progress`, but the DISPLAYED goal
/// stays the raw user goal (`test/kcal_goal_consistency_test.dart`).
class TodayCalorieHero extends StatelessWidget {
  const TodayCalorieHero({
    super.key,
    required this.consumedKcal,
    required this.burnedKcal,
    required this.kcalGoal,
    required this.streak,
  });

  final int consumedKcal;

  /// Live from the step count today, frozen on archive days. 0 means "no
  /// entry" — the tile shows a dash rather than an invented zero.
  final int burnedKcal;

  final int kcalGoal;

  /// Already resolved via `LifetimeStats.effectiveStreakOn`.
  final int streak;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;

    final goal = kcalGoal <= 0 ? 1 : kcalGoal;
    final eaten = consumedKcal.clamp(0, 99999).toInt();
    final burned = burnedKcal.clamp(0, 99999).toInt();
    final adjustedGoal = goal + burned;
    final remaining = (adjustedGoal - eaten).clamp(-99999, 99999).toInt();
    final progress = (eaten / adjustedGoal).clamp(0.0, 1.0);
    final ueberzogen = remaining < 0;

    return Container(
      key: const ValueKey('today-kcal-hero'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.forest,
        borderRadius: BorderRadius.circular(rHero),
      ),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: DotGridBackground(color: t.lime.withValues(alpha: 0.16)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        l10n.todayKcalBudgetEyebrow,
                        style: AppType.eyebrow(t.lime),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // The RAW daily goal: burned credit belongs in the
                    // REMAINING number, or this reads 2,300 while the goals
                    // screen says 2,000.
                    Flexible(
                      child: Text(
                        l10n.todayKcalGoalLabel(kcalThousands(goal, l10n)),
                        key: const ValueKey('today-kcal-goal'),
                        textAlign: TextAlign.right,
                        style: AppType.ui(
                          11,
                          weight: FontWeight.w500,
                          color: t.onForest.withValues(alpha: 0.65),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // 66 px base font becomes 132 px at textScaler 2.0.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: <Widget>[
                      Text(
                        // Magnitude only; the unit carries the sign.
                        kcalThousands(remaining.abs(), l10n),
                        key: const ValueKey('today-kcal-remaining'),
                        style: AppType.display(
                          66,
                          color: t.onForest,
                          height: 0.9,
                          letterSpacing: -3,
                        ),
                      ),
                      const SizedBox(width: 9),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          ueberzogen
                              ? l10n.todayKcalOver
                              : l10n.todayKcalRemaining,
                          style: AppType.ui(
                            13,
                            // Stays onForest: `danger` is illegible on forest
                            // in light mode, so the unit carries the signal.
                            weight:
                                ueberzogen ? FontWeight.w700 : FontWeight.w600,
                            color: ueberzogen
                                ? t.lime
                                : t.onForest.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Semantics(
                  label: l10n.todaySemanticsCalorieProgress,
                  value: l10n.todaySemanticsCalorieProgressValue(
                    (progress * 100).round(),
                  ),
                  child: TickGauge(progress: progress),
                ),
                const SizedBox(height: 18),
                _StatTiles(
                  tiles: <_Kachel>[
                    _Kachel(
                      keyValue: 'today-stat-eaten',
                      value: kcalThousands(eaten, l10n),
                      label: l10n.todayStatEaten,
                    ),
                    _Kachel(
                      keyValue: 'today-stat-burned',
                      // Same as calories_overview_card.dart:198-200.
                      value: burned == 0 ? '—' : kcalThousands(burned, l10n),
                      label: l10n.todayStatBurned,
                    ),
                    _Kachel(
                      keyValue: 'today-stat-streak',
                      value: '$streak',
                      label: l10n.todayStatStreak,
                      valueColor: t.lime,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The three metric tiles. Side by side up to [_stackAbove] text scale, one
/// under the other beyond it: a third of the card (~92 px) cannot hold a
/// scaled label, and a FittedBox would only undo the user's text setting
/// (review F8-09). The hero number above keeps its FittedBox — it is the one
/// place where shrinking is the intent.
class _StatTiles extends StatelessWidget {
  const _StatTiles({required this.tiles});

  final List<_Kachel> tiles;

  static const double _stackAbove = 1.3;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final stacked = scaler.scale(10) / 10 > _stackAbove;
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (var i = 0; i < tiles.length; i++) ...<Widget>[
            if (i > 0) ...<Widget>[
              const SizedBox(height: 10),
              const _Trenner(horizontal: true),
              const SizedBox(height: 10),
            ],
            tiles[i],
          ],
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (var i = 0; i < tiles.length; i++) ...<Widget>[
          if (i > 0) ...<Widget>[
            _Trenner(height: scaler.scale(34)),
            const SizedBox(width: 16),
          ],
          Expanded(child: tiles[i]),
        ],
      ],
    );
  }
}

class _Kachel extends StatelessWidget {
  const _Kachel({
    required this.keyValue,
    required this.value,
    required this.label,
    this.valueColor,
  });

  final String keyValue;
  final String value;
  final String label;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // Real text size, no FittedBox: the layout above makes room instead.
    // Labels may wrap at a hyphen ("TAGE-STREAK"); numbers never wrap.
    return Column(
      key: ValueKey<String>(keyValue),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          value,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: AppType.display(
            20,
            weight: FontWeight.w700,
            color: valueColor ?? t.onForest,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: AppType.ui(
            10.5,
            weight: FontWeight.w500,
            color: t.onForest.withValues(alpha: 0.6),
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

/// Hairline between tiles: vertical beside them, horizontal when stacked.
class _Trenner extends StatelessWidget {
  const _Trenner({this.horizontal = false, this.height = 34});

  final bool horizontal;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: horizontal ? double.infinity : 1,
      height: horizontal ? 1 : height,
      color: context.t.onForest.withValues(alpha: 0.18),
    );
  }
}
