// Fix-Lauf 2026-08-27, Paket I (F6-02/F6-07): Suche und Filter des
// Rezepte-Tabs.
//
//   * Unter `en` trifft die Suche die ÜBERSETZTE Kategorie ("fish",
//     "breakfast") — vorher lief sie nur gegen die deutsche Identität.
//   * Umlaut-Faltung: "haehnchen" findet "Hähnchen".
//   * Zutaten werden durchsucht.
//   * "Eigene"-Chip direkt nach "Alle", nur solange es eigene Rezepte gibt.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/design/design.dart';

const _eigenes = FitnessRecipe(
  slug: 'user_mein_teller',
  title: 'Mein Testteller',
  description: '',
  portion: '',
  ingredients: 'Quinoa\nEdamame',
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

Widget _app({
  Locale locale = const Locale('de'),
  List<FitnessRecipe> userRecipes = const <FitnessRecipe>[],
}) {
  return MaterialApp(
    theme: buildEatovaTheme(Brightness.dark),
    locale: locale,
    supportedLocales: const [Locale('de'), Locale('en')],
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: RecipesScreen(
            onAddMeal: (MealAnalysisResult _, MealSlot __) {},
            initialUserRecipes: userRecipes,
          ),
        ),
      ),
    ),
  );
}

void _pinViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _suche(WidgetTester tester, String query) async {
  await tester.enterText(
    find.byKey(const ValueKey('recipes-search-input')),
    query,
  );
  await tester.pumpAndSettle();
}

/// Textsuche über Titel, Beschreibung und Zutaten — ohne die Kategorie, um
/// den reinen Text-Anteil einer Query zu bestimmen.
bool _textTreffer(FitnessRecipe r, String query) {
  final q = foldRecipeSearchText(query);
  return foldRecipeSearchText(r.title).contains(q) ||
      foldRecipeSearchText(r.description).contains(q) ||
      foldRecipeSearchText(r.ingredients).contains(q);
}

void main() {
  group('EN: die Suche trifft die übersetzte Kategorie', () {
    testWidgets('"fish" liefert genau die Fisch-Rezepte', (tester) async {
      _pinViewport(tester);
      await tester.pumpWidget(_app(locale: const Locale('en')));
      await tester.pumpAndSettle();

      final fisch = recipeCatalogEn
          .where((r) => r.categories.contains('Fisch'))
          .toList(growable: false);
      // Vorbedingung: kein englischer Text enthält "fish" wörtlich — die
      // Kategorie ist der EINZIGE Pfad. Sonst würde der Test nichts beweisen.
      expect(recipeCatalogEn.where((r) => _textTreffer(r, 'fish')), isEmpty);

      await _suche(tester, 'fish');

      expect(find.text('${fisch.length} matches'), findsOneWidget);
      expect(
        find.byKey(ValueKey('recipe-tile-${fisch.first.slug}')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('recipe-tile-hahnchen_mit_reis_and_brokkoli')),
        findsNothing,
      );
    });

    testWidgets('"breakfast" liefert alle Frühstücksrezepte', (tester) async {
      _pinViewport(tester);
      await tester.pumpWidget(_app(locale: const Locale('en')));
      await tester.pumpAndSettle();

      final nurText = recipeCatalogEn
          .where((r) => _textTreffer(r, 'breakfast'))
          .length;
      final erwartet = recipeCatalogEn
          .where((r) =>
              r.categories.contains('Frühstück') || _textTreffer(r, 'breakfast'))
          .length;
      expect(erwartet, greaterThan(nurText),
          reason: 'Vorbedingung: der Kategorie-Pfad muss Rezepte beitragen, '
              'die der Text allein nicht findet.');

      await _suche(tester, 'breakfast');

      expect(find.text('$erwartet matches'), findsOneWidget);
    });
  });

  group('DE: Umlaut-Faltung und Zutaten', () {
    testWidgets('"haehnchen" findet Hähnchen — gleich viele wie "hähnchen"',
        (tester) async {
      _pinViewport(tester);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await _suche(tester, 'haehnchen');
      expect(
        find.byKey(const ValueKey('recipe-tile-hahnchen_mit_reis_and_brokkoli')),
        findsOneWidget,
      );
      final mitAe = tester
          .widgetList<Text>(find.textContaining(' Treffer'))
          .map((t) => t.data)
          .single;

      await _suche(tester, 'hähnchen');
      final mitUmlaut = tester
          .widgetList<Text>(find.textContaining(' Treffer'))
          .map((t) => t.data)
          .single;

      expect(mitAe, mitUmlaut);
      expect(mitAe, isNot('0 Treffer'));
    });

    testWidgets('eine Zutat, die nur in der Zutatenliste steht, ist findbar',
        (tester) async {
      _pinViewport(tester);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // "Chiasamen" steht bei den Overnight Oats nur in den Zutaten.
      final oats = fitnessRecipes
          .firstWhere((r) => r.slug == 'overnight_oats_mit_skyr_and_banane');
      expect(oats.title.toLowerCase().contains('chiasamen'), isFalse);
      expect(oats.description.toLowerCase().contains('chiasamen'), isFalse);
      expect(oats.ingredients.toLowerCase().contains('chiasamen'), isTrue);

      await _suche(tester, 'chiasamen');

      expect(find.text('1 Treffer'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('recipe-tile-overnight_oats_mit_skyr_and_banane')),
        findsOneWidget,
      );
    });
  });

  group('"Eigene"-Chip', () {
    testWidgets('fehlt ohne eigene Rezepte', (tester) async {
      _pinViewport(tester);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('recipe-filter-Alle')), findsOneWidget);
      expect(find.byKey(const ValueKey('recipe-filter-Eigene')), findsNothing);
    });

    testWidgets('steht mit eigenem Rezept direkt nach "Alle" und filtert',
        (tester) async {
      _pinViewport(tester);
      await tester.pumpWidget(_app(userRecipes: [_eigenes]));
      await tester.pumpAndSettle();

      final alle = find.byKey(const ValueKey('recipe-filter-Alle'));
      final eigene = find.byKey(const ValueKey('recipe-filter-Eigene'));
      final protein = find.byKey(const ValueKey('recipe-filter-High Protein'));
      expect(eigene, findsOneWidget);
      expect(tester.getTopLeft(eigene).dx, greaterThan(tester.getTopLeft(alle).dx));
      expect(
        tester.getTopLeft(eigene).dx,
        lessThan(tester.getTopLeft(protein).dx),
      );
      expect(tester.widget<FilterChipPill>(eigene).label, 'Eigene');

      await tester.tap(eigene);
      await tester.pumpAndSettle();

      expect(tester.widget<FilterChipPill>(eigene).selected, isTrue);
      expect(find.text('1 Treffer'), findsOneWidget);
      expect(find.byKey(ValueKey('recipe-tile-${_eigenes.slug}')),
          findsOneWidget);
      expect(
        find.byKey(const ValueKey('recipe-tile-hahnchen_mit_reis_and_brokkoli')),
        findsNothing,
      );
    });

    testWidgets('ein Kategorie-Chip blendet eigene Rezepte weiterhin aus '
        '(Regressionsschutz, gewollt)', (tester) async {
      _pinViewport(tester);
      await tester.pumpWidget(_app(userRecipes: [_eigenes]));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('recipe-filter-High Protein')));
      await tester.pumpAndSettle();

      expect(find.byKey(ValueKey('recipe-tile-${_eigenes.slug}')),
          findsNothing);
    });
  });
}
