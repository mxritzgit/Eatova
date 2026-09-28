// Persisted German fallbacks: writers stay byte-identical, displays resolve.
//
// Rows written by every earlier build carry these values, and installed older
// builds on other devices read what this build writes. So the first group pins
// the WIRE values (and the identities derived from them); the rest pins the
// display resolution per family in both languages, plus the guard that user
// text that only resembles a fallback is never rewritten.

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/models/persisted_labels.dart';
import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/models/shopping_list.dart';
import 'package:eatova/src/screens/today/today_texts.dart';
import 'package:eatova/src/services/meals_sync.dart' show mealResultFromJson;

/// The adjustment sentences exactly as builds before this change wrote them.
const _legacyGrams =
    'Manuell angepasst: 250 g statt der ursprünglichen Portion.';
const _legacyGramsDensity =
    'Manuell angepasst: 250 g statt der ursprünglichen Portion. Kalorien neu '
    'berechnet mit 180 kcal pro 100 g.';
const _legacyItems =
    'Einzelne Bestandteile wurden manuell bestätigt oder angepasst. '
    'Gesamtwerte wurden aus der Summe der Positionen neu berechnet.';
const _legacyItemsNoMacros =
    'Einzelne Bestandteile wurden manuell bestätigt oder angepasst. '
    'Kalorien und Gramm wurden aus der Summe der Positionen neu berechnet. '
    'Die Makro-Nährwerte lassen sich aus der geänderten Zusammensetzung '
    'nicht mehr ableiten und werden deshalb nicht ausgewiesen.';

MealAnalysisResult _meal({
  String name = 'Haferbrei',
  String protein = '-',
  String notes = '',
  String source = 'photoAi',
  String? barcode,
  String? brand,
  List<MealComponent> items = const <MealComponent>[],
}) => MealAnalysisResult(
  mealName: name,
  caloriesKcal: 450,
  estimatedGrams: 250,
  kcalPer100G: 180,
  protein: protein,
  carbs: '-',
  fat: '-',
  confidence: 'high',
  portionNotes: notes,
  sourceLabel: source,
  barcode: barcode,
  brand: brand,
  items: items,
);

Map<String, dynamic> _offProduct({String? name, String? brand}) =>
    <String, dynamic>{
      if (name != null) 'product_name': name,
      if (brand != null) 'brands': brand,
      'serving_quantity': 50,
      'nutriments': <String, dynamic>{
        'energy-kcal_100g': 530,
        'proteins_100g': 25,
        'carbohydrates_100g': 57,
        'fat_100g': 30,
      },
    };

RecipeIngredient _offIngredient(String name, String? code) => RecipeIngredient(
  name: name,
  grams: 50,
  per100g: const RecipeNutrition(caloriesKcal: 530),
  source: IngredientSource.openFoodFacts,
  productCode: code,
);

FitnessRecipe _ownRecipe({
  String title = 'Eigenes Rezept',
  String description = '',
  String ingredients = '',
  List<String> categories = const <String>['Eigene'],
  List<RecipeIngredient> structured = const <RecipeIngredient>[],
  bool userCreated = true,
}) => FitnessRecipe(
  slug: 'user_fixture',
  title: title,
  description: description,
  portion: '',
  ingredients: ingredients,
  preparation: '',
  professionalHint: '',
  imageAsset: '',
  caloriesKcal: 520,
  proteinG: 40,
  carbsG: 50,
  fatG: 15,
  estimatedGrams: structured.isEmpty ? 300 : 0,
  categories: categories,
  userCreated: userCreated,
  structuredIngredients: structured,
);

void main() {
  group('Schreibseite bleibt byte-gleich (Kompatibilitaet)', () {
    test('Namens-Fallbacks der Schreiber sind unveraendert deutsch', () {
      expect(
        MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
          'caloriesKcal': 300,
        }).mealName,
        'Unbekannte Mahlzeit',
      );
      expect(
        MealAnalysisResult.fromEdgeFunction(<String, dynamic>{
          'mealName': '  ',
          'caloriesKcal': 300,
        }).mealName,
        'Mahlzeit',
      );
      expect(
        MealAnalysisResult.fromOpenFoodFacts(
          _offProduct(),
          '4001234567890',
        ).mealName,
        'Produkt 4001234567890',
      );
      expect(
        MealAnalysisResult.fromOpenFoodFacts(
          _offProduct(brand: 'Milka'),
          '4001234567890',
        ).mealName,
        'Produkt 4001234567890 · Milka',
      );
      expect(
        MealComponent.fromJson(<String, dynamic>{'grams': 40}).name,
        'Zutat',
      );
      expect(
        FitnessRecipe.fromRow(<String, dynamic>{'slug': 'user_x'}).title,
        'Eigenes Rezept',
      );
      expect(
        mealResultFromJson(<String, dynamic>{'caloriesKcal': 1}).mealName,
        'Mahlzeit',
      );
    });

    test('Anpassungs-Hinweise sind die alten Saetze, Byte fuer Byte', () {
      final base = _meal(
        items: const <MealComponent>[
          MealComponent(name: 'Reis', grams: 150, caloriesKcal: 200),
          MealComponent(name: 'Huhn', grams: 100, caloriesKcal: 250),
        ],
      );
      expect(base.adjustedToGrams(250).portionNotes, _legacyGramsDensity);
      expect(
        _meal().copyWithZeroDensity().adjustedToGrams(250).portionNotes,
        _legacyGrams,
      );
      // Same items, same order, factor 1: macros stay derivable.
      expect(base.adjustedToItems(base.items).portionNotes, _legacyItems);
      expect(
        base
            .adjustedToItems(const <MealComponent>[
              MealComponent(name: 'Reis', grams: 300, caloriesKcal: 400),
            ])
            .portionNotes,
        _legacyItemsNoMacros,
      );
    });

    test('Makro-Texte werden weiter mit Komma geschrieben', () {
      expect(MealAnalysisResult.macroForGrams(25, 50), '12,5 g');
      expect(
        MealAnalysisResult.fromOpenFoodFacts(_offProduct(), '1').fat,
        '15 g',
      );
    });

    test('Favoriten-Schluessel haengen weiter am gespeicherten Namen', () {
      expect(
        FavoriteMeal.idFor(_meal(name: 'Unbekannte Mahlzeit')),
        'name:unbekannte mahlzeit',
      );
      expect(
        FavoriteMeal.idFor(_meal(name: 'Mahlzeit')),
        'name:mahlzeit',
      );
    });

    test('die deutschen ARB-Texte sind genau die Drahtwerte', () {
      // A drifting German ARB text would change the German display of every
      // stored row, so the ARB is pinned to the wire values here.
      expect(deL10n.foodUnknownMealName, PersistedLabels.unknownMealName);
      expect(deL10n.foodMealNameFallback, PersistedLabels.mealNameFallback);
      expect(deL10n.recipesOwnTitle, PersistedLabels.ownRecipeTitle);
      expect(
        deL10n.foodIngredientFallbackName,
        PersistedLabels.ingredientNameFallback,
      );
      expect(
        deL10n.foodProductFallbackName('42'),
        PersistedLabels.productName('42'),
      );
      for (final raw in const <String>[
        _legacyGrams,
        _legacyGramsDensity,
        _legacyItems,
        _legacyItemsNoMacros,
      ]) {
        expect(MealAnalysisResult.resolvePortionNotes(raw, deL10n), raw);
      }
    });
  });

  group('Anzeige: Mahlzeitnamen', () {
    test('Unbekannte Mahlzeit und Mahlzeit', () {
      expect(_meal(name: 'Unbekannte Mahlzeit').resolvedMealName(enL10n),
          'Unknown meal');
      expect(_meal(name: 'Unbekannte Mahlzeit').resolvedMealName(deL10n),
          'Unbekannte Mahlzeit');
      expect(_meal(name: 'Mahlzeit').resolvedMealName(enL10n), 'Meal');
      expect(_meal(name: 'Mahlzeit').resolvedMealName(deL10n), 'Mahlzeit');
    });

    test('Produkt <Barcode> nur mit genau diesem gespeicherten Barcode', () {
      final named = MealAnalysisResult.fromOpenFoodFacts(
        _offProduct(brand: 'Milka'),
        '4001234567890',
      );
      expect(named.resolvedMealName(enL10n), 'Product 4001234567890 · Milka');
      expect(named.resolvedMealName(deL10n), 'Produkt 4001234567890 · Milka');
      final bare = MealAnalysisResult.fromOpenFoodFacts(_offProduct(), '42');
      expect(bare.resolvedMealName(enL10n), 'Product 42');
      // Search hits without a code: the writer stored just "Produkt".
      final noCode = MealAnalysisResult.fromOpenFoodFacts(_offProduct(), '');
      expect(noCode.mealName, 'Produkt');
      expect(noCode.resolvedMealName(enL10n), 'Product');
      final noCodeBrand = MealAnalysisResult.fromOpenFoodFacts(
        _offProduct(brand: 'Milka'),
        '',
      );
      expect(noCodeBrand.resolvedMealName(enL10n), 'Product · Milka');
    });

    test('Eigenes Rezept nur als protokolliertes Rezept', () {
      for (final source in const <String>['recipe', 'Eatova Rezept']) {
        expect(
          _meal(name: 'Eigenes Rezept', source: source).resolvedMealName(enL10n),
          'Your recipe',
        );
      }
      // A manual entry the user named like that is theirs.
      expect(
        _meal(name: 'Eigenes Rezept', source: 'manual').resolvedMealName(enL10n),
        'Eigenes Rezept',
      );
    });

    test('Bestandteile: Zutat und das aus der Mahlzeit gebildete Einzelteil',
        () {
      final meal = _meal(
        name: 'Produkt 42',
        barcode: '42',
        items: const <MealComponent>[
          MealComponent(name: 'Zutat', grams: 10, caloriesKcal: 10),
          MealComponent(name: 'Produkt 42', grams: 10, caloriesKcal: 10),
          MealComponent(name: 'Reis', grams: 10, caloriesKcal: 10),
        ],
      );
      expect(
        [for (final item in meal.items) meal.resolvedItemName(item, enL10n)],
        ['Ingredient', 'Product 42', 'Reis'],
      );
      expect(
        [for (final item in meal.items) meal.resolvedItemName(item, deL10n)],
        ['Zutat', 'Produkt 42', 'Reis'],
      );
      expect(
        meal.resolvedItemName(meal.asSingleComponent, enL10n),
        'Product 42',
      );
    });

    test('Heute-Untertitel', () {
      final meals = <LoggedMeal>[
        for (final name in const <String>['Unbekannte Mahlzeit', 'Mahlzeit'])
          LoggedMeal(
            id: name,
            result: _meal(name: name),
            loggedAt: DateTime(2026, 9, 28, 12),
          ),
      ];
      expect(mealSlotSubtitle(meals, enL10n), 'Unknown meal · Meal');
      expect(
        mealSlotSubtitle(meals, deL10n),
        'Unbekannte Mahlzeit · Mahlzeit',
      );
    });
  });

  group('Anzeige: Anpassungs-Hinweise', () {
    test('alle vier Saetze auf Englisch', () {
      expect(
        MealAnalysisResult.resolvePortionNotes(_legacyGrams, enL10n),
        'Adjusted manually: 250 g instead of the original portion.',
      );
      expect(
        MealAnalysisResult.resolvePortionNotes(_legacyGramsDensity, enL10n),
        'Adjusted manually: 250 g instead of the original portion. Calories '
        'recalculated at 180 kcal per 100 g.',
      );
      expect(
        MealAnalysisResult.resolvePortionNotes(_legacyItems, enL10n),
        'Individual items were confirmed or adjusted manually. Totals were '
        'recalculated from the sum of the items.',
      );
      expect(
        MealAnalysisResult.resolvePortionNotes(_legacyItemsNoMacros, enL10n),
        'Individual items were confirmed or adjusted manually. Calories and '
        'grams were recalculated from the sum of the items. Macros can no '
        'longer be derived from the changed composition and are therefore '
        'not shown.',
      );
    });

    test('frisch angepasste Mahlzeit zeigt den englischen Satz', () {
      final adjusted = _meal().adjustedToGrams(1500);
      expect(
        adjusted.resolvedPortionNotes(enL10n),
        'Adjusted manually: 1500 g instead of the original portion. Calories '
        'recalculated at 180 kcal per 100 g.',
      );
    });
  });

  group('Anzeige: Hinweis eines protokollierten Rezepts', () {
    // `toMealResultForServings` writes `<portion> · <description> <hint>` in
    // the language active when logging. The placeholder parts must follow the
    // display language; resolving must give exactly what the writer would
    // have produced in that language.
    String note(FitnessRecipe recipe, double servings, AppLocalizations l10n) =>
        recipe.toMealResultForServings(servings, l10n).portionNotes;

    test('Platzhalter-Teile folgen der Anzeigesprache, in beide Richtungen', () {
      final recipe = _ownRecipe(title: 'Linsensuppe');
      for (final servings in const <double>[1, 2, 1.5]) {
        final german = recipe.toMealResultForServings(servings, deL10n);
        final english = recipe.toMealResultForServings(servings, enL10n);
        expect(german.resolvedPortionNotes(enL10n), english.portionNotes,
            reason: '$servings');
        expect(german.resolvedPortionNotes(deL10n), german.portionNotes);
        expect(english.resolvedPortionNotes(deL10n), german.portionNotes,
            reason: '$servings');
      }
      expect(
        note(recipe, 1, deL10n),
        '1 Portion · Eigenes Rezept Selbst angelegt. Werte beruhen auf deinen '
        'Angaben.',
      );
      expect(
        recipe
            .toMealResultForServings(1.5, deL10n)
            .resolvedPortionNotes(enL10n),
        '1.5 servings · Your recipe Self-added. Values are based on what you '
        'entered.',
      );
    });

    test('Rezepttext des Nutzers und des Katalogs bleibt', () {
      final own = _ownRecipe(title: 'Suppe').copyWith(
        portion: '1 Teller',
        description: 'Meine Suppe',
      );
      expect(
        own.toMealResult(deL10n).resolvedPortionNotes(enL10n),
        '1 Teller · Meine Suppe Self-added. Values are based on what you '
        'entered.',
      );
      final catalog = recipeCatalogDe.first;
      final logged = catalog.toMealResultForServings(2, deL10n);
      expect(
        logged.resolvedPortionNotes(enL10n),
        '2 servings · ${catalog.description} ${catalog.professionalHint}',
      );
    });

    test('ausserhalb eines Rezepts bleibt derselbe Text unberuehrt', () {
      final raw = note(_ownRecipe(), 2, deL10n);
      expect(_meal(notes: raw).resolvedPortionNotes(enL10n), raw);
      expect(
        _meal(notes: raw, source: 'manual').resolvedPortionNotes(enL10n),
        raw,
      );
    });
  });

  group('Anzeige: Makro-Texte', () {
    test('Dezimaltrennzeichen je Sprache, keine neue Rundung', () {
      expect(PersistedLabels.macroText('12,5 g', enL10n), '12.5 g');
      expect(PersistedLabels.macroText('12,5 g', deL10n), '12,5 g');
      expect(PersistedLabels.macroText('12.25 g', deL10n), '12,25 g');
      expect(PersistedLabels.macroText('12 g', enL10n), '12 g');
      expect(PersistedLabels.macroText('-', enL10n), '-');
      final meal = _meal(protein: '30,4 g');
      expect(meal.resolvedProtein(enL10n), '30.4 g');
      expect(meal.resolvedCarbs(enL10n), '-');
    });
  });

  group('Anzeige: Rezepte, Zutaten, Einkaufsliste', () {
    test('Titel-Fallback nur fuer eigene Rezepte', () {
      expect(_ownRecipe().displayTitle(enL10n), 'Your recipe');
      expect(_ownRecipe().displayTitle(deL10n), 'Eigenes Rezept');
      expect(
        _ownRecipe(userCreated: false).displayTitle(enL10n),
        'Eigenes Rezept',
      );
    });

    test('Produkt-Zutat nur mit passendem Produktcode', () {
      final ingredient = _offIngredient('Produkt 4001 · Milka', '4001');
      expect(ingredient.displayName(enL10n), 'Product 4001 · Milka');
      expect(ingredient.displayName(deL10n), 'Produkt 4001 · Milka');
      expect(_offIngredient('Produkt', null).displayName(enL10n), 'Product');
    });

    test('Import-Quelle folgt der Sprache, in beide Richtungen', () {
      String line(String text, AppLocalizations l10n) =>
          FitnessRecipe.resolveImportSourceLine(text, l10n);
      expect(
        line('Suppe\n\nQuelle: https://example.com/a', enL10n),
        'Suppe\n\nSource: https://example.com/a',
      );
      expect(
        line('Source: https://example.com/a', deL10n),
        'Quelle: https://example.com/a',
      );
      expect(
        _ownRecipe(
          description: 'Quelle: https://example.com/a',
          categories: <String>['${recipeIngredientsBasisPrefix}per_serving'],
        ).displayDescription(enL10n),
        'Source: https://example.com/a',
      );
    });

    test('Einkaufsliste: Namen aufgeloest, IDs unveraendert', () {
      final day = DateTime(2026, 9, 28);
      final plans = <PlannedMeal>[
        PlannedMeal.create(
          recipe: _ownRecipe(
            structured: <RecipeIngredient>[
              _offIngredient('Produkt 4001 · Milka', '4001'),
            ],
          ),
          day: day,
          slot: MealSlot.dinner,
          id: '11111111-1111-4111-8111-111111111111',
        ),
        PlannedMeal.create(
          recipe: _ownRecipe(ingredients: '200 g Linsen'),
          day: day,
          slot: MealSlot.lunch,
          id: '22222222-2222-4222-8222-222222222222',
        ),
      ];
      final raw = buildShoppingList(plans, day);
      final en = buildShoppingList(plans, day, l10n: enL10n);
      final de = buildShoppingList(plans, day, l10n: deL10n);
      expect(en.map((i) => i.id), raw.map((i) => i.id));
      expect(de.map((i) => i.id), raw.map((i) => i.id));
      expect(en.map((i) => i.grams == null ? i.recipeTitle : i.name), [
        'Product 4001 · Milka',
        'Your recipe',
      ]);
      expect(de.map((i) => i.grams == null ? i.recipeTitle : i.name), [
        'Produkt 4001 · Milka',
        'Eigenes Rezept',
      ]);
    });
  });

  group('Waechter: Nutzertext bleibt unangetastet', () {
    test('nur exakte Drahtwerte werden aufgeloest', () {
      for (final name in const <String>[
        'unbekannte mahlzeit',
        'Unbekannte Mahlzeit mit Reis',
        'Mahlzeit!',
        'Meine Mahlzeit',
        'Mein Produkt 42',
        'Produktmix 42',
        'Eigenes Rezept von Oma',
      ]) {
        expect(_meal(name: name).resolvedMealName(enL10n), name);
      }
      // "Produkt 42" without the matching stored barcode is the user's.
      expect(_meal(name: 'Produkt 42').resolvedMealName(enL10n), 'Produkt 42');
      expect(
        _meal(name: 'Produkt 42', barcode: '43').resolvedMealName(enL10n),
        'Produkt 42',
      );
      expect(
        _meal(name: 'Produkt 42 Vollkorn', barcode: '42')
            .resolvedMealName(enL10n),
        'Produkt 42 Vollkorn',
      );
      expect(
        _offIngredient('Produkt 4001 · Milka', '4002').displayName(enL10n),
        'Produkt 4001 · Milka',
      );
      expect(
        RecipeIngredient(
          name: 'Zutat',
          grams: 10,
          per100g: const RecipeNutrition(),
        ).displayName(enL10n),
        'Zutat',
        reason: 'a manual ingredient name is user text',
      );
    });

    test('Hinweise, Makros und Quellen ausserhalb der Muster bleiben', () {
      for (final note in const <String>[
        'Manuell angepasst: viel Soße.',
        'Manuell angepasst: 250 g statt der ursprünglichen Portion',
        '$_legacyItems Danke!',
        'Ca. 120 g Nudeln mit 80 g Soße.',
      ]) {
        expect(MealAnalysisResult.resolvePortionNotes(note, enL10n), note);
      }
      for (final macro in const <String>['ca. 12,5 g', '12,5g', '12,5 kg']) {
        expect(PersistedLabels.macroText(macro, enL10n), macro);
      }
      for (final text in const <String>[
        'Quelle: meine Oma',
        'Suppe\n\nQuelle: https://example.com/a und mehr',
        'Quelle: https://example.com/a\n\nNotiz',
      ]) {
        expect(FitnessRecipe.resolveImportSourceLine(text, enL10n), text);
      }
    });
  });
}

extension on MealAnalysisResult {
  /// Same meal without a usable density, so the adjustment note has no kcal.
  MealAnalysisResult copyWithZeroDensity() => MealAnalysisResult(
    mealName: mealName,
    caloriesKcal: 0,
    estimatedGrams: estimatedGrams,
    kcalPer100G: 0,
    protein: protein,
    carbs: carbs,
    fat: fat,
    confidence: confidence,
    portionNotes: portionNotes,
  );
}
