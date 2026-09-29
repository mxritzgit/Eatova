import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/day_nutrition.dart';
import '../../models/logged_meal.dart';
import '../../models/recipe_pick.dart';
import '../../models/training_insights.dart';
import '../../services/kcal_format.dart';
import '../../services/meal_totals.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
import '../../widgets/recipes/recipe_photo.dart';
import 'today_glyphs.dart';
import 'today_texts.dart';

/// An [InkWell] only when there is something to do. Without [onTap] the
/// child keeps its key but shows no ripple and no tap action, so a control
/// without a destination never looks or reads as live.
class TodayTapTarget extends StatelessWidget {
  const TodayTapTarget({
    super.key,
    required this.onTap,
    required this.child,
    this.borderRadius,
    this.customBorder,
  });

  final VoidCallback? onTap;
  final Widget child;
  final BorderRadius? borderRadius;
  final ShapeBorder? customBorder;

  @override
  Widget build(BuildContext context) => onTap == null
      ? child
      : InkWell(
          onTap: onTap,
          borderRadius: borderRadius,
          customBorder: customBorder,
          child: child,
        );
}

/// Glyph on a 44 px tinted tile (radius 14), as in the design's rows.
class _GlyphTile extends StatelessWidget {
  const _GlyphTile({
    required this.glyph,
    required this.tint,
    required this.ink,
  });

  final TodayGlyph glyph;
  final Color tint, ink;

  @override
  Widget build(BuildContext context) => Container(
    width: 44,
    height: 44,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: tint,
      borderRadius: BorderRadius.circular(rControl),
    ),
    child: TodayGlyphIcon(glyph, color: ink),
  );
}

/// The design's slot tiles: sunrise, bowl, moon and apple on their hues.
///
/// Today-only stand-in: the Food task owns the shared slot style and its
/// `SlotIconTile`; Today switches to it when the tabs are merged. The values
/// equal the design's (breakfast tint rgba(70,151,226,.16) + #8CC4FF, lunch
/// rgba(29,176,113,.16) + #6FDCA4, dinner rgba(213,124,17,.18) + #FFB866,
/// snacks rgba(185,165,255,.16) + #C8B8FF).
class _SlotTile extends StatelessWidget {
  const _SlotTile(this.slot);
  final MealSlot slot;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final (glyph, tint, ink) = switch (slot) {
      MealSlot.breakfast => (
        TodayGlyph.sunrise,
        t.carbs.withValues(alpha: 0.16),
        t.carbsInk,
      ),
      MealSlot.lunch => (
        TodayGlyph.bowl,
        t.protein.withValues(alpha: 0.16),
        t.proteinInk,
      ),
      MealSlot.dinner => (
        TodayGlyph.moon,
        t.fat.withValues(alpha: 0.18),
        t.fatInk,
      ),
      MealSlot.snack => (TodayGlyph.apple, t.accentTintStrong, t.accentText),
    };
    return _GlyphTile(glyph: glyph, tint: tint, ink: ink);
  }
}

/// "Tonight's pick": the recipe for today's next open main meal
/// (`HomeStore.nextMealPick`), opening that recipe. The line under the
/// numbers says what the day has left after it; a planned meal that does not
/// fit says how far it goes over instead.
class TodayPickRow extends StatelessWidget {
  const TodayPickRow({super.key, required this.pick, this.onTap});

  final RecipePick pick;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final eyebrow = pick.source == RecipePickSource.planned
        ? l10n.todayPickPlannedEyebrow(pick.slot.name)
        : l10n.todayPickEyebrow(pick.slot.name);
    final kcal = pick.kcal;
    final left = pick.kcalLeftAfter;
    final radius = BorderRadius.circular(rCard);
    return MergeSemantics(
      child: Semantics(
        button: onTap != null,
        child: Material(
          color: t.surf,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: t.cardBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: TodayTapTarget(
            key: const ValueKey('today-pick'),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(rThumb),
                    child: SizedBox.square(
                      dimension: 84,
                      child: ExcludeSemantics(
                        child: RecipePhoto(recipe: pick.recipe),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          eyebrow.toUpperCase(),
                          semanticsLabel: eyebrow,
                          style: AppType.ui(
                            12,
                            weight: FontWeight.w700,
                            color: t.accentText,
                            letterSpacing: 12 * 0.06,
                            height: todayLineHeight,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          pick.recipe.displayTitle(l10n),
                          key: const ValueKey('today-pick-title'),
                          style: AppType.ui(
                            16,
                            weight: FontWeight.w700,
                            color: t.ink,
                            height: 1.25,
                          ),
                        ),
                        if (kcal != null) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            l10n.todayPickMeta(
                              kcalThousands(kcal, l10n),
                              pick.proteinG ?? 0,
                            ),
                            style: AppType.ui(
                              13,
                              color: t.ink2,
                              height: todayLineHeight,
                            ),
                          ),
                        ],
                        if (left != null) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            left >= 0
                                ? l10n.todayPickLeaves(
                                    kcalThousands(left, l10n),
                                  )
                                : l10n.todayPickOver(
                                    kcalThousands(-left, l10n),
                                  ),
                            key: const ValueKey('today-pick-leaves'),
                            style: AppType.ui(
                              13,
                              weight: FontWeight.w700,
                              color: left >= 0 ? t.success : t.warning,
                              height: todayLineHeight,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Meals" with the "Open food log" link to the Food tab. The row is at
/// least 44 px high so the link is a full touch target.
class TodayMealsHeader extends StatelessWidget {
  const TodayMealsHeader({super.key, this.onOpenFoodLog});

  final VoidCallback? onOpenFoodLog;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        // Heading left, link right; with large text the link wraps under
        // the heading instead of overflowing.
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: <Widget>[
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Align(
                alignment: Alignment.centerLeft,
                widthFactor: 1,
                heightFactor: 1,
                child: HeadingSemantics(
                  level: 2,
                  child: Text(
                    l10n.todayMealsTitleArchive,
                    style: AppType.display(
                      22,
                      weight: FontWeight.w700,
                      color: t.ink,
                      letterSpacing: -0.22,
                      height: todayLineHeight,
                    ),
                  ),
                ),
              ),
            ),
            if (onOpenFoodLog != null)
              Semantics(
                button: true,
                child: InkWell(
                  key: const ValueKey('today-open-food-log'),
                  borderRadius: BorderRadius.circular(rChip),
                  onTap: onOpenFoodLog,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: 44,
                      minWidth: 44,
                    ),
                    child: Center(
                      widthFactor: 1,
                      child: Text(
                        l10n.todayOpenFoodLog,
                        style: AppType.ui(
                          14,
                          weight: FontWeight.w700,
                          color: t.accentText,
                          height: todayLineHeight,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The four slots in one card. A filled slot lists its items and kcal; an
/// empty one on today suggests a kcal band from the day's budget. Each slot's
/// add button opens the Food tab's add flow for THAT slot on the shown day;
/// the next open main meal's button is accent-filled.
class TodayMealsCard extends StatelessWidget {
  const TodayMealsCard({
    super.key,
    required this.slots,
    required this.summary,
    this.isToday = true,
    this.accentSlot,
    this.onAdd,
  });

  /// All four slots in [MealSlot.values] order.
  final List<MealSlotSummary> slots;
  final DayNutritionSummary summary;
  final bool isToday;
  final MealSlot? accentSlot;
  final ValueChanged<MealSlot>? onAdd;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Container(
      key: const ValueKey('today-meals-card'),
      padding: const EdgeInsets.fromLTRB(14, 2, 8, 2),
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: t.cardBorder),
      ),
      child: Column(
        children: <Widget>[
          for (var i = 0; i < slots.length; i++) ...<Widget>[
            if (i > 0) Container(height: 1, color: t.line),
            TodayMealRow(
              slot: slots[i],
              subtitle: _subtitle(slots[i], l10n),
              accent: slots[i].slot == accentSlot,
              onAdd: onAdd == null ? null : () => onAdd!(slots[i].slot),
            ),
          ],
        ],
      ),
    );
  }

  String _subtitle(MealSlotSummary slot, AppLocalizations l10n) {
    if (!slot.isEmpty) return mealSlotSubtitle(slot.meals, l10n);
    if (!isToday) return l10n.todaySlotNothingLogged;
    final range = summary.suggestedKcalRange(slot.slot);
    return l10n.todaySlotSuggested(
      kcalThousands(range.minKcal, l10n),
      kcalThousands(range.maxKcal, l10n),
    );
  }
}

class TodayMealRow extends StatelessWidget {
  const TodayMealRow({
    super.key,
    required this.slot,
    required this.subtitle,
    this.accent = false,
    this.onAdd,
  });

  final MealSlotSummary slot;
  final String subtitle;
  final bool accent;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final name = slot.slot.name;
    final kcal = slot.isEmpty
        ? null
        : Text(
            '${kcalThousands(slot.kcal, l10n)} kcal',
            key: ValueKey<String>('today-meal-kcal-$name'),
            maxLines: 1,
            style: AppType.ui(
              14,
              weight: FontWeight.w700,
              color: t.inkMuted,
              height: todayLineHeight,
            ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          );
    final label = Text(
      slot.slot.label(l10n),
      maxLines: 1,
      style: AppType.ui(
        16,
        weight: FontWeight.w700,
        color: t.ink,
        height: todayLineHeight,
      ),
    );
    final sub = Text(
      subtitle,
      key: ValueKey<String>('today-meal-sub-$name'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      style: AppType.ui(13, color: t.ink3, height: todayLineHeight),
    );
    return Padding(
      key: ValueKey<String>('today-meal-row-$name'),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Tile, add button and gaps are fixed; the kcal moves under the
          // subtitle when the name would otherwise get less than ~72 px.
          final fixed = 44 + 12 + (onAdd == null ? 0 : 12 + 44);
          final kcalWidth = kcal == null
              ? 0.0
              : _widthOf(kcal.data!, kcal.style!, context) + 12;
          final inline = constraints.maxWidth - fixed - kcalWidth >= 72;
          return Row(
            children: <Widget>[
              _SlotTile(slot.slot),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: label,
                    ),
                    const SizedBox(height: 2),
                    sub,
                    if (kcal != null && !inline) ...<Widget>[
                      const SizedBox(height: 2),
                      kcal,
                    ],
                  ],
                ),
              ),
              if (kcal != null && inline) ...<Widget>[
                const SizedBox(width: 12),
                kcal,
              ],
              if (onAdd != null) ...<Widget>[
                const SizedBox(width: 12),
                _AddButton(
                  key: ValueKey<String>('today-meal-add-$name'),
                  accent: accent,
                  label: l10n.foodSlotAddLabel(slot.slot.label(l10n)),
                  onTap: onAdd!,
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  static double _widthOf(String text, TextStyle style, BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}

/// 34 px round "+" in a 44 px target: accent fill for the next open main
/// meal, the accent tint otherwise.
class _AddButton extends StatelessWidget {
  const _AddButton({
    super.key,
    required this.accent,
    required this.label,
    required this.onTap,
  });

  final bool accent;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: true,
      label: label,
      child: SizedBox.square(
        dimension: 44,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Center(
              child: Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accent ? t.accentFill : t.accentTint,
                  shape: BoxShape.circle,
                ),
                child: TodayGlyphIcon(
                  TodayGlyph.plus,
                  size: 18,
                  color: accent ? t.onAccentFill : t.accentText,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Steps against the goal with the activity credit, then the next workout of
/// the selected plan. Without a step source the steps row is dropped rather
/// than claiming "0 / 8,000"; on Health Connect a missing source says so and
/// leads to the profile's connection settings.
class TodayActivityCard extends StatelessWidget {
  const TodayActivityCard({
    super.key,
    this.steps,
    required this.stepsGoal,
    required this.burnedKcal,
    this.healthConnectMissing = false,
    this.onReviewHealth,
    this.workout,
    this.onOpenTraining,
  });

  final int? steps;
  final int stepsGoal, burnedKcal;
  final bool healthConnectMissing;
  final VoidCallback? onReviewHealth;
  final TrainingNextWorkout? workout;
  final VoidCallback? onOpenTraining;

  /// Whether the card has anything to show at all.
  static bool hasContent({
    required int? steps,
    required bool healthConnectMissing,
    required TrainingNextWorkout? workout,
  }) => steps != null || healthConnectMissing || workout != null;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final count = steps;
    final top = count != null
        ? TodayStepsRow(steps: count, goal: stepsGoal, burnedKcal: burnedKcal)
        : healthConnectMissing
        ? _HealthMissingRow(onReview: onReviewHealth)
        : null;
    final next = workout;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.todayStatActivityLabel,
      child: Container(
        key: const ValueKey('today-activity-card'),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
        decoration: BoxDecoration(
          color: t.surf,
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(color: t.cardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ?top,
            if (next != null) ...<Widget>[
              if (top != null) ...<Widget>[
                const SizedBox(height: 14),
                Container(height: 1, color: t.line),
                const SizedBox(height: 14),
              ],
              _WorkoutRow(workout: next, onTap: onOpenTraining),
            ],
          ],
        ),
      ),
    );
  }
}

/// "1,392 / 8,000 steps", the credit in orange and a 6 px bar.
class TodayStepsRow extends StatelessWidget {
  const TodayStepsRow({
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
    final reached = target > 0 && count >= target;
    final progress = target <= 0 ? 0.0 : (count / target).clamp(0.0, 1.0);
    final value = Text(
      formatThousands(count, l10n.localeName),
      key: const ValueKey('today-steps-value'),
      style: AppType.display(
        20,
        weight: FontWeight.w700,
        color: t.ink,
        height: todayLineHeight,
      ),
    );
    final unit = Text(
      target > 0
          ? l10n.todayStepsOfGoal(formatThousands(target, l10n.localeName))
          : l10n.todayStepsNoGoal,
      key: const ValueKey('today-steps-goal'),
      style: AppType.ui(13, color: t.ink3, height: todayLineHeight),
    );
    final credit = burnedKcal > 0
        ? Text(
            '+${formatThousands(burnedKcal, l10n.localeName)} kcal',
            key: const ValueKey('today-steps-kcal'),
            style: AppType.ui(
              14,
              weight: FontWeight.w700,
              color: t.activityInk,
              height: todayLineHeight,
            ),
          )
        : null;
    final semanticValue = l10n.todaySemanticsStepsProgressValue(
      formatThousands(count, l10n.localeName),
      formatThousands(target, l10n.localeName),
    );
    return Row(
      key: const ValueKey('today-steps-card'),
      children: <Widget>[
        _GlyphTile(
          glyph: TodayGlyph.pulse,
          tint: t.activityTint,
          ink: t.activityInk,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              LayoutBuilder(
                builder: (context, constraints) {
                  final line = Wrap(
                    spacing: 4,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.end,
                    children: <Widget>[value, unit],
                  );
                  if (credit == null) return line;
                  final scaler = MediaQuery.textScalerOf(context);
                  double width(Text text) {
                    final painter = TextPainter(
                      text: TextSpan(text: text.data, style: text.style),
                      textDirection: TextDirection.ltr,
                      textScaler: scaler,
                      maxLines: 1,
                    )..layout();
                    final w = painter.width;
                    painter.dispose();
                    return w;
                  }

                  final side =
                      width(value) + 4 + width(unit) + 8 + width(credit) <=
                      constraints.maxWidth;
                  return side
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: <Widget>[
                            value,
                            const SizedBox(width: 4),
                            Expanded(child: unit),
                            const SizedBox(width: 8),
                            credit,
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            line,
                            const SizedBox(height: 2),
                            credit,
                          ],
                        );
                },
              ),
              const SizedBox(height: 8),
              Semantics(
                label: l10n.todaySemanticsStepsProgress,
                value: reached
                    ? '$semanticValue, ${l10n.todayStepsGoalReached}'
                    : semanticValue,
                child: ExcludeSemantics(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: progress),
                    duration: motionDuration(
                      context,
                      const Duration(milliseconds: 320),
                    ),
                    curve: Curves.easeOutCubic,
                    builder: (context, value, _) => ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        key: const ValueKey('today-steps-bar'),
                        value: value,
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(3),
                        backgroundColor: t.tile,
                        valueColor: AlwaysStoppedAnimation(t.activity),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HealthMissingRow extends StatelessWidget {
  const _HealthMissingRow({this.onReview});
  final VoidCallback? onReview;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Row(
      key: const ValueKey('today-health-connect-missing'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _GlyphTile(
          glyph: TodayGlyph.pulse,
          tint: t.activityTint,
          ink: t.activityInk,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                l10n.healthConnectMissingTitle,
                style: AppType.ui(
                  15,
                  weight: FontWeight.w700,
                  color: t.ink,
                  height: todayLineHeight,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                l10n.healthConnectMissingHint,
                style: AppType.ui(13, color: t.ink2, height: 1.35),
              ),
              if (onReview != null)
                TextButton(
                  onPressed: onReview,
                  child: Text(l10n.healthConnectReview),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The selected plan's next workout (a rotation, not a schedule), leading
/// to the Training tab.
class _WorkoutRow extends StatelessWidget {
  const _WorkoutRow({required this.workout, this.onTap});

  final TrainingNextWorkout workout;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final minutes = workout.estimatedMinutes;
    return MergeSemantics(
      child: Semantics(
        button: onTap != null,
        child: TodayTapTarget(
          key: const ValueKey('today-workout-row'),
          borderRadius: BorderRadius.circular(rControl),
          onTap: onTap,
          child: Row(
            children: <Widget>[
              _GlyphTile(
                glyph: TodayGlyph.dumbbell,
                tint: t.accentTintStrong,
                ink: t.accentText,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      workout.title,
                      key: const ValueKey('today-workout-title'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.ui(
                        15,
                        weight: FontWeight.w700,
                        color: t.ink,
                        height: todayLineHeight,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      workout.completedToday
                          ? l10n.todayWorkoutDone(minutes)
                          : l10n.todayWorkoutNext(minutes),
                      key: const ValueKey('today-workout-sub'),
                      style: AppType.ui(
                        13,
                        color: t.ink3,
                        height: todayLineHeight,
                      ),
                    ),
                  ],
                ),
              ),
              if (onTap != null) ...<Widget>[
                const SizedBox(width: 8),
                TodayGlyphIcon(TodayGlyph.chevron, size: 18, color: t.ink3),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The day is still loading: one spinner instead of a falsely empty meals
/// card. Same text as the Food tab's.
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
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: t.accent),
          ),
          const SizedBox(height: 10),
          Text(
            context.l10n.todayDayLoading,
            style: AppType.ui(
              12.5,
              weight: FontWeight.w600,
              color: t.ink2,
              height: todayLineHeight,
            ),
          ),
        ],
      ),
    );
  }
}
