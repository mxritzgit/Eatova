import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/lifetime_stats.dart';
import '../../models/logged_meal.dart';
import '../../models/macro_progress.dart';
import '../../models/user_profile.dart';
import '../../services/day_math.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import 'today_day_strip.dart';
import 'today_hero.dart';
import 'today_sections.dart';
import 'today_texts.dart';

/// The day dashboard tab.
///
/// Pure display widget: data in as parameters, actions out as callbacks. It
/// knows neither store nor sync, so it can be pumped without a backend and
/// the shell keeps control over tabs and routes. It answers "where do I
/// stand?"; the food tab owns editing meals.
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
    this.profileInitial,
    this.dayLoading = false,
    this.onDateSelected,
    this.onOpenCoach,
    this.onOpenProfile,
    this.onOpenMealSlot,
  });

  final String userName;
  final UserProfile profile;

  /// Calories eaten on [selectedDate].
  final int consumedKcal;

  /// Estimated from steps. The shell passes 0 for past days, and the tile
  /// then shows a dash instead of claiming zero.
  final int burnedKcal;

  final MacroProgress macroProgress;

  /// Step count for [selectedDate]; `null` means no step source, and the
  /// steps card is dropped rather than claiming zero. Goal comes from profile.
  final int? steps;

  /// Only the meals of [selectedDate].
  final List<LoggedMeal> meals;

  final DateTime selectedDate;

  /// Already resolved via [LifetimeStats.effectiveStreakOn]: a broken chain
  /// arrives as 0.
  final int streak;

  final String? profileInitial;
  final bool dayLoading;

  final ValueChanged<DateTime>? onDateSelected;
  final VoidCallback? onOpenCoach;
  final VoidCallback? onOpenProfile;

  /// The only way to log: a slot row leads into the food tab.
  final ValueChanged<MealSlot>? onOpenMealSlot;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;

    // Exactly one clock read per build, or greeting and day strip could land
    // on opposite sides of midnight.
    final jetzt = clock.now();
    final heute = startOfDay(jetzt);
    final istHeute = daysBetween(heute, selectedDate) == 0;

    final restProtein =
        (profile.proteinGoalG - macroProgress.proteinG).round().clamp(0, 99999);
    final schritte = steps;

    // No SafeArea and no horizontal padding here: the shell supplies both,
    // a second padding would double the margin. The bottom 12 only keeps the
    // last card off the navigation bar.
    return ListView(
      key: const ValueKey('screen-today'),
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
      children: <Widget>[
        _Kopfzeile(
          // Eyebrow follows the selected day (else it contradicts the day
          // strip below); the greeting follows the wall clock.
          eyebrow: todayEyebrow(selectedDate, l10n),
          greeting: todayGreeting(l10n, jetzt),
          initial: profileInitial ?? todayInitial(userName),
          onOpenProfile: onOpenProfile,
        ),
        const SizedBox(height: 16),
        TodayDayStrip(
          selectedDate: selectedDate,
          today: heute,
          onSelected: onDateSelected,
        ),
        const SizedBox(height: 14),
        // Hero and macros share the loading state of the meals card below:
        // while an archive day loads, both values are still zero and would
        // assert numbers that do not exist yet. The single loading card under
        // the heading carries that state.
        if (!dayLoading) ...<Widget>[
          TodayCalorieHero(
            consumedKcal: consumedKcal,
            burnedKcal: burnedKcal,
            kcalGoal: profile.dailyKcalGoal,
            streak: streak,
          ),
          // Steps sit right under the hero: they are the math behind the
          // burned tile. Without a step source the card is dropped, see
          // [steps].
          if (schritte != null) ...<Widget>[
            const SizedBox(height: 14),
            TodayStepsCard(
              steps: schritte,
              goal: profile.dailyStepsGoal,
              burnedKcal: burnedKcal,
            ),
          ],
          const SizedBox(height: 14),
          AppCard(
            key: const ValueKey('today-macros-card'),
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SectionHeading(
                  title: l10n.todayMacrosTitle,
                  trailing: l10n.todayMacrosTrailing,
                ),
                const SizedBox(height: 14),
                MacroBar(
                  label: l10n.todayMacroProtein,
                  value: macroProgress.proteinG.round(),
                  goal: profile.proteinGoalG,
                  unit: 'g',
                  color: t.protein,
                ),
                MacroBar(
                  label: l10n.todayMacroCarbs,
                  value: macroProgress.carbsG.round(),
                  goal: profile.carbsGoalG,
                  unit: 'g',
                  color: t.carbs,
                ),
                MacroBar(
                  label: l10n.todayMacroFat,
                  value: macroProgress.fatG.round(),
                  goal: profile.fatGoalG,
                  unit: 'g',
                  color: t.fat,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
        // Archive days need a different title. No `trailing`: it would look
        // like a link but be dead, and the slot rows already lead to the
        // food tab.
        SectionHeading(
          title: istHeute
              ? l10n.todayMealsTitleToday
              : l10n.todayMealsTitleArchive,
        ),
        const SizedBox(height: 12),
        if (dayLoading)
          const TodayDayLoadingCard()
        else
          TodayMealsCard(meals: meals, onOpenSlot: onOpenMealSlot),
        const SizedBox(height: 14),
        TodayCoachBanner(
          teaser: coachTeaser(
            // While the day loads `meals` is empty without the day being
            // empty, so the teaser must not claim it is.
            dayIsEmpty: !dayLoading && meals.isEmpty,
            remainingProteinG: restProtein,
            l10n: l10n,
            isToday: istHeute,
          ),
          onTap: onOpenCoach,
        ),
      ],
    );
  }
}

class _Kopfzeile extends StatelessWidget {
  const _Kopfzeile({
    required this.eyebrow,
    required this.greeting,
    required this.initial,
    this.onOpenProfile,
  });

  final String eyebrow;
  final String greeting;
  final String initial;
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
              Text(
                eyebrow,
                key: const ValueKey('today-eyebrow'),
                style: AppType.eyebrow(t.ink2, size: 10.5),
              ),
              const SizedBox(height: 3),
              // The tab's only rank-1 mark (P9-06c); the two SectionHeadings
              // below are rank 2. The annotation sits on the greeting alone:
              // this row is the first child of a ListView, whose
              // IndexedSemantics merges compatible siblings into ONE node —
              // without a node of its own the mark would read the eyebrow
              // ("SUNDAY, 9 AUGUST 2026") and the profile tile too.
              HeadingSemantics(
                level: 1,
                child: Text(
                  greeting,
                  style: AppType.display(30, color: t.ink, height: 1.1),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Semantics(
          button: true,
          label: context.l10n.todaySemanticsOpenProfile,
          // 14 instead of rControl (15): the design spec names 14 for this
          // 44 px tile, and the spec wins per contract §3.
          child: Material(
            color: t.forest,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              key: const ValueKey('today-profile'),
              borderRadius: BorderRadius.circular(14),
              onTap: onOpenProfile,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Center(
                  // FittedBox like MealAvatar: fixed tile, letter grows with
                  // the system font.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      initial,
                      style: AppType.ui(
                        14,
                        weight: FontWeight.w700,
                        color: t.lime,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
