part of 'home_store.dart';

/// Read-only derivations for the redesigned tabs: thin bindings of the store
/// state to the pure functions in `models/day_nutrition.dart`,
/// `models/recipe_pick.dart`, `models/training_insights.dart` and
/// `services/meal_totals.dart`. No writes, no notifications; the only state
/// is one identity-keyed memo ([recentWorkoutSummaries]).
///
/// Every other call computes a fresh value, so a `StoreSelector` must select
/// the INPUTS named per member (G11), never the result.
mixin _HomeStoreDerivationsPart on _HomeStoreBase {
  /// The logging streak for the header pill: the server-kept
  /// [LifetimeStats.currentStreak] while its last tracked day is today or
  /// yesterday, else 0 ([LifetimeStats.effectiveStreakOn]). A fresh morning
  /// keeps yesterday's streak; back-dated logs neither extend nor break it.
  ///
  /// Selector inputs: [lifetimeStats] (plus the day, via rollover).
  int get loggingStreak => lifetimeStats.effectiveStreakOn(clock.now());

  /// O(1) change fingerprint of [plannedMeals] (and shopping checks) for
  /// selectors: [plannedMeals] returns a new list on every read.
  int get mealPlansRevision => _mealPlansVersion;

  /// Budget, eaten, activity credit and macros left for [date].
  ///
  /// Selector inputs: [loggedMeals], [profile], [dailyActivity] and
  /// `stepsForFoodDate(date)` (the activity credit).
  DayNutritionSummary nutritionSummaryForFoodDate(DateTime date) =>
      DayNutritionSummary(
        profile: profile,
        burnedKcal: burnedKcalForFoodDate(date),
        consumed: macroProgressForFoodDate(date),
      );

  /// Today's next open main meal ([nextOpenMainMealSlot]), or null.
  ///
  /// Selector inputs: [loggedMeals] (plus the clock's current slot).
  MealSlot? nextOpenMainSlot() {
    final now = clock.now();
    return nextOpenMainMealSlot(now: now, todaysMeals: mealsForFoodDate(now));
  }

  /// The recipe for today's next open main meal ([pickRecipeForNextMeal]):
  /// the user's visible recipes plus the catalog of [localeName]
  /// (`context.l10n.localeName`), filtered by the profile's diet, against
  /// today's remaining kcal (budget incl. activity credit).
  ///
  /// Selector inputs: [loggedMeals], [profile], [dailyActivity],
  /// `stepsForFoodDate(now)`, [userRecipes], [pendingRecipeDeletes],
  /// [mealPlansRevision] and the locale.
  RecipePick? nextMealPick({required String localeName}) {
    final now = clock.now();
    return pickRecipeForNextMeal(
      now: now,
      todaysMeals: mealsForFoodDate(now),
      remainingKcal: nutritionSummaryForFoodDate(now).remainingKcal,
      recipes: <FitnessRecipe>[
        ...visibleUserRecipes,
        ...recipeCatalogForLocale(localeName),
      ],
      diet: profile.diet,
      plannedMeals: plannedMeals,
    );
  }

  /// Today's workout of the selected plan ([nextTrainingWorkout]), or null
  /// without a plan.
  ///
  /// Selector inputs: [trainingPlans], [selectedTrainingPlanId],
  /// [trainingHistory].
  TrainingNextWorkout? nextTrainingWorkoutForToday() => nextTrainingWorkout(
    plan: selectedTrainingPlan,
    history: trainingHistory,
    now: clock.now(),
  );

  /// This week's finished sessions per day ([trainingWeekOf]).
  ///
  /// Selector inputs: [trainingHistory], [trainingPlans],
  /// [selectedTrainingPlanId].
  TrainingWeek currentTrainingWeek() => trainingWeekOf(
    now: clock.now(),
    history: trainingHistory,
    plan: selectedTrainingPlan,
  );

  /// Weekly load for the last five full weeks plus this one
  /// ([trainingVolumeTrend]).
  ///
  /// Selector inputs: [trainingHistory].
  TrainingVolumeTrend weeklyTrainingVolume() =>
      trainingVolumeTrend(history: trainingHistory, now: clock.now());

  /// The newest [limit] workouts with duration and PR count
  /// ([recentTrainingWorkouts]).
  ///
  /// Memoized on the identity of [trainingHistory] and [limit]: the PR count
  /// replays the WHOLE history (up to 2000 workouts, ~5 ms), and the Training
  /// tab rebuilds on every set of a running session. The history list is
  /// unmodifiable and replaced on every change, so identity is a complete
  /// fingerprint; the memo lives on this store, i.e. per account session.
  ///
  /// Selector inputs: [trainingHistory].
  List<TrainingWorkoutSummary> recentWorkoutSummaries({int limit = 3}) {
    final history = trainingHistory;
    final memo = _recentWorkoutsMemo;
    if (memo != null &&
        identical(memo.history, history) &&
        memo.limit == limit) {
      return memo.value;
    }
    final value = recentTrainingWorkouts(history, limit: limit);
    _recentWorkoutsMemo = (history: history, limit: limit, value: value);
    return value;
  }

  ({
    List<TrainingHistoryEntry> history,
    int limit,
    List<TrainingWorkoutSummary> value,
  })?
  _recentWorkoutsMemo;
}
