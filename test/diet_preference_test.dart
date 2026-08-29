import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';

import 'support/harness.dart';

// PROD-6: a vegetarian or vegan profile must NEVER be actively recommended a
// meat or fish recipe, while manual browsing stays unrestricted on purpose.
// One widget test covers the real screen wiring.

FitnessRecipe _byTitle(String title) =>
    fitnessRecipes.firstWhere((r) => r.title == title);

void main() {
  group('FitnessRecipe.matchesDiet (reine Eignungs-Heuristik)', () {
    final lachs = _byTitle('Lachs mit Süßkartoffel & Spargel'); // fish
    final rind = _byTitle('Rindersteak mit Kartoffeln & Bohnen'); // meat
    final tofu = _byTitle('Tofu mit Reis & Edamame'); // vegetarian tag
    // Egg dish; carries the `Vegetarisch` tag since P2-03.
    final omelett = _byTitle('Omelett mit Spinat & Avocado');

    test('none erlaubt jedes Rezept', () {
      for (final r in fitnessRecipes) {
        expect(r.matchesDiet(DietPreference.none), isTrue,
            reason: '${r.title} sollte bei "none" passen');
      }
    });

    test('vegetarian schließt Fisch UND Fleisch aus', () {
      expect(lachs.matchesDiet(DietPreference.vegetarian), isFalse);
      expect(rind.matchesDiet(DietPreference.vegetarian), isFalse);
      expect(tofu.matchesDiet(DietPreference.vegetarian), isTrue);
      expect(omelett.matchesDiet(DietPreference.vegetarian), isTrue); // egg = veg
    });

    test('vegan: nur explizit pflanzlich markierte Gerichte, keine Eier', () {
      expect(tofu.matchesDiet(DietPreference.vegan), isTrue);
      expect(omelett.matchesDiet(DietPreference.vegan), isFalse); // egg not vegan
      expect(lachs.matchesDiet(DietPreference.vegan), isFalse);
      expect(rind.matchesDiet(DietPreference.vegan), isFalse);
    });

    test('pescetarian erlaubt Fisch, aber kein Fleisch', () {
      expect(lachs.matchesDiet(DietPreference.pescetarian), isTrue);
      expect(rind.matchesDiet(DietPreference.pescetarian), isFalse);
      expect(tofu.matchesDiet(DietPreference.pescetarian), isTrue);
    });

    test('Eigen-Rezepte werden nie wegen Präferenz gefiltert', () {
      final own = FitnessRecipe(
        slug: FitnessRecipe.userRecipeSlug(),
        title: 'Mein Steak-Teller',
        description: 'd',
        portion: '1',
        ingredients: 'Rind',
        preparation: 'p',
        professionalHint: 'h',
        imageAsset: '',
        caloriesKcal: 700,
        proteinG: 50,
        carbsG: 40,
        fatG: 30,
        estimatedGrams: 500,
        categories: const <String>['Hauptgericht', 'High Protein'],
        userCreated: true,
      );
      expect(own.matchesDiet(DietPreference.vegan), isTrue);
    });

    test('vegetarian filtert die Bestandsliste auf rein veg/ei-Gerichte', () {
      final veg = fitnessRecipes
          .where((r) => r.matchesDiet(DietPreference.vegetarian))
          .map((r) => r.title)
          .toList();
      expect(veg, isNot(contains('Lachs mit Süßkartoffel & Spargel')));
      expect(veg, isNot(contains('Rindersteak mit Kartoffeln & Bohnen')));
      expect(veg, isNot(contains('Garnelen mit Vollkornnudeln & Zucchini')));
      expect(veg, contains('Tofu mit Reis & Edamame'));
    });
  });

  // P2-03 (Review 2026-08-29): Filter-Chip und Empfehlung widersprachen sich.
  // `matchesDiet` liess das Omelett ueber `isMeat == false` durch und empfahl
  // es Vegetariern aktiv, waehrend der Chip `categories.contains('Vegetarisch')`
  // auswertet und es ausblendete — dasselbe Gericht, zwei Antworten.
  group('Katalog-Tags und matchesDiet sagen dasselbe (P2-03)', () {
    for (final (sprache, katalog) in <(String, List<FitnessRecipe>)>[
      ('de', recipeCatalogDe),
      ('en', recipeCatalogEn),
    ]) {
      test('$sprache: vegetarisch empfohlen == unter dem Chip auffindbar', () {
        for (final r in katalog) {
          expect(
            r.matchesDiet(DietPreference.vegetarian),
            r.categories.contains('Vegetarisch'),
            reason: '${r.slug}: Chip und Empfehlung widersprechen sich '
                '(${r.categories}).',
          );
        }
      });

      test('$sprache: jedes vegane Rezept traegt auch den Vegetarisch-Tag', () {
        // Sonst faende der Vegetarisch-Chip die veganen Teller nicht.
        for (final r in katalog.where((r) => r.categories.contains('Vegan'))) {
          expect(r.categories, contains('Vegetarisch'), reason: r.slug);
        }
      });

      test('$sprache: 12 fleisch- und fischfreie Rezepte, alle getaggt', () {
        // Nachgezaehlt: 11 trugen den Tag schon, das Omelett kam mit P2-03
        // dazu. Der Befund nannte "10 von 11" — beide Zahlen waren um eins
        // daneben, die Richtung stimmte.
        final vegetarisch = katalog
            .where((r) => r.matchesDiet(DietPreference.vegetarian))
            .toList(growable: false);
        expect(vegetarisch, hasLength(12));
        expect(katalog.where((r) => r.categories.contains('Fisch')),
            hasLength(6));
      });
    }

    test('ein Fleischgericht OHNE Hauptgericht/High-Protein-Tag wird '
        'Vegetariern nicht empfohlen', () {
      // Nebenbefund derselben Wurzel: `isMeat` hing frueher an
      // `Hauptgericht`/`High Protein`. Ein kuenftiges Speck-Fruehstueck mit nur
      // `Frühstück` waere als diaet-neutral durchgerutscht.
      const speckfruehstueck = FitnessRecipe(
        slug: 'speck_und_ei',
        title: 'Speck & Ei',
        description: 'd',
        portion: '1',
        ingredients: 'Speck',
        preparation: 'p',
        professionalHint: 'h',
        imageAsset: '',
        caloriesKcal: 500,
        proteinG: 25,
        carbsG: 10,
        fatG: 40,
        estimatedGrams: 300,
        categories: <String>['Frühstück', 'Low Carb'],
      );
      expect(speckfruehstueck.matchesDiet(DietPreference.vegetarian), isFalse);
      expect(speckfruehstueck.matchesDiet(DietPreference.pescetarian), isFalse);
      expect(speckfruehstueck.matchesDiet(DietPreference.vegan), isFalse);
      expect(speckfruehstueck.matchesDiet(DietPreference.none), isTrue);
    });
  });

  group('RecipesScreen empfiehlt keine präferenz-verletzenden Rezepte', () {
    // Macros where the meat/fish plates would rank top without a filter.
    const remaining =
        MacroProgress(proteinG: 60, carbsG: 60, fatG: 25, kcal: 700);

    Future<void> pump(WidgetTester tester, DietPreference diet) async {
      tester.view.physicalSize = const Size(1179, 2556);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await pumpLocalized(
        tester,
        RecipesScreen(
          diet: diet,
          remainingMacros: remaining,
          onAddMeal: (MealAnalysisResult _, MealSlot __) {},
        ),
        reducedMotion: false,
        safeArea: false,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('vegetarisch: kein Lachs/Rindersteak im Ziel-Match-Carousel',
        (tester) async {
      await pump(tester, DietPreference.vegetarian);

      // Goal matches sit at the list end of a lazy list.
      final goalMatches = find.byKey(const ValueKey('recipe-goal-matches'));
      await tester.dragUntilVisible(
        goalMatches,
        find.byKey(const ValueKey('screen-recipes')),
        const Offset(0, -250),
      );
      await tester.pumpAndSettle();
      expect(goalMatches, findsOneWidget);

      // Never in the promoted carousel; in the main list they may, by design.
      expect(
        find.descendant(
          of: goalMatches,
          matching: find.text('Lachs mit Süßkartoffel & Spargel'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: goalMatches,
          matching: find.text('Rindersteak mit Kartoffeln & Bohnen'),
        ),
        findsNothing,
      );
    });

    testWidgets('none: Lachs darf weiterhin als Ziel-Match erscheinen',
        (tester) async {
      await pump(tester, DietPreference.none);
      // Without a preference the unfiltered path is active.
      expect(find.byKey(const ValueKey('screen-recipes')), findsOneWidget);
      final goalMatches = find.byKey(const ValueKey('recipe-goal-matches'));
      await tester.dragUntilVisible(
        goalMatches,
        find.byKey(const ValueKey('screen-recipes')),
        const Offset(0, -250),
      );
      await tester.pumpAndSettle();
      expect(goalMatches, findsOneWidget);
    });
  });
}
