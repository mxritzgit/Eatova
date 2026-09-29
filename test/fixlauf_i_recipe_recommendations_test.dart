// Fix-Lauf 2026-08-27, Paket I (F6-04): Empfehlungs-Karussell.
//
// Seit dem Dark-Redesign (2026-09-28) ist das Karussell von "Für dich" das
// Regal „Viel Protein, unter 500 kcal": ein Filter über die sichtbaren
// Rezepte statt einer Katalog-Empfehlung. Was von F6-04 bleibt:
//
//   * Die Auswahl rotiert mit dem Kalendertag (`clock.now()`), statt immer
//     dieselben Katalog-Karten zu zeigen.
//   * Der Ernährungsfilter greift vor der Auswahl.
//
// Neu nach der Design-Vorgabe: eigene Rezepte, die den Filter erfüllen,
// stehen vorne — mit der leuchtenden Platzhalter-Grafik statt des Streifens —,
// eigene Rezepte, die ihn nicht erfüllen, nie.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/recipe_shelf.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/widgets/design/design.dart';

import 'support/harness.dart';

FitnessRecipe _eigenes(String slug, {int kcal = 420, int protein = 38}) =>
    FitnessRecipe(
      slug: 'user_$slug',
      title: 'Mein $slug',
      description: '',
      portion: '',
      ingredients: '',
      preparation: '',
      professionalHint: '',
      imageAsset: '',
      caloriesKcal: kcal,
      proteinG: protein,
      carbsG: 50,
      fatG: 15,
      estimatedGrams: 300,
      categories: const <String>['Eigene'],
      userCreated: true,
    );

Future<void> _pumpApp(
  WidgetTester tester, {
  List<FitnessRecipe> userRecipes = const <FitnessRecipe>[],
  DietPreference diet = DietPreference.none,
}) {
  return pumpLocalized(
    tester,
    RecipesScreen(
      onAddMeal: (MealAnalysisResult _, MealSlot __) {},
      initialUserRecipes: userRecipes,
      diet: diet,
    ),
  );
}

void _pinViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Finder _regal() => find.byKey(const ValueKey('recipe-shelf-lean'));

/// Slugs der Regal-Karten in Reihenfolge.
List<String> _karten(WidgetTester tester) => tester
    .widgetList(
      find.descendant(
        of: _regal(),
        matching: find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'recipe-shelf-lean-',
              ),
        ),
      ),
    )
    .map(
      (w) => (w.key! as ValueKey<String>).value.substring(
        'recipe-shelf-lean-'.length,
      ),
    )
    .toList(growable: false);

List<FitnessRecipe> get _katalogTreffer =>
    recipeCatalogDe.where(isLeanHighProtein).toList(growable: false);

/// Fester Tag für die Fälle, die nicht die Rotation selbst prüfen (K-02).
final DateTime _tag = DateTime(2026, 8, 15, 12);

void main() {
  testWidgets('eigene Treffer stehen vorne, mit Platzhalter-Grafik; eigene '
      'Nicht-Treffer nie', (tester) async {
    _pinViewport(tester);
    final treffer = _eigenes('bowl');
    final schwer = _eigenes('schwer', kcal: 650, protein: 50);
    await withClock(Clock.fixed(_tag), () async {
      await _pumpApp(tester, userRecipes: [treffer, schwer]);
      await tester.pumpAndSettle();

      final karten = _karten(tester);
      expect(karten.first, treffer.slug);
      expect(karten, isNot(contains(schwer.slug)));
      expect(
        karten.skip(1),
        rotatedRecommendations(
          _katalogTreffer,
          _tag,
          count: _katalogTreffer.length,
        ).map((r) => r.slug),
      );
      // Kein Foto: die leuchtende Grafik des Designs, nie der Streifen.
      final karte = find.byKey(ValueKey('recipe-shelf-lean-${treffer.slug}'));
      expect(
        find.descendant(of: karte, matching: find.byType(ImagePlaceholder)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: karte,
          matching: find.byKey(const ValueKey('recipe-art-bowl')),
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('die Katalog-Auswahl rotiert mit dem Kalendertag', (
    tester,
  ) async {
    _pinViewport(tester);
    final tag1 = DateTime(2026, 8, 27, 12);
    final tag2 = DateTime(2026, 8, 28, 12);

    await withClock(Clock.fixed(tag1), () async {
      await _pumpApp(tester);
      await tester.pumpAndSettle();
      expect(
        _karten(tester).first,
        rotatedRecommendations(_katalogTreffer, tag1).first.slug,
      );
    });

    await withClock(Clock.fixed(tag2), () async {
      await _pumpApp(tester);
      await tester.pumpAndSettle();
      final erwartet1 = rotatedRecommendations(_katalogTreffer, tag1).first;
      final erwartet2 = rotatedRecommendations(_katalogTreffer, tag2).first;
      expect(erwartet2.slug, isNot(erwartet1.slug));
      expect(
        _karten(tester).first,
        erwartet2.slug,
        reason: 'Die Karte von gestern ist heute nicht mehr die erste.',
      );
    });
  });

  testWidgets('Ernährungsfilter greift weiterhin: vegetarisch sieht keinen '
      'Caesar Salad, vegan ein leeres und damit verstecktes Regal', (
    tester,
  ) async {
    _pinViewport(tester);
    await withClock(Clock.fixed(DateTime(2026, 8, 27, 12)), () async {
      await _pumpApp(tester, diet: DietPreference.vegetarian);
      await tester.pumpAndSettle();
      final karten = _karten(tester);
      expect(karten, isNotEmpty);
      expect(karten, isNot(contains('hahnchen_caesar_salat')));
      for (final slug in karten) {
        final rezept = recipeCatalogDe.firstWhere((r) => r.slug == slug);
        expect(
          rezept.matchesDiet(DietPreference.vegetarian),
          isTrue,
          reason: slug,
        );
      }

      await _pumpApp(tester, diet: DietPreference.vegan);
      await tester.pumpAndSettle();
      expect(
        _regal(),
        findsNothing,
        reason: 'Kein veganer Katalog-Treffer: das Regal blendet sich aus.',
      );
    });
  });
}
