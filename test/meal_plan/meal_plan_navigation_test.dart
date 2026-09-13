import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/shopping_list.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/harness.dart';

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

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);

  testWidgets(
    'choosing a recipe after scrolling opens the editor from the top',
    (tester) async {
      await withClock(Clock.fixed(_today), () async {
        final store = _store();
        await pumpLocalized(
          tester,
          MealPlanScreen(store: store),
          locale: const Locale('en'),
          surfaceSize: const Size(320, 852),
          textScale: 2,
          settle: true,
        );
        final add = find.byKey(const ValueKey('meal-plan-add-2026-09-07'));
        await tester.scrollUntilVisible(
          add,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await _tap(tester, add);
        final choice = find.text(recipeCatalogEn[5].title);
        await _tap(tester, choice);
        final editor = find.byKey(const ValueKey('meal-plan-editor-scroll'));
        expect(
          tester.widget<SingleChildScrollView>(editor).controller!.offset,
          0,
        );
        final title = find.descendant(
          of: editor,
          matching: find.text('Plan a meal'),
        );
        expect(title.hitTestable(), findsOneWidget);
        expect(store.plannedMeals, isEmpty);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'shopping progress follows checks and keeps them when changing weeks',
    (tester) async {
      await withClock(Clock.fixed(_today), () async {
        final store = _store();
        final recipe = recipeCatalogEn.first.copyWith(
          ingredients: '',
          structuredIngredients: [
            RecipeIngredient(
              name: 'Rice',
              grams: 150,
              source: IngredientSource.manual,
              per100g: const RecipeNutrition(
                caloriesKcal: 350,
                proteinG: 8,
                carbsG: 75,
                fatG: 1,
              ),
            ),
          ],
        );
        await store.savePlannedMeal(
          PlannedMeal.create(recipe: recipe, day: _today, slot: MealSlot.lunch),
        );
        final item = buildShoppingList(store.plannedMeals, _today).single;
        await pumpLocalized(
          tester,
          MealPlanScreen(store: store),
          locale: const Locale('en'),
          surfaceSize: const Size(393, 852),
          settle: true,
        );
        await _tap(
          tester,
          find.byKey(const ValueKey('meal-plan-tab-shopping')),
        );
        final row = find.byKey(ValueKey('shopping-item-${item.id}'));
        await _tap(tester, row);
        expect(store.shoppingChecks[item.id], isTrue);
        expect(tester.widget<CheckboxListTile>(row).value, isTrue);
        expect(find.text('All shopping done'), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('meal-plan-next-week')));
        expect(row, findsNothing);
        await _tap(
          tester,
          find.byKey(const ValueKey('meal-plan-previous-week')),
        );
        expect(tester.widget<CheckboxListTile>(row).value, isTrue);
        await _tap(tester, row);
        expect(store.shoppingChecks[item.id], isFalse);
        expect(find.text('All shopping done'), findsNothing);
        expect(store.loggedMeals, isEmpty);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets('meal menu edits portions and deletes the same planned meal', (
    tester,
  ) async {
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      final plan = PlannedMeal.create(
        recipe: recipeCatalogEn.first,
        day: _today,
        slot: MealSlot.lunch,
      );
      await store.savePlannedMeal(plan);
      await pumpLocalized(
        tester,
        MealPlanScreen(store: store),
        locale: const Locale('en'),
        surfaceSize: const Size(393, 852),
        settle: true,
      );
      final menu = find.byKey(ValueKey('meal-plan-menu-${plan.id}'));
      await _tap(tester, menu);
      await _tap(tester, find.text('Edit planned meal'));
      final portions = find.byKey(const ValueKey('meal-plan-servings'));
      await tester.ensureVisible(portions);
      await tester.enterText(portions, '2');
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const ValueKey('meal-plan-save')));
      expect(store.plannedMeals.single.id, plan.id);
      expect(store.plannedMeals.single.servings, 2);
      expect(store.plannedMeals.single.recipe.title, plan.recipe.title);
      await _tap(tester, menu);
      await _tap(tester, find.text('Delete'));
      expect(store.plannedMeals, isEmpty);
      expect(store.loggedMeals, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}
