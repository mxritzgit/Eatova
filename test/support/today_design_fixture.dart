// The Today tab's design scenario (dark redesign, 2026-09-28) as a store
// fixture, shared by the capture test and the Today wiring flows.
//
// Mon 2026-09-28 19:00; budget 2,123 = goal 2,050 + 73 activity credit from
// 1,392 steps (140 kg / 180 cm / male); 1,221 kcal eaten with P/C/F
// 111/144/20 of 162/222/57; breakfast 401, lunch 597, snacks 223, dinner
// open; a selected plan whose next workout is "Upper Body Push" (≈ 50 min);
// streak 1.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_day.dart';

import '../flows/flow_test_helpers.dart' show storeOf;
import 'design_capture.dart';
import 'harness.dart';

/// The design's clock: Monday, 28 September 2026, 19:00 (dinner is next).
final DateTime designNow = DateTime(2026, 9, 28, 19);

/// A granted step source whose count a test can change between reads.
class DesignSteps extends NoopHealthService {
  DesignSteps({this.steps = 1392});

  int steps;

  @override
  HealthAuthState get authState => HealthAuthState.granted;

  @override
  Future<HealthAuthState> requestAuthorization() async => authState;

  @override
  Future<HealthSnapshot> readSnapshot() async =>
      HealthSnapshot(stepsToday: steps, fetchedAt: clock.now());
}

/// Goal 2,050 and the macro goals of the design; 140 kg / 180 cm / male turn
/// the 1,392 steps into the design's +73 kcal.
const UserProfile designProfile = UserProfile(
  dailyKcalGoal: 2050,
  proteinGoalG: 162,
  carbsGoalG: 222,
  fatGoalG: 57,
  weightKg: 140,
  heightCm: 180,
  sex: BiologicalSex.male,
  dailyStepsGoal: 8000,
);

LoggedMeal designMeal(
  String id,
  String name,
  MealSlot slot,
  DateTime at, {
  required int kcal,
  int protein = 0,
  int carbs = 0,
  int fat = 0,
}) => LoggedMeal(
  id: id,
  loggedAt: at,
  localDay: localDayKey(at),
  forcedSlot: slot,
  result: MealAnalysisResult(
    mealName: name,
    caloriesKcal: kcal,
    estimatedGrams: 100,
    kcalPer100G: kcal.toDouble(),
    protein: '$protein g',
    carbs: '$carbs g',
    fat: '$fat g',
    confidence: 'Hoch',
    portionNotes: '',
  ),
);

/// Breakfast 401, lunch 597, snacks 223, dinner empty: 1,221 kcal and
/// P/C/F 111/144/20.
List<LoggedMeal> designDay() => <LoggedMeal>[
  designMeal(
    'b1',
    'Skyr',
    MealSlot.breakfast,
    DateTime(2026, 9, 28, 8, 10),
    kcal: 158,
    protein: 25,
    carbs: 10,
    fat: 1,
  ),
  designMeal(
    'b2',
    'Oats',
    MealSlot.breakfast,
    DateTime(2026, 9, 28, 8, 11),
    kcal: 186,
    protein: 7,
    carbs: 32,
    fat: 4,
  ),
  designMeal(
    'b3',
    'Blueberries',
    MealSlot.breakfast,
    DateTime(2026, 9, 28, 8, 12),
    kcal: 57,
    protein: 1,
    carbs: 13,
  ),
  designMeal(
    'l1',
    'Chicken',
    MealSlot.lunch,
    DateTime(2026, 9, 28, 12, 40),
    kcal: 300,
    protein: 55,
    fat: 7,
  ),
  designMeal(
    'l2',
    'Rice',
    MealSlot.lunch,
    DateTime(2026, 9, 28, 12, 41),
    kcal: 230,
    protein: 5,
    carbs: 50,
    fat: 1,
  ),
  designMeal(
    'l3',
    'Broccoli',
    MealSlot.lunch,
    DateTime(2026, 9, 28, 12, 42),
    kcal: 67,
    protein: 5,
    carbs: 9,
    fat: 1,
  ),
  designMeal(
    's1',
    'Banana',
    MealSlot.snack,
    DateTime(2026, 9, 28, 16, 20),
    kcal: 105,
    protein: 1,
    carbs: 27,
  ),
  designMeal(
    's2',
    'Whey shake',
    MealSlot.snack,
    DateTime(2026, 9, 28, 16, 25),
    kcal: 118,
    protein: 12,
    carbs: 3,
    fat: 6,
  ),
];

/// Five exercises of 4 x 10 with 160 s rest: the app's estimate is 50 min.
TrainingPlan designPlan() => TrainingPlan(
  id: 'design-plan',
  proposal: CoachTrainingProposal(
    title: 'Strength plan',
    workouts: <TrainingWorkout>[
      TrainingWorkout(
        title: 'Upper Body Push',
        exercises: <TrainingExercise>[
          for (final (id, name) in const <(String, String)>[
            ('bench', 'Bench press'),
            ('incline', 'Incline dumbbell press'),
            ('ohp', 'Overhead press'),
            ('dips', 'Dips'),
            ('pushdown', 'Triceps pushdown'),
          ])
            TrainingExercise(
              id: id,
              name: name,
              sets: 4,
              reps: 10,
              restSeconds: 160,
            ),
        ],
      ),
    ],
  ),
);

/// Mounts the real shell at the design's phone geometry and seeds the
/// scenario; call inside `withClock(Clock.fixed(designNow), ...)`.
Future<HomeStore> pumpDesignToday(
  WidgetTester tester, {
  bool emptyDay = false,
  Locale locale = const Locale('en'),
  DesignSteps? health,
  List<LoggedMeal>? meals,
}) async {
  pinDesignViewport(tester);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        EatovaHomePage(healthService: health ?? DesignSteps()),
        locale: locale,
        safeArea: false,
        scaffold: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
  final store = storeOf(tester);
  store
    ..profile = designProfile
    ..loggedMeals = meals ?? (emptyDay ? const <LoggedMeal>[] : designDay())
    ..lifetimeStats = LifetimeStats(
      currentStreak: 1,
      lastTrackedDate: clock.now(),
      sessionStart: clock.now(),
    );
  await store.refreshHealthSteps();
  // The save serializes through timers; pump fake time instead of awaiting.
  var saved = false;
  unawaited(
    store.saveTrainingPlan(designPlan()).whenComplete(() => saved = true),
  );
  for (var i = 0; i < 200 && !saved; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(store.trainingPlans, isNotEmpty, reason: 'plan not saved');
  store.setTab(0);
  await tester.pumpAndSettle();
  return store;
}
