import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/day_nutrition.dart';
import '../../models/lifetime_stats.dart';
import '../../models/logged_meal.dart';
import '../../models/recipe_pick.dart';
import '../../models/reminder_time.dart';
import '../../models/training_insights.dart';
import '../../models/training_session.dart';
import '../../models/user_profile.dart';
import '../../services/day_math.dart';
import '../../services/energy_check.dart';
import '../../services/meal_totals.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/lively.dart';
import '../../widgets/common/persistence_action.dart';
import '../../widgets/design/design.dart';
import '../../widgets/profile/profile_widgets.dart'
    show WeighInActions, showWeightEntrySheet;
import 'today_day_strip.dart';
import 'today_energy_check.dart';
import 'today_glyphs.dart';
import 'today_health_prompt.dart';
import 'today_hero.dart';
import 'today_macros.dart';
import 'today_reminder_prompt.dart';
import 'today_sections.dart';
import 'today_streak_hint.dart';
import 'today_target_reached.dart';
import 'today_texts.dart';
import 'today_trends.dart';
import 'today_weekly_check.dart';
import 'today_weigh.dart';

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
    required this.summary,
    required this.meals,
    required this.selectedDate,
    required this.streak,
    this.steps,
    this.healthConnect = false,
    this.healthConnectLinked = false,
    this.profileInitial,
    this.dayLoading = false,
    this.pick,
    this.nextWorkout,
    this.activeSession,
    this.accentSlot,
    this.onDateSelected,
    this.onOpenProfile,
    this.onOpenMealSlot,
    this.onOpenPick,
    this.onOpenFoodLog,
    this.onOpenTraining,
    this.onResumeWorkout,
    this.energyCheck,
    this.onAcceptEnergyCheck,
    this.onDismissEnergyCheck,
    this.reminderPrompt,
    this.onAcceptReminderPrompt,
    this.onDismissReminderPrompt,
    this.onChangeReminderTime,
    this.energyCheckProgress,
    this.latestWeightKg,
    this.onLogWeight,
    this.weighIns,
    this.healthPrompt,
    this.weightImportPrompt,
    this.trendsPreview,
    this.onOpenTrends,
    this.isCompleteDay,
    this.onFillYesterday,
    this.energyCheckResult,
    this.onAskCoachAboutCheck,
    this.targetReached,
  });

  final String userName;
  final UserProfile profile;

  /// The store's day numbers for [selectedDate]
  /// (`HomeStore.nutritionSummaryForFoodDate`): budget = goal + activity
  /// credit, eaten, macros. No Activity stat without a credit.
  final DayNutritionSummary summary;

  /// Step count for [selectedDate]; `null` means no step source, and the
  /// steps row is dropped rather than claiming zero. Goal comes from profile.
  final int? steps;

  /// The step source is Health Connect (Android), not Apple Health.
  final bool healthConnect;

  /// This account connected Health Connect (`HomeStore.healthConnectLinked`):
  /// only then does a day without steps say so. Accounts that never
  /// connected or declined see the intro card or nothing.
  final bool healthConnectLinked;

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

  /// The saved workout checkpoint (`HomeStore.trainingSession`): while it
  /// exists the workout row names its workout as in progress and taps
  /// [onResumeWorkout] instead. Today only.
  final TrainingSessionSnapshot? activeSession;

  /// Today's next open main meal (`HomeStore.nextOpenMainSlot`, the rule
  /// behind [pick]); its add button is accent-filled. Ignored on archive
  /// days and while a day loads.
  final MealSlot? accentSlot;

  final ValueChanged<DateTime>? onDateSelected;

  /// The avatar and the streak pill. The profile page also holds the
  /// settings entry the old header carried.
  final VoidCallback? onOpenProfile;

  /// A slot's add button: the Food tab's add flow for that slot and day.
  final ValueChanged<MealSlot>? onOpenMealSlot;

  /// The pick row. The shell routes it through the shared
  /// `openRecipePick`: a suggestion opens its recipe detail, a planned meal
  /// the meal plan, whose "eat" is `HomeStore.eatPlannedMeal`.
  final ValueChanged<RecipePick>? onOpenPick;
  final VoidCallback? onOpenFoodLog;
  final VoidCallback? onOpenTraining;
  final VoidCallback? onResumeWorkout;

  /// The weekly energy check's proposal (docs/WEIGHT-TREND.md); shown on
  /// today only, under the day's numbers it would change.
  final EnergyCheckProposal? energyCheck;
  final Future<void> Function()? onAcceptEnergyCheck;
  final Future<void> Function()? onDismissEnergyCheck;

  /// The one-time reminder offer at this time (C4); null hides it. Today only,
  /// under the meals it is about.
  final ReminderTime? reminderPrompt;
  final Future<void> Function()? onAcceptReminderPrompt;
  final Future<void> Function()? onDismissReminderPrompt;
  final ValueChanged<ReminderTime>? onChangeReminderTime;

  /// How far the weekly check is from an estimate
  /// (`HomeStore.energyCheckProgress`); its line shows on today only, and
  /// not next to a proposal.
  final EnergyCheckProgress? energyCheckProgress;

  /// The latest weigh-in for the weight chip; null shows "Log weight".
  final double? latestWeightKg;

  /// Saves a weigh-in from the chip's sheet, the profile's entry path
  /// (`showWeightEntrySheet`). Null hides the chip; today only.
  final PersistValueChanged<double>? onLogWeight;

  /// The weigh-in sheet's date row and history link; null keeps "log now".
  final WeighInActions? weighIns;

  /// The health intro card, Apple Health or Health Connect after
  /// [healthConnect] (`HomeStore.healthIntroVisible`); null hides it. Today
  /// only.
  final ({Future<void> Function() connect, Future<void> Function() dismiss})?
  healthPrompt;

  /// The scale import's one-time question
  /// (`HomeStore.healthWeightImportOfferVisible`); null hides it. Today only.
  final ({Future<void> Function() accept, Future<void> Function() dismiss})?
  weightImportPrompt;

  /// The last seven completed days for the trends card; null hides it
  /// (archive days). Today only, at the end of the page.
  final TodayTrendsPreview? trendsPreview;
  final VoidCallback? onOpenTrends;

  /// Whether a day passes the complete-day rule
  /// (`HomeStore.isCompleteFoodDay`); the day strip marks those days. Null
  /// shows no markers.
  final bool Function(DateTime day)? isCompleteDay;

  /// Opens the add flow on yesterday; non-null only while yesterday is empty
  /// and an entry for it would save the streak
  /// (`HomeStore.yesterdayRescuesStreak`). Today only.
  final VoidCallback? onFillYesterday;

  /// The week's result when the check estimates without a proposal
  /// (`HomeStore.energyCheckResult`, once a week); today only, and never
  /// beside the proposal card, which speaks for the check then.
  final EnergyCheckEstimate? energyCheckResult;

  /// "Ask the coach" on the result card: a prepared question in the Coach's
  /// composer, unsent (2026-10-22). Null hides it.
  final VoidCallback? onAskCoachAboutCheck;

  /// The reached target's question (`HomeStore.targetReachedPrompt`):
  /// hold, or a new goal; null hides it. Today only.
  final ({
    int targetKg,
    bool gain,
    Future<void> Function() hold,
    VoidCallback newGoal,
  })?
  targetReached;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    // Exactly one clock read per build, or heading, strip and next slot could
    // land on opposite sides of midnight.
    final jetzt = clock.now();
    final heute = startOfDay(jetzt);
    final istHeute = daysBetween(heute, selectedDate) == 0;

    final slots = mealSlotSummariesForFoodDate(meals, selectedDate);
    final nextSlot = istHeute && !dayLoading ? accentSlot : null;
    final shownPick = istHeute && !dayLoading ? pick : null;
    final workout = istHeute ? nextWorkout : null;
    final session = istHeute ? activeSession : null;
    final check = istHeute && !dayLoading ? energyCheck : null;
    final reminder = istHeute && !dayLoading ? reminderPrompt : null;
    final showCheckCard =
        check != null &&
        onAcceptEnergyCheck != null &&
        onDismissEnergyCheck != null;
    final logWeight = istHeute ? onLogWeight : null;
    final health = istHeute && !dayLoading ? healthPrompt : null;
    final weightImport = istHeute && !dayLoading ? weightImportPrompt : null;
    final result = istHeute && !dayLoading && !showCheckCard
        ? energyCheckResult
        : null;
    // The weekly check explained, from its line and its result card.
    void explainCheck() => showWeeklyCheckExplainer(
      context,
      onOpenFoodLog: onOpenFoodLog,
      onLogWeight: logWeight == null
          ? null
          : () => showWeightEntrySheet(
              context,
              initial: latestWeightKg ?? profile.weightKg.toDouble(),
              onSave: logWeight,
              actions: weighIns,
            ),
    );
    final trends = istHeute && !dayLoading ? trendsPreview : null;
    final reached = istHeute ? targetReached : null;
    final fillYesterday = istHeute && !dayLoading ? onFillYesterday : null;
    final healthMissing = steps == null && healthConnect && healthConnectLinked;
    final showActivity =
        !dayLoading &&
        TodayActivityCard.hasContent(
          steps: steps,
          healthConnectMissing: healthMissing,
          workout: workout,
          activeSession: session,
        );

    // No SafeArea and no side padding: the shell supplies the gutters. The
    // page runs under the status bar and the floating tab bar; it starts at
    // the shared title origin and pads its end by the bar's band (plus the
    // design's clearance), so the last card can scroll clear of the glass.
    final navInset = MediaQuery.paddingOf(context).bottom;
    final page = SingleChildScrollView(
      key: const ValueKey('screen-today'),
      // Unclipped: the selected day's glow reaches into the shell's side
      // gutter as in the design; the tab stack still clips at the screen.
      clipBehavior: Clip.none,
      padding: EdgeInsets.only(
        top: TabChrome.topInset(context),
        bottom: navInset + 68,
      ),
      // Own layer: a scroll frame then moves the recorded page instead of
      // re-recording all of it (the viewport is the nearest boundary).
      child: RepaintBoundary(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
        children: livelyStagger(<Widget>[
            _TodayHeader(
              key: TabChrome.headerKey,
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
              isComplete: isCompleteDay,
            ),
            const SizedBox(height: 16),
            // While an archive day loads its numbers are still zero; the one
            // loading card under the heading carries that state instead.
            if (!dayLoading) ...<Widget>[
              TodayCalorieCard(summary: summary, isToday: istHeute),
              const SizedBox(height: 16),
              TodayMacros(summary: summary),
              if (logWeight != null) ...<Widget>[
                const SizedBox(height: 12),
                TodayWeighRow(
                  key: const ValueKey('today-weigh'),
                  latestKg: latestWeightKg,
                  onTap: () => showWeightEntrySheet(
                    context,
                    initial: latestWeightKg ?? profile.weightKg.toDouble(),
                    onSave: logWeight,
                    actions: weighIns,
                  ),
                  // The proposal or result card speaks for the check while
                  // it shows.
                  progress: showCheckCard || result != null
                      ? null
                      : energyCheckProgress,
                  onExplain: explainCheck,
                ),
              ],
              if (reached != null) ...<Widget>[
                const SizedBox(height: 16),
                TodayTargetReachedCard(
                  targetKg: reached.targetKg,
                  gain: reached.gain,
                  onHold: reached.hold,
                  onNewGoal: reached.newGoal,
                ),
              ],
              if (result != null) ...<Widget>[
                const SizedBox(height: 16),
                TodayWeeklyResultCard(
                  estimate: result,
                  onExplain: explainCheck,
                  onAskCoach: onAskCoachAboutCheck,
                ),
              ],
              if (showCheckCard) ...<Widget>[
                const SizedBox(height: 16),
                TodayEnergyCheckCard(
                  proposal: check,
                  onAccept: onAcceptEnergyCheck!,
                  onDismiss: onDismissEnergyCheck!,
                ),
              ],
              if (shownPick != null) ...<Widget>[
                const SizedBox(height: 16),
                TodayPickRow(
                  pick: shownPick,
                  onTap: onOpenPick == null
                      ? null
                      : () => onOpenPick!(shownPick),
                ),
              ],
            ],
            if (fillYesterday != null) ...<Widget>[
              const SizedBox(height: 16),
              TodayYesterdayHint(onTap: fillYesterday),
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
            if (reminder != null &&
                onAcceptReminderPrompt != null &&
                onDismissReminderPrompt != null) ...<Widget>[
              const SizedBox(height: 16),
              TodayReminderPromptCard(
                time: reminder,
                onAccept: onAcceptReminderPrompt!,
                onDismiss: onDismissReminderPrompt!,
                onChangeTime: onChangeReminderTime,
              ),
            ],
            if (health != null) ...<Widget>[
              const SizedBox(height: 16),
              TodayHealthPromptCard(
                healthConnect: healthConnect,
                onConnect: health.connect,
                onDismiss: health.dismiss,
              ),
            ],
            if (weightImport != null) ...<Widget>[
              const SizedBox(height: 16),
              TodayWeightImportCard(
                healthConnect: healthConnect,
                onAccept: weightImport.accept,
                onDismiss: weightImport.dismiss,
              ),
            ],
            if (showActivity) ...<Widget>[
              const SizedBox(height: 16),
              TodayActivityCard(
                steps: steps,
                stepsGoal: profile.dailyStepsGoal,
                burnedKcal: summary.burnedKcal,
                healthConnectMissing: healthMissing,
                onReviewHealth: onOpenProfile,
                workout: workout,
                activeSession: session,
                onOpenTraining: onOpenTraining,
                onResumeWorkout: onResumeWorkout,
              ),
            ],
            if (trends != null && onOpenTrends != null) ...<Widget>[
              const SizedBox(height: 16),
              TodayTrendsCard(preview: trends, onOpen: onOpenTrends!),
            ],
        ]),
        ),
      ),
    );
    // First view of the tab: the sections enter top to bottom, once per
    // session (the shell keeps a visited tab mounted).
    return LivelyStaggerScope(child: page);
  }
}

/// Date line and title on the left; streak pill and profile avatar on the
/// right, both 44 px high.
class _TodayHeader extends StatelessWidget {
  const _TodayHeader({
    super.key,
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
      child: PressScale(
        enabled: onTap != null,
      child: Material(
        color: t.activityTint,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: TodayTapTarget(
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
      button: onTap != null,
      label: context.l10n.todayProfileAndSettings,
      child: PressScale(
        enabled: onTap != null,
      child: Material(
        color: t.surf2,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: TodayTapTarget(
          key: const ValueKey('today-profile'),
          customBorder: shape,
          onTap: onTap,
          child: SizedBox.square(
            dimension: 44,
            child: Center(
              // Fixed circle: the letter grows with the system font until it
              // fills it.
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
      ),
    );
  }
}
