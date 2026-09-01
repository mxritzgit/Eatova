// Fix-Lauf 2026-08-27, Paket I (F6-04): Empfehlungs-Karussell.
//
//   * Eigene Rezepte (Platzhalter-Streifen statt Foto) sind keine
//     „Empfehlung" — sie bleiben draußen, der Badge gehört dem Katalog.
//   * Die Auswahl rotiert mit dem Kalendertag (`clock.now()`), statt immer
//     dieselben vier Karten zu zeigen.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';

import 'support/harness.dart';

const _eigenes = FitnessRecipe(
  slug: 'user_mein_teller',
  title: 'Mein Testteller',
  description: '',
  portion: '',
  ingredients: '',
  preparation: '',
  professionalHint: '',
  imageAsset: '',
  caloriesKcal: 520,
  proteinG: 40,
  carbsG: 50,
  fatG: 15,
  estimatedGrams: 300,
  categories: <String>['Eigene'],
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
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
  );
}

void _pinViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Finder _karussell() => find.byKey(const ValueKey('recipe-recommended'));

Finder _karte(String slug) => find.descendant(
      of: _karussell(),
      matching: find.byKey(ValueKey('recipe-recommended-$slug')),
    );

/// Pinned day for the cases that do not test the rotation itself (K-02): the
/// carousel picks its cards off `clock.now()` at BUILD time while the
/// expectation reads the clock again at assertion time, so on the real clock a
/// midnight rollover between the two would compare two different days.
final DateTime _tag = DateTime(2026, 8, 15, 12);

void main() {
  testWidgets('eigene Rezepte stehen nie im Karussell — auch nicht an '
      'erster Stelle', (tester) async {
    _pinViewport(tester);
    await withClock(Clock.fixed(_tag), () async {
      await _pumpApp(tester, userRecipes: [_eigenes]);
      await tester.pumpAndSettle();

      expect(_karussell(), findsOneWidget);
      // Wäre es drin, stünde es (wie in der Liste) vorne und wäre gerendert.
      expect(_karte(_eigenes.slug), findsNothing);
      // Der Katalog ist es, der empfohlen wird.
      final erste = rotatedRecommendations(recipeCatalogDe, _tag).first;
      expect(_karte(erste.slug), findsOneWidget);
      // In der Hauptliste bleibt das eigene Rezept vorne.
      expect(
          find.byKey(ValueKey('recipe-tile-${_eigenes.slug}')), findsOneWidget);
    });
  });

  testWidgets('der Badge „EMPFOHLEN" hängt nur an Katalog-Karten',
      (tester) async {
    _pinViewport(tester);
    await withClock(Clock.fixed(_tag), () async {
      await _pumpApp(tester, userRecipes: [_eigenes]);
      await tester.pumpAndSettle();

      // Jede gerenderte Karte im Karussell trägt den Badge — und jede davon
      // ist eine Katalog-Karte. Der eigene Eintrag muss dabei WIRKLICH im
      // Fenster liegen, sonst prüft die Schleife nur, dass ein Katalog-Rezept
      // ein Katalog-Rezept ist: mit dem eigenen Rezept im Topf stünde es an
      // Position `_tag % (n + 1)`, und ein Deckel auf die Kartenzahl könnte es
      // sonst zufällig hinausschieben.
      final mitEigenem = rotatedRecommendations(
        <FitnessRecipe>[_eigenes, ...recipeCatalogDe],
        _tag,
      );
      expect(mitEigenem.first.slug, _eigenes.slug,
          reason: 'Vorbedingung: an diesem Tag WÜRDE das eigene Rezept ins '
              'Fenster fallen, wenn der Topf es enthielte');

      final karten = find.descendant(
        of: _karussell(),
        matching: find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>)
                  .value
                  .startsWith('recipe-recommended-'),
        ),
      );
      final badges = find.descendant(
        of: _karussell(),
        matching: find.text('EMPFOHLEN'),
      );
      expect(karten, findsWidgets);
      expect(badges.evaluate().length, karten.evaluate().length);
      for (final karte in karten.evaluate()) {
        final slug = (karte.widget.key! as ValueKey<String>)
            .value
            .substring('recipe-recommended-'.length);
        expect(slug, isNot(_eigenes.slug));
        expect(recipeCatalogDe.any((r) => r.slug == slug), isTrue, reason: slug);
      }
    });
  });

  testWidgets('die Auswahl rotiert mit dem Kalendertag', (tester) async {
    _pinViewport(tester);
    final tag1 = DateTime(2026, 8, 27, 12);
    final tag2 = DateTime(2026, 8, 28, 12);

    await withClock(Clock.fixed(tag1), () async {
      await _pumpApp(tester);
      await tester.pumpAndSettle();
      final erwartet = rotatedRecommendations(recipeCatalogDe, tag1).first;
      expect(_karte(erwartet.slug), findsOneWidget);
    });

    await withClock(Clock.fixed(tag2), () async {
      await _pumpApp(tester);
      await tester.pumpAndSettle();
      final erwartet1 = rotatedRecommendations(recipeCatalogDe, tag1).first;
      final erwartet2 = rotatedRecommendations(recipeCatalogDe, tag2).first;
      expect(erwartet2.slug, isNot(erwartet1.slug));
      expect(_karte(erwartet2.slug), findsOneWidget);
      expect(_karte(erwartet1.slug), findsNothing,
          reason: 'Die Karte von gestern ist heute nicht mehr die erste.');
    });
  });

  testWidgets('Ernährungsfilter greift weiterhin: vegan sieht kein Hähnchen '
      'im Karussell', (tester) async {
    _pinViewport(tester);
    await withClock(Clock.fixed(DateTime(2026, 8, 27, 12)), () async {
      await _pumpApp(tester, diet: DietPreference.vegan);
      await tester.pumpAndSettle();

      final vegan = recipeCatalogDe
          .where((r) => r.matchesDiet(DietPreference.vegan))
          .toList(growable: false);
      final erwartet =
          rotatedRecommendations(vegan, DateTime(2026, 8, 27, 12)).first;
      expect(_karte(erwartet.slug), findsOneWidget);
      expect(_karte('hahnchen_mit_reis_and_brokkoli'), findsNothing);
    });
  });
}
