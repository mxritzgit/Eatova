// Review 2026-10-19 (P1): the Recipes tab promotes (For you: hero, lean
// shelf and its "See all", more recommendations, goal matches) only what the
// user eats; the browse list and the detail keep everything and say what an
// avoided recipe contains.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/food_preferences.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';

import '../support/harness.dart';

const _avoided = {
  FoodAvoidance.lactose,
  FoodAvoidance.gluten,
  FoodAvoidance.nuts,
  FoodAvoidance.fish,
};

const _rest = MacroProgress(proteinG: 60, carbsG: 80, fatG: 25, kcal: 700);

void _tallSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 20000);
  addTearDown(tester.view.reset);
}

Future<void> _pump(
  WidgetTester tester, {
  Set<FoodAvoidance> avoidances = const {},
  Locale locale = const Locale('de'),
}) async {
  await tester.pumpWidget(
    localizedApp(
      RecipesScreen(
        onAddMeal: (MealAnalysisResult _, MealSlot __) {},
        remainingMacros: _rest,
        avoidances: avoidances,
      ),
      locale: locale,
    ),
  );
  await tester.pumpAndSettle();
}

/// Slugs behind the keys with [prefix], in tree order.
List<String> _slugs(WidgetTester tester, String prefix) => tester
    .widgetList(
      find.byWidgetPredicate((w) {
        final key = w.key;
        return key is ValueKey<String> && key.value.startsWith(prefix);
      }),
    )
    .map((w) => (w.key! as ValueKey<String>).value.substring(prefix.length))
    .toList(growable: false);

/// Every recipe For you promotes: hero, lean shelf, recipe rows, goal cards.
List<String> _promoted(WidgetTester tester) => [
  ..._slugs(tester, 'recipe-hero-photo-'),
  ..._slugs(tester, 'recipe-shelf-lean-'),
  ..._slugs(tester, 'recipe-tile-'),
  ..._slugs(tester, 'recipe-goal-match-'),
];

FitnessRecipe _recipe(String slug) =>
    recipeCatalogDe.firstWhere((r) => r.slug == slug);

Finder _hint(String slug) => find.byKey(ValueKey('recipe-avoid-hint-$slug'));

const _lachs = 'lachs_mit_sukartoffel_and_spargel';
const _haehnchen = 'hahnchen_mit_reis_and_brokkoli';

void main() {
  testWidgets('Für dich empfiehlt nichts, was gemieden wird', (tester) async {
    _tallSurface(tester);
    await withClock(Clock.fixed(DateTime(2026, 10, 19, 12)), () async {
      await _pump(tester);
      final before = _promoted(tester);
      expect(
        before.any((slug) => !_recipe(slug).fitsAvoidances(_avoided)),
        isTrue,
        reason: 'Vorbedingung: ohne Filter empfiehlt die Seite Gemiedenes',
      );

      await _pump(tester, avoidances: _avoided);
      final after = _promoted(tester);
      expect(after, isNotEmpty);
      for (final slug in after) {
        expect(_recipe(slug).fitsAvoidances(_avoided), isTrue, reason: slug);
      }
      expect(_slugs(tester, 'recipe-avoid-hint-'), isEmpty);
      // Every lean catalog dish has dairy: the shelf hides itself.
      expect(find.byKey(const ValueKey('recipe-shelf-lean')), findsNothing);

      // The lean shelf's "See all" is its full list and filtered alike.
      const fishAndNuts = {FoodAvoidance.fish, FoodAvoidance.nuts};
      await _pump(tester, avoidances: fishAndNuts);
      await tester.tap(find.byKey(const ValueKey('recipe-lean-see-all')));
      await tester.pumpAndSettle();
      final all = _slugs(tester, 'recipe-tile-');
      expect(all, isNotEmpty);
      for (final slug in all) {
        expect(_recipe(slug).fitsAvoidances(fishAndNuts), isTrue, reason: slug);
      }
      expect(all, isNot(contains('hahnchen_caesar_salat')));
    });
  });

  testWidgets('Alle Rezepte behält gemiedene Rezepte, mit leisem Hinweis', (
    tester,
  ) async {
    _tallSurface(tester);
    await _pump(tester, avoidances: const {FoodAvoidance.fish});
    await tester.tap(find.byKey(const ValueKey('recipes-tab-all')));
    await tester.pumpAndSettle();

    expect(_slugs(tester, 'recipe-tile-'), hasLength(recipeCatalogDe.length));
    expect(_hint(_lachs), findsOneWidget);
    expect(
      find.descendant(of: _hint(_lachs), matching: find.text('Enthält Fisch')),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(_hint(_lachs)).label,
      'Enthält, was du nicht isst: Fisch',
    );
    expect(_hint(_haehnchen), findsNothing);
    final hinted = _slugs(tester, 'recipe-avoid-hint-').toSet();
    expect(hinted, {
      for (final r in recipeCatalogDe)
        if (!r.fitsAvoidances(const {FoodAvoidance.fish})) r.slug,
    });

    // The detail says it too.
    await tester.tap(find.byKey(const ValueKey('recipe-tile-$_lachs')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recipe-detail-$_lachs')), findsOneWidget);
    expect(_hint(_lachs), findsOneWidget);
  });

  testWidgets('ohne gemiedene Lebensmittel kein Hinweis, englischer Text', (
    tester,
  ) async {
    _tallSurface(tester);
    await _pump(tester, locale: const Locale('en'));
    await tester.tap(find.byKey(const ValueKey('recipes-tab-all')));
    await tester.pumpAndSettle();
    expect(_slugs(tester, 'recipe-avoid-hint-'), isEmpty);

    await _pump(
      tester,
      locale: const Locale('en'),
      avoidances: const {FoodAvoidance.mustard, FoodAvoidance.fish},
    );
    expect(
      find.descendant(
        of: _hint(_lachs),
        matching: find.text('Contains: Fish, Mustard'),
      ),
      findsOneWidget,
    );
  });
}
