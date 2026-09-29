// Wiring of the redesigned Food tab (dark redesign, Task 3): every control
// is tapped in the real shell and must DO what it promises, and every figure
// must render the store's values and follow the store when it changes.
//
// Scenario: the design day (test/support/food_design_fixture.dart) at
// Monday 2026-09-28 18:30 — dinner is the open slot and the recipe pick
// targets it. External services are fakes; the store runs without sync.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/recipe_pick.dart';
import 'package:eatova/src/screens/barcode_scanner_sheet.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/meal_camera_launcher.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/kcal/food_date_picker.dart';
import 'package:eatova/src/widgets/kcal/meal_slot_picker.dart';

import '../support/design_capture.dart';
import '../support/food_design_fixture.dart';
import '../support/harness.dart';
import 'flow_test_helpers.dart';

/// Records where the AI scan was started and cancels it.
class _RecordingCamera implements MealCameraLauncher {
  final List<MealSlot> launches = <MealSlot>[];

  @override
  Future<MealCameraCapture?> launch(
    BuildContext context, {
    required MealSlot initialSlot,
  }) async {
    launches.add(initialSlot);
    return null;
  }
}

/// Scanner platform without a camera; [emit] delivers a scanned code.
class _FakeScanner extends MobileScannerPlatform
    with MockPlatformInterfaceMixin {
  final StreamController<BarcodeCapture?> _barcodes =
      StreamController<BarcodeCapture?>.broadcast();
  final StreamController<TorchState> _torch =
      StreamController<TorchState>.broadcast();
  final StreamController<double> _zoom = StreamController<double>.broadcast();

  void emit(String code) => _barcodes.add(
    BarcodeCapture(
      barcodes: <Barcode>[Barcode(rawValue: code, format: BarcodeFormat.ean13)],
    ),
  );

  @override
  Stream<BarcodeCapture?> get barcodesStream => _barcodes.stream;
  @override
  Stream<TorchState> get torchStateStream => _torch.stream;
  @override
  Stream<double> get zoomScaleStateStream => _zoom.stream;
  @override
  Widget buildCameraView() => const SizedBox.expand();
  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async =>
      const MobileScannerViewAttributes(
        cameraDirection: CameraFacing.back,
        currentTorchMode: TorchState.off,
        numberOfCameras: 1,
        size: Size(1280, 720),
        initialDeviceOrientation: DeviceOrientation.portraitUp,
      );
  @override
  Future<void> stop() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> toggleTorch() async {}
  @override
  Future<void> updateScanWindow(Rect? window) async {}
  @override
  Future<void> dispose() async {}
}

MealAnalysisResult _result(
  String name,
  int kcal, {
  int protein = 0,
  int carbs = 0,
  int fat = 0,
}) => MealAnalysisResult(
  mealName: name,
  caloriesKcal: kcal,
  estimatedGrams: 100,
  kcalPer100G: kcal.toDouble(),
  protein: '$protein g',
  carbs: '$carbs g',
  fat: '$fat g',
  confidence: 'database',
  portionNotes: '',
  sourceLabel: 'OpenFoodFacts',
);

/// The real shell on the Food tab with the design day (or [meals]).
Future<HomeStore> _pumpFood(
  WidgetTester tester, {
  List<LoggedMeal>? meals,
  MealCameraLauncher? camera,
  bool safeAreas = true,
}) async {
  pinDesignViewport(tester);
  if (!safeAreas) {
    // The add sheet's own snack host lays out off screen at the iPhone
    // insets in the headless test font (pre-existing, not Food's layout).
    tester.view.padding = FakeViewPadding.zero;
    tester.view.viewPadding = FakeViewPadding.zero;
  }
  await tester.pumpWidget(
    localizedApp(
      EatovaHomePage(
        productService: FakeProductLookupService(),
        mealAnalyzer: FakeMealAnalyzer(),
        mealCameraLauncher: camera ?? _RecordingCamera(),
      ),
      locale: const Locale('en'),
      safeArea: false,
      scaffold: false,
    ),
  );
  await tester.pumpAndSettle();
  final store = storeOf(tester)
    ..profile = foodDesignProfile
    ..loggedMeals = meals ?? foodDesignMeals();
  // The tab switch notifies, so the Food tab builds on the seed.
  await tester.tap(find.byKey(const ValueKey('nav-Food')));
  await tester.pumpAndSettle();
  return store;
}

Finder _key(String key) => find.byKey(ValueKey<String>(key));

Finder _inCard(MealSlot slot, Finder finder) =>
    find.descendant(of: _key('food-slot-card-${slot.name}'), matching: finder);

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(_key(key)).data!;

/// The keyed diary row that shows [name] (keys carry the day index).
Finder _row(String name) => find.ancestor(
  of: find.text(name),
  matching: find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('food-history-entry-'),
  ),
);

/// Flex of the protein, carbs and fat segments; null for a missing one.
List<int?> _barFlex(WidgetTester tester) => [
  for (final macro in ['protein', 'carbs', 'fat'])
    _key('food-macro-bar-$macro').evaluate().isEmpty
        ? null
        : tester
              .widget<Expanded>(
                find.ancestor(
                  of: _key('food-macro-bar-$macro'),
                  matching: find.byType(Expanded),
                ),
              )
              .flex,
];

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  group('Header and day switcher', () {
    testWidgets('the calendar button opens the date picker; the picked day '
        'drives the whole tab', (tester) async {
      await withClock(Clock.fixed(foodDesignNow), () async {
        final store = await _pumpFood(tester);
        expect(_text(tester, 'food-date-headline'), 'Today');
        expect(_text(tester, 'food-date-selected-label'), 'Monday, Sep 28');

        await tester.tap(_key('food-date-calendar'));
        await tester.pumpAndSettle();
        expect(find.byType(FoodDatePicker), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: _key('food-date-picker'),
            matching: find.text('25'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(_key('food-date-confirm'));
        await tester.pumpAndSettle();

        expect(store.selectedFoodDate, DateTime(2026, 9, 25));
        expect(_text(tester, 'food-date-headline'), '3 days ago');
        expect(_text(tester, 'food-date-selected-label'), 'Friday, Sep 25');
        // Summary and diary follow the picked (empty) day.
        expect(_text(tester, 'food-day-total'), '0');
        expect(_text(tester, 'food-day-left'), '2,123');
        for (final slot in MealSlot.values) {
          expect(_key('food-slot-empty-${slot.name}'), findsOneWidget);
        }
        // A past day gets no pick and no "suggested" guide.
        expect(_key('food-pick-row'), findsNothing);
        expect(find.textContaining('Suggested'), findsNothing);
      });
    });

    testWidgets('the chevrons switch the day; next is disabled on today', (
      tester,
    ) async {
      await withClock(Clock.fixed(foodDesignNow), () async {
        final store = await _pumpFood(tester);
        IconButton arrow(String key) => tester.widget<IconButton>(_key(key));
        expect(arrow('food-date-next').onPressed, isNull);
        expect(arrow('food-date-previous').onPressed, isNotNull);

        await tester.tap(_key('food-date-previous'));
        await tester.pumpAndSettle();
        expect(store.selectedFoodDate, DateTime(2026, 9, 27));
        expect(_text(tester, 'food-date-headline'), 'Yesterday');
        expect(_text(tester, 'food-date-selected-label'), 'Sunday, Sep 27');
        expect(_text(tester, 'food-day-total'), '0');
        expect(arrow('food-date-next').onPressed, isNotNull);

        await tester.tap(_key('food-date-next'));
        await tester.pumpAndSettle();
        expect(store.selectedFoodDate, DateTime(2026, 9, 28));
        expect(_text(tester, 'food-date-headline'), 'Today');
        expect(_text(tester, 'food-day-total'), '1,221');
      });
    });
  });

  group('Day summary', () {
    testWidgets('shows the store\'s numbers and follows logging, deleting '
        'and undo', (tester) async {
      await withClock(Clock.fixed(foodDesignNow), () async {
        final store = await _pumpFood(tester);
        expect(_text(tester, 'food-day-total'), '1,221');
        expect(_text(tester, 'food-day-left'), '902');
        expect(find.text('LEFT'), findsOneWidget);
        for (final grams in ['111 g', '144 g', '20 g']) {
          expect(find.text(grams), findsOneWidget);
        }
        // Stacked bar: segments sized by kcal share (444 : 576 : 180).
        expect(_barFlex(tester), <int?>[370, 480, 150]);

        // Logging (store) updates every figure.
        await store.addResultToDailyTotal(
          _result('Salmon', 300, protein: 30, carbs: 0, fat: 20),
          slot: MealSlot.dinner,
        );
        await tester.pumpAndSettle();
        expect(_text(tester, 'food-day-total'), '1,521');
        expect(_text(tester, 'food-day-left'), '602');
        expect(find.text('141 g'), findsOneWidget);
        expect(find.text('40 g'), findsOneWidget);
        expect(_inCard(MealSlot.dinner, find.text('Salmon')), findsOneWidget);
        expect(_text(tester, 'food-slot-kcal-dinner'), '300');
        // 564 : 576 : 360 kcal.
        expect(_barFlex(tester), <int?>[376, 384, 240]);

        // Over budget: the label says so and the number turns into a state.
        await store.addResultToDailyTotal(
          _result('Pizza', 1000, carbs: 100, fat: 40, protein: 40),
          slot: MealSlot.snack,
        );
        await tester.pumpAndSettle();
        expect(find.text('OVER'), findsOneWidget);
        expect(_text(tester, 'food-day-left'), '398');
        expect(
          tester.widget<Text>(_key('food-day-left')).style!.color,
          AppTokens.dark.warning,
        );
        // 724 : 976 : 720 kcal.
        expect(_barFlex(tester), <int?>[299, 403, 298]);

        // Deleting through the row's swipe action, then undo.
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        final pizza = _row('Pizza');
        await tester.ensureVisible(pizza);
        await tester.pumpAndSettle();
        final index = (tester.widget(pizza).key! as ValueKey<String>).value
            .split('-')
            .last;
        await tester.drag(pizza, const Offset(-300, 0));
        await tester.pumpAndSettle();
        await tester.tap(_key('food-history-delete-$index'));
        await tester.pumpAndSettle();
        expect(
          store.loggedMeals.any((m) => m.result.mealName == 'Pizza'),
          isFalse,
        );
        expect(_text(tester, 'food-day-total'), '1,521');
        expect(find.text('LEFT'), findsOneWidget);
        expect(_barFlex(tester), <int?>[376, 384, 240]);
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        expect(_text(tester, 'food-day-total'), '2,521');
        expect(_row('Pizza'), findsOneWidget);
        expect(_barFlex(tester), <int?>[299, 403, 298]);

        // The day switch takes the whole summary along, the bar included.
        await _tapVisible(tester, _key('food-date-previous'));
        expect(_text(tester, 'food-day-total'), '0');
        expect(_barFlex(tester), <int?>[null, null, null]);
        expect(find.text('0 g'), findsNWidgets(3));
        await _tapVisible(tester, _key('food-date-next'));
        expect(_text(tester, 'food-day-total'), '2,521');
        expect(_barFlex(tester), <int?>[299, 403, 298]);
      });
    });

    testWidgets('an empty day shows zeros, the bare track, four suggested '
        'bands and the dinner pick', (tester) async {
      await withClock(Clock.fixed(foodDesignNow), () async {
        await _pumpFood(tester, meals: const <LoggedMeal>[]);
        expect(_text(tester, 'food-day-total'), '0');
        expect(_text(tester, 'food-day-left'), '2,123');
        expect(_key('food-macro-bar'), findsOneWidget);
        expect(_key('food-macro-bar-protein'), findsNothing);
        expect(find.text('0 g'), findsNWidgets(3));
        for (final (slot, band) in [
          (MealSlot.breakfast, 'Suggested 400–550 kcal'),
          (MealSlot.lunch, 'Suggested 550–700 kcal'),
          (MealSlot.dinner, 'Suggested 550–700 kcal'),
          (MealSlot.snack, 'Suggested 150–300 kcal'),
        ]) {
          expect(_inCard(slot, find.text(band)), findsOneWidget);
        }
        // One pick, in the slot it targets, although all four are empty.
        expect(_key('food-pick-row'), findsOneWidget);
        expect(_inCard(MealSlot.dinner, _key('food-pick-row')), findsOneWidget);
      });
    });

    testWidgets('tapping the summary opens Trends', (tester) async {
      await withClock(Clock.fixed(foodDesignNow), () async {
        await _pumpFood(tester);
        await tester.tap(_key('topbar-trends'));
        await tester.pumpAndSettle();
        expect(_key('screen-trends'), findsOneWidget);
      });
    });
  });

  group('Meal cards', () {
    testWidgets('cards show the slot\'s time, count and total; the header '
        'toggles the macro details', (tester) async {
      await withClock(Clock.fixed(foodDesignNow), () async {
        await _pumpFood(tester);
        expect(
          _inCard(MealSlot.breakfast, find.text('08:10 · 3 items')),
          findsOneWidget,
        );
        expect(_text(tester, 'food-slot-kcal-breakfast'), '401');
        expect(_text(tester, 'food-slot-kcal-lunch'), '597');
        expect(_text(tester, 'food-slot-kcal-snack'), '223');
        expect(_key('food-slot-kcal-dinner'), findsNothing);
        // Oldest first, with amount and kcal.
        expect(
          tester.getTopLeft(find.text('Skyr, natural')).dy,
          lessThan(tester.getTopLeft(find.text('Blueberries')).dy),
        );
        expect(_inCard(MealSlot.breakfast, find.text('250 g')), findsOneWidget);

        expect(_key('food-slot-macros-breakfast'), findsNothing);
        expect(_key('food-entry-time-b1'), findsNothing);
        await tester.tap(_key('food-slot-toggle-breakfast'));
        await tester.pumpAndSettle();
        expect(
          _text(tester, 'food-slot-macros-breakfast'),
          'P 35 g · C 51 g · F 4 g',
        );
        expect(find.text('P 27 g · C 10 g · F 1 g'), findsOneWidget);
        // Each entry's logged time comes back with the details.
        for (final id in ['b1', 'b2', 'b3']) {
          expect(_text(tester, 'food-entry-time-$id'), '08:10');
        }
        expect(_key('food-entry-time-l1'), findsNothing);
        await tester.tap(_key('food-slot-toggle-breakfast'));
        await tester.pumpAndSettle();
        expect(_key('food-slot-macros-breakfast'), findsNothing);
        expect(_key('food-entry-time-b1'), findsNothing);
      });
    });

    testWidgets('an item row opens the edit sheet of exactly that meal', (
      tester,
    ) async {
      await withClock(Clock.fixed(foodDesignNow), () async {
        await _pumpFood(tester);
        await _tapVisible(tester, _row('Oat flakes'));
        final sheet = _key('edit-meal-sheet');
        expect(sheet, findsOneWidget);
        expect(
          find.descendant(
            of: sheet,
            matching: find.textContaining('Oat flakes'),
          ),
          findsWidgets,
        );
        expect(
          find.descendant(of: sheet, matching: find.textContaining('Skyr')),
          findsNothing,
        );
      });
    });

    testWidgets('"Add to <slot>" opens the add flow for that slot and the '
        'shown day, and logs there', (tester) async {
      await withClock(Clock.fixed(foodDesignNow), () async {
        final store = await _pumpFood(tester, safeAreas: false);
        await _tapVisible(tester, _key('food-slot-add-lunch'));
        expect(_key('add-meal-sheet'), findsOneWidget);
        expect(
          tester.widget<MealSlotPicker>(find.byType(MealSlotPicker)).selected,
          MealSlot.lunch,
        );
        expect(
          _text(tester, 'add-meal-date-context'),
          allOf(contains('Sep 28'), contains('Lunch')),
        );
        await tester.tap(_key('add-meal-sheet-close'));
        await tester.pumpAndSettle();

        // On an archive day the same row books onto THAT day and slot.
        await _tapVisible(tester, _key('food-date-previous'));
        expect(store.selectedFoodDate, DateTime(2026, 9, 27));
        await _tapVisible(tester, _key('food-slot-add-snack'));
        expect(
          _text(tester, 'add-meal-date-context'),
          allOf(contains('Sep 27'), contains('Snacks')),
        );
        await tester.enterText(
          _key('kcal-product-search-input'),
          'Dr Oetker Salami',
        );
        await tester.tap(_key('kcal-product-search-button'));
        await tester.pumpAndSettle();
        await tester.tap(_key('kcal-product-suggestion-0'));
        await tester.pumpAndSettle();
        await _tapVisible(tester, _key('kcal-product-suggestion-add-0'));
        final added = store.loggedMeals.firstWhere(
          (m) => m.result.mealName.contains('Salami'),
        );
        expect(added.slot, MealSlot.snack);
        expect(added.localDay ?? localDayKey(added.loggedAt), '2026-09-27');
      });
    });
  });

  group('Fits tonight', () {
    testWidgets('the pick row sits only in the pick\'s empty slot and opens '
        'the recipe, which logs into the chosen slot', (tester) async {
      await withClock(Clock.fixed(foodDesignNow), () async {
        final store = await _pumpFood(tester);
        expect(_key('food-pick-row'), findsOneWidget);
        expect(_inCard(MealSlot.dinner, _key('food-pick-row')), findsOneWidget);
        expect(find.text('FITS TONIGHT · 610 KCAL'), findsOneWidget);
        const title = 'Turkey Steak with Quinoa & Roasted Vegetables';
        expect(find.text(title), findsOneWidget);

        final before = store.loggedMeals.length;
        await _tapVisible(tester, _key('food-pick-row'));
        final detail = tester.widget<RecipeDetailScreen>(
          find.byType(RecipeDetailScreen),
        );
        expect(detail.recipe.title, title);
        await _tapVisible(tester, _key('recipe-add-button'));
        await _tapVisible(tester, _key('recipe-meal-picker-dinner'));
        final logged = store.loggedMeals.where(
          (m) => m.slot == MealSlot.dinner,
        );
        expect(logged.single.result.caloriesKcal, 610);
        // Exactly one new diary row.
        expect(store.loggedMeals.length, before + 1);

        // Back on Food: dinner is filled, so the pick is gone.
        Navigator.of(tester.element(find.byType(RecipeDetailScreen))).pop();
        await tester.pumpAndSettle();
        expect(_key('food-pick-row'), findsNothing);
        expect(_text(tester, 'food-slot-kcal-dinner'), '610');
        expect(_text(tester, 'food-day-left'), '292');
      });
    });

    testWidgets('a planned pick (2 servings) opens the meal plan, whose Eat '
        'logs the shown kcal once and marks the plan eaten', (tester) async {
      await withClock(Clock.fixed(foodDesignNow), () async {
        final store = await _pumpFood(tester);
        final recipe = recipeCatalogForLocale('en').firstWhere(
          (r) => recipeSuitsSlot(r, MealSlot.dinner) && r.canLogServings(2),
        );
        final plan = PlannedMeal.create(
          recipe: recipe,
          day: foodDesignNow,
          slot: MealSlot.dinner,
          servings: 2,
        );
        await store.savePlannedMeal(plan);
        await tester.pumpAndSettle();

        final pick = store.nextMealPick(localeName: 'en')!;
        expect(pick.source, RecipePickSource.planned);
        expect(pick.servings, 2);
        final shown = pick.kcal!;
        final label =
            'PLANNED · ${NumberFormat.decimalPattern('en').format(shown)} KCAL';
        expect(_inCard(MealSlot.dinner, find.text(label)), findsOneWidget);
        final before = store.loggedMeals.length;

        await _tapVisible(tester, _key('food-pick-row'));
        expect(find.byType(MealPlanScreen), findsOneWidget);
        expect(find.byType(RecipeDetailScreen), findsNothing);
        await _tapVisible(tester, _key('meal-plan-eat-${plan.id}'));

        // One row, the planned servings, the plan entry eaten.
        expect(store.loggedMeals.length, before + 1);
        final dinner = store.loggedMeals.where(
          (m) => m.slot == MealSlot.dinner,
        );
        expect(dinner.single.id, plan.id);
        expect(dinner.single.result.caloriesKcal, shown);
        expect(
          store.plannedMeals.singleWhere((p) => p.id == plan.id).isEaten,
          isTrue,
        );
        // The plan offers no second "Eat".
        expect(_key('meal-plan-eat-${plan.id}'), findsNothing);

        Navigator.of(tester.element(find.byType(MealPlanScreen))).pop();
        await tester.pumpAndSettle();
        expect(_key('food-pick-row'), findsNothing);
        expect(
          _text(tester, 'food-slot-kcal-dinner'),
          NumberFormat.decimalPattern('en').format(shown),
        );
        expect(store.loggedMeals.length, before + 1);
      });
    });

    testWidgets('a planned pick without loggable nutrition opens the meal '
        'plan and logs nothing', (tester) async {
      await withClock(Clock.fixed(foodDesignNow), () async {
        final store = await _pumpFood(tester);
        const pending = FitnessRecipe(
          slug: 'user_pending_stew',
          title: 'Pending stew',
          description: '',
          portion: '1 plate',
          ingredients: '',
          preparation: '',
          professionalHint: '',
          imageAsset: '',
          caloriesKcal: 500,
          proteinG: 30,
          carbsG: 40,
          fatG: 15,
          estimatedGrams: 400,
          categories: [recipeNutritionPendingCategory],
          userCreated: true,
        );
        await store.savePlannedMeal(
          PlannedMeal.create(
            recipe: pending,
            day: foodDesignNow,
            slot: MealSlot.dinner,
          ),
        );
        await tester.pumpAndSettle();
        final pick = store.nextMealPick(localeName: 'en')!;
        expect(pick.source, RecipePickSource.planned);
        expect(pick.kcal, isNull);
        expect(_inCard(MealSlot.dinner, find.text('PLANNED')), findsOneWidget);
        final before = store.loggedMeals.length;

        await _tapVisible(tester, _key('food-pick-row'));
        expect(find.byType(MealPlanScreen), findsOneWidget);
        expect(find.byType(RecipeDetailScreen), findsNothing);
        expect(store.loggedMeals.length, before);
      });
    });

    testWidgets('no pick row after 21:00', (tester) async {
      await withClock(Clock.fixed(DateTime(2026, 9, 28, 21, 30)), () async {
        await _pumpFood(tester);
        expect(_key('food-pick-row'), findsNothing);
        expect(_key('food-slot-empty-dinner'), findsOneWidget);
      });
    });
  });

  group('Capture dock', () {
    testWidgets('the search capsule opens the search sheet for the current '
        'slot', (tester) async {
      await withClock(Clock.fixed(foodDesignNow), () async {
        await _pumpFood(tester);
        await tester.tap(_key('food-search'));
        await tester.pumpAndSettle();
        expect(_key('add-meal-sheet'), findsOneWidget);
        expect(_key('kcal-product-search-input'), findsOneWidget);
        expect(find.text(enL10n.foodSearchModeTitle), findsOneWidget);
        expect(
          tester.widget<MealSlotPicker>(find.byType(MealSlotPicker)).selected,
          MealSlot.dinner,
        );
        expect(
          _text(tester, 'add-meal-date-context'),
          allOf(contains('Sep 28'), contains('Dinner')),
        );
        await tester.tap(_key('add-meal-sheet-close'));
        await tester.pumpAndSettle();

        // On an archive day the search books onto THAT day.
        await _tapVisible(tester, _key('food-date-previous'));
        await tester.tap(_key('food-search'));
        await tester.pumpAndSettle();
        expect(
          _text(tester, 'add-meal-date-context'),
          allOf(contains('Sep 27'), contains('Dinner')),
        );
      });
    });

    testWidgets('the barcode button opens the scanner; a scan lands in the '
        'chosen slot', (tester) async {
      final prior = MobileScannerPlatform.instance;
      final scanner = _FakeScanner();
      MobileScannerPlatform.instance = scanner;
      addTearDown(() => MobileScannerPlatform.instance = prior);
      await withClock(Clock.fixed(foodDesignNow), () async {
        final store = await _pumpFood(tester);
        await tester.tap(_key('food-action-barcode'));
        await tester.pumpAndSettle();
        final sheet = tester.widget<BarcodeScannerSheet>(
          find.byType(BarcodeScannerSheet),
        );
        expect(sheet.initialSlot, MealSlot.dinner);

        scanner.emit('4001724012345');
        await tester.pumpAndSettle();
        expect(find.byType(BarcodeScannerSheet), findsNothing);
        await _tapVisible(tester, _key('analyse-add-daily-button'));
        final added = store.loggedMeals.firstWhere(
          (m) => m.result.mealName.contains('Salami'),
        );
        expect(added.slot, MealSlot.dinner);
      });
    });

    testWidgets('the camera button starts the AI scan for the current slot', (
      tester,
    ) async {
      await withClock(Clock.fixed(foodDesignNow), () async {
        final camera = _RecordingCamera();
        await _pumpFood(tester, camera: camera);
        await tester.tap(_key('food-action-ai'));
        await tester.pumpAndSettle();
        expect(camera.launches, <MealSlot>[MealSlot.dinner]);
      });
    });

    testWidgets('the camera button leads into the scan preview', (
      tester,
    ) async {
      await withClock(Clock.fixed(foodDesignNow), () async {
        await _pumpFood(tester, camera: FakeMealCameraLauncher());
        await tester.tap(_key('food-action-ai'));
        await tester.pumpAndSettle();
        expect(_key('meal-scan-start'), findsOneWidget);
      });
    });

    testWidgets('manual entry: long-press on the capsule opens it directly '
        'and it saves into the chosen slot', (tester) async {
      await withClock(Clock.fixed(foodDesignNow), () async {
        final store = await _pumpFood(tester);
        await tester.longPress(_key('food-search'));
        await tester.pumpAndSettle();
        final sheet = _key('manual-meal-sheet');
        expect(sheet, findsOneWidget);
        expect(
          find.descendant(of: sheet, matching: find.text('Monday, Sep 28')),
          findsOneWidget,
        );
        await tester.enterText(_key('manual-meal-name'), 'Soup');
        await tester.enterText(_key('manual-meal-kcal100'), '120');
        await tester.pump();
        await _tapVisible(tester, _key('manual-meal-save'));
        final soup = store.loggedMeals.firstWhere(
          (m) => m.result.mealName == 'Soup',
        );
        expect(soup.slot, MealSlot.dinner);
      });
    });

    testWidgets('manual entry and favorites stay reachable from the add '
        'flow', (tester) async {
      await withClock(Clock.fixed(foodDesignNow), () async {
        final store = await _pumpFood(tester);
        await store.toggleFavorite(_result('Porridge', 350));
        await tester.pumpAndSettle();

        await _tapVisible(tester, _key('food-slot-add-breakfast'));
        await _tapVisible(tester, _key('add-meal-favorites-all'));
        expect(_key('favorites-sheet'), findsOneWidget);
        Navigator.of(tester.element(_key('favorites-sheet'))).pop();
        await tester.pumpAndSettle();

        await _tapVisible(tester, _key('manual-entry-button'));
        expect(_key('manual-meal-sheet'), findsOneWidget);
      });
    });
  });

  group('Semantics and targets', () {
    testWidgets('every control has a name and a 44 px target', (tester) async {
      final semantics = tester.ensureSemantics();
      await withClock(Clock.fixed(foodDesignNow), () async {
        await _pumpFood(tester);
        final l10n = enL10n;
        for (final label in [
          l10n.foodCalendarButtonSemantics,
          l10n.foodDockSearchLabel,
          l10n.foodScanBarcodeTooltip,
          l10n.foodDockCameraLabel,
        ]) {
          expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
        }
        expect(find.byTooltip(l10n.todaySemanticsDatePrev), findsOneWidget);
        expect(find.byTooltip(l10n.todaySemanticsDateNext), findsOneWidget);
        for (final key in [
          'food-date-calendar',
          'food-date-previous',
          'food-date-next',
          'food-search',
          'food-action-barcode',
          'food-action-ai',
          'food-slot-add-breakfast',
          'food-slot-toggle-breakfast',
          'food-pick-row',
          'topbar-trends',
        ]) {
          final size = tester.getSize(_key(key));
          expect(size.height, greaterThanOrEqualTo(44), reason: key);
          expect(size.width, greaterThanOrEqualTo(44), reason: key);
        }
        expect(
          tester.getSize(_row('Skyr, natural')).height,
          greaterThanOrEqualTo(44),
        );
        // The capsule is the dock's route to manual entry: a long-press
        // action with its hint, next to the tap that opens search.
        expect(
          tester.getSemantics(_key('food-search')),
          isSemantics(
            label: l10n.foodDockSearchLabel,
            isButton: true,
            hasTapAction: true,
            hasLongPressAction: true,
            onLongPressHint: l10n.foodManualEntryCta,
          ),
        );
        // The slot names are headings, the pick row a button with a hint.
        expect(
          tester.getSemantics(find.text('Breakfast')),
          isSemantics(isHeader: true),
        );
        expect(
          tester.getSemantics(_key('food-pick-row')),
          isSemantics(
            isButton: true,
            hasTapAction: true,
            hint: l10n.recipesViewRecipe,
            // The eyebrow reads in sentence case (its semantics label).
            label:
                'Fits tonight · 610 kcal\n'
                'Turkey Steak with Quinoa & Roasted Vegetables',
          ),
        );
      });
      semantics.dispose();
    });
  });
}
