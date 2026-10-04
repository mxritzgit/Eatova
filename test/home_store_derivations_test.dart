import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/recipe_pick.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

import 'outbox/outbox_test_helpers.dart' as h;

// Store wiring of the Task 7 derivations: each accessor must read the live
// store state (profile, diary, activity credit, recipes, plan, history) and
// the frozen clock. The rules themselves are pinned in test/models/.

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

final _now = DateTime(2026, 9, 28, 18, 30);

HomeStore _store() {
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Moritz',
    emitSnack: _noopSnack,
  );
  addTearDown(store.dispose);
  return store;
}

LoggedMeal _meal(
  String id,
  DateTime at, {
  required int kcal,
  String protein = '0 g',
  String name = 'Meal',
}) => LoggedMeal(
  id: id,
  loggedAt: at,
  localDay: localDayKey(at),
  result: MealAnalysisResult(
    mealName: name,
    caloriesKcal: kcal,
    estimatedGrams: 200,
    kcalPer100G: kcal / 2,
    protein: protein,
    carbs: '0 g',
    fat: '0 g',
    confidence: 'Hoch',
    portionNotes: '',
  ),
);

/// The design day: 401 + 597 + 223 = 1,221 kcal, 111 g protein, dinner open.
List<LoggedMeal> _designDay() => [
  _meal('b1', DateTime(2026, 9, 28, 8, 10), kcal: 158, protein: '25 g'),
  _meal('b2', DateTime(2026, 9, 28, 8, 12), kcal: 186, protein: '7 g'),
  _meal('b3', DateTime(2026, 9, 28, 8, 11), kcal: 57, protein: '1 g'),
  _meal('l1', DateTime(2026, 9, 28, 12, 45), kcal: 597, protein: '50 g'),
  _meal(
    's1',
    DateTime(2026, 9, 28, 16, 20),
    kcal: 105,
    protein: '1 g',
  ).copyWith(forcedSlot: MealSlot.snack),
  _meal(
    's2',
    DateTime(2026, 9, 28, 16, 25),
    kcal: 118,
    protein: '27 g',
  ).copyWith(forcedSlot: MealSlot.snack),
  // Yesterday must not leak into today.
  _meal('y1', DateTime(2026, 9, 27, 19), kcal: 900, protein: '60 g'),
];

const _profile = UserProfile(
  dailyKcalGoal: 2123,
  proteinGoalG: 162,
  carbsGoalG: 222,
  fatGoalG: 57,
);

void main() {
  test('nutrition summary reads profile, diary and the activity credit', () {
    withClock(Clock.fixed(_now), () {
      final store = _store()
        ..profile = _profile
        ..loggedMeals = _designDay();
      final today = store.nutritionSummaryForFoodDate(_now);
      expect(today.consumedKcal, 1221);
      // NoopHealthService: no step source today, so no activity credit.
      expect(today.burnedKcal, 0);
      expect(today.remainingKcal, 902);
      expect(today.proteinLeftG, 51);

      // A past day takes its pinned activity credit from dailyActivity.
      final yesterday = DateTime(2026, 9, 27);
      store.dailyActivity = {localDayKey(yesterday): (steps: 1392, kcal: 73)};
      final past = store.nutritionSummaryForFoodDate(yesterday);
      expect(past.burnedKcal, 73);
      expect(past.budgetKcal, 2196);
      expect(past.consumedKcal, 900);
    });
  });

  test('next open slot and the recipe pick follow the store state', () async {
    await withClock(Clock.fixed(_now), () async {
      final store = _store()
        ..profile = _profile
        ..loggedMeals = _designDay();
      expect(store.nextOpenMainSlot(), MealSlot.dinner);

      final pick = store.nextMealPick(localeName: 'en')!;
      expect(pick.slot, MealSlot.dinner);
      expect(
        pick.recipe.title,
        'Turkey Steak with Quinoa & Roasted Vegetables',
      );
      expect(pick.kcalLeftAfter, 292);
      expect(
        store.nextMealPick(localeName: 'de')!.recipe.title,
        'Putensteak mit Quinoa & Ofengemüse',
      );

      // The profile's diet is applied.
      store.profile = _profile.copyWith(diet: DietPreference.vegan);
      expect(
        store.nextMealPick(localeName: 'de')!.recipe.slug,
        'tofu_mit_reis_and_edamame',
      );
      store.profile = _profile;

      // Own recipes join the pool; a pending delete hides them again.
      const own = FitnessRecipe(
        slug: 'user_own_dinner',
        title: 'Own dinner',
        description: '',
        portion: '',
        ingredients: '',
        preparation: '',
        professionalHint: '',
        imageAsset: '',
        caloriesKcal: 700,
        proteinG: 80,
        carbsG: 50,
        fatG: 20,
        estimatedGrams: 500,
        categories: ['Eigene'],
        userCreated: true,
      );
      await store.saveUserRecipe(own);
      expect(store.nextMealPick(localeName: 'de')!.recipe.slug, own.slug);
      store.setRecipeDeletePending(own.slug, pending: true);
      expect(
        store.nextMealPick(localeName: 'de')!.recipe.slug,
        'putensteak_mit_quinoa_and_ofengemuse',
      );

      // A planned dinner wins, and the revision fingerprint moves.
      final before = store.mealPlansRevision;
      final plan = PlannedMeal.create(
        recipe: recipeCatalogDe.first,
        day: _now,
        slot: MealSlot.dinner,
      );
      await store.savePlannedMeal(plan);
      expect(store.mealPlansRevision, isNot(before));
      final planned = store.nextMealPick(localeName: 'de')!;
      expect(planned.source, RecipePickSource.planned);
      expect(planned.plannedMeal?.id, plan.id);

      // Dinner logged: nothing left to pick.
      store.loggedMeals = [
        _meal('d1', DateTime(2026, 9, 28, 18, 20), kcal: 500),
        ...store.loggedMeals,
      ];
      expect(store.nextOpenMainSlot(), isNull);
      expect(store.nextMealPick(localeName: 'de'), isNull);
    });
  });

  test('logging streak reads the frozen day', () {
    final store = withClock(Clock.fixed(_now), _store);
    store.lifetimeStats = LifetimeStats(
      currentStreak: 12,
      longestStreak: 20,
      lastTrackedDate: DateTime(2026, 9, 27),
    );
    // Fresh morning: yesterday's chain still shows.
    expect(withClock(Clock.fixed(_now), () => store.loggingStreak), 12);
    // Two days later the chain is broken.
    expect(
      withClock(
        Clock.fixed(DateTime(2026, 9, 29, 9)),
        () => store.loggingStreak,
      ),
      0,
    );
  });

  test('training accessors: empty store, then a plan with history', () async {
    await withClock(Clock.fixed(_now), () async {
      final empty = _store();
      expect(empty.nextTrainingWorkoutForToday(), isNull);
      expect(empty.currentTrainingWeek().plannedSessions, isNull);
      expect(empty.currentTrainingWeek().doneSessions, 0);
      expect(empty.weeklyTrainingVolume().weeks, hasLength(6));
      expect(empty.recentWorkoutSummaries(), isEmpty);

      // Completing a workout needs the durable cache: a real store over the
      // fake PostgREST and an in-memory LocalCache.
      final env = h.setup();
      final store = env.store;
      await h.bootUntilIdle(store);

      final plan = TrainingPlan(
        id: 'ppl',
        proposal: CoachTrainingProposal(
          title: 'Strength plan',
          workouts: [
            TrainingWorkout(
              title: 'Upper Body Push',
              exercises: [
                TrainingExercise(
                  id: 'bench',
                  name: 'Bench press',
                  sets: 1,
                  reps: 8,
                  restSeconds: 90,
                ),
              ],
            ),
            TrainingWorkout(
              title: 'Upper Body Pull',
              exercises: [
                TrainingExercise(
                  id: 'row',
                  name: 'Row',
                  sets: 1,
                  reps: 8,
                  restSeconds: 90,
                ),
              ],
            ),
          ],
        ),
      );
      await store.saveTrainingPlan(plan);
      expect(store.nextTrainingWorkoutForToday()!.workoutIndex, 0);
      expect(store.currentTrainingWeek().plannedSessions, 2);

      final start = DateTime(2026, 9, 28, 7);
      final saved = store.trainingPlans.single;
      final entry = TrainingHistoryEntry(
        snapshot: TrainingSessionSnapshot(
          plan: saved,
          sessionId: '00000000-0000-4000-8000-000000000001',
          startedAt: start,
          actualSets: [
            TrainingSetActual(
              reference: const TrainingSetReference(
                exerciseIndex: 0,
                setIndex: 0,
              ),
              completedAt: start.add(const Duration(minutes: 1)),
              reps: 8,
              weightKg: 75,
            ),
          ],
          workoutIndex: 0,
          exerciseIndex: 0,
          setIndex: 0,
          phase: TrainingSessionPhase.review,
          remainingMilliseconds: 0,
          completedSets: const [
            TrainingSetReference(exerciseIndex: 0, setIndex: 0),
          ],
        ),
        finishedAt: start.add(const Duration(minutes: 52)),
      );
      await store.completeTrainingSession(
        entry,
        generation: store.trainingSessionGeneration,
      );

      final next = store.nextTrainingWorkoutForToday()!;
      expect(next.workoutIndex, 0);
      expect(next.completedToday, isTrue);
      // Today keeps the finished Push; the Training card offers Pull.
      expect(next.upNextWorkoutIndex, 1);
      expect(next.exercises.single.lastTopSet!.weightKg, 75);
      expect(store.currentTrainingWeek().days.first.done, isTrue);
      expect(store.weeklyTrainingVolume().currentWeek.volumeKg, 600);
      final recent = store.recentWorkoutSummaries();
      expect(recent.single.duration, const Duration(minutes: 52));
      expect(recent.single.personalRecords, 0);
    });
  });

  // Perf polish 2026-10-01: the PR count replays the whole history, so the
  // store memoizes the recent list on the history's identity. The memo must
  // follow every history change and must never cross into another account's
  // store.
  test('recentWorkoutSummaries: memo folgt der Historie und bleibt pro '
      'Store (Konto)', () async {
    await withClock(Clock.fixed(_now), () async {
      final env = h.setup();
      final store = env.store;
      await h.bootUntilIdle(store);
      await store.saveTrainingPlan(
        TrainingPlan(
          id: 'memo',
          proposal: CoachTrainingProposal(
            title: 'Memo plan',
            workouts: [
              TrainingWorkout(
                title: 'Bench day',
                exercises: [
                  TrainingExercise(
                    id: 'bench',
                    name: 'Bench press',
                    sets: 1,
                    reps: 8,
                    restSeconds: 90,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      final plan = store.trainingPlans.single;
      TrainingHistoryEntry workout(int n, double kg) {
        final start = DateTime(2026, 9, 20 + n, 7);
        return TrainingHistoryEntry(
          snapshot: TrainingSessionSnapshot(
            plan: plan,
            sessionId: '00000000-0000-4000-8000-00000000010$n',
            startedAt: start,
            actualSets: [
              TrainingSetActual(
                reference: const TrainingSetReference(
                  exerciseIndex: 0,
                  setIndex: 0,
                ),
                completedAt: start.add(const Duration(minutes: 1)),
                reps: 8,
                weightKg: kg,
              ),
            ],
            workoutIndex: 0,
            exerciseIndex: 0,
            setIndex: 0,
            phase: TrainingSessionPhase.review,
            remainingMilliseconds: 0,
            completedSets: const [
              TrainingSetReference(exerciseIndex: 0, setIndex: 0),
            ],
          ),
          finishedAt: start.add(Duration(minutes: 40 + n)),
        );
      }

      expect(store.recentWorkoutSummaries(), isEmpty);
      await store.completeTrainingSession(
        workout(1, 70),
        generation: store.trainingSessionGeneration,
      );
      final one = store.recentWorkoutSummaries();
      expect(one.map((w) => w.personalRecords), [0]);
      // Unchanged history: the same instance, no second replay.
      expect(identical(store.recentWorkoutSummaries(), one), isTrue);
      // A different limit is its own question.
      expect(store.recentWorkoutSummaries(limit: 0), isEmpty);

      await store.completeTrainingSession(
        workout(2, 80),
        generation: store.trainingSessionGeneration,
      );
      final two = store.recentWorkoutSummaries();
      expect(identical(two, one), isFalse);
      expect(two.map((w) => w.entry.id), [
        workout(2, 80).id,
        workout(1, 70).id,
      ]);
      expect(two.map((w) => w.personalRecords), [1, 0]);

      await store.deleteTrainingHistory(workout(2, 80).id);
      expect(
        store.recentWorkoutSummaries().map((w) => w.entry.id),
        [workout(1, 70).id],
      );

      // Account switch = a new store: nothing of the first store's memo.
      final other = h.setup().store;
      await h.bootUntilIdle(other);
      expect(other.recentWorkoutSummaries(), isEmpty);
      expect(store.recentWorkoutSummaries(), hasLength(1));
    });
  });
}
