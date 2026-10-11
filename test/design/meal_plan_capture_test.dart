// Visual evidence for the meal plan and recipe history in the dark redesign
// (2026-10-03, planner redesign 2026-10-04): the plan editor (choosing a
// recipe, then its day, slot and servings), the calendar it opens, the week
// card with its day strip, planned, eaten and empty days, a jump from the
// strip, the meal menu and its remove decision card (2026-10-11), the
// shopping list (filled and empty), and the recipe
// history with its restore dialog. The receipt (2026-10-10) also renders a
// German week and its done stamp.
// Own recipes without a photo (2026-10-11) show the glowing recipe art in
// the week rows, the editor's list and its chosen card (meal-plan-art-*).
// The weekly receipt (2026-10-11) merges the same ingredient from several
// meals into one row with a detail line of days, marks an amount it could
// not convert, names a recipe without ingredients, and gathers spices and
// staples in "Gewürze & Vorrat", collapsed and expanded
// (meal-plan-shopping-receipt-de*, meal-plan-shopping-pantry-*,
// meal-plan-narrow-receipt-*).
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/meal-plan-*.png; without it the suite still checks that
// every surface renders without an exception or overflow, also at 320 px
// with 2x text.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/shopping_receipt.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/screens/recipes/recipe_history_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/services/user_recipe_reads.dart';
import 'package:eatova/src/widgets/design/states.dart';
import 'package:eatova/src/widgets/kcal/food_date_picker.dart';
import 'package:eatova/src/widgets/recipes/recipe_photo.dart';

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

/// An own recipe planned twice: its chicken merges with the bowl's.
FitnessRecipe get _chicken => recipeCatalogDe.first.copyWith(
  slug: 'user_chicken_broccoli',
  title: 'Hähnchen mit Brokkoli',
  ingredients:
      '180 g Hähnchenbrustfilet\n1 Zwiebel\n2 Knoblauchzehen\n'
      '1 TL Paprikapulver, edelsüß\nSalz, Pfeffer\n1 EL Olivenöl\n'
      '250 g Brokkoli',
  structuredIngredients: const [],
);

/// An import for four, planned for two: its leek ("2 Stangen") cannot be
/// converted and keeps the recipe's amount.
FitnessRecipe get _soup => recipeCatalogDe.first.copyWith(
  slug: 'user_import_soup',
  title: 'Kartoffel-Lauch-Suppe',
  ingredients:
      '2 Stangen Lauch\n800 g Kartoffeln\n1 Zwiebel\n1 l Gemüsebrühe\n'
      'Öl zum Braten',
  structuredIngredients: const [],
  categories: ['Eigene', '${recipeIngredientsBasisPrefix}per_recipe'],
  batchServings: 4,
);

/// A recipe without an ingredient list.
FitnessRecipe get _leftovers => recipeCatalogDe.first.copyWith(
  slug: 'user_leftovers',
  title: 'Resteessen',
  ingredients: '',
  structuredIngredients: const [],
);

/// The German week of the weekly receipt: Monday's pizza, chicken on Tuesday
/// and Thursday, the soup for two on Wednesday, the bowl on Thursday and
/// leftovers on Friday.
Future<void> _seedGermanWeek(HomeStore store) async {
  for (final (recipe, day, slot, servings) in [
    (_pizza, 0, MealSlot.dinner, 1.0),
    (_chicken, 1, MealSlot.lunch, 1.0),
    (_soup, 2, MealSlot.dinner, 2.0),
    (_bowl, 3, MealSlot.lunch, 1.0),
    (_chicken, 3, MealSlot.dinner, 1.0),
    (_leftovers, 4, MealSlot.dinner, 1.0),
  ]) {
    await store.savePlannedMeal(
      PlannedMeal.create(
        recipe: recipe,
        day: _now.add(Duration(days: day)),
        slot: slot,
        servings: servings,
      ),
    );
  }
}

/// Mounts the planner in German on [store].
Future<void> _pumpGerman(WidgetTester tester, HomeStore store) async {
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
}

/// Scrolls the main list so [finder] sits [offset] px below the top.
Future<void> _scrollToTop(
  WidgetTester tester,
  Finder finder, {
  double offset = 60,
}) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await scrollDesignTabBy(tester, tester.getTopLeft(finder).dy - offset);
}

/// An own recipe without a photo (imageAsset ''): every thumb shows the
/// glowing recipe art, its motif from [categories].
FitnessRecipe _own(String slug, String title, List<String> categories) =>
    FitnessRecipe(
      slug: 'user_$slug',
      title: title,
      description: '',
      portion: '1 bowl (about 420 g)',
      ingredients: '150 g rice\n180 g chicken breast',
      preparation: 'Cook, slice and serve.',
      professionalHint: '',
      imageAsset: '',
      caloriesKcal: 590,
      proteinG: 48,
      carbsG: 60,
      fatG: 14,
      estimatedGrams: 420,
      categories: categories,
      userCreated: true,
    );

/// Bowl, fish and leaf: the three motifs of the art.
final _ownBowl = _own('art_bowl', 'Green power bowl', const ['Eigene']);
final _ownFish = _own('art_fish', 'Lemon salmon tray', const ['Fisch']);
final _ownLeaf = _own('art_leaf', 'Chickpea spinach curry', const [
  'Vegetarisch',
]);

/// Plans the three own recipes (lunch and dinner today, lunch tomorrow) and
/// keeps them in the store, so the editor lists them first.
Future<void> _seedOwnRecipes(HomeStore store) async {
  for (final recipe in [_ownLeaf, _ownFish, _ownBowl]) {
    await store.saveUserRecipe(recipe);
  }
  await store.savePlannedMeal(
    PlannedMeal.create(recipe: _ownBowl, day: _now, slot: MealSlot.lunch),
  );
  await store.savePlannedMeal(
    PlannedMeal.create(recipe: _ownFish, day: _now, slot: MealSlot.dinner),
  );
  await store.savePlannedMeal(
    PlannedMeal.create(
      recipe: _ownLeaf,
      day: _now.add(const Duration(days: 1)),
      slot: MealSlot.lunch,
    ),
  );
}

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
  bool ownRecipes = false,
}) async {
  _viewport(tester, narrow: narrow);
  final store = _store();
  if (ownRecipes) {
    await _seedOwnRecipes(store);
  } else if (withPlans) {
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
  final restore = _key('recipe-history-restore-4');
  await tester.ensureVisible(restore);
  await tester.pumpAndSettle();
  await tester.tap(restore);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(_key('recipe-history-confirm'), findsOneWidget);
  // No spinner at the end of the list behind the dialog, and nothing
  // claims a restore the user has not confirmed yet (the confirmed one:
  // feedback-recipe-history-restoring in feedback_surfaces_capture_test).
  expect(find.byType(CircularProgressIndicator), findsNothing);
  expect(
    find.descendant(of: restore, matching: find.text('Restore version')),
    findsOneWidget,
  );
  expect(find.text('Restoring…'), findsNothing);
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

      // Removing asks on the decision card first; Cancel keeps the plan.
      await tester.tap(find.text('Remove from plan'));
      await tester.pumpAndSettle();
      expect(_key('meal-plan-remove-dialog'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-remove-dialog');
      await tester.tap(_key('meal-plan-remove-cancel'));
      await tester.pumpAndSettle();
      expect(store.plannedMeals.any((p) => p.id == lunch.id), isTrue);
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

  testWidgets('German weekly receipt: merged rows, pantry collapsed and '
      'expanded, ticked off to its stamp', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      _viewport(tester);
      final store = _store();
      await _seedGermanWeek(store);
      await _pumpGerman(tester, store);
      await _tapVisible(tester, _key('meal-plan-tab-shopping'));
      final receipt = buildShoppingReceipt(
        store.plannedMeals,
        _now,
        decimalSeparator: ',',
        l10n: deL10n,
      );
      // No recipe headings: one row per ingredient, the chicken of three
      // meals (the bowl's in English) summed, with its days below.
      expect(find.text('FÜR DEN PIZZABODEN:'), findsNothing);
      final chicken = receipt.rows.singleWhere(
        (r) => r.label == 'Hähnchenbrustfilet',
      );
      expect(chicken.parts, hasLength(3));
      expect(find.text('540 g'), findsOneWidget);
      expect(
        find.text(
          'Di\u00A0180\u00A0g\u00A0· Do\u00A0Mittag\u00A0180\u00A0g\u00A0· '
          'Do\u00A0Abend\u00A0180\u00A0g',
        ),
        findsOneWidget,
      );
      expect(find.text('2 1/2'), findsOneWidget);
      await _scrollToTop(tester, _key('shopping-receipt'), offset: 110);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-shopping-receipt-de');

      // The leek keeps the recipe's amount, marked as such; the leftovers
      // have no list to merge.
      expect(
        find.text('Mi\u00A02\u00A0Stangen (Rezept für 4 Port.)'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Ohne Zutatenliste: Resteessen (Fr). Rezept vor dem Einkauf prüfen.',
        ),
        findsOneWidget,
      );
      await _scrollToTop(tester, _key('shopping-item-${chicken.id}'));
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-shopping-receipt-de-01');

      // Spices and staples: one line of names until opened.
      final pantry = _key('shopping-pantry');
      expect(_key('shopping-pantry-summary'), findsOneWidget);
      for (final row in receipt.pantry) {
        expect(_key('shopping-item-${row.id}'), findsNothing);
      }
      await _scrollToTop(tester, _key('shopping-empty-recipes'), offset: 160);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-shopping-pantry-collapsed');

      await _tapVisible(tester, _key('shopping-pantry-toggle'));
      expect(_key('shopping-pantry-summary'), findsNothing);
      for (final row in receipt.pantry) {
        expect(_key('shopping-item-${row.id}'), findsOneWidget);
      }
      await _scrollToTop(tester, pantry, offset: 110);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-shopping-pantry-expanded');

      // Every main row ticked off stamps the receipt; the pantry does not
      // count.
      for (final row in receipt.rows) {
        await store.setShoppingChecked(row.toggle(store.shoppingChecks));
      }
      final salt = receipt.pantry.singleWhere((r) => r.label == 'Salz');
      await store.setShoppingChecked(salt.toggle(store.shoppingChecks));
      await tester.pumpAndSettle();
      expect(_key('shopping-receipt-stamp'), findsOneWidget);
      await scrollDesignTabBy(tester, -260);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-shopping-receipt-done');
      await scrollDesignTabBy(tester, 3000);
      await captureDesignShot(tester, 'meal-plan-shopping-receipt-done-01');
    });
  });

  testWidgets('German weekly receipt at 320 px with 2x text', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      _viewport(tester, narrow: true);
      final store = _store();
      await _seedGermanWeek(store);
      await tester.pumpWidget(
        designCaptureBoundary(
          localizedApp(
            MealPlanScreen(store: store),
            locale: const Locale('de'),
            textScale: 2,
            safeArea: false,
            scaffold: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _tapVisible(tester, _key('meal-plan-tab-shopping'));
      final rows = buildShoppingReceipt(
        store.plannedMeals,
        _now,
        decimalSeparator: ',',
        l10n: deL10n,
      ).rows;
      final chicken = rows.singleWhere((r) => r.label == 'Hähnchenbrustfilet');
      // Large text puts each meal on a line of its own.
      expect(
        find.text(
          'Di 180\u00A0g\nDo\u00A0Mittag 180\u00A0g\nDo\u00A0Abend 180\u00A0g',
        ),
        findsOneWidget,
      );
      await _scrollToTop(tester, _key('shopping-item-${chicken.id}'));
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-narrow-receipt-de');
      final leek = rows.singleWhere((r) => r.label == 'Lauch');
      await _scrollToTop(tester, _key('shopping-item-${leek.id}'));
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-narrow-receipt-de-01');

      await _scrollToTop(tester, _key('shopping-pantry'), offset: 110);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-narrow-receipt-pantry');
      await _tapVisible(tester, _key('shopping-pantry-toggle'));
      await _scrollToTop(tester, _key('shopping-pantry'), offset: 110);
      await scrollDesignTabBy(tester, 500);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-narrow-receipt-pantry-open');
    });
  });

  testWidgets('week while the plans load', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      _viewport(tester);
      final store = _store()..mealPlansLoading = true;
      await tester.pumpWidget(
        designCaptureBoundary(
          localizedApp(
            MealPlanScreen(store: store),
            locale: const Locale('en'),
            safeArea: false,
            scaffold: false,
          ),
        ),
      );
      // The progress bar never settles.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // A cold load does not claim seven empty days.
      expect(find.text('Plan a meal'), findsNothing);
      expect(find.byType(SkeletonCard), findsWidgets);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-week-loading');
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

  testWidgets('own recipes without a photo: week rows and the editor', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      await _pumpPlan(tester, ownRecipes: true);
      // Today's 56 px row thumbs draw the art, each in its own motif.
      expect(_key('recipe-art-bowl'), findsOneWidget);
      expect(_key('recipe-art-fish'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-art-week');

      // The editor lists the own recipes first, with the art in the
      // 64 x 70 list thumbs ...
      await _tapVisible(tester, _key('meal-plan-add-2026-09-28'));
      await precacheDesignImages(tester);
      final inEditor = find.descendant(
        of: _key('meal-plan-editor-scroll'),
        matching: find.byType(RecipeArt),
      );
      expect(inEditor, findsNWidgets(3));
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-art-editor-list');

      // ... and on the chosen recipe's card.
      await _tapVisible(
        tester,
        find.descendant(
          of: _key('meal-plan-editor-scroll'),
          matching: find.text(_ownBowl.title),
        ),
      );
      expect(_key('meal-plan-slot-group'), findsOneWidget);
      expect(
        find.descendant(
          of: _key('meal-plan-editor-scroll'),
          matching: _key('recipe-art-bowl'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-art-editor-card');
    });
  });

  testWidgets('320 px with 2x text, own recipes without a photo', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      await _pumpPlan(tester, ownRecipes: true, narrow: true, textScale: 2);
      await tester.scrollUntilVisible(
        find.text(_ownFish.title),
        200,
        scrollable: designMainScrollable(),
      );
      // The whole dinner row, thumb included.
      await scrollDesignTabBy(tester, -160);
      expect(find.byType(RecipeArt), findsWidgets);
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-art-narrow-week');
      await scrollDesignTabBy(tester, -3000);

      await _tapVisible(tester, _key('meal-plan-add-2026-09-28'));
      await _tapVisible(
        tester,
        find.descendant(
          of: _key('meal-plan-editor-scroll'),
          matching: find.text(_ownFish.title),
        ),
      );
      // Large text stacks the card: the art spans the width.
      expect(
        find.descendant(
          of: _key('meal-plan-editor-scroll'),
          matching: _key('recipe-art-fish'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'meal-plan-art-narrow-editor-card');
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
