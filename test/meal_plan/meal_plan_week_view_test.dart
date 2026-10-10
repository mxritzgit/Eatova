// The planner redesign of 2026-10-04: the week strip jumps to a day, an
// empty day is one "Plan a meal" row, a meal row names its kcal and turns
// its eaten toggle into the eaten state, free-text ingredients lose their
// list markers, and the empty shopping list plans a meal for the shown week.
// Since the receipt (2026-10-10) every free-text line is checked on its own.

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/shopping_list.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
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

  testWidgets('free-text ingredients are listed without list markers and '
      'each line is checked on its own', (tester) async {
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      final recipe = recipeCatalogEn.first.copyWith(
        title: 'Beef bowl',
        ingredients: '- 200 g beef\n• 1 onion\n\n* Salt',
        structuredIngredients: const [],
      );
      await store.savePlannedMeal(
        PlannedMeal.create(recipe: recipe, day: _today, slot: MealSlot.dinner),
      );
      final item = buildShoppingList(store.plannedMeals, _today).single;
      final [beef, onion, salt] = item.lines;
      await _pump(tester, store);
      await _tap(tester, _key('meal-plan-tab-shopping'));

      for (final text in ['Beef', '200 g', 'Onion', '1', 'Salt']) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      expect(find.textContaining('- 200'), findsNothing);
      expect(find.textContaining('•'), findsNothing);

      // One tap checks one ingredient, nothing else.
      final saltRow = _key('shopping-item-${salt.id}');
      await _tap(tester, saltRow);
      expect(store.shoppingChecks, {salt.id: true});
      expect(
        tester.getSemantics(saltRow),
        isSemantics(hasCheckedState: true, isChecked: true, label: 'Salt'),
      );
      expect(
        tester.getSemantics(_key('shopping-item-${beef.id}')),
        isSemantics(
          hasCheckedState: true,
          isChecked: false,
          label: 'Beef\n200 g',
        ),
      );
      expect(find.text('1 of 3 checked off'), findsOneWidget);
      expect(_key('shopping-receipt-stamp'), findsNothing);

      await _tap(tester, _key('shopping-item-${beef.id}'));
      await _tap(tester, _key('shopping-item-${onion.id}'));
      expect(find.text('All shopping done'), findsOneWidget);
      expect(_key('shopping-receipt-stamp'), findsOneWidget);

      // Unchecking one line reopens the list.
      await _tap(tester, _key('shopping-item-${onion.id}'));
      expect(store.shoppingChecks[onion.id], isFalse);
      expect(store.shoppingChecks[beef.id], isTrue);
      expect(find.text('2 of 3 checked off'), findsOneWidget);
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
      final items = buildShoppingList(store.plannedMeals, _today);
      final (:done, :total) = shoppingProgress(items, store.shoppingChecks);
      expect(find.text('$done of $total checked off'), findsOneWidget);
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
