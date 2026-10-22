// The planner redesign of 2026-10-04: the week strip jumps to a day, an
// empty day is one "Plan a meal" row, a meal row names its kcal and turns
// its eaten toggle into the eaten state, and the empty shopping list plans a
// meal for the shown week. The receipt's rows, checks and pantry are pinned
// in meal_plan_weekly_receipt_test.dart.

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/shopping_receipt.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/harness.dart';

/// A Monday, so the shown week is Sep 7 to Sep 13.
final _today = DateTime(2026, 9, 7, 12);

HomeStore _store() {
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Fixture',
    emitSnack: h.SnackCapture().call,
  );
  addTearDown(store.dispose);
  return store;
}

Future<void> _pump(WidgetTester tester, HomeStore store) => pumpLocalized(
  tester,
  MealPlanScreen(store: store),
  locale: const Locale('en'),
  surfaceSize: const Size(393, 852),
  settle: true,
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder _key(String key) => find.byKey(ValueKey(key));

Finder get _editor => _key('meal-plan-editor-scroll');

/// Picks the first catalog recipe in the open editor and saves it.
Future<void> _saveFirstRecipe(WidgetTester tester) async {
  await _tap(
    tester,
    find.descendant(
      of: _editor,
      matching: find.text(recipeCatalogEn.first.title),
    ),
  );
  await _tap(tester, _key('meal-plan-save'));
}

void main() {
  setUp(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);

  testWidgets('the week strip jumps to the tapped day and marks today', (
    tester,
  ) async {
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      // Two meals on every day but Monday: a week taller than the screen.
      for (var day = 8; day <= 13; day++) {
        for (final slot in [MealSlot.lunch, MealSlot.dinner]) {
          await store.savePlannedMeal(
            PlannedMeal.create(
              recipe: recipeCatalogEn[day],
              day: DateTime(2026, 9, day),
              slot: slot,
            ),
          );
        }
      }
      await _pump(tester, store);
      expect(
        tester.getSemantics(_key('meal-plan-strip-2026-09-10')),
        isSemantics(
          isButton: true,
          isSelected: false,
          label: 'Thursday, September 10, 2 meals planned',
        ),
      );
      expect(
        tester.getSemantics(_key('meal-plan-strip-2026-09-07')),
        isSemantics(
          isButton: true,
          isSelected: true,
          label: 'Monday, September 7, Today, No meals yet',
        ),
      );
      final thursday = _key('meal-plan-day-2026-09-10');
      final list = tester.getRect(find.byType(Scrollable).first);
      expect(tester.getTopLeft(thursday).dy, greaterThan(list.bottom));

      await tester.tap(_key('meal-plan-strip-2026-09-10'));
      await tester.pumpAndSettle();
      // The day's section now starts at the top of the list.
      expect(tester.getTopLeft(thursday).dy, moreOrLessEquals(list.top));
      expect(
        tester.getRect(find.text('Thursday  Sep\u00A010')).top,
        lessThan(list.top + 60),
      );
      expect(store.plannedMeals, hasLength(12));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('an empty day is one "Plan a meal" row that plans that day', (
    tester,
  ) async {
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      await _pump(tester, store);
      final add = _key('meal-plan-add-2026-09-09');
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      // The row carries its words; no second control for the same day.
      expect(
        find.descendant(of: add, matching: find.text('Plan a meal')),
        findsOneWidget,
      );
      expect(_key('meal-plan-empty-2026-09-09'), findsNothing);
      expect(
        tester.getSemantics(add),
        isSemantics(
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          label: 'Plan a meal',
        ),
      );

      await _tap(tester, add);
      expect(_editor, findsOneWidget);
      // The picker names kcal and protein per serving.
      final first = recipeCatalogEn.first;
      expect(
        tester
            .widget<Text>(_key('meal-plan-pick-nutrition-${first.slug}'))
            .data,
        enL10n.recipesKcalProteinSummary(first.caloriesKcal, first.proteinG),
      );
      await _tap(
        tester,
        find.descendant(
          of: _editor,
          matching: find.text(recipeCatalogEn.first.title),
        ),
      );
      expect(
        find.descendant(
          of: _key('meal-plan-day'),
          matching: find.text(
            DateFormat.yMMMMEEEEd('en').format(DateTime(2026, 9, 9)),
          ),
        ),
        findsOneWidget,
      );
      await _tap(tester, _key('meal-plan-save'));
      expect(store.plannedMeals.single.day, '2026-09-09');
      // Now planned, the day offers its add button in the header instead.
      expect(
        find.descendant(
          of: _key('meal-plan-add-2026-09-09'),
          matching: find.text('Plan a meal'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('during the cold load every day keeps its add control', (
    tester,
  ) async {
    await withClock(Clock.fixed(_today), () async {
      final store = _store()..mealPlansLoading = true;
      await pumpLocalized(
        tester,
        MealPlanScreen(store: store),
        locale: const Locale('en'),
        surfaceSize: const Size(393, 852),
      );
      // The progress bar never settles.
      await tester.pump(const Duration(milliseconds: 300));
      // The outline still says the plans are on their way …
      expect(find.byType(SkeletonCard), findsWidgets);
      expect(find.text('Plan a meal'), findsNothing);
      // … and planning stays possible, from the day's header.
      final add = _key('meal-plan-add-2026-09-09');
      expect(add, findsOneWidget);
      expect(
        tester.getSemantics(add),
        isSemantics(
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          label: 'Plan a meal',
        ),
      );
      await tester.ensureVisible(add);
      await tester.pump(const Duration(milliseconds: 300));
      Future<void> tapAndWait(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(finder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
      }

      await tapAndWait(add);
      expect(_editor, findsOneWidget);
      // The plan is written while the load still runs, on that day.
      await tapAndWait(
        find.descendant(
          of: _editor,
          matching: find.text(recipeCatalogEn.first.title),
        ),
      );
      await tapAndWait(_key('meal-plan-save'));
      expect(store.plannedMeals.single.day, '2026-09-09');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a meal row shows the kcal the eaten toggle logs, then its '
      'eaten state', (tester) async {
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      final recipe = recipeCatalogEn[2];
      final plan = PlannedMeal.create(
        recipe: recipe,
        day: DateTime(2026, 9, 8),
        slot: MealSlot.lunch,
        servings: 2,
      );
      await store.savePlannedMeal(plan);
      final kcal = recipe.toMealResultForServings(2, enL10n).caloriesKcal;
      await _pump(tester, store);
      final meta = [
        'Lunch',
        '2 servings',
        '${NumberFormat.decimalPattern('en').format(kcal)} kcal',
      ].map((part) => part.replaceAll(' ', '\u00A0')).join(' · ');
      expect(find.text(meta), findsOneWidget);
      expect(find.text('1 meal planned'), findsOneWidget);

      final eat = _key('meal-plan-eat-${plan.id}');
      expect(
        tester.getSemantics(eat),
        isSemantics(
          isButton: true,
          hasCheckedState: true,
          isChecked: false,
          hasEnabledState: true,
          isEnabled: true,
          label: 'Mark as eaten today',
        ),
      );
      await _tap(tester, eat);

      // Logged once, with the planned portion, on today's diary day.
      expect(store.loggedMeals, hasLength(1));
      expect(store.loggedMeals.single.id, plan.id);
      expect(store.loggedMeals.single.result.caloriesKcal, kcal);
      expect(store.loggedMeals.single.effectiveLocalDay, '2026-09-07');
      expect(eat, findsNothing);
      final eaten = _key('meal-plan-eaten-${plan.id}');
      expect(
        tester.getSemantics(eaten),
        isSemantics(
          hasCheckedState: true,
          isChecked: true,
          hasEnabledState: true,
          isEnabled: false,
          label: 'Logged on Sep 7',
        ),
      );
      expect(find.text('Logged on Sep 7'), findsOneWidget);
      expect(_key('meal-plan-menu-${plan.id}'), findsNothing);
      await tester.scrollUntilVisible(
        _key('meal-plan-week-summary'),
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('1 meal planned · 1 eaten'), findsOneWidget);

      // The eaten state takes no second tap.
      await tester.tap(eaten);
      await tester.pumpAndSettle();
      expect(store.loggedMeals, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a meal row opens its recipe read-only, with the ingredients '
      'for the planned servings', (tester) async {
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      final catalog = recipeCatalogEn[2];
      final cases = [
        // A per-serving import converts every line.
        (
          recipe: recipeCatalogEn.first.copyWith(
            slug: 'user_import_rice_bowl',
            title: 'Rice bowl',
            ingredients: '- 100 g rice\n- 2 eggs',
            categories: ['Eigene', '${recipeIngredientsBasisPrefix}per_serving'],
          ),
          lines: ['200 g rice', '4 eggs'],
          hint: enL10n.recipeIngredientsForServings('2'),
          header: enL10n.recipesOwnTitle,
        ),
        // A catalog text with lines that cannot convert stays as written,
        // and says for how many it is.
        (
          recipe: catalog,
          lines: [catalog.ingredients.split('\n').first.substring(2)],
          hint: enL10n.recipeIngredientsPlannedPerServing('2'),
          header: enL10n.recipesBrandTitle,
        ),
        // One whose every line converts is written for one serving.
        (
          recipe: recipeCatalogEn.firstWhere(
            (r) => r.slug == 'skyr_bowl_mit_beeren_and_granola',
          ),
          lines: ['500 g plain skyr', '2 tsp honey'],
          hint: enL10n.recipeIngredientsForServings('2'),
          header: enL10n.recipesBrandTitle,
        ),
        // An own recipe's text has no confirmed basis: as written.
        (
          recipe: recipeCatalogEn.first.copyWith(
            slug: 'user_rice_bowl',
            title: 'My rice bowl',
            ingredients: '- 100 g rice',
          ),
          lines: ['100 g rice'],
          hint: enL10n.recipeIngredientsOriginalUnknown,
          header: enL10n.recipesOwnTitle,
        ),
      ];
      final plans = [
        for (final (i, c) in cases.indexed)
          PlannedMeal.create(
            recipe: c.recipe,
            day: DateTime(2026, 9, 8 + i),
            slot: MealSlot.lunch,
            servings: 2,
          ),
      ];
      for (final plan in plans) {
        await store.savePlannedMeal(plan);
      }
      await _pump(tester, store);
      for (final (i, c) in cases.indexed) {
        await _tap(tester, _key('meal-plan-open-${plans[i].id}'));
        expect(find.byType(RecipeDetailScreen), findsOneWidget);
        // Read-only: a plan is eaten through the plan, never from here.
        expect(_key('recipe-add-card'), findsNothing);
        expect(find.text(c.header), findsOneWidget, reason: c.recipe.slug);
        expect(find.text(c.hint), findsOneWidget, reason: c.recipe.slug);
        for (final line in c.lines) {
          expect(find.text(line), findsOneWidget, reason: c.recipe.slug);
        }
        await _tap(tester, _key('recipe-detail-back'));
      }
      expect(store.loggedMeals, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a past day\'s meal asks for the diary day, the planned day '
      'first', (tester) async {
    // A Wednesday: Monday and Tuesday of the shown week are past.
    final wednesday = DateTime(2026, 9, 9, 12);
    await withClock(Clock.fixed(wednesday), () async {
      final store = _store();
      final monday = PlannedMeal.create(
        recipe: recipeCatalogEn[2],
        day: DateTime(2026, 9, 7),
        slot: MealSlot.dinner,
      );
      final tuesday = PlannedMeal.create(
        recipe: recipeCatalogEn[3],
        day: DateTime(2026, 9, 8),
        slot: MealSlot.dinner,
      );
      await store.savePlannedMeal(monday);
      await store.savePlannedMeal(tuesday);
      await _pump(tester, store);
      expect(
        tester.getSemantics(_key('meal-plan-eat-${monday.id}')),
        isSemantics(
          isButton: true,
          hasCheckedState: true,
          hasEnabledState: true,
          isEnabled: true,
          label: 'Mark as eaten',
        ),
      );

      await _tap(tester, _key('meal-plan-eat-${monday.id}'));
      final planned = _key('meal-plan-eat-planned-day');
      final today = _key('meal-plan-eat-today');
      expect(
        tester.getTopLeft(planned).dy,
        lessThan(tester.getTopLeft(today).dy),
      );
      await _tap(tester, planned);
      expect(store.loggedMeals.single.effectiveLocalDay, '2026-09-07');
      expect(store.loggedMeals.single.loggedAt.hour, 12);
      expect(find.text('Logged on Sep 7'), findsOneWidget);
      // A back-fill two days back does not continue a streak.
      expect(store.loggingStreak, 0);

      // A dismissal logs nothing; the second choice logs today.
      await _tap(tester, _key('meal-plan-eat-${tuesday.id}'));
      await _tap(tester, _key('meal-plan-eat-cancel'));
      expect(store.loggedMeals, hasLength(1));
      await _tap(tester, _key('meal-plan-eat-${tuesday.id}'));
      await _tap(tester, today);
      expect(
        store.loggedMeals.map((m) => m.effectiveLocalDay),
        containsAll(['2026-09-07', '2026-09-09']),
      );
      expect(find.text('Logged on Sep 9'), findsOneWidget);
      expect(store.loggingStreak, 1);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('the empty shopping list plans a meal in the shown week', (
    tester,
  ) async {
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      await _pump(tester, store);
      await _tap(tester, _key('meal-plan-tab-shopping'));
      expect(_key('shopping-summary'), findsOneWidget);
      expect(find.text('Nothing to buy yet'), findsOneWidget);

      // This week: today.
      await _tap(tester, _key('shopping-empty-plan'));
      await _saveFirstRecipe(tester);
      expect(store.plannedMeals.single.day, '2026-09-07');
      expect(_key('shopping-empty-plan'), findsNothing);
      final (:done, :total) = buildShoppingReceipt(
        store.plannedMeals,
        _today,
        l10n: enL10n,
      ).progress(store.shoppingChecks);
      expect(
        tester.widget<Text>(_key('shopping-progress-label')).data,
        '$done of $total checked off',
      );
      expect(total, greaterThan(1));

      // Next week: its Monday.
      await _tap(tester, _key('meal-plan-next-week'));
      await _tap(tester, _key('shopping-empty-plan'));
      await _saveFirstRecipe(tester);
      expect(
        store.plannedMeals.map((p) => p.day),
        containsAll(['2026-09-07', '2026-09-14']),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
