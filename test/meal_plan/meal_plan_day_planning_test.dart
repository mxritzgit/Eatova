// Review 2026-10-19, "Speiseplan als Tagesplanung": every planned day names
// its kcal against the day's goal, and a recipe detail plans the recipe
// through the planner's own editor. Ticking a past or future entry is
// unchanged (owner decision pending).

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
  )..profile = const UserProfile(dailyKcalGoal: 2100);
  addTearDown(store.dispose);
  return store;
}

FitnessRecipe _catalog(String slug) =>
    recipeCatalogEn.firstWhere((r) => r.slug == slug);

/// An imported recipe whose nutrition is still missing: not loggable.
const _pending = FitnessRecipe(
  slug: 'user_import_pending',
  title: 'Imported soup',
  description: '',
  portion: '',
  ingredients: 'Water',
  preparation: '',
  professionalHint: '',
  imageAsset: '',
  caloriesKcal: 0,
  proteinG: 0,
  carbsG: 0,
  fatG: 0,
  estimatedGrams: 0,
  categories: ['Eigene', recipeNutritionPendingCategory],
  userCreated: true,
);

Future<void> _plan(
  HomeStore store,
  FitnessRecipe recipe,
  int day,
  MealSlot slot, {
  double servings = 1,
}) => store.savePlannedMeal(
  PlannedMeal.create(
    recipe: recipe,
    day: DateTime(2026, 9, day),
    slot: slot,
    servings: servings,
  ),
);

Finder _kcal(String day) => find.byKey(ValueKey('meal-plan-day-kcal-$day'));

String _text(WidgetTester tester, Finder finder) =>
    tester.widget<Text>(finder).data!;

void main() {
  testWidgets('jeder geplante Tag nennt seine kcal gegen das Tagesziel', (
    tester,
  ) async {
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      // Tuesday: 500 + 2 x 640.
      await _plan(
        store,
        _catalog('protein_pancakes_mit_beeren'),
        8,
        MealSlot.breakfast,
      );
      await _plan(
        store,
        _catalog('lachs_mit_sukartoffel_and_spargel'),
        8,
        MealSlot.dinner,
        servings: 2,
      );
      // Wednesday: 610 plus one meal that cannot be logged.
      await _plan(
        store,
        _catalog('putensteak_mit_quinoa_and_ofengemuse'),
        9,
        MealSlot.lunch,
      );
      await _plan(store, _pending, 9, MealSlot.dinner);
      await pumpLocalized(
        tester,
        MealPlanScreen(store: store),
        locale: const Locale('en'),
        surfaceSize: const Size(393, 852),
      );

      expect(_kcal('2026-09-07'), findsNothing, reason: 'empty day');
      await tester.ensureVisible(_kcal('2026-09-08'));
      expect(_text(tester, _kcal('2026-09-08')), '1,780 of 2,100 kcal planned');
      await tester.ensureVisible(_kcal('2026-09-09'));
      expect(
        _text(tester, _kcal('2026-09-09')),
        '610 of 2,100 kcal planned · 1 meal without kcal',
      );

      // An eaten meal still counts: it is part of the day.
      final pancakes = store.plannedMeals.firstWhere(
        (p) => p.recipe.slug == 'protein_pancakes_mit_beeren',
      );
      await store.eatPlannedMeal(pancakes.id);
      await tester.pumpAndSettle();
      expect(_text(tester, _kcal('2026-09-08')), '1,780 of 2,100 kcal planned');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('die Tageszeile bleibt bei 320 px und doppelter Schrift lesbar', (
    tester,
  ) async {
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      await _plan(
        store,
        _catalog('putensteak_mit_quinoa_and_ofengemuse'),
        7,
        MealSlot.lunch,
      );
      await _plan(store, _pending, 7, MealSlot.dinner);
      await pumpLocalized(
        tester,
        MealPlanScreen(store: store),
        surfaceSize: const Size(320, 640),
        textScale: 2,
      );
      final line = _kcal('2026-09-07');
      await tester.scrollUntilVisible(line, 200);
      await tester.pumpAndSettle();
      expect(
        _text(tester, line),
        '610 von 2.100 kcal geplant · 1 Mahlzeit ohne kcal',
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('„Zum Speiseplan" öffnet den Editor mit dem Rezept, der Tag kommt '
      'aus dem Kalender, gespeichert '
      'wird erst beim Speichern', (tester) async {
    await withClock(Clock.fixed(_today), () async {
      final store = _store();
      final skyr = recipeCatalogDe.firstWhere(
        (r) => r.slug == 'skyr_bowl_mit_beeren_and_granola',
      );
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => MealPlanScreen.planRecipe(context, store, skyr),
            child: const Text('plan'),
          ),
        ),
        surfaceSize: const Size(393, 852),
      );
      await tester.tap(find.text('plan'));
      await tester.pumpAndSettle();

      final editor = find.byKey(const ValueKey('meal-plan-editor-scroll'));
      expect(
        find.descendant(of: editor, matching: find.text(skyr.title)),
        findsOneWidget,
      );
      // Straight to the details: no recipe search, the recipe changeable.
      expect(find.byType(TextField), findsOneWidget, reason: 'servings only');
      expect(
        find.byKey(const ValueKey('meal-plan-editor-change')),
        findsOneWidget,
      );
      expect(store.plannedMeals, isEmpty);

      // The day comes from the app's calendar sheet.
      await tester.ensureVisible(find.byKey(const ValueKey('meal-plan-day')));
      await tester.tap(find.byKey(const ValueKey('meal-plan-day')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('food-date-day-2026-9-9')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('food-date-confirm')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const ValueKey('meal-plan-save')));
      await tester.tap(find.byKey(const ValueKey('meal-plan-save')));
      await tester.pumpAndSettle();
      final plan = store.plannedMeals.single;
      expect(plan.recipe.slug, skyr.slug);
      expect(plan.day, '2026-09-09');
      // A breakfast dish starts on breakfast.
      expect(plan.slot, MealSlot.breakfast);
      expect(plan.isEaten, isFalse, reason: 'planning logs nothing');
    });
  });

  testWidgets('die Rezeptdetails zeigen „Zum Speiseplan" nur mit Planer', (
    tester,
  ) async {
    final planned = <String>[];
    final lachs = recipeCatalogDe[1];
    await pumpLocalized(
      tester,
      RecipesScreen(
        onAddMeal: (MealAnalysisResult _, MealSlot __) {},
        onPlanRecipe: (context, recipe) async => planned.add(recipe.slug),
      ),
      surfaceSize: const Size(1400, 3000),
    );
    await tester.tap(find.byKey(const ValueKey('recipes-tab-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('recipe-tile-${lachs.slug}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recipe-detail-plan')));
    await tester.pumpAndSettle();
    expect(planned, [lachs.slug]);
    expect(find.text('Zum Speiseplan'), findsOneWidget);

    // A fresh tree: the pushed detail above would otherwise stay.
    await tester.pumpWidget(const SizedBox());
    await pumpLocalized(
      tester,
      RecipeDetailScreen(recipe: lachs, onAddMeal: (_, _) {}),
    );
    expect(find.byKey(const ValueKey('recipe-detail-plan')), findsNothing);
  });
}
