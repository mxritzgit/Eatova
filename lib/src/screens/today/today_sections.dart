import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/day_nutrition.dart';
import '../../models/logged_meal.dart';
import '../../models/recipe_pick.dart';
import '../../models/training_insights.dart';
import '../../models/training_session.dart';
import '../../services/kcal_format.dart';
import '../../services/meal_totals.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../../widgets/common/lively.dart';
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
        child: PressScale(
          enabled: onTap != null,
          scale: kPressScaleCard,
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
      ),
    );
  }
}

/// "Meals" with the "Open food log" link to the Food tab, the shared
/// [EatovaTextAction] with its 48 px target.
///
/// The link's label ends flush with the cards; its press capsule reaches
/// into the gutter. With large text it moves under the heading, its label
/// flush with the heading's start.
class TodayMealsHeader extends StatelessWidget {
  const TodayMealsHeader({super.key, this.onOpenFoodLog});

  final VoidCallback? onOpenFoodLog;

  /// [EatovaTextAction]'s horizontal padding without a capsule.
  static const double _linkInset = 12;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final style = AppType.display(
      22,
      weight: FontWeight.w700,
      color: t.ink,
      letterSpacing: -0.22,
      height: todayLineHeight,
    );
    final heading = HeadingSemantics(
      level: 2,
      child: Text(l10n.todayMealsTitle, style: style),
    );
    final open = onOpenFoodLog;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (open == null) {
              return Align(alignment: Alignment.centerLeft, child: heading);
            }
            final link = EatovaTextAction(
              buttonKey: const ValueKey('today-open-food-log'),
              label: l10n.todayOpenFoodLog,
              onTap: open,
            );
            final scaler = MediaQuery.textScalerOf(context);
            final beside =
                _widthOf(l10n.todayMealsTitle, style, scaler) +
                    kSpace8 +
                    _widthOf(
                      l10n.todayOpenFoodLog,
                      AppType.ui(14, weight: FontWeight.w700),
                      scaler,
                    ) +
                    2 * _linkInset <=
                constraints.maxWidth;
            // Towards the end edge beside the heading, the start under it.
            final end = Directionality.of(context) == TextDirection.rtl
                ? -1.0
                : 1.0;
            if (beside) {
              return Row(
                children: <Widget>[
                  Expanded(child: heading),
                  const SizedBox(width: kSpace8),
                  Transform.translate(
                    offset: Offset(_linkInset * end, 0),
                    child: link,
                  ),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                heading,
                Transform.translate(
                  offset: Offset(-_linkInset * end, 0),
                  child: link,
                ),
              ],
            );
          },
        ),
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

/// The four slots in one card. A filled slot lists its items and kcal; an
/// empty one on today suggests a kcal band from the day's budget. Each slot's
/// add button opens the Food tab's add flow for THAT slot on the shown day;
/// the next open main meal's button is lit, the others are tinted.
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
    // The "+" disc sits as far from the edge as the tiles: its compact
    // target reaches past the disc by this much on either side.
    final margin = onAdd == null
        ? 0.0
        : (IconButtonSize.compact.target - IconButtonSize.compact.disc) / 2;
    return Container(
      key: const ValueKey('today-meals-card'),
      padding: EdgeInsets.fromLTRB(kCardInset, 0, kCardInset - margin, 0),
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: t.cardBorder),
      ),
      child: Column(
        children: <Widget>[
          for (var i = 0; i < slots.length; i++) ...<Widget>[
            // Hairlines start at the text column, as in a ListSection.
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: IconBadgeSize.lg.edge + kRowLeadingGap,
                endIndent: margin,
                color: t.line,
              ),
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
    final range = summary.suggestedKcalRange(
      slot.slot,
      emptySlots: [
        for (final s in slots)
          if (s.isEmpty) s.slot,
      ],
    );
    // Budget (almost) used up: no band that would push the day over.
    if (range == null) return l10n.todaySlotNothingLogged;
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
    final kcalStyle = AppType.ui(
      14,
      weight: FontWeight.w700,
      color: t.inkMuted,
      height: todayLineHeight,
      tabular: true,
    );
    final kcalText = '${kcalThousands(slot.kcal, l10n)} kcal';
    final kcal = slot.isEmpty
        ? null
        : CountingText(
            value: slot.kcal.toDouble(),
            format: (v) => '${kcalThousands(v.round(), l10n)} kcal',
            textKey: ValueKey<String>('today-meal-kcal-$name'),
            maxLines: 1,
            style: kcalStyle,
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
      // 44 px tile + 2 x 12: the 68 px of a list row with a badge.
      padding: const EdgeInsets.symmetric(vertical: kSpace12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Tile, add button and gaps are fixed; the kcal moves under the
          // subtitle when the name would otherwise get less than ~72 px.
          final fixed =
              44 +
              kRowLeadingGap +
              (onAdd == null ? 0 : 12 + IconButtonSize.compact.target);
          final kcalWidth = kcal == null
              ? 0.0
              : _widthOf(kcalText, kcalStyle, context) + 12;
          final inline = constraints.maxWidth - fixed - kcalWidth >= 72;
          return Row(
            children: <Widget>[
              SlotIconTile(slot: slot.slot),
              const SizedBox(width: kRowLeadingGap),
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
                // The next open main meal's "+" is the page's lit action.
                AppIconButton(
                  key: ValueKey<String>('today-meal-add-$name'),
                  semanticLabel: l10n.foodSlotAddLabel(slot.slot.label(l10n)),
                  onTap: onAdd,
                  tone: accent ? IconButtonTone.primary : IconButtonTone.accent,
                  size: IconButtonSize.compact,
                  child: const TodayGlyphIcon(TodayGlyph.plus),
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

/// Steps against the goal with the activity credit, then the next workout of
/// the selected plan, or the saved workout while one is in progress. Without
/// a step source the steps row is dropped rather than claiming "0 / 8,000";
/// on Health Connect a missing source says so and leads to the profile's
/// connection settings.
class TodayActivityCard extends StatelessWidget {
  const TodayActivityCard({
    super.key,
    this.steps,
    required this.stepsGoal,
    required this.burnedKcal,
    this.healthConnectMissing = false,
    this.onReviewHealth,
    this.workout,
    this.activeSession,
    this.onOpenTraining,
    this.onResumeWorkout,
  });

  final int? steps;
  final int stepsGoal, burnedKcal;
  final bool healthConnectMissing;
  final VoidCallback? onReviewHealth;
  final TrainingNextWorkout? workout;

  /// A saved workout checkpoint: the row shows it in place of [workout].
  final TrainingSessionSnapshot? activeSession;
  final VoidCallback? onOpenTraining;
  final VoidCallback? onResumeWorkout;

  /// Whether the card has anything to show at all.
  static bool hasContent({
    required int? steps,
    required bool healthConnectMissing,
    required TrainingNextWorkout? workout,
    TrainingSessionSnapshot? activeSession,
  }) =>
      steps != null ||
      healthConnectMissing ||
      workout != null ||
      activeSession != null;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final count = steps;
    final Widget? top = count != null
        ? TodayStepsRow(steps: count, goal: stepsGoal, burnedKcal: burnedKcal)
        : healthConnectMissing
        ? _HealthMissingRow(onReview: onReviewHealth)
        : null;
    final session = activeSession;
    final next = workout;
    final row = session != null
        ? _WorkoutRow(
            title: session.workout.title,
            subtitle: l10n.todayWorkoutInProgress,
            onTap: onResumeWorkout,
          )
        : next != null
        ? _WorkoutRow(
            title: next.title,
            subtitle: next.completedToday
                ? l10n.todayWorkoutDone(next.estimatedMinutes)
                : l10n.todayWorkoutNext(next.estimatedMinutes),
            onTap: onOpenTraining,
          )
        : null;
    // A list card: rows with the list row's insets, the hairline at the
    // text column.
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.todayStatActivityLabel,
      child: Material(
        key: const ValueKey('today-activity-card'),
        color: t.surf,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rCard),
          side: BorderSide(color: t.cardBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (top != null) _ActivityRowPadding(child: top),
            if (row != null) ...<Widget>[
              if (top != null)
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: listRowStacked(context)
                      ? kCardInset
                      : ListDividerInset.textLg.indent,
                  endIndent: kCardInset,
                  color: t.line,
                ),
              row,
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
              tabular: true,
            ),
          )
        : null;
    final semanticValue = l10n.todaySemanticsStepsProgressValue(
      formatThousands(count, l10n.localeName),
      formatThousands(target, l10n.localeName),
    );
    return _ActivityLead(
      key: const ValueKey('today-steps-card'),
      badge: _ActivityBadge(glyph: TodayGlyph.pulse, color: t.activity),
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
                duration: motionDuration(context, kMotionValue),
                curve: kMotionCurve,
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
    );
  }
}

/// A row's badge and its content side by side; from about 1.6x text the
/// badge stands above the content, which keeps the full width, as in a
/// [ListRow] ([listRowStacked]). [trailing] (a chevron) ends the badge's
/// line then.
class _ActivityLead extends StatelessWidget {
  const _ActivityLead({
    super.key,
    required this.badge,
    required this.child,
    this.trailing,
    this.alignTop = false,
  });

  final Widget badge, child;
  final Widget? trailing;

  /// The badge at the content's top rather than its centre.
  final bool alignTop;

  @override
  Widget build(BuildContext context) {
    if (listRowStacked(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(children: <Widget>[badge, const Spacer(), ?trailing]),
          const SizedBox(height: 10),
          child,
        ],
      );
    }
    return Row(
      crossAxisAlignment: alignTop
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: <Widget>[
        badge,
        const SizedBox(width: kRowLeadingGap),
        Expanded(child: child),
        if (trailing case final trailing?) ...<Widget>[
          const SizedBox(width: 6),
          trailing,
        ],
      ],
    );
  }
}

/// The activity card's insets: a list row's 18 px sides and 14 px rhythm.
class _ActivityRowPadding extends StatelessWidget {
  const _ActivityRowPadding({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: kCardInset, vertical: 14),
    child: child,
  );
}

/// A Today line glyph on a large badge: tinted by [color], or the accent.
class _ActivityBadge extends StatelessWidget {
  const _ActivityBadge({required this.glyph, this.color});

  final TodayGlyph glyph;
  final Color? color;

  @override
  Widget build(BuildContext context) => IconBadge(
    size: IconBadgeSize.lg,
    tone: IconBadgeTone.accent,
    color: color,
    child: TodayGlyphIcon(glyph),
  );
}

class _HealthMissingRow extends StatelessWidget {
  const _HealthMissingRow({this.onReview});
  final VoidCallback? onReview;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return _ActivityLead(
      key: const ValueKey('today-health-connect-missing'),
      alignTop: true,
      badge: _ActivityBadge(glyph: TodayGlyph.pulse, color: t.activity),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(l10n.healthConnectMissingTitle, style: AppType.rowTitle(t.ink)),
          const SizedBox(height: 3),
          Text(l10n.healthConnectMissingHint, style: AppType.subhead(t.ink2)),
          if (onReview != null) ...<Widget>[
            const SizedBox(height: kSpace12),
            SoftPillButton(label: l10n.healthConnectReview, onTap: onReview),
          ],
        ],
      ),
    );
  }
}

/// The selected plan's next workout (a rotation, not a schedule), leading
/// to the Training tab, or the workout in progress, resuming it. A list
/// row: the whole width presses, the chevron only when it leads somewhere.
class _WorkoutRow extends StatelessWidget {
  const _WorkoutRow({required this.title, required this.subtitle, this.onTap});

  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return MergeSemantics(
      child: Semantics(
        button: onTap != null,
        child: TodayTapTarget(
          key: const ValueKey('today-workout-row'),
          onTap: onTap,
          child: _ActivityRowPadding(
            child: _ActivityLead(
              badge: const _ActivityBadge(glyph: TodayGlyph.dumbbell),
              trailing: onTap == null
                  ? null
                  : ExcludeSemantics(
                      child: Icon(
                        AppIcons.chevronRight,
                        size: AppIconSize.standard,
                        color: t.ink3,
                      ),
                    ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    key: const ValueKey('today-workout-title'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.rowTitle(t.ink),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    key: const ValueKey('today-workout-sub'),
                    // The meal rows' subtitle tone on the same page.
                    style: AppType.subhead(t.ink3),
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

/// The day is still loading: the meals card's four slot rows as silhouettes
/// instead of a falsely empty card. Same spoken label as the Food tab's.
class TodayDayLoadingCard extends StatelessWidget {
  const TodayDayLoadingCard({super.key});

  @override
  Widget build(BuildContext context) => SkeletonCard(
    key: const ValueKey('today-day-loading'),
    rows: 4,
    tileSize: 44,
    tileRadius: rControl,
    semanticLabel: context.l10n.todayDayLoading,
  );
}
