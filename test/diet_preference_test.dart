import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

// PROD-6: Diät-/Präferenz-Personalisierung. Ein vegetarisches/veganes Profil
// darf NIE ein fleisch-/fischhaltiges Rezept aktiv empfohlen bekommen
// (Empfehlungs-Carousel + „Passt zu deinem Ziel"). Der User kann über den
// Kategorie-Filter weiterhin alles manuell durchsuchen — das wird hier bewusst
// NICHT eingeschränkt. Netz-/Client-frei für die Modell-Tests, ein
// Widget-Test deckt zusätzlich die echte Screen-Verdrahtung ab.

FitnessRecipe _byTitle(String title) =>
    fitnessRecipes.firstWhere((r) => r.title == title);

void main() {
  group('FitnessRecipe.matchesDiet (reine Eignungs-Heuristik)', () {
    final lachs = _byTitle('Lachs mit Süßkartoffel & Spargel'); // Fisch
    final rind = _byTitle('Rindersteak mit Kartoffeln & Bohnen'); // Fleisch
    final tofu = _byTitle('Tofu mit Reis & Edamame'); // Vegetarisch-Tag
    final omelett = _byTitle('Omelett mit Spinat & Avocado'); // Ei, kein Tag

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
      expect(omelett.matchesDiet(DietPreference.vegetarian), isTrue); // Ei = veg
    });

    test('vegan: nur explizit pflanzlich markierte Gerichte, keine Eier', () {
      expect(tofu.matchesDiet(DietPreference.vegan), isTrue);
      expect(omelett.matchesDiet(DietPreference.vegan), isFalse); // Ei nicht vegan
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

  group('RecipesScreen empfiehlt keine präferenz-verletzenden Rezepte', () {
    // Restmakros, bei denen die High-Protein-Fleisch-/Fisch-Teller ohne Filter
    // ganz oben ranken würden — so ist der Diät-Vorfilter scharf getestet.
    const remaining =
        MacroProgress(proteinG: 60, carbsG: 60, fatG: 25, kcal: 700);

    Future<void> pump(WidgetTester tester, DietPreference diet) async {
      tester.view.physicalSize = const Size(1179, 2556);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildEatovaTheme(Brightness.dark),
          locale: const Locale('de'),
          supportedLocales: const [Locale('de'), Locale('en')],
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(
            body: RecipesScreen(
              diet: diet,
              remainingMacros: remaining,
              onAddMeal: (MealAnalysisResult _, MealSlot __) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('vegetarisch: kein Lachs/Rindersteak im Ziel-Match-Carousel',
        (tester) async {
      await pump(tester, DietPreference.vegetarian);

      // Ziel-Matches steht am Listenende → erst ins Bild scrollen (lazy List).
      final goalMatches = find.byKey(const ValueKey('recipe-goal-matches'));
      await tester.dragUntilVisible(
        goalMatches,
        find.byKey(const ValueKey('screen-recipes')),
        const Offset(0, -250),
      );
      await tester.pumpAndSettle();
      expect(goalMatches, findsOneWidget);

      // Im beworbenen Match-Carousel dürfen Lachs/Rindersteak NIE auftauchen.
      // (In der ungefilterten Hauptliste schon — das ist Absicht.)
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
      // Ohne Präferenz ist der ungefilterte Pfad aktiv — der Screen rendert.
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
