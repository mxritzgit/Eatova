import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/day_nutrition.dart';
import '../../models/lifetime_stats.dart';
import '../../models/logged_meal.dart';
import '../../models/macro_progress.dart';
import '../../models/recipe_pick.dart';
import '../../models/training_insights.dart';
import '../../models/user_profile.dart';
import '../../services/day_math.dart';
import '../../services/meal_totals.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import 'today_day_strip.dart';
import 'today_glyphs.dart';
import 'today_hero.dart';
import 'today_macros.dart';
import 'today_sections.dart';
import 'today_texts.dart';

/// The day dashboard tab (dark redesign, 2026-09-28): header with streak and
/// profile, the 7-day strip, the calorie card, macro tiles, the recipe pick,
/// the four meal slots and the activity card.
///
/// Pure display widget: data in as parameters, actions out as callbacks. It
/// knows neither store nor sync, so it can be pumped without a backend and
/// the shell keeps control over tabs and routes. The numbers follow
/// [DayNutritionSummary], the rule every tab shares.
class TodayScreen extends StatelessWidget {
  const TodayScreen({
    super.key,
    required this.userName,
    required this.profile,
    required this.consumedKcal,
    required this.burnedKcal,
    required this.macroProgress,
    required this.meals,
    required this.selectedDate,
    required this.streak,
    this.steps,
    this.healthConnect = false,
    this.profileInitial,
    this.dayLoading = false,
    this.pick,
    this.nextWorkout,
    this.onDateSelected,
    this.onOpenProfile,
    this.onOpenMealSlot,
    this.onOpenRecipe,
    this.onOpenMealPlan,
    this.onOpenFoodLog,
    this.onOpenTraining,
  });

  final String userName;
  final UserProfile profile;

  /// Calories eaten on [selectedDate].
  final int consumedKcal;

  /// Activity credit estimated from steps; no Activity stat without one.
  final int burnedKcal;

  final MacroProgress macroProgress;

  /// Step count for [selectedDate]; `null` means no step source, and the
  /// steps row is dropped rather than claiming zero. Goal comes from profile.
  final int? steps;
  final bool healthConnect;

  /// Only the meals of [selectedDate].
  final List<LoggedMeal> meals;

  final DateTime selectedDate;

  /// Already resolved via [LifetimeStats.effectiveStreakOn]: a broken chain
  /// arrives as 0 and hides the pill.
  final int streak;

  final String? profileInitial;
  final bool dayLoading;

  /// Today's recipe for the next open main meal; shown on today only.
  final RecipePick? pick;

  /// The selected plan's next workout; shown on today only.
  final TrainingNextWorkout? nextWorkout;

  final ValueChanged<DateTime>? onDateSelected;

  /// The avatar and the streak pill. The profile page also holds the
  /// settings entry the old header carried.
  final VoidCallback? onOpenProfile;

  /// A slot's add button: the Food tab's add flow for that slot and day.
  final ValueChanged<MealSlot>? onOpenMealSlot;

  /// A suggested pick opens its recipe detail (add = one serving, chosen
  /// slot).
  final ValueChanged<RecipePick>? onOpenRecipe;

  /// A planned pick opens the meal plan: only its "eat" action logs through
  /// `HomeStore.eatPlannedMeal` (planned servings, entry marked eaten). The
  /// recipe detail's generic add would log one serving, leave the entry open
  /// and later duplicate the diary row.
  final VoidCallback? onOpenMealPlan;
  final VoidCallback? onOpenFoodLog;
  final VoidCallback? onOpenTraining;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    // Exactly one clock read per build, or heading, strip and next slot could
    // land on opposite sides of midnight.
    final jetzt = clock.now();
    final heute = startOfDay(jetzt);
    final istHeute = daysBetween(heute, selectedDate) == 0;

    final summary = DayNutritionSummary(
      profile: profile,
      burnedKcal: burnedKcal,
      consumed: MacroProgress(
        proteinG: macroProgress.proteinG,
        carbsG: macroProgress.carbsG,
        fatG: macroProgress.fatG,
        kcal: consumedKcal,
      ),
    );
    final slots = mealSlotSummariesForFoodDate(meals, selectedDate);
    // The accent add button marks the slot the recipe pick serves: the same
    // rule (nextOpenMainMealSlot) on the same meals and clock.
    final nextSlot = istHeute && !dayLoading
        ? nextOpenMainMealSlot(now: jetzt, todaysMeals: meals)
        : null;
    final shownPick = istHeute && !dayLoading ? pick : null;
    final workout = istHeute ? nextWorkout : null;
    final healthMissing = steps == null && healthConnect;
    final showActivity =
        !dayLoading &&
        TodayActivityCard.hasContent(
          steps: steps,
          healthConnectMissing: healthMissing,
          workout: workout,
        );

    // No SafeArea and no side padding: the shell supplies both. The page runs
    // under the floating tab bar and pads its end by the bar's band (plus the
    // design's clearance), so the last card can scroll clear of the glass.
    final navInset = MediaQuery.paddingOf(context).bottom;
    return SingleChildScrollView(
      key: const ValueKey('screen-today'),
      // Unclipped: the selected day's glow reaches into the shell's side
      // gutter as in the design; the tab stack still clips at the screen.
      clipBehavior: Clip.none,
      // Top 3: the shell's 12 plus 3 put the header 62 px below the screen
      // top on the design's phone, as in the reference.
      padding: EdgeInsets.only(top: 3, bottom: navInset + 68),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _TodayHeader(
            dateLine: todayHeaderDate(selectedDate, heute, l10n),
            dateSemantics: todayDateLabel(heute, selectedDate, l10n),
            title: l10n.navToday,
            streak: streak,
            initial: profileInitial ?? todayInitial(userName),
            onOpenProfile: onOpenProfile,
          ),
          const SizedBox(height: 16),
          TodayDayStrip(
            selectedDate: selectedDate,
            today: heute,
            onSelected: onDateSelected,
          ),
          const SizedBox(height: 16),
          // While an archive day loads its numbers are still zero; the one
          // loading card under the heading carries that state instead.
          if (!dayLoading) ...<Widget>[
            TodayCalorieCard(summary: summary, isToday: istHeute),
            const SizedBox(height: 16),
            TodayMacros(summary: summary),
            if (shownPick != null) ...<Widget>[
              const SizedBox(height: 16),
              TodayPickRow(pick: shownPick, onTap: _pickAction(shownPick)),
            ],
          ],
          const SizedBox(height: 16),
          TodayMealsHeader(onOpenFoodLog: onOpenFoodLog),
          if (dayLoading)
            const TodayDayLoadingCard()
          else
            TodayMealsCard(
              slots: slots,
              summary: summary,
              isToday: istHeute,
              accentSlot: nextSlot,
              onAdd: onOpenMealSlot,
            ),
          if (showActivity) ...<Widget>[
            const SizedBox(height: 16),
            TodayActivityCard(
              steps: steps,
              stepsGoal: profile.dailyStepsGoal,
              burnedKcal: burnedKcal,
              healthConnectMissing: healthMissing,
              onReviewHealth: onOpenProfile,
              workout: workout,
              onOpenTraining: onOpenTraining,
            ),
          ],
        ],
      ),
    );
  }

  /// Where the pick row leads; see [onOpenRecipe] and [onOpenMealPlan].
  /// Lives here until the Food tab's shared pick actions are merged.
  VoidCallback? _pickAction(RecipePick pick) {
    if (pick.source == RecipePickSource.planned) return onOpenMealPlan;
    final open = onOpenRecipe;
    return open == null ? null : () => open(pick);
  }
}

/// Date line and title on the left; streak pill and profile avatar on the
/// right, both 44 px high.
class _TodayHeader extends StatelessWidget {
  const _TodayHeader({
    required this.dateLine,
    required this.dateSemantics,
    required this.title,
    required this.streak,
    required this.initial,
    this.onOpenProfile,
  });

  final String dateLine, dateSemantics, title, initial;
  final int streak;
  final VoidCallback? onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Semantics(
                container: true,
                label: dateSemantics,
                child: Text(
                  dateLine,
                  key: const ValueKey('today-date-selected-label'),
                  style: AppType.ui(
                    14,
                    weight: FontWeight.w600,
                    color: t.ink2,
                    height: todayLineHeight,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              HeadingSemantics(
                level: 1,
                child: Text(
                  title,
                  style: AppType.pageTitle(t.ink),
                  textScaler: AppType.pageTitleScaler(context),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        if (streak > 0) ...<Widget>[
          _StreakPill(streak: streak, onTap: onOpenProfile),
          const SizedBox(width: 8),
        ],
        _ProfileAvatar(initial: initial, onTap: onOpenProfile),
      ],
    );
  }
}

/// Flame and count on the activity tint. Opens the profile, where the
/// streak and the record live.
class _StreakPill extends StatelessWidget {
  const _StreakPill({required this.streak, this.onTap});
  final int streak;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: onTap != null,
      label: context.l10n.todayStreakSemantics(streak),
      child: Material(
        color: t.activityTint,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('today-streak'),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: ExcludeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TodayGlyphIcon(
                      TodayGlyph.flame,
                      size: 18,
                      color: t.activityInk,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '$streak',
                      key: const ValueKey('today-streak-count'),
                      style: AppType.ui(
                        15,
                        weight: FontWeight.w800,
                        color: t.activityInk,
                        height: todayLineHeight,
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

/// The initial in a 44 px circle with an accent ring: profile and settings.
class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.initial, this.onTap});
  final String initial;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final shape = CircleBorder(
      side: BorderSide(color: t.accent.withValues(alpha: 0.45), width: 1.5),
    );
    return Semantics(
      button: true,
      label: context.l10n.todayProfileAndSettings,
      child: Material(
        color: t.surf2,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('today-profile'),
          customBorder: shape,
          onTap: onTap,
          child: SizedBox.square(
            dimension: 44,
            child: Center(
              // FittedBox like MealAvatar: fixed circle, the letter grows
              // with the system font until it fills it.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  initial,
                  style: AppType.ui(
                    16,
                    weight: FontWeight.w800,
                    color: t.inkSoft,
                    height: todayLineHeight,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
