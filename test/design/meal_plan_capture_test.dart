// Visual evidence for the meal plan and recipe history in the dark redesign
// (2026-10-03, planner redesign 2026-10-04): the plan editor (choosing a
// recipe, then its day, slot and servings), the calendar it opens, the week
// card with its day strip, planned, eaten and empty days, a jump from the
// strip, the meal menu, the shopping list (filled and empty), and the recipe
// history with its restore dialog. The receipt (2026-10-10) also renders a
// German import with section labels and its done stamp.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/meal-plan-*.png; without it the suite still checks that
// every surface renders without an exception or overflow, also at 320 px
// with 2x text.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/shopping_list.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/screens/recipes/recipe_history_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/services/user_recipe_reads.dart';
import 'package:eatova/src/widgets/kcal/food_date_picker.dart';

import '../outbox/outbox_test_helpers.dart' as h;
import '../support/design_capture.dart';
import '../support/harness.dart';

/// Monday, so the shown week starts today.
final _now = DateTime(2026, 9, 28, 18, 30);

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

FitnessRecipe get _bowl => recipeCatalogEn.first.copyWith(
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
    RecipeIngredient(
      name: 'Chicken breast',
      grams: 180,
      source: IngredientSource.manual,
      per100g: const RecipeNutrition(
        caloriesKcal: 110,
        proteinG: 23,
        carbsG: 0,
        fatG: 1.5,
      ),
    ),
  ],
);

/// A free-text recipe as an import brings it: section labels, fractions and
/// lines without an amount.
FitnessRecipe get _pizza => recipeCatalogDe.first.copyWith(
  title: 'High-Protein Körniger-Frischkäse-Pizza',
  ingredients:
      'Für den Pizzaboden:\n• 200 g körniger Frischkäse\n• 2 Eier\n'
      '• 3 EL Weizenmehl\n• 1½ EL Backpulver\n• Etwas Salz\nBelag:\n'
      '• 3 EL Tomatensoße\n• ½ weiße Zwiebel\n'
      '• 1 Dose Thunfisch im eigenen Saft\n• 20 g Mais\n'
      '• 25 g geriebener Light-Käse',
  structuredIngredients: const [],
);

/// Pins the reference phone, or a 320 px wide one for the narrow checks.
void _viewport(WidgetTester tester, {bool narrow = false}) {
  pinDesignViewport(tester);
  if (narrow) {
    tester.view.physicalSize = const Size(320, 844) * kDesignPixelRatio;
  }
}

/// Mounts the planner; with [withPlans] an eaten breakfast and lunch today,
/// and dinner tomorrow.
Future<HomeStore> _pumpPlan(
  WidgetTester tester, {
  bool narrow = false,
  double textScale = 1,
  bool withPlans = true,
}) async {
  _viewport(tester, narrow: narrow);
  final store = _store();
  if (withPlans) {
    final breakfast = PlannedMeal.create(
      recipe: recipeCatalogEn[11],
      day: _now,
      slot: MealSlot.breakfast,
    );
    await store.savePlannedMeal(breakfast);
    await store.eatPlannedMeal(breakfast.id);
    await store.savePlannedMeal(
      PlannedMeal.create(recipe: _bowl, day: _now, slot: MealSlot.lunch),
    );
    await store.savePlannedMeal(
      PlannedMeal.create(
        recipe: recipeCatalogEn[3],
        day: _now.add(const Duration(days: 1)),
        slot: MealSlot.dinner,
        servings: 2,
      ),
    );
  }
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        MealPlanScreen(store: store),
        locale: const Locale('en'),
        textScale: textScale,
        safeArea: false,
        scaffold: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await precacheDesignImages(tester);
  return store;
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder _key(String key) => find.byKey(ValueKey(key));

/// The editor's own scroll view (the week list sits behind the sheet).
Finder get _editorScroll => find
    .descendant(
      of: _key('meal-plan-editor-scroll'),
      matching: find.byType(Scrollable),
    )
    .first;

/// Opens the editor for today and picks the first catalog recipe.
Future<void> _openFilledEditor(WidgetTester tester) async {
  final add = _key('meal-plan-add-2026-09-28');
  await tester.scrollUntilVisible(add, 200, scrollable: designMainScrollable());
  await _tapVisible(tester, add);
  // The week behind the sheet may show the same recipe.
  await _tapVisible(
    tester,
    find.descendant(
      of: _key('meal-plan-editor-scroll'),
      matching: find.text(recipeCatalogEn.first.title),
    ),
  );
  await precacheDesignImages(tester);
}

final _restorable = FitnessRecipe.fromRow({
  'slug': 'user_bowl',
  'title': 'Green power bowl',
  'ingredients': '150 g rice\n180 g chicken breast\n1 handful spinach',
  'preparation':
      'Cook the rice. Sear the chicken, slice it and serve both '
      'over the spinach.',
  'estimated_g': 420,
  'calories_kcal': 610,
});

RecipeHistoryPage _history() => RecipeHistoryPage(
  versions: [
    RecipeVersion(
      recipe: _restorable,
      revision: 4,
      deleted: false,
      recordedAt: DateTime.utc(2026, 9, 27, 17, 12),
    ),
    RecipeVersion(
      recipe: _restorable,
      revision: 3,
      deleted: true,
      recordedAt: DateTime.utc(2026, 9, 20, 9, 5),
    ),
  ],
  currentRevision: 5,
  currentDeleted: false,
  nextBefore: 3,
);

Future<void> _pumpHistory(
  WidgetTester tester, {
  bool narrow = false,
  double textScale = 1,
}) async {
  _viewport(tester, narrow: narrow);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        RecipeHistoryScreen(
          loadHistory: ({slug, beforeRevision}) async => _history(),
          restoreVersion: (recipe, {required expectedRevision}) async =>
              SyncDelivery.delivered,
          isSessionCurrent: () => true,
        ),
        locale: const Locale('en'),
        textScale: textScale,
        safeArea: false,
        scaffold: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Expands version 4 and opens its restore dialog.
Future<void> _openRestoreDialog(WidgetTester tester, String prefix) async {
  await _tapVisible(tester, _key('recipe-history-version-4'));
  expect(_key('recipe-history-restore-4'), findsOneWidget);
  expect(tester.takeException(), isNull);
  await captureDesignShot(tester, '$prefix-01');
  // The restore keeps a progress indicator spinning behind the dialog, so
  // this cannot settle.
  final restore = _key('recipe-history-restore-4');
  await tester.ensureVisible(restore);
  await tester.pumpAndSettle();
  await tester.tap(restore);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(_key('recipe-history-confirm'), findsOneWidget);
  expect(tester.takeException(), isNull);
  await captureDesignShot(tester, '$prefix-dialog');
}

void main() {
  setUpAll(loadDesignFonts);

  testWidgets('meal plan week, menu and shopping list', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final store = await _pumpPlan(tester);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-week-00');
      await scrollDesignTabBy(tester, 600);
      await captureDesignShot(tester, 'meal-plan-week-01');
      await scrollDesignTabBy(tester, -2000);

      // The strip jumps to Sunday.
      await tester.tap(_key('meal-plan-strip-2026-10-04'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-week-jump');
      await scrollDesignTabBy(tester, -3000);

      final lunch = store.plannedMeals.firstWhere(
        (p) => p.slot == MealSlot.lunch,
      );
      await _tapVisible(tester, _key('meal-plan-menu-${lunch.id}'));
      expect(find.text('Edit planned meal'), findsOneWidget);
      await captureDesignShot(tester, 'meal-plan-week-menu');
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      await scrollDesignTabBy(tester, -3000);

      await _tapVisible(tester, _key('meal-plan-tab-shopping'));
      await precacheDesignImages(tester);
      await captureDesignShot(tester, 'meal-plan-shopping-00');
      await scrollDesignTabBy(tester, 240);
      final first = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('shopping-item-'),
      );
      await _tapVisible(tester, first.first);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-shopping');
    });
  });

  testWidgets('German receipt with sections, ticked off to its stamp', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      _viewport(tester);
      final store = _store();
      await store.savePlannedMeal(
        PlannedMeal.create(recipe: _pizza, day: _now, slot: MealSlot.dinner),
      );
      await store.savePlannedMeal(
        PlannedMeal.create(
          recipe: _bowl,
          day: _now.add(const Duration(days: 2)),
          slot: MealSlot.lunch,
        ),
      );
      await tester.pumpWidget(
        designCaptureBoundary(
          localizedApp(
            MealPlanScreen(store: store),
            locale: const Locale('de'),
            safeArea: false,
            scaffold: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _tapVisible(tester, _key('meal-plan-tab-shopping'));
      expect(find.text('FÜR DEN PIZZABODEN:'), findsOneWidget);
      expect(find.text('1 1/2 EL'), findsOneWidget);
      expect(find.text('Thunfisch im eigenen Saft'), findsOneWidget);
      await scrollDesignTabBy(tester, 420);
      await captureDesignShot(tester, 'meal-plan-shopping-receipt-de');

      final items = buildShoppingList(store.plannedMeals, _now);
      for (final item in items) {
        if (item.grams != null) {
          await store.setShoppingChecked(
            ShoppingCheck(id: item.id, checked: true),
          );
        }
        for (final line in item.lines.where((l) => !l.heading)) {
          await store.setShoppingChecked(
            ShoppingCheck(id: line.id, checked: true),
          );
        }
      }
      await tester.pumpAndSettle();
      expect(_key('shopping-receipt-stamp'), findsOneWidget);
      await scrollDesignTabBy(tester, 3000);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-shopping-receipt-done');
    });
  });

  testWidgets('empty shopping list', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _pumpPlan(tester, withPlans: false);
      await _tapVisible(tester, _key('meal-plan-tab-shopping'));
      expect(_key('shopping-empty-plan'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-shopping-empty');
    });
  });

  testWidgets('meal plan editor, empty, filled and its calendar', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      await _pumpPlan(tester, withPlans: false);
      await _tapVisible(tester, _key('meal-plan-add-2026-09-28'));
      await precacheDesignImages(tester);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-editor-empty');

      await _tapVisible(tester, find.text(recipeCatalogEn.first.title));
      await precacheDesignImages(tester);
      expect(_key('meal-plan-slot-group'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-editor-filled');
      await scrollDesignTabBy(tester, 600, scrollable: _editorScroll);
      await captureDesignShot(tester, 'meal-plan-editor-filled-01');

      await _tapVisible(tester, _key('meal-plan-day'));
      expect(find.byType(FoodDatePicker), findsOneWidget);
      expect(find.text('Plan for this day'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-editor-calendar');
    });
  });

  testWidgets('recipe history and its restore dialog', (tester) async {
    await _pumpHistory(tester);
    await captureDesignShot(tester, 'meal-plan-history-00');
    await _openRestoreDialog(tester, 'meal-plan-history');
  });

  testWidgets('320 px with 2x text', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _pumpPlan(tester, narrow: true, textScale: 2);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-narrow-week');
      await scrollDesignTabBy(tester, 900);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-narrow-week-01');
      await scrollDesignTabBy(tester, -3000);

      await _tapVisible(tester, _key('meal-plan-tab-shopping'));
      await precacheDesignImages(tester);
      await scrollDesignTabBy(tester, 700);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-narrow-shopping');
      await scrollDesignTabBy(tester, -3000);
      await _tapVisible(tester, _key('meal-plan-tab-week'));

      await _openFilledEditor(tester);
      expect(tester.takeException(), isNull);
      await scrollDesignTabBy(tester, 420, scrollable: _editorScroll);
      await captureDesignShot(tester, 'meal-plan-narrow-editor');
      await scrollDesignTabBy(tester, 3000, scrollable: _editorScroll);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-narrow-editor-01');
    });
  });

  testWidgets('320 px with 2x text, recipe history', (tester) async {
    await _pumpHistory(tester, narrow: true, textScale: 2);
    expect(tester.takeException(), isNull);
    await captureDesignShot(tester, 'meal-plan-narrow-history-00');
    await _openRestoreDialog(tester, 'meal-plan-narrow-history');
  });
}
