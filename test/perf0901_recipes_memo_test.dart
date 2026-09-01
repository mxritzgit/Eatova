// Perf-Audit 2026-09-01, Paket B4: der Rezepte-Tab faltete und sortierte den
// ganzen Katalog bei JEDEM Build neu — also bei jedem Tastendruck.
//
// Zwei Klassen von Aussagen, beide notwendig:
//
//   * TEMPO — `RecipeMemoStats` zaehlt die echten Neuberechnungen. Ein Memo
//     ist von aussen unsichtbar (es kommt dieselbe Liste zurueck), also ist
//     der Zaehler der einzige Weg, Treffer und Fehltreffer zu unterscheiden.
//   * VERHALTEN — der gerenderte Trefferstand wird gegen die Referenz-
//     Implementierung geprueft, also gegen den Code, wie er VOR dem Memo in
//     recipes_screen.dart stand. Der Schluessel muss dabei die Sprache
//     enthalten: `filteredRecipes` matcht auf `recipeCategoryLabel`, und
//     dieselbe Query liefert unter de und en verschiedene Ergebnisse.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';

import 'support/harness.dart';

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

const _zweites = FitnessRecipe(
  slug: 'user_zweiter_teller',
  title: 'Zanderfilet Spezial',
  description: '',
  portion: '',
  ingredients: 'Zander\nZitrone',
  preparation: '',
  professionalHint: '',
  imageAsset: '',
  caloriesKcal: 480,
  proteinG: 44,
  carbsG: 20,
  fatG: 18,
  estimatedGrams: 280,
  categories: <String>['Eigene'],
  userCreated: true,
);

/// Two stable list identities: `didUpdateWidget` adopts a new list only when
/// its IDENTITY changed, so a fresh literal per pump would be a different
/// scenario than "nothing changed".
const _einRezept = <FitnessRecipe>[_eigenes];
const _zweiRezepte = <FitnessRecipe>[_eigenes, _zweites];

const _rest = MacroProgress(proteinG: 90, carbsG: 180, fatG: 50, kcal: 1600);

/// Deliberately oversized in BOTH directions, because two lazy `ListView`s
/// would otherwise hide what these tests measure: tall enough that every
/// result tile lands in the element tree (else [_slugs] sees only the visible
/// ones and the comparison against the reference is vacuous), wide enough that
/// the horizontal filter strip builds every chip (else the later chips cannot
/// be tapped). No layout claim is made here, so the odd surface costs nothing.
void _grosseFlaeche(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 20000);
  addTearDown(tester.view.reset);
}

Future<void> _pump(
  WidgetTester tester, {
  Locale locale = const Locale('de'),
  List<FitnessRecipe> userRecipes = const <FitnessRecipe>[],
  DietPreference diet = DietPreference.none,
  MacroProgress? remaining,
}) async {
  await tester.pumpWidget(
    localizedApp(
      RecipesScreen(
        onAddMeal: (MealAnalysisResult _, MealSlot __) {},
        initialUserRecipes: userRecipes,
        diet: diet,
        remainingMacros: remaining,
      ),
      locale: locale,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _suche(WidgetTester tester, String query) async {
  await tester.enterText(
    find.byKey(const ValueKey('recipes-search-input')),
    query,
  );
  await tester.pumpAndSettle();
}

const _tilePrefix = 'recipe-tile-';
const _cardPrefix = 'recipe-recommended-';

/// Slugs carried by the keys with [prefix], in tree order.
List<String> _keySlugs(WidgetTester tester, String prefix) => tester
    .widgetList(find.byWidgetPredicate((w) {
      final key = w.key;
      return key is ValueKey<String> && key.value.startsWith(prefix);
    }))
    .map((w) => (w.key! as ValueKey<String>).value.substring(prefix.length))
    .toList(growable: false);

/// Slugs of the rendered result list, in list order.
List<String> _slugs(WidgetTester tester) => _keySlugs(tester, _tilePrefix);

/// Slugs of the rendered recommendation cards. Only the carousel keys its
/// cards; the goal-match cards carry no key, so this cannot mix them up.
List<String> _empfehlungen(WidgetTester tester) =>
    _keySlugs(tester, _cardPrefix);

bool _istVegan(String slug) => recipeCatalogForLocale('de')
    .firstWhere((r) => r.slug == slug)
    .matchesDiet(DietPreference.vegan);

/// The pre-memo implementation, copied verbatim out of recipes_screen.dart as
/// it stood before the perf audit. Everything the screen renders now has to
/// come out of here identically.
List<FitnessRecipe> _referenz(
  List<FitnessRecipe> alle,
  String query,
  String filter,
  AppLocalizations l10n,
) {
  final normalizedQuery = foldRecipeSearchText(query.trim());
  bool hit(String text) => foldRecipeSearchText(text).contains(normalizedQuery);
  return alle.where((recipe) {
    final matchesFilter = switch (filter) {
      "Alle" => true,
      "Eigene" => recipe.userCreated,
      _ => recipe.categories.contains(filter),
    };
    final matchesQuery = normalizedQuery.isEmpty ||
        hit(recipe.title) ||
        hit(recipe.description) ||
        hit(recipe.ingredients) ||
        recipe.categories.any(
          (category) =>
              hit(category) || hit(recipeCategoryLabel(category, l10n)),
        );
    return matchesFilter && matchesQuery;
  }).toList(growable: false);
}

List<FitnessRecipe> _alleRezepte(
  List<FitnessRecipe> eigene,
  String localeName,
) =>
    <FitnessRecipe>[...eigene, ...recipeCatalogForLocale(localeName)];

void main() {
  setUp(RecipeMemoStats.reset);

  group('Der Cache trifft, solange sich nichts aendert', () {
    testWidgets('ein Rebuild mit denselben Eingaben rechnet nichts neu',
        (tester) async {
      _grosseFlaeche(tester);
      await _pump(tester, userRecipes: _einRezept, remaining: _rest);
      await _suche(tester, 'lachs');

      final index = RecipeMemoStats.indexBuilds;
      final folds = RecipeMemoStats.folds;
      final filter = RecipeMemoStats.filterRuns;
      final diet = RecipeMemoStats.dietRuns;
      final goal = RecipeMemoStats.goalRuns;
      final vorher = _slugs(tester);

      // Derselbe Baum noch einmal: didUpdateWidget plus Build, aber kein
      // einziger geaenderter Eingang.
      await _pump(tester, userRecipes: _einRezept, remaining: _rest);

      expect(RecipeMemoStats.indexBuilds, index);
      expect(RecipeMemoStats.folds, folds);
      expect(RecipeMemoStats.filterRuns, filter);
      expect(RecipeMemoStats.dietRuns, diet);
      expect(RecipeMemoStats.goalRuns, goal);
      expect(_slugs(tester), vorher);
    });

    testWidgets(
        'jedes Rezept wird genau EINMAL gefaltet, egal wie viele Tastendruecke',
        (tester) async {
      _grosseFlaeche(tester);
      await _pump(tester);

      // Leere Query faltet nichts — genau wie vorher, sonst waere der
      // Normalfall durch den Index teurer geworden.
      expect(RecipeMemoStats.folds, 0);
      expect(RecipeMemoStats.filterRuns, 1);

      for (final query in <String>['l', 'la', 'lac', 'lach', 'lachs']) {
        await _suche(tester, query);
      }

      // 30 Katalogrezepte, einmal gefaltet — nicht 5 x 30.
      expect(RecipeMemoStats.folds, recipeCatalogForLocale('de').length);
      // Ein Lauf pro WIRKLICH neuer Query (plus dem leeren Erststand). Die
      // Rebuilds, die pumpAndSettle dazwischen ausloest, zaehlen nicht mit.
      expect(RecipeMemoStats.filterRuns, 6);
      expect(RecipeMemoStats.indexBuilds, 1);
    });

    testWidgets(
        'ein frisches MacroProgress mit denselben Zahlen rechnet nicht neu',
        (tester) async {
      _grosseFlaeche(tester);
      await _pump(tester, remaining: _rest);
      final goal = RecipeMemoStats.goalRuns;

      // ABSICHTLICH aus Feldern gebaut statt als const-Literal: ein const mit
      // denselben Zahlen waere auf DASSELBE Objekt kanonisiert, und der Test
      // wuerde die Wert-Gleichheit gar nicht pruefen (genau daran ist die
      // erste Fassung dieses Tests vorbeigelaufen).
      final frisch = MacroProgress(
        proteinG: _rest.proteinG,
        carbsG: _rest.carbsG,
        fatG: _rest.fatG,
        kcal: _rest.kcal,
      );
      expect(identical(frisch, _rest), isFalse,
          reason: 'Vorbedingung: es muss ein anderes Objekt sein.');

      // Die Home-Shell baut `Ziel - Fortschritt` bei jedem Build neu, und
      // MacroProgress hat kein `==`. Ein Identitaets-Schluessel wuerde hier
      // jedes Mal danebengreifen.
      await _pump(tester, remaining: frisch);

      expect(RecipeMemoStats.goalRuns, goal);
    });
  });

  group('Jeder Eingang des Schluessels macht den Cache ungueltig', () {
    testWidgets('die Query', (tester) async {
      _grosseFlaeche(tester);
      await _pump(tester);
      final vorher = RecipeMemoStats.filterRuns;

      await _suche(tester, 'lachs');

      expect(RecipeMemoStats.filterRuns, vorher + 1);
    });

    testWidgets('der Filter-Chip', (tester) async {
      _grosseFlaeche(tester);
      await _pump(tester);
      await _suche(tester, 'e');
      final vorher = RecipeMemoStats.filterRuns;

      await tester.tap(find.byKey(const ValueKey('recipe-filter-Fisch')));
      await tester.pumpAndSettle();

      expect(RecipeMemoStats.filterRuns, vorher + 1);
      for (final slug in _slugs(tester)) {
        final rezept =
            recipeCatalogForLocale('de').firstWhere((r) => r.slug == slug);
        expect(rezept.categories, contains('Fisch'));
      }
    });

    testWidgets('der Rezeptbestand — ein neues eigenes Rezept ist sofort '
        'findbar', (tester) async {
      _grosseFlaeche(tester);
      await _pump(tester, userRecipes: _einRezept);
      await _suche(tester, 'zanderfilet');
      expect(_slugs(tester), isEmpty);
      final index = RecipeMemoStats.indexBuilds;

      await _pump(tester, userRecipes: _zweiRezepte);

      expect(RecipeMemoStats.indexBuilds, index + 1);
      expect(_slugs(tester), <String>[_zweites.slug]);
    });

    testWidgets('ein geloeschtes eigenes Rezept verschwindet aus dem Cache',
        (tester) async {
      _grosseFlaeche(tester);
      await _pump(tester, userRecipes: _zweiRezepte);
      await _suche(tester, 'zanderfilet');
      expect(_slugs(tester), <String>[_zweites.slug]);

      await _pump(tester, userRecipes: _einRezept);

      expect(_slugs(tester), isEmpty);
    });

    testWidgets('das letzte eigene Rezept faellt weg — der Chip verschwindet, '
        'die Auswahl faellt auf "Alle" zurueck und der Cache folgt',
        (tester) async {
      // Der Pfad, der zwei Eingaenge auf einmal dreht: `_dropOwnFilterIfEmpty`
      // schreibt `selectedFilter` um, waehrend sich der Rezeptbestand aendert.
      _grosseFlaeche(tester);
      await _pump(tester, userRecipes: _einRezept);
      await tester.tap(find.byKey(const ValueKey('recipe-filter-Eigene')));
      await tester.pumpAndSettle();
      expect(_slugs(tester), <String>[_eigenes.slug]);

      await _pump(tester);

      expect(find.byKey(const ValueKey('recipe-filter-Eigene')), findsNothing);
      expect(
        _slugs(tester),
        recipeCatalogForLocale('de').map((r) => r.slug).toList(growable: false),
        reason: 'Nach dem Rueckfall auf "Alle" muss der ganze Katalog stehen, '
            'nicht der gemerkte "Eigene"-Stand.',
      );
    });

    testWidgets('die Ernaehrungsform — auch der Karussell-Pool folgt ihr',
        (tester) async {
      _grosseFlaeche(tester);
      // Fester Tag: die Karussell-Auswahl haengt am Kalendertag. Mit der
      // echten Uhr waere dieser Fall datumsabhaengig (Vorfall K-02).
      await withClock(Clock.fixed(DateTime(2026, 9, 1, 12)), () async {
        await _pump(tester, remaining: _rest);
        final diet = RecipeMemoStats.dietRuns;
        final goal = RecipeMemoStats.goalRuns;
        final vorher = _empfehlungen(tester);
        expect(vorher.any((slug) => !_istVegan(slug)), isTrue,
            reason: 'Vorbedingung: ohne Diaet steht mindestens eine nicht '
                'vegane Karte im Karussell, sonst zeigt der Wechsel nichts.');

        await _pump(
          tester,
          remaining: _rest,
          diet: DietPreference.vegan,
        );

        expect(RecipeMemoStats.dietRuns, diet + 1);
        expect(RecipeMemoStats.goalRuns, goal + 1);
        // `catalogPool` hat einen EIGENEN Schluessel, und der stand bis hierher
        // ungeprueft: die Zaehler oben laufen ueber `forDiet`/`goalMatches`.
        // Ein Wechsel der Ernaehrungsform in den Einstellungen liess den alten
        // Pool stehen — der Screen bleibt im IndexedStack gemountet.
        final nachher = _empfehlungen(tester);
        expect(nachher, isNotEmpty);
        for (final slug in nachher) {
          expect(_istVegan(slug), isTrue,
              reason: '„$slug" ist nicht vegan und darf nach dem Wechsel nicht '
                  'mehr empfohlen werden.');
        }
      });
    });

    testWidgets('jeder EINZELNE Makro-Wert macht den Ziel-Cache ungueltig',
        (tester) async {
      // Vorher drehte dieser Fall alle vier Zahlen auf einmal. Damit blieb
      // jeder einzelne Bestandteil des Schluessels ungeprueft: ein Cache, der
      // nur drei der vier Werte kennt, reichte den alten Stand weiter — und
      // die Ziel-Sektion zeigte Vorschlaege zu einem Rest, den es nicht mehr
      // gibt.
      _grosseFlaeche(tester);
      await _pump(tester, remaining: _rest);
      var goal = RecipeMemoStats.goalRuns;
      var rest = _rest;

      final aenderungen =
          <String, MacroProgress Function(MacroProgress)>{
        'Protein': (r) => MacroProgress(
            proteinG: r.proteinG + 25,
            carbsG: r.carbsG,
            fatG: r.fatG,
            kcal: r.kcal),
        'Kohlenhydrate': (r) => MacroProgress(
            proteinG: r.proteinG,
            carbsG: r.carbsG + 40,
            fatG: r.fatG,
            kcal: r.kcal),
        'Fett': (r) => MacroProgress(
            proteinG: r.proteinG,
            carbsG: r.carbsG,
            fatG: r.fatG + 20,
            kcal: r.kcal),
        'kcal': (r) => MacroProgress(
            proteinG: r.proteinG,
            carbsG: r.carbsG,
            fatG: r.fatG,
            kcal: r.kcal + 400),
      };

      for (final eintrag in aenderungen.entries) {
        rest = eintrag.value(rest);
        await _pump(tester, remaining: rest);
        expect(RecipeMemoStats.goalRuns, goal + 1,
            reason: 'Nur ${eintrag.key} geaendert — genau dieser Wert steht im '
                'Schluessel, also muss die Rangliste neu laufen.');
        goal = RecipeMemoStats.goalRuns;
      }
    });

    testWidgets('DIE SPRACHE — dieselbe Query liefert unter de etwas anderes '
        'als unter en', (tester) async {
      _grosseFlaeche(tester);
      await _pump(tester, locale: const Locale('en'));
      await _suche(tester, 'fish');

      final fischRezepte = recipeCatalogForLocale('en')
          .where((r) => r.categories.contains('Fisch'))
          .map((r) => r.slug)
          .toList(growable: false);
      expect(_slugs(tester), fischRezepte);
      expect(fischRezepte, isNotEmpty);
      final index = RecipeMemoStats.indexBuilds;

      // Sprachwechsel OHNE die Query anzufassen: der State bleibt stehen,
      // nur `l10n.localeName` wechselt. Ein Cache ohne Sprache im Schluessel
      // wuerde hier die englischen Treffer weiterreichen.
      await _pump(tester, locale: const Locale('de'));

      expect(
        tester
            .widget<TextField>(
                find.byKey(const ValueKey('recipes-search-input')))
            .controller!
            .text,
        'fish',
        reason: 'Vorbedingung: der State darf nicht neu aufgebaut worden '
            'sein, sonst prueft der Test nur einen Neustart.',
      );
      expect(RecipeMemoStats.indexBuilds, index + 1);
      expect(
        _slugs(tester),
        _referenz(
          _alleRezepte(const <FitnessRecipe>[], 'de'),
          'fish',
          "Alle",
          await AppLocalizations.delegate.load(const Locale('de')),
        ).map((r) => r.slug).toList(growable: false),
      );
      // Und der deutsche Stand ist wirklich ein anderer.
      expect(_slugs(tester), isNot(fischRezepte));
    });
  });

  group('Das Ergebnis ist Zeichen fuer Zeichen das alte', () {
    // Queries, die jeden Pfad der alten Kette treffen: Titel, Beschreibung,
    // Zutaten, neutrale Kategorie-Identitaet und uebersetztes Label.
    const queries = <String>[
      '',
      '  ',
      'lachs',
      'haehnchen',
      'hähnchen',
      'chiasamen',
      'fish',
      'breakfast',
      'frühstück',
      'high protein',
      'vegan',
      'zzz-gibt-es-nicht',
      'e',
    ];

    for (final locale in <String>['de', 'en']) {
      for (final filter in <String>["Alle", "Eigene", "Fisch", "Low Carb"]) {
        testWidgets('$locale · Filter $filter', (tester) async {
          _grosseFlaeche(tester);
          final l10n =
              await AppLocalizations.delegate.load(Locale(locale));
          await _pump(tester, locale: Locale(locale), userRecipes: _einRezept);
          if (filter != "Alle") {
            await tester.tap(find.byKey(ValueKey('recipe-filter-$filter')));
            await tester.pumpAndSettle();
          }

          for (final query in queries) {
            await _suche(tester, query);
            expect(
              _slugs(tester),
              _referenz(
                _alleRezepte(_einRezept, locale),
                query,
                filter,
                l10n,
              ).map((r) => r.slug).toList(growable: false),
              reason: 'Query "$query" unter $locale/$filter',
            );
          }
        });
      }
    }
  });
}
