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
import 'today_macros.dart';
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
    this.healthConnect = false,
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

  /// Estimated from steps. No activity line is shown for an absent credit.
  final int burnedKcal;

  final MacroProgress macroProgress;

  /// Step count for [selectedDate]; `null` means no step source, and the
  /// steps card is dropped rather than claiming zero. Goal comes from profile.
  final int? steps;
  final bool healthConnect;

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

  /// Slot rows and the fixed add action lead into the food tab.
  final ValueChanged<MealSlot>? onOpenMealSlot;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;

    // Exactly one clock read per build, or heading and day strip could land
    // on opposite sides of midnight.
    final jetzt = clock.now();
    final heute = startOfDay(jetzt);
    final istHeute = daysBetween(heute, selectedDate) == 0;

    final restProtein = (profile.proteinGoalG - macroProgress.proteinG)
        .round()
        .clamp(0, 99999);
    final schritte = steps;

    // No SafeArea and no horizontal padding here: the shell supplies both,
    // a second padding would double the margin. The bottom 12 only keeps the
    // last card off the navigation bar.
    final content = ListView(
      key: const ValueKey('screen-today'),
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
      children: <Widget>[
        _Kopfzeile(
          title: l10n.navToday,
          initial: profileInitial ?? todayInitial(userName),
          onOpenProfile: onOpenProfile,
        ),
        const SizedBox(height: 2),
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
            isToday: istHeute,
          ),
          const SizedBox(height: 10),
          TodayMacros(progress: macroProgress, profile: profile),
          if (schritte != null) ...<Widget>[
            const SizedBox(height: 14),
            TodayStepsCard(
              steps: schritte,
              goal: profile.dailyStepsGoal,
              burnedKcal: burnedKcal,
            ),
          ] else if (healthConnect) ...<Widget>[
            const SizedBox(height: 14),
            AppCard(
              key: const ValueKey('today-health-connect-missing'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.healthConnectMissingTitle,
                    style: AppType.display(
                      17,
                      weight: FontWeight.w700,
                      color: t.ink,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.healthConnectMissingHint,
                    style: AppType.ui(12, color: t.ink2, height: 1.4),
                  ),
                  if (onOpenProfile != null)
                    TextButton(
                      onPressed: onOpenProfile,
                      child: Text(l10n.healthConnectReview),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
        ],
        // Archive days need a different title. No `trailing`: it would look
        // like a link but be dead, and the slot rows already lead to the
        // food tab.
        SectionHeading(
          title: istHeute
              ? l10n.todayMealsTitleToday
              : l10n.todayMealsTitleArchive,
        ),
        const SizedBox(height: 8),
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
    return Column(
      children: [
        Expanded(child: content),
        if (onOpenMealSlot != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FilledButton.icon(
              key: const ValueKey('today-add-meal'),
              onPressed: dayLoading
                  ? null
                  : () => onOpenMealSlot!(currentMealSlot()),
              style: FilledButton.styleFrom(
                backgroundColor: t.brandSurface,
                foregroundColor: t.onBrandSurface,
                minimumSize: const Size(double.infinity, kPrimaryButtonHeight),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(rPill),
                ),
              ),
              icon: const Icon(Icons.add_circle_rounded, size: 23),
              label: Text(l10n.todayAddMeal),
            ),
          ),
      ],
    );
  }
}

class _Kopfzeile extends StatelessWidget {
  const _Kopfzeile({
    required this.title,
    required this.initial,
    this.onOpenProfile,
  });

  final String title;
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
              HeadingSemantics(
                level: 1,
                child: Text(
                  title,
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
          child: Material(
            color: t.brandSurface,
            borderRadius: BorderRadius.circular(rPill),
            child: InkWell(
              key: const ValueKey('today-profile'),
              borderRadius: BorderRadius.circular(rPill),
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
                        color: t.onBrandSurface,
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
