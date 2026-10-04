// Wiring check of the redesigned Today tab (dark redesign, 2026-09-29 user
// requirement): every interactive element does what it promises in the REAL
// shell, and every number follows the store.
//
// Runs on `EatovaHomePage` with the design scenario (today_design_fixture):
// Mon 2026-09-28 19:00, 1,221 of 2,123 kcal, dinner open, 1,392 steps, a plan
// whose next workout is "Upper Body Push", streak 1. English, like the
// design's copy.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/recipe_pick.dart';
import 'package:eatova/src/screens/profile_screen.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/screens/today/today_macros.dart';
import 'package:eatova/src/screens/today/today_progress.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/services/kcal_format.dart';
import 'package:eatova/src/widgets/kcal/meal_slot_picker.dart';

import '../support/today_design_fixture.dart';

final AppLocalizations _en = lookupAppLocalizations(const Locale('en'));

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey<String>(key))).data!;

String _fmt(int n) => formatThousands(n, 'en');

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey<String>(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// Back to the Today tab, scrolled to the top.
Future<void> _backToToday(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('nav-Heute')));
  await tester.pumpAndSettle();
  final page = find.byKey(const ValueKey('screen-today'));
  final scrollable = find.descendant(
    of: page,
    matching: find.byType(Scrollable),
  );
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pumpAndSettle();
}

/// Every calorie-card and macro value against the store's day summary.
void _expectDayNumbers(WidgetTester tester, HomeStore store, DateTime day) {
  final summary = store.nutritionSummaryForFoodDate(day);
  expect(
    _text(tester, 'today-kcal-remaining'),
    _fmt(summary.remainingKcal.abs()),
  );
  expect(_text(tester, 'today-stat-eaten'), _fmt(summary.consumedKcal));
  expect(_text(tester, 'today-kcal-goal'), _fmt(summary.goalKcal));
  expect(
    _text(tester, 'today-kcal-budget'),
    summary.remainingKcal < 0
        ? _en.todayArcBudgetOver(_fmt(summary.budgetKcal))
        : _en.todayArcBudget(_fmt(summary.budgetKcal)),
  );
  expect(
    _text(tester, 'today-kcal-percent'),
    _en.todayEatenPercent((summary.eatenFraction * 100).round()),
  );
  expect(
    tester.widget<TodayCalorieArc>(find.byType(TodayCalorieArc)).progress,
    summary.eatenFraction,
  );
  // Each macro tile against its own numbers (not just "some text on
  // screen"): eaten, goal and grams left.
  final tiles = {
    for (final tile in tester.widgetList<TodayMacroTile>(
      find.byType(TodayMacroTile),
    ))
      tile.label: tile,
  };
  expect(tiles.keys, [
    _en.todayMacroProtein,
    _en.todayMacroCarbs,
    _en.todayMacroFat,
  ]);
  for (final (label, eaten, goal, left) in [
    (
      _en.todayMacroProtein,
      summary.consumed.proteinG,
      summary.proteinGoalG,
      summary.proteinLeftG,
    ),
    (
      _en.todayMacroCarbs,
      summary.consumed.carbsG,
      summary.carbsGoalG,
      summary.carbsLeftG,
    ),
    (
      _en.todayMacroFat,
      summary.consumed.fatG,
      summary.fatGoalG,
      summary.fatLeftG,
    ),
  ]) {
    final tile = tiles[label]!;
    expect(tile.value, eaten.round(), reason: label);
    expect(tile.goal, goal, reason: label);
    expect(tile.left, left, reason: label);
  }
}

/// Which slot's "+" carries the accent fill; null when none does.
MealSlot? _accentSlot(WidgetTester tester) {
  MealSlot? accent;
  for (final slot in MealSlot.values) {
    final circle = find.descendant(
      of: find.byKey(ValueKey<String>('today-meal-add-${slot.name}')),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).shape == BoxShape.circle,
      ),
    );
    final fill =
        (tester.widget<Container>(circle).decoration! as BoxDecoration).color;
    if (fill == AppTokens.dark.accentFill) {
      expect(accent, isNull, reason: 'one accent at most');
      accent = slot;
    }
  }
  return accent;
}

MealAnalysisResult _dinner() => const MealAnalysisResult(
  mealName: 'Salmon bowl',
  caloriesKcal: 650,
  estimatedGrams: 400,
  kcalPer100G: 162.5,
  protein: '40 g',
  carbs: '60 g',
  fat: '22 g',
  confidence: 'Hoch',
  portionNotes: '',
);

void main() {
  testWidgets('streak pill and avatar open the profile; settings sit '
      'behind it', (tester) async {
    await withClock(Clock.fixed(designNow), () async {
      final store = await pumpDesignToday(tester);
      expect(_text(tester, 'today-streak-count'), '1');

      // The pill reads the store and follows it.
      store.lifetimeStats = LifetimeStats(
        currentStreak: 9,
        lastTrackedDate: designNow,
        sessionStart: designNow,
      );
      store.setTab(0);
      await tester.pumpAndSettle();
      expect(_text(tester, 'today-streak-count'), '9');

      await _tap(tester, 'today-streak');
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(
        tester
            .widget<ProfileScreen>(find.byType(ProfileScreen))
            .stats
            .currentStreak,
        9,
      );
      await _tap(tester, 'profile-close');
      expect(find.byType(ProfileScreen), findsNothing);

      await _tap(tester, 'today-profile');
      expect(find.byType(ProfileScreen), findsOneWidget);
      // The old header's settings button moved here.
      await _tap(tester, 'profile-open-settings');
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('each day of the strip switches the shown day and all data '
      'follows', (tester) async {
    await withClock(Clock.fixed(designNow), () async {
      final store = await pumpDesignToday(tester);
      // Yesterday's 2,400 kcal dinner and its pinned activity credit.
      final yesterday = DateTime(2026, 9, 27);
      store
        ..loggedMeals = [
          ...store.loggedMeals,
          designMeal(
            'y1',
            'Pizza',
            MealSlot.dinner,
            DateTime(2026, 9, 27, 20),
            kcal: 2400,
            protein: 90,
          ),
        ]
        ..dailyActivity = {'2026-09-27': (steps: 5000, kcal: 260)};
      store.setTab(0);
      await tester.pumpAndSettle();
      _expectDayNumbers(tester, store, designNow);

      await _tap(tester, 'today-day-2026-09-27');
      expect(store.selectedFoodDate, yesterday);
      expect(_text(tester, 'today-date-selected-label'), 'Sunday, Sep 27');
      _expectDayNumbers(tester, store, yesterday);
      expect(_text(tester, 'today-stat-burned'), '+260');
      expect(find.text('OVER THAT DAY'), findsOneWidget);
      expect(_text(tester, 'today-meal-kcal-dinner'), '2,400 kcal');
      expect(_text(tester, 'today-meal-sub-lunch'), 'Nothing logged');
      expect(_text(tester, 'today-steps-value'), '5,000');
      // Pick and next workout belong to today only.
      expect(find.byKey(const ValueKey('today-pick')), findsNothing);
      expect(
        find.byKey(const ValueKey('today-workout-row'), skipOffstage: false),
        findsNothing,
      );

      // Every other cell of the week selects exactly its day.
      for (var day = 22; day <= 28; day++) {
        await _tap(tester, 'today-day-2026-09-$day');
        expect(store.selectedFoodDate, DateTime(2026, 9, day));
        expect(
          tester.getSemantics(find.byKey(ValueKey('today-day-2026-09-$day'))),
          isSemantics(isSelected: true),
        );
      }
      _expectDayNumbers(tester, store, designNow);
      expect(find.text('LEFT TODAY'), findsOneWidget);
      expect(find.byKey(const ValueKey('today-pick')), findsOneWidget);
    });
  });

  testWidgets('logging a meal updates arc, stats, macros, rows and the pick; '
      'undo restores them', (tester) async {
    await withClock(Clock.fixed(designNow), () async {
      final store = await pumpDesignToday(tester);
      expect(find.byKey(const ValueKey('today-pick')), findsOneWidget);
      expect(_accentSlot(tester), MealSlot.dinner);

      final id = await store.addResultToDailyTotal(
        _dinner(),
        slot: MealSlot.dinner,
      );
      await tester.pumpAndSettle();
      _expectDayNumbers(tester, store, designNow);
      expect(_text(tester, 'today-stat-eaten'), '1,871');
      expect(_text(tester, 'today-kcal-remaining'), '252');
      expect(_text(tester, 'today-meal-kcal-dinner'), '650 kcal');
      expect(_text(tester, 'today-meal-sub-dinner'), 'Salmon bowl');
      // Dinner is logged: no open main meal is left at 19:00, so neither a
      // pick nor an accent button remains.
      expect(find.byKey(const ValueKey('today-pick')), findsNothing);
      expect(_accentSlot(tester), isNull);

      await store.removeLoggedMeal(id);
      await tester.pumpAndSettle();
      _expectDayNumbers(tester, store, designNow);
      expect(_text(tester, 'today-stat-eaten'), '1,221');
      expect(_accentSlot(tester), MealSlot.dinner);

      // The shell's undo snack brings the meal and the numbers back.
      final undo = find.widgetWithText(SnackBarAction, _en.commonUndo);
      expect(undo, findsOneWidget);
      await tester.tap(undo);
      await tester.pumpAndSettle();
      _expectDayNumbers(tester, store, designNow);
      expect(_text(tester, 'today-stat-eaten'), '1,871');
      expect(_text(tester, 'today-meal-kcal-dinner'), '650 kcal');
      expect(_accentSlot(tester), isNull);
    });
  });

  testWidgets('the empty dinner\'s band follows what is left and falls '
      'back to "Nothing logged" once the budget is used up', (tester) async {
    await withClock(Clock.fixed(designNow), () async {
      final store = await pumpDesignToday(tester);
      // 902 left with only dinner open: capped at 33 % of 2,123 = 700.
      expect(_text(tester, 'today-meal-sub-dinner'), 'Suggested 550–700 kcal');

      // A 650 kcal snack leaves 252: the band shrinks to the rest.
      await store.addResultToDailyTotal(_dinner(), slot: MealSlot.snack);
      await tester.pumpAndSettle();
      expect(_text(tester, 'today-meal-sub-dinner'), 'Suggested 200–250 kcal');

      // Over budget: no band that pushes the day further over.
      await store.addResultToDailyTotal(_dinner(), slot: MealSlot.lunch);
      await tester.pumpAndSettle();
      expect(
        _text(tester, 'today-meal-sub-dinner'),
        _en.todaySlotNothingLogged,
      );
    });
  });

  testWidgets('the accent "+" follows the store: logging the next main meal '
      'moves it on, a snack leaves it', (tester) async {
    // 08:30 on an empty day: breakfast is the next open main meal.
    await withClock(Clock.fixed(DateTime(2026, 9, 28, 8, 30)), () async {
      final store = await pumpDesignToday(tester, emptyDay: true);
      expect(_accentSlot(tester), MealSlot.breakfast);
      expect(store.nextOpenMainSlot(), MealSlot.breakfast);

      // A snack is not a main meal: the accent stays.
      await store.addResultToDailyTotal(_dinner(), slot: MealSlot.snack);
      await tester.pumpAndSettle();
      expect(_accentSlot(tester), MealSlot.breakfast);

      await store.addResultToDailyTotal(_dinner(), slot: MealSlot.breakfast);
      await tester.pumpAndSettle();
      expect(_accentSlot(tester), MealSlot.lunch);
      expect(_accentSlot(tester), store.nextOpenMainSlot());
      _expectDayNumbers(tester, store, DateTime(2026, 9, 28));

      await store.addResultToDailyTotal(_dinner(), slot: MealSlot.lunch);
      await tester.pumpAndSettle();
      expect(_accentSlot(tester), MealSlot.dinner);

      // Another day shown: no accent at all.
      await _tap(tester, 'today-day-2026-09-27');
      expect(_accentSlot(tester), isNull);
    });
  });

  testWidgets('"Tonight\'s pick" opens its recipe; adding there logs to the '
      'dinner of the shown day', (tester) async {
    await withClock(Clock.fixed(designNow), () async {
      final store = await pumpDesignToday(tester);
      final pick = store.nextMealPick(localeName: 'en')!;

      await _tap(tester, 'today-pick');
      expect(
        find.byKey(ValueKey('recipe-detail-${pick.recipe.slug}')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<RecipeDetailScreen>(find.byType(RecipeDetailScreen))
            .recipe
            .slug,
        pick.recipe.slug,
      );

      await _tap(tester, 'recipe-add-button');
      await _tap(tester, 'recipe-meal-picker-dinner');
      final added = store
          .mealsForFoodDate(designNow)
          .where((m) => m.result.mealName == pick.recipe.displayTitle(_en));
      expect(added, hasLength(1));
      expect(added.single.slot, MealSlot.dinner);
      expect(added.single.result.caloriesKcal, pick.kcal);

      await _tap(tester, 'recipe-detail-back');
      _expectDayNumbers(tester, store, designNow);
      // Dinner is taken: the row is gone, as it is without any pick.
      expect(find.byKey(const ValueKey('today-pick')), findsNothing);
    });
  });

  testWidgets('a planned pick opens the meal plan; "eat" logs the planned '
      'servings once and marks the entry eaten', (tester) async {
    await withClock(Clock.fixed(designNow), () async {
      final store = await pumpDesignToday(tester);
      // Two servings of a catalog dinner planned for today.
      final recipe = recipeCatalogEn.firstWhere(
        (r) => recipeSuitsSlot(r, MealSlot.dinner),
      );
      final plan = PlannedMeal.create(
        recipe: recipe,
        day: designNow,
        slot: MealSlot.dinner,
        servings: 2,
      );
      await store.savePlannedMeal(plan);
      store.setTab(0);
      await tester.pumpAndSettle();

      final pick = store.nextMealPick(localeName: 'en')!;
      expect(pick.source, RecipePickSource.planned);
      expect(pick.servings, 2);
      final shownKcal = pick.kcal!;
      expect(find.text('PLANNED FOR TONIGHT'), findsOneWidget);
      expect(
        find.text(_en.todayPickMeta(_fmt(shownKcal), pick.proteinG!)),
        findsOneWidget,
      );
      final before = store.mealsForFoodDate(designNow).length;

      await _tap(tester, 'today-pick');
      expect(find.byType(MealPlanScreen), findsOneWidget);
      expect(find.byType(RecipeDetailScreen), findsNothing);

      await _tap(tester, 'meal-plan-eat-${plan.id}');
      final logged = store.mealsForFoodDate(designNow);
      expect(logged, hasLength(before + 1), reason: 'exactly one new row');
      final row = logged.singleWhere((m) => m.id == plan.id);
      expect(row.result.caloriesKcal, shownKcal);
      expect(row.slot, MealSlot.dinner);
      expect(
        store.plannedMeals.singleWhere((p) => p.id == plan.id).isEaten,
        isTrue,
      );
      // Eating it again is a no-op, not a duplicate diary row.
      await store.eatPlannedMeal(plan.id);
      expect(store.mealsForFoodDate(designNow), hasLength(before + 1));

      // Back to Today (the plan's header scrolled away with its list).
      Navigator.of(tester.element(find.byType(MealPlanScreen))).pop();
      await tester.pumpAndSettle();
      _expectDayNumbers(tester, store, designNow);
      expect(
        _text(tester, 'today-meal-kcal-dinner'),
        '${_fmt(shownKcal)} kcal',
      );
      expect(find.byKey(const ValueKey('today-pick')), findsNothing);
    });
  });

  testWidgets('a planned pick without loggable kcal shows no numbers and '
      'leads to the meal plan, where it cannot be eaten', (tester) async {
    await withClock(Clock.fixed(designNow), () async {
      final store = await pumpDesignToday(tester);
      const pending = FitnessRecipe(
        slug: 'user_pending_dinner',
        title: 'Imported stew',
        description: '',
        portion: '',
        ingredients: '',
        preparation: '',
        professionalHint: '',
        imageAsset: '',
        caloriesKcal: 0,
        proteinG: 0,
        carbsG: 0,
        fatG: 0,
        estimatedGrams: 0,
        categories: <String>[recipeNutritionPendingCategory],
        userCreated: true,
      );
      final plan = PlannedMeal.create(
        recipe: pending,
        day: designNow,
        slot: MealSlot.dinner,
      );
      await store.savePlannedMeal(plan);
      store.setTab(0);
      await tester.pumpAndSettle();

      final pick = store.nextMealPick(localeName: 'en')!;
      expect(pick.source, RecipePickSource.planned);
      expect(pick.kcal, isNull);
      expect(_text(tester, 'today-pick-title'), 'Imported stew');
      expect(find.textContaining('g protein'), findsNothing);
      expect(find.byKey(const ValueKey('today-pick-leaves')), findsNothing);
      final before = store.mealsForFoodDate(designNow).length;

      await _tap(tester, 'today-pick');
      expect(find.byType(MealPlanScreen), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(ValueKey('meal-plan-eat-${plan.id}'))),
        isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
        reason: 'nothing loggable to eat',
      );
      expect(store.mealsForFoodDate(designNow), hasLength(before));
    });
  });

  testWidgets('"Open food log" switches to the Food tab on the shown day', (
    tester,
  ) async {
    await withClock(Clock.fixed(designNow), () async {
      final store = await pumpDesignToday(tester);
      await _tap(tester, 'today-day-2026-09-26');
      await _tap(tester, 'today-open-food-log');
      expect(store.selectedTab, 1);
      expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);
      expect(store.selectedFoodDate, DateTime(2026, 9, 26));
      // No sheet: the link opens the log, not the add flow.
      expect(find.byKey(const ValueKey('add-meal-sheet')), findsNothing);
    });
  });

  testWidgets('each slot\'s add button opens the add flow for THAT slot and '
      'the shown day', (tester) async {
    await withClock(Clock.fixed(designNow), () async {
      final store = await pumpDesignToday(tester);
      for (final day in <DateTime>[designNow, DateTime(2026, 9, 25)]) {
        for (final slot in MealSlot.values) {
          await _backToToday(tester);
          final key = 'today-day-2026-09-${day.day}';
          await _tap(tester, key);
          await _tap(tester, 'today-meal-add-${slot.name}');
          expect(store.selectedTab, 1, reason: '$day $slot');
          expect(find.byKey(const ValueKey('add-meal-sheet')), findsOneWidget);
          expect(
            tester.widget<MealSlotPicker>(find.byType(MealSlotPicker)).selected,
            slot,
            reason: 'the "+" of ${slot.name} preselects ${slot.name}',
          );
          expect(
            store.selectedFoodDate,
            DateTime(day.year, day.month, day.day),
          );
          await _tap(tester, 'add-meal-sheet-close');
        }
      }
    });
  });

  testWidgets('the steps row follows the step source; the credit reaches '
      'the calorie card', (tester) async {
    await withClock(Clock.fixed(designNow), () async {
      final health = DesignSteps();
      final store = await pumpDesignToday(tester, health: health);
      expect(_text(tester, 'today-steps-value'), '1,392');

      health.steps = 8400;
      await store.refreshHealthSteps();
      await tester.pumpAndSettle();
      final burned = store.burnedKcalForFoodDate(designNow);
      expect(burned, greaterThan(73));
      expect(_text(tester, 'today-steps-value'), '8,400');
      expect(_text(tester, 'today-steps-kcal'), '+${_fmt(burned)} kcal');
      expect(_text(tester, 'today-stat-burned'), '+${_fmt(burned)}');
      _expectDayNumbers(tester, store, designNow);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const ValueKey('today-steps-bar')),
            )
            .value,
        1.0,
      );
    });
  });

  testWidgets('the next-workout row names the plan\'s workout and switches '
      'to Training', (tester) async {
    await withClock(Clock.fixed(designNow), () async {
      final store = await pumpDesignToday(tester);
      final next = store.nextTrainingWorkoutForToday()!;
      expect(_text(tester, 'today-workout-title'), next.title);
      expect(
        _text(tester, 'today-workout-sub'),
        _en.todayWorkoutNext(next.estimatedMinutes),
      );

      await _tap(tester, 'today-workout-row');
      expect(store.selectedTab, 3);
      expect(find.byKey(const ValueKey('training-open-plans')), findsOneWidget);
    });
  });
}
