import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import 'today_progress.dart';
import 'today_texts.dart';

/// Raw goal remains distinct from the activity-adjusted daily budget.
class TodayCalorieHero extends StatelessWidget {
  const TodayCalorieHero({
    super.key,
    required this.consumedKcal,
    required this.burnedKcal,
    required this.kcalGoal,
    required this.streak,
    this.isToday = true,
  });

  final int consumedKcal, burnedKcal, kcalGoal, streak;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final goal = kcalGoal <= 0 ? 1 : kcalGoal;
    final eaten = consumedKcal.clamp(0, 99999);
    final burned = burnedKcal.clamp(0, 99999);
    final budget = goal + burned;
    final remaining = (budget - eaten).clamp(-99999, 99999);
    final progress = (eaten / budget).clamp(0.0, 1.0);
    final percent = (progress * 100).round();
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isToday ? l10n.todayBalanceRemaining : l10n.todayBalanceArchive,
          style: AppType.ui(
            14,
            weight: FontWeight.w600,
            color: t.onBrandSurface,
          ),
        ),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            kcalThousands(remaining.abs(), l10n),
            key: const ValueKey('today-kcal-remaining'),
            style: AppType.display(48, color: t.onBrandSurface, height: 1),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          remaining < 0 ? l10n.todayKcalOver : l10n.todayKcalRemaining,
          style: AppType.ui(
            15,
            weight: FontWeight.w600,
            color: t.onBrandSurface,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          l10n.todayBalanceEaten(kcalThousands(eaten, l10n)),
          key: const ValueKey('today-stat-eaten'),
          style: AppType.ui(12, color: t.onBrandSurface, height: 1.45),
        ),
        Text(
          l10n.todayKcalGoalLabel(kcalThousands(goal, l10n)),
          key: const ValueKey('today-kcal-goal'),
          style: AppType.ui(12, color: t.onBrandSurface, height: 1.45),
        ),
        if (burned > 0)
          Text(
            l10n.todayBalanceActivity(kcalThousands(burned, l10n)),
            key: const ValueKey('today-stat-burned'),
            style: AppType.ui(12, color: t.onBrandSurface, height: 1.45),
          ),
      ],
    );

    Widget ring(double size) => Semantics(
      label: l10n.todaySemanticsCalorieProgress,
      value: l10n.todaySemanticsCalorieProgressValue(percent),
      child: ExcludeSemantics(
        child: TodayProgressRing(
          key: const ValueKey('today-kcal-ring'),
          fillCenter: true,
          progress: progress,
          size: size,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(color: t.ink, shape: BoxShape.circle),
                child: Icon(
                  Icons.local_fire_department_outlined,
                  color: t.bg,
                  size: 21,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                '$percent%',
                maxLines: 1,
                style: AppType.display(21, color: t.onBrandSurface),
              ),
            ],
          ),
        ),
      ),
    );

    return Container(
      key: const ValueKey('today-kcal-hero'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: t.brandSurface,
        borderRadius: BorderRadius.circular(rHero),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked = constraints.maxWidth < 270 || textScale > 1.3;
          final size = stacked
              ? (112 + 44 * textScale).clamp(170.0, 240.0)
              : (constraints.maxWidth * 0.43).clamp(118.0, 170.0);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (stacked) ...[
                details,
                const SizedBox(height: 18),
                Align(child: ring(size)),
              ] else
                Row(
                  children: [
                    Expanded(child: details),
                    const SizedBox(width: 12),
                    ring(size),
                  ],
                ),
              if (streak > 0) ...[
                const SizedBox(height: 12),
                Text(
                  l10n.todayBalanceStreak(streak),
                  key: const ValueKey('today-stat-streak'),
                  style: AppType.ui(11, color: t.onBrandSurface),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
