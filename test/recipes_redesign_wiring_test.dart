// Wiring of the redesigned Recipes tab (dark redesign Task 4, 2026-09-29
// requirement "design <-> logic"): every control is tapped and its REAL
// outcome asserted — the route or sheet that opens, the store mutation that
// runs, the undo that reverts it — and every data-bound value is checked to
// follow the store.
//
// Most cases mount the real home page (preview store, no sync) in the design
// scenario: Mon 2026-09-28 18:30, a 2,123 kcal goal, 1,221 kcal logged,
// dinner open, so the shared pick is the turkey steak (610 kcal, 58 g).

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/generated/app_localizations.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/recipe_pick.dart';
import 'package:eatova/src/models/recipe_shelf.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/recipes/meal_plan_screen.dart';
import 'package:eatova/src/screens/recipes/recipe_history_screen.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/services/user_recipe_reads.dart';
import 'package:eatova/src/widgets/design/design.dart';

import 'design/recipes_redesign_capture_test.dart'
    show designDay, designOwnRecipes;
import 'flows/flow_test_helpers.dart' show storeOf;
import 'support/design_capture.dart' show loadDesignFonts, pinDesignViewport;
import 'support/harness.dart';
import 'support/recipe_navigation.dart' show recipesList, revealRecipeChip;

final _now = DateTime(2026, 9, 28, 18, 30);

const _profile = UserProfile(
  dailyKcalGoal: 2123,
  proteinGoalG: 162,
  carbsGoalG: 222,
  fatGoalG: 57,
);

const _turkey = 'putensteak_mit_quinoa_and_ofengemuse';
const _turkeyTitle = 'Turkey Steak with Quinoa & Roasted Vegetables';

Finder _key(String key) => find.byKey(ValueKey<String>(key));

late AppLocalizations _en;

/// The real home page in the design scenario, on the Recipes tab.
Future<HomeStore> _pumpHome(
  WidgetTester tester, {
  bool ownRecipes = false,
}) async {
  pinDesignViewport(tester);
  await tester.pumpWidget(
    localizedApp(
      EatovaHomePage(),
      locale: const Locale('en'),
      safeArea: false,
      scaffold: false,
    ),
  );
  await tester.pumpAndSettle();
  final store = storeOf(tester)
    ..profile = _profile
    ..loggedMeals = designDay();
  if (ownRecipes) {
    for (final recipe in designOwnRecipes) {
      await store.saveUserRecipe(recipe);
    }
  }
  await tester.tap(_key('nav-Rezepte'));
  await tester.pumpAndSettle();
  return store;
}

/// Builds [finder] in the lazy recipes list (from the top, downwards) and
/// scrolls it on screen, clear of the floating tab bar.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    tester.state<ScrollableState>(recipesList()).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(finder, 200, scrollable: recipesList());
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

/// [_reveal], then tap.
Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Builds the chip [key] in the lazy chip bar and scrolls it on screen.
Future<void> _revealChip(WidgetTester tester, String key) =>
    revealRecipeChip(tester, key);

/// Slugs of the list rows currently built.
List<String> _rowSlugs(WidgetTester tester) => tester
    .widgetList(
      find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('recipe-tile-'),
      ),
    )
    .map(
      (w) =>
          (w.key! as ValueKey<String>).value.substring('recipe-tile-'.length),
    )
    .toList(growable: false);

/// Every chip of the bar, as (key, is a section chip).
List<(String, bool)> get _chipKeys => <(String, bool)>[
  ('recipes-tab-for-you', true),
  ('recipes-tab-all', true),
  ('recipes-tab-own', true),
  for (final filter in recipeFilters.skip(1)) ('recipe-filter-$filter', false),
];

/// Which chips are selected right now (builds the whole lazy bar first).
Future<Set<String>> _selectedChips(WidgetTester tester) async {
  final selected = <String>{};
  for (final (key, section) in _chipKeys) {
    await _revealChip(tester, key);
    final finder = _key(key);
    final isSelected = section
        ? tester.widget<Semantics>(finder).properties.selected
        : tester.widget<FilterChipPill>(finder).selected;
    if (isSelected == true) selected.add(key);
  }
  return selected;
}

/// An own recipe whose nutrition is still missing: it cannot be logged, so a
/// planned entry of it has no kcal.
const _pendingRecipe = FitnessRecipe(
  slug: 'user_pending',
  title: 'Imported stew',
  description: '',
  portion: '',
  ingredients: 'Beans',
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

FitnessRecipe _catalog(String slug) =>
    recipeCatalogEn.firstWhere((r) => r.slug == slug);

MealAnalysisResult _meal(String name, int kcal) => MealAnalysisResult(
  mealName: name,
  caloriesKcal: kcal,
  estimatedGrams: 100,
  kcalPer100G: kcal.toDouble(),
  protein: '5 g',
  carbs: '5 g',
  fat: '5 g',
  confidence: 'Hoch',
  portionNotes: '',
);

void main() {
  setUpAll(() async {
    // Real fonts: the layout (hero height, what sits above the fold) is the
    // one the captures show, not the test font's square glyphs.
    await loadDesignFonts();
    _en = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('header', () {
    testWidgets('calendar opens the meal plan; its shopping list is one tab '
        'away', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        await _pumpHome(tester);
        await tester.tap(_key('recipe-meal-plan-button'));
        await tester.pumpAndSettle();
        expect(find.byType(MealPlanScreen), findsOneWidget);

        await tester.tap(_key('meal-plan-tab-shopping'));
        await tester.pumpAndSettle();
        expect(_key('shopping-summary'), findsOneWidget);
      });
    });

    testWidgets('"+" offers import and create, each opens its sheet', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        await _pumpHome(tester);
        await tester.tap(_key('recipe-add-choice-button'));
        await tester.pumpAndSettle();
        expect(_key('recipe-add-choice-sheet'), findsOneWidget);
        await tester.tap(_key('recipe-add-choice-create'));
        await tester.pumpAndSettle();
        expect(_key('recipe-add-choice-sheet'), findsNothing);
        expect(_key('recipe-create-sheet'), findsOneWidget);

        await tester
            .state<NavigatorState>(find.byType(Navigator).first)
            .maybePop();
        await tester.pumpAndSettle();
        await tester.tap(_key('recipe-add-choice-button'));
        await tester.pumpAndSettle();
        await tester.tap(_key('recipe-add-choice-import'));
        await tester.pumpAndSettle();
        expect(_key('recipe-import-sheet'), findsOneWidget);
      });
    });
  });

  group('search and filters', () {
    testWidgets('search narrows the list and leaves For you', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        await _pumpHome(tester);
        expect(_key('recipe-hero'), findsOneWidget);

        await tester.enterText(_key('recipes-search-input'), 'salmon');
        await tester.pumpAndSettle();

        expect(_key('recipe-hero'), findsNothing);
        expect(await _selectedChips(tester), {'recipes-tab-all'});
        final hits = recipeCatalogEn
            .where(
              (r) =>
                  foldRecipeSearchText(r.title).contains('salmon') ||
                  foldRecipeSearchText(r.description).contains('salmon') ||
                  foldRecipeSearchText(r.ingredients).contains('salmon'),
            )
            .map((r) => r.slug)
            .toList(growable: false);
        expect(hits, isNotEmpty);
        expect(find.text('${hits.length} matches'), findsOneWidget);
        expect(_rowSlugs(tester), hits);

        // Clearing brings the whole list back.
        await tester.tap(_key('recipes-search-clear'));
        await tester.pumpAndSettle();
        expect(find.text('${recipeCatalogEn.length} matches'), findsOneWidget);
      });
    });

    testWidgets('the filter button lists every chip; a pick filters and '
        'selects it', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        await _pumpHome(tester);
        await tester.tap(_key('recipes-filter-button'));
        await tester.pumpAndSettle();
        expect(_key('recipe-filter-sheet'), findsOneWidget);
        for (final id in <String>[
          'for-you',
          'all',
          'own',
          ...recipeFilters.skip(1),
        ]) {
          expect(_key('recipe-filter-option-$id'), findsOneWidget, reason: id);
        }

        await _tapVisible(tester, _key('recipe-filter-option-Fisch'));
        expect(_key('recipe-filter-sheet'), findsNothing);
        expect(await _selectedChips(tester), {'recipe-filter-Fisch'});
        final fish = recipeCatalogEn
            .where((r) => r.categories.contains('Fisch'))
            .map((r) => r.slug)
            .toList(growable: false);
        expect(_rowSlugs(tester), fish);
      });
    });

    testWidgets('every chip filters the list and carries the selection', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        await _pumpHome(tester, ownRecipes: true);
        final own = designOwnRecipes.map((r) => r.slug).toSet();
        for (final (key, _) in _chipKeys) {
          await _revealChip(tester, key);
          await tester.tap(_key(key));
          await tester.pumpAndSettle();
          expect(await _selectedChips(tester), {key}, reason: key);
          // Back to the top, where the rows start.
          await tester.ensureVisible(
            find.byKey(const ValueKey('recipes-chip-bar')),
          );
          await tester.pumpAndSettle();
          switch (key) {
            case 'recipes-tab-for-you':
              expect(_key('recipe-hero'), findsOneWidget);
            case 'recipes-tab-all':
              expect(
                find.text('${recipeCatalogEn.length + own.length} matches'),
                findsOneWidget,
              );
            case 'recipes-tab-own':
              expect(find.text('${own.length} matches'), findsOneWidget);
              expect(_rowSlugs(tester).toSet(), own);
            default:
              final filter = key.substring('recipe-filter-'.length);
              // Own recipes with the tag count too (the poke is "Fisch").
              final expected = <FitnessRecipe>[
                ...designOwnRecipes,
                ...recipeCatalogEn,
              ].where((r) => r.categories.contains(filter)).length;
              expect(
                find.text('$expected matches'),
                findsOneWidget,
                reason: key,
              );
              for (final slug in _rowSlugs(tester)) {
                expect(
                  <FitnessRecipe>[
                    ...designOwnRecipes,
                    ...recipeCatalogEn,
                  ].firstWhere((r) => r.slug == slug).categories,
                  contains(filter),
                  reason: slug,
                );
              }
          }
        }
      });
    });
  });

  group('hero', () {
    testWidgets('shows the shared pick: title, eyebrow, fits badge, numbers '
        'and the AI label of a catalog photo', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final store = await _pumpHome(tester);
        final pick = store.nextMealPick(localeName: 'en')!;
        expect(pick.recipe.slug, _turkey);
        final hero = _key('recipe-hero');
        expect(
          find.descendant(of: hero, matching: find.text(_turkeyTitle)),
          findsOneWidget,
        );
        expect(find.text('PICKED FOR TONIGHT'), findsOneWidget);
        expect(_key('recipe-hero-fits'), findsOneWidget);
        expect(
          find.descendant(
            of: _key('recipe-hero-kcal'),
            matching: find.text('610'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: _key('recipe-hero-protein'),
            matching: find.text('58 g'),
          ),
          findsOneWidget,
        );
        expect(find.text('Add to dinner'), findsOneWidget);
        expect(_key('recipe-hero-ai-label'), findsOneWidget);
      });
    });

    testWidgets('"Add to dinner" logs the pick to TODAY\'s dinner even with '
        'another day open, and Undo removes exactly that entry', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final store = await _pumpHome(tester);
        store.setFoodDate(DateTime(2026, 9, 27));
        await tester.pumpAndSettle();
        final before = store.loggedMeals.length;

        await _tapVisible(tester, _key('recipe-hero-add'));

        expect(store.loggedMeals.length, before + 1);
        final added = store.loggedMeals.firstWhere(
          (m) => m.result.mealName == _turkeyTitle,
        );
        expect(added.forcedSlot, MealSlot.dinner);
        expect(added.effectiveLocalDay, localDayKey(_now));
        expect(added.result.caloriesKcal, 610);
        expect(find.text('Added 610 kcal to Dinner.'), findsOneWidget);

        // Dinner is filled now: the pick moves on, the hero follows.
        expect(
          store.nextMealPick(localeName: 'en')?.recipe.slug,
          isNot(_turkey),
        );
        expect(
          find.descendant(
            of: _key('recipe-hero'),
            matching: find.text(_turkeyTitle),
          ),
          findsNothing,
        );

        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        expect(store.loggedMeals.any((m) => m.id == added.id), isFalse);
        expect(store.loggedMeals.length, before);
        expect(
          find.descendant(
            of: _key('recipe-hero'),
            matching: find.text(_turkeyTitle),
          ),
          findsOneWidget,
        );
      });
    });

    testWidgets('a planned dinner is the pick and is eaten through the plan', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final store = await _pumpHome(tester);
        final plan = PlannedMeal.create(
          recipe: _catalog('hahnchen_caesar_salat'),
          day: _now,
          slot: MealSlot.dinner,
        );
        await store.savePlannedMeal(plan);
        await tester.pumpAndSettle();

        expect(find.text('FROM YOUR MEAL PLAN'), findsOneWidget);
        expect(
          find.descendant(
            of: _key('recipe-hero'),
            matching: find.text(_catalog('hahnchen_caesar_salat').title),
          ),
          findsOneWidget,
        );
        expect(_key('recipe-hero-fits'), findsOneWidget);

        await _tapVisible(tester, _key('recipe-hero-add'));

        expect(
          store.plannedMeals.firstWhere((p) => p.id == plan.id).isEaten,
          isTrue,
        );
        final eaten = store.loggedMeals.firstWhere((m) => m.id == plan.id);
        expect(eaten.forcedSlot, MealSlot.dinner);
        expect(eaten.effectiveLocalDay, localDayKey(_now));
      });
    });

    testWidgets('a planned pick with 2 servings logs exactly what the hero '
        'shows, marks the plan eaten and leaves one diary row', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final store = await _pumpHome(tester);
        final recipe = _catalog('hahnchen_caesar_salat');
        final plan = PlannedMeal.create(
          recipe: recipe,
          day: _now,
          slot: MealSlot.dinner,
          servings: 2,
        );
        await store.savePlannedMeal(plan);
        await tester.pumpAndSettle();

        final pick = store.nextMealPick(localeName: 'en')!;
        expect(pick.source, RecipePickSource.planned);
        expect(pick.servings, 2);
        expect(pick.kcal, recipe.caloriesKcal * 2);
        expect(
          find.descendant(
            of: _key('recipe-hero-kcal'),
            matching: find.text('${pick.kcal}'),
          ),
          findsOneWidget,
        );
        final before = store.loggedMeals.length;

        await _tapVisible(tester, _key('recipe-hero-add'));

        expect(store.loggedMeals.length, before + 1);
        final rows = store.loggedMeals
            .where((m) => m.result.mealName == recipe.title)
            .toList();
        expect(rows, hasLength(1), reason: 'no duplicate diary row');
        expect(rows.single.id, plan.id);
        expect(rows.single.result.caloriesKcal, pick.kcal);
        expect(rows.single.forcedSlot, MealSlot.dinner);
        expect(
          store.plannedMeals.firstWhere((p) => p.id == plan.id).isEaten,
          isTrue,
        );
        expect(find.text('Added ${pick.kcal} kcal to Dinner.'), findsOneWidget);
        // The eaten plan is no longer the pick: no second tap can log it.
        expect(
          store.nextMealPick(localeName: 'en')?.plannedMeal?.id,
          isNot(plan.id),
        );
      });
    });

    testWidgets('a planned pick without loggable kcal offers the meal plan, '
        'not a dead add; "View recipe" opens it read-only', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final store = await _pumpHome(tester);
        await store.savePlannedMeal(
          PlannedMeal.create(
            recipe: _pendingRecipe,
            day: _now,
            slot: MealSlot.dinner,
          ),
        );
        await tester.pumpAndSettle();
        expect(store.nextMealPick(localeName: 'en')!.kcal, isNull);

        expect(_key('recipe-hero-add'), findsNothing);
        expect(_key('recipe-hero-fits'), findsNothing);
        expect(
          find.descendant(
            of: _key('recipe-hero-kcal'),
            matching: find.text('—'),
          ),
          findsOneWidget,
        );
        await _tapVisible(tester, _key('recipe-hero-view'));
        expect(_key('recipe-detail-${_pendingRecipe.slug}'), findsOneWidget);
        expect(_key('recipe-add-card'), findsNothing);
        expect(_key('recipe-add-button'), findsNothing);
        expect(_key('recipe-detail-delete'), findsNothing);
        await tester.tap(_key('recipe-detail-back'));
        await tester.pumpAndSettle();

        await _tapVisible(tester, _key('recipe-hero-open-plan'));
        expect(find.byType(MealPlanScreen), findsOneWidget);
      });
    });

    testWidgets('"View recipe" of a loggable planned pick is read-only too: '
        'the plan entry is logged by the hero only', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final store = await _pumpHome(tester);
        await store.savePlannedMeal(
          PlannedMeal.create(
            recipe: _catalog('hahnchen_caesar_salat'),
            day: _now,
            slot: MealSlot.dinner,
          ),
        );
        await tester.pumpAndSettle();
        await _tapVisible(tester, _key('recipe-hero-view'));
        expect(_key('recipe-detail-hahnchen_caesar_salat'), findsOneWidget);
        expect(_key('recipe-add-button'), findsNothing);
        expect(_key('recipe-add-card'), findsNothing);
      });
    });

    testWidgets('"Fits your day" and the pick follow the remaining kcal', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final store = await _pumpHome(tester);
        // A suggestion always fits; logging 400 kcal (902 -> 502 left) moves
        // the pick to a recipe that still fits.
        await store.addResultToDailyTotal(
          _meal('Snack', 400),
          slot: MealSlot.snack,
        );
        await tester.pumpAndSettle();
        final pick = store.nextMealPick(localeName: 'en')!;
        expect(pick.recipe.slug, isNot(_turkey));
        expect(pick.kcal, lessThanOrEqualTo(502));
        expect(
          find.descendant(
            of: _key('recipe-hero'),
            matching: find.text(pick.recipe.title),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: _key('recipe-hero-kcal'),
            matching: find.text('${pick.kcal}'),
          ),
          findsOneWidget,
        );
        expect(_key('recipe-hero-fits'), findsOneWidget);

        // A planned dinner stays the pick even when it no longer fits: the
        // badge goes away.
        await store.savePlannedMeal(
          PlannedMeal.create(
            recipe: _catalog(_turkey),
            day: _now,
            slot: MealSlot.dinner,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: _key('recipe-hero'),
            matching: find.text(_turkeyTitle),
          ),
          findsOneWidget,
        );
        expect(_key('recipe-hero-fits'), findsNothing);
      });
    });

    testWidgets('the bookmark pins the pick as a favorite and unpins it', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final semantics = tester.ensureSemantics();
        try {
          final store = await _pumpHome(tester);
          final result = _catalog(_turkey).toMealResultForServings(1, _en);
          expect(store.isFavorite(result), isFalse);
          final save = _key('recipe-hero-save');
          expect(
            tester.getSemantics(save),
            isSemantics(
              label: 'Save as favorite',
              isButton: true,
              hasToggledState: true,
              isToggled: false,
              hasTapAction: true,
            ),
          );

          await _tapVisible(tester, save);
          expect(store.isFavorite(result), isTrue);
          expect(
            store.favorites
                .where((f) => f.pinned)
                .map((f) => f.result.mealName),
            contains(_turkeyTitle),
          );
          expect(
            tester.getSemantics(save),
            isSemantics(
              label: 'Remove from favorites',
              isButton: true,
              hasToggledState: true,
              isToggled: true,
              hasTapAction: true,
            ),
          );

          await _tapVisible(tester, save);
          expect(store.isFavorite(result), isFalse);
        } finally {
          semantics.dispose();
        }
      });
    });

    testWidgets('"View recipe" opens that recipe', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        await _pumpHome(tester);
        await _tapVisible(tester, _key('recipe-hero-view'));
        expect(_key('recipe-detail-$_turkey'), findsOneWidget);
        // A suggestion's detail keeps its own add action.
        expect(_key('recipe-add-button'), findsOneWidget);
      });
    });

    testWidgets('without a pick the hero is the best goal match: no "fits" '
        'claim, and its add button logs through the slot sheet', (
      tester,
    ) async {
      // 22:00: no main meal is open any more, so there is no pick.
      await withClock(Clock.fixed(DateTime(2026, 9, 28, 22)), () async {
        final store = await _pumpHome(tester);
        expect(store.nextMealPick(localeName: 'en'), isNull);
        expect(_key('recipe-hero'), findsOneWidget);
        expect(find.text('FITS YOUR GOAL'), findsOneWidget);
        expect(_key('recipe-hero-fits'), findsNothing);
        expect(find.text('Add to tracker'), findsOneWidget);
        final title = tester.widget<Text>(_key('recipe-hero-title')).data!;
        final before = store.loggedMeals.length;

        await _tapVisible(tester, _key('recipe-hero-add'));
        expect(_key('recipe-meal-picker-sheet'), findsOneWidget);
        await _tapVisible(tester, _key('recipe-meal-picker-lunch'));

        expect(store.loggedMeals.length, before + 1);
        final added = store.loggedMeals.firstWhere(
          (m) => m.result.mealName == title,
        );
        expect(added.forcedSlot, MealSlot.lunch);
      });
    });
  });

  group('shelves and cards', () {
    testWidgets('lean shelf: a card opens its recipe; "See all" lists the '
        'whole set with no chip selected', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        await _pumpHome(tester, ownRecipes: true);
        final poke = designOwnRecipes[1];
        await _tapVisible(tester, _key('recipe-shelf-lean-${poke.slug}'));
        expect(_key('recipe-detail-${poke.slug}'), findsOneWidget);
        await tester.tap(_key('recipe-detail-back'));
        await tester.pumpAndSettle();

        await _tapVisible(tester, _key('recipe-lean-see-all'));
        // The list it opens starts at the top.
        expect(tester.state<ScrollableState>(recipesList()).position.pixels, 0);
        final expected = leanHighProteinRecipes(<FitnessRecipe>[
          ...designOwnRecipes.reversed,
          ...recipeCatalogEn,
        ]);
        expect(find.text('High protein, under 500 kcal'), findsOneWidget);
        expect(find.text('${expected.length} matches'), findsOneWidget);
        expect(_rowSlugs(tester), expected.map((r) => r.slug).toList());
        expect(await _selectedChips(tester), isEmpty);
      });
    });

    testWidgets('the lean shelf hides when nothing qualifies', (tester) async {
      // Vegan: none of the catalog's shelf recipes is vegan.
      await withClock(Clock.fixed(_now), () async {
        pinDesignViewport(tester);
        await pumpLocalized(
          tester,
          RecipesScreen(
            onAddMeal: (MealAnalysisResult _, MealSlot __) {},
            diet: DietPreference.vegan,
            remainingMacros: const MacroProgress(
              proteinG: 60,
              carbsG: 80,
              fatG: 30,
              kcal: 900,
            ),
          ),
          locale: const Locale('en'),
          settle: true,
        );
        expect(_key('recipe-hero'), findsOneWidget);
        expect(_key('recipe-shelf-lean'), findsNothing);
        await _reveal(tester, _key('recipes-your-recipes'));
        expect(_key('recipes-your-recipes'), findsOneWidget);
      });
    });

    testWidgets('goal-match cards open their recipe', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        await _pumpHome(tester);
        final shelf = _key('recipe-goal-matches');
        await _reveal(tester, shelf);
        final card = find
            .descendant(
              of: shelf,
              matching: find.byWidgetPredicate(
                (w) =>
                    w.key is ValueKey<String> &&
                    (w.key! as ValueKey<String>).value.startsWith(
                      'recipe-goal-match-',
                    ),
              ),
            )
            .first;
        final slug = (tester.widget(card).key! as ValueKey<String>).value
            .substring('recipe-goal-match-'.length);
        await _tapVisible(tester, card);
        expect(_key('recipe-detail-$slug'), findsOneWidget);
      });
    });

    testWidgets('"See all" of More recommendations opens All', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        await _pumpHome(tester);
        await _tapVisible(tester, _key('recipes-more-see-all'));
        expect(await _selectedChips(tester), {'recipes-tab-all'});
      });
    });

    testWidgets('Your recipes: Import and Create open their sheets', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        await _pumpHome(tester);
        await _tapVisible(tester, _key('recipe-import-button'));
        expect(_key('recipe-import-sheet'), findsOneWidget);
        await tester
            .state<NavigatorState>(find.byType(Navigator).first)
            .maybePop();
        await tester.pumpAndSettle();

        await _tapVisible(tester, _key('recipe-create-button'));
        expect(_key('recipe-create-sheet'), findsOneWidget);
      });
    });
  });

  group('screen seams', () {
    testWidgets('no pick and no goal match: no hero, no dead controls', (
      tester,
    ) async {
      pinPhoneViewport(tester);
      await pumpLocalized(
        tester,
        RecipesScreen(onAddMeal: (MealAnalysisResult _, MealSlot __) {}),
        locale: const Locale('en'),
        settle: true,
      );
      expect(_key('recipe-hero'), findsNothing);
      // Without a meal-plan hook there is no calendar button at all.
      expect(_key('recipe-meal-plan-button'), findsNothing);
      // Without an import hook "+" creates directly.
      await tester.tap(_key('recipe-add-choice-button'));
      await tester.pumpAndSettle();
      expect(_key('recipe-add-choice-sheet'), findsNothing);
      expect(_key('recipe-create-sheet'), findsOneWidget);
    });

    testWidgets('a planned pick without kcal and without a meal plan hook '
        'shows no primary button', (tester) async {
      pinPhoneViewport(tester);
      await pumpLocalized(
        tester,
        RecipesScreen(
          onAddMeal: (MealAnalysisResult _, MealSlot __) {},
          onEatPlannedMeal: (_) async => SyncDelivery.delivered,
          mealPick: RecipePick(
            recipe: _pendingRecipe,
            slot: MealSlot.dinner,
            source: RecipePickSource.planned,
            servings: 1,
            kcal: null,
            proteinG: null,
            remainingKcalBefore: 900,
            plannedMeal: PlannedMeal.create(
              recipe: _pendingRecipe,
              day: _now,
              slot: MealSlot.dinner,
            ),
          ),
        ),
        locale: const Locale('en'),
        settle: true,
      );
      expect(_key('recipe-hero'), findsOneWidget);
      expect(_key('recipe-hero-add'), findsNothing);
      expect(_key('recipe-hero-open-plan'), findsNothing);
      expect(_key('recipe-hero-view'), findsOneWidget);
    });

    testWidgets('recipe history stays reachable from My recipes', (
      tester,
    ) async {
      pinPhoneViewport(tester);
      var loads = 0;
      await pumpLocalized(
        tester,
        RecipesScreen(
          onAddMeal: (MealAnalysisResult _, MealSlot __) {},
          onLoadRecipeHistory: ({String? slug, int? beforeRevision}) async {
            loads++;
            return const RecipeHistoryPage(
              versions: [],
              currentRevision: null,
              currentDeleted: null,
              nextBefore: null,
            );
          },
          onRestoreRecipe: (recipe, {required int expectedRevision}) async =>
              SyncDelivery.delivered,
        ),
        locale: const Locale('en'),
        settle: true,
      );
      expect(_key('recipe-history-open'), findsNothing);
      await tester.tap(_key('recipes-tab-own'));
      await tester.pumpAndSettle();
      await _tapVisible(tester, _key('recipe-history-open'));
      expect(find.byType(RecipeHistoryScreen), findsOneWidget);
      expect(loads, greaterThan(0));
    });

    testWidgets('goal-match hero numbers come from the recipe, the shelf '
        'excludes it', (tester) async {
      pinPhoneViewport(tester);
      const remaining = MacroProgress(
        proteinG: 90,
        carbsG: 180,
        fatG: 50,
        kcal: 1600,
      );
      await pumpLocalized(
        tester,
        RecipesScreen(
          onAddMeal: (MealAnalysisResult _, MealSlot __) {},
          remainingMacros: remaining,
        ),
        locale: const Locale('en'),
        settle: true,
      );
      final best = recipeCatalogEn
          .map((r) => (r, r.matchScore(remaining)))
          .reduce((a, b) => b.$2 > a.$2 ? b : a)
          .$1;
      expect(tester.widget<Text>(_key('recipe-hero-title')).data, best.title);
      expect(
        find.descendant(
          of: _key('recipe-hero-kcal'),
          matching: find.text('${best.caloriesKcal}'),
        ),
        findsOneWidget,
      );
      expect(_key('recipe-goal-match-${best.slug}'), findsNothing);
    });
  });

  group('accessibility', () {
    testWidgets('every control has a label and a 44 px target', (tester) async {
      await withClock(Clock.fixed(_now), () async {
        final semantics = tester.ensureSemantics();
        try {
          await _pumpHome(tester, ownRecipes: true);
          await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          expect(
            tester.getSemantics(_key('recipe-meal-plan-button')),
            isSemantics(label: 'Meal plan', isButton: true, hasTapAction: true),
          );
          expect(
            tester.getSemantics(_key('recipe-add-choice-button')),
            isSemantics(
              label: 'New or imported recipe',
              isButton: true,
              hasTapAction: true,
            ),
          );
          expect(
            tester.getSemantics(_key('recipes-tab-for-you')),
            isSemantics(
              label: 'For you',
              isButton: true,
              hasSelectedState: true,
              isSelected: true,
              hasTapAction: true,
            ),
          );
          final hero = tester.renderObject<RenderBox>(_key('recipe-hero-add'));
          expect(hero.size.height, greaterThanOrEqualTo(44));
        } finally {
          semantics.dispose();
        }
      });
    });
  });
}
