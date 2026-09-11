import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../services/kcal_format.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
import 'today_texts.dart';
import 'today_progress.dart';

/// Every slot remains reachable, including empty and explicitly assigned slots.
class TodayMealsCard extends StatelessWidget {
  const TodayMealsCard({super.key, required this.meals, this.onOpenSlot});
  final List<LoggedMeal> meals;
  final ValueChanged<MealSlot>? onOpenSlot;

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey('today-meals-card'),
    children: [
      for (final slot in MealSlot.values) ...[
        TodayMealRow(
          slot: slot,
          meals: meals
              .where((meal) => meal.slot == slot)
              .toList(growable: false),
          last: slot == MealSlot.values.last,
          onTap: onOpenSlot == null ? null : () => onOpenSlot!(slot),
        ),
        if (slot != MealSlot.values.last) const SizedBox(height: 8),
      ],
    ],
  );
}

class TodayMealRow extends StatelessWidget {
  const TodayMealRow({
    super.key,
    required this.slot,
    required this.meals,
    this.last = false,
    this.onTap,
  });
  final MealSlot slot;
  final List<LoggedMeal> meals;
  final bool last;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final kcal = meals.fold<int>(
      0,
      (sum, meal) => sum + meal.result.caloriesKcal,
    );
    final empty = meals.isEmpty;
    final icon = switch (slot) {
      MealSlot.breakfast => Icons.breakfast_dining_outlined,
      MealSlot.lunch => Icons.lunch_dining_outlined,
      MealSlot.dinner => Icons.dinner_dining_outlined,
      MealSlot.snack => Icons.cookie_outlined,
    };
    return Material(
      color: t.surf,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rCard),
        side: BorderSide(color: t.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey<String>('today-meal-row-${slot.name}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: empty ? t.surf2 : t.brandSurface,
                  borderRadius: BorderRadius.circular(rControl),
                ),
                child: Icon(
                  icon,
                  color: empty ? t.ink2 : t.onBrandSurface,
                  size: 26,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      slot.label(l10n),
                      style: AppType.ui(11.5, color: t.ink2),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      empty
                          ? l10n.todayMealOpen
                          : mealSlotSubtitle(meals, l10n),
                      style: AppType.ui(
                        14,
                        weight: FontWeight.w600,
                        color: t.ink,
                        height: 1.25,
                      ),
                    ),
                    if (!empty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${kcalThousands(kcal, l10n)} kcal',
                        style: AppType.ui(12, color: t.ink2),
                      ),
                    ],
                  ],
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 8),
                Icon(
                  empty ? Icons.add_rounded : Icons.chevron_right_rounded,
                  size: 21,
                  color: t.ink2,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Daily steps and the activity credit behind the calorie budget.
class TodayStepsCard extends StatelessWidget {
  const TodayStepsCard({
    super.key,
    required this.steps,
    required this.goal,
    required this.burnedKcal,
  });
  final int steps, goal, burnedKcal;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final count = steps.clamp(0, 9999999);
    final target = goal.clamp(0, 9999999);
    final progress = target <= 0 ? 0.0 : (count / target).clamp(0.0, 1.0);
    final subtitle = <String>[
      if (burnedKcal > 0)
        l10n.todayStepsBurned(formatThousands(burnedKcal, l10n.localeName)),
      if (target > 0 && count >= target) l10n.todayStepsGoalReached,
    ].join(' · ');
    return Container(
      key: const ValueKey('today-steps-card'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.surf2,
        borderRadius: BorderRadius.circular(rCard),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.maxWidth >= 285 &&
              MediaQuery.textScalerOf(context).scale(14) <= 18;
          return Row(
            children: [
              StepsIcon(size: 28, color: t.ink),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 5,
                      runSpacing: 3,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          formatThousands(count, l10n.localeName),
                          key: const ValueKey('today-steps-value'),
                          style: AppType.display(21, color: t.ink),
                        ),
                        if (target > 0)
                          Text(
                            '/ ${formatThousands(target, l10n.localeName)}',
                            key: const ValueKey('today-steps-goal'),
                            style: AppType.ui(13, color: t.ink),
                          ),
                        Text(
                          l10n.todayStepsTitle,
                          style: AppType.ui(13, color: t.ink),
                        ),
                      ],
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        key: const ValueKey('today-steps-subtitle'),
                        style: AppType.ui(11.5, color: t.ink2, height: 1.4),
                      ),
                    ],
                    const SizedBox(height: 9),
                    Semantics(
                      label: l10n.todaySemanticsStepsProgress,
                      value: l10n.todaySemanticsStepsProgressValue(
                        formatThousands(count, l10n.localeName),
                        formatThousands(target, l10n.localeName),
                      ),
                      child: ExcludeSemantics(
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: progress),
                          duration: motionDuration(
                            context,
                            const Duration(milliseconds: 320),
                          ),
                          curve: Curves.easeOutCubic,
                          builder: (context, value, _) => ClipRRect(
                            borderRadius: BorderRadius.circular(rPill),
                            child: LinearProgressIndicator(
                              key: const ValueKey('today-steps-bar'),
                              borderRadius: BorderRadius.circular(rPill),
                              value: value,
                              minHeight: 8,
                              backgroundColor: t.surf,
                              valueColor: AlwaysStoppedAnimation(
                                t.progressAccent,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (compact && target > 0) ...[
                const SizedBox(width: 12),
                ExcludeSemantics(
                  child: TodayProgressRing(
                    key: const ValueKey('today-steps-ring'),
                    progress: progress,
                    size: 52,
                    child: Text(
                      '${(progress * 100).round()}%',
                      style: AppType.ui(
                        12,
                        weight: FontWeight.w700,
                        color: t.ink,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// The AI coach banner, with a concrete teaser from the remaining macros.
class TodayCoachBanner extends StatelessWidget {
  const TodayCoachBanner({super.key, required this.teaser, this.onTap});

  final String teaser;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Container(
      key: const ValueKey('today-coach-banner'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.surf2,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: t.line),
      ),
      child: Stack(
        children: <Widget>[
          Positioned(
            right: -30,
            top: -30,
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: t.lime.withValues(alpha: 0.30),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(l10n.todayCoachEyebrow, style: AppType.eyebrow(t.ink2)),
                const SizedBox(height: 6),
                // No fixed text width: it breaks at large system font sizes.
                // The column already gives the text the card width, and the
                // circle top right sits behind it.
                Text(
                  teaser,
                  style: AppType.display(
                    19,
                    weight: FontWeight.w700,
                    color: t.ink,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Material(
                    color: t.forest,
                    borderRadius: BorderRadius.circular(rChip),
                    child: InkWell(
                      key: const ValueKey('today-coach-cta'),
                      onTap: onTap,
                      borderRadius: BorderRadius.circular(rChip),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 44),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 15,
                          vertical: 9,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Flexible(
                              child: Text(
                                l10n.todayCoachCta,
                                style: AppType.ui(
                                  12,
                                  weight: FontWeight.w600,
                                  color: t.onForest,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 16,
                              color: t.lime,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The day is still loading — spinner instead of a falsely empty meals card.
/// Text identical to the food tab (meal_analysis_screen.dart:965).
class TodayDayLoadingCard extends StatelessWidget {
  const TodayDayLoadingCard({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AppCard(
      key: const ValueKey('today-day-loading'),
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
          const SizedBox(height: 10),
          Text(
            context.l10n.todayDayLoading,
            style: AppType.ui(12.5, weight: FontWeight.w600, color: t.ink2),
          ),
        ],
      ),
    );
  }
}
