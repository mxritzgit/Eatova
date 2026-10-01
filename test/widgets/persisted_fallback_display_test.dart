// Persisted German fallback values render in the active language.
//
// Meal names ('Unbekannte Mahlzeit', 'Mahlzeit', 'Produkt <barcode>'),
// component names ('Zutat'), the adjustment notes and German-formatted macro
// text ('12,5 g') are WIRE values: rows written by every earlier build carry
// them, and already-installed builds on other devices keep reading them
// verbatim. The writers therefore stay unchanged and the DISPLAY resolves them.
// Every fixture below is read through `mealResultFromJson`, i.e. exactly the
// way a stored diary/favorite payload reaches the screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/meals_sync.dart'
    show mealResultFromJson, mealResultToJson;
import 'package:eatova/src/widgets/kcal/diary_meal_card.dart';
import 'package:eatova/src/widgets/kcal/saved_meal_presentation.dart';
import 'package:eatova/src/widgets/meal/meal_widgets.dart';

import '../support/food_navigation.dart';
import '../support/harness.dart';

const _en = Locale('en');
const _de = Locale('de');

/// A stored payload as `mealResultToJson` writes it; [fields] override.
MealAnalysisResult _stored(Map<String, dynamic> fields) =>
    mealResultFromJson(<String, dynamic>{
      'mealName': 'Mahlzeit',
      'caloriesKcal': 420,
      'estimatedGrams': 300,
      'kcalPer100G': 140.0,
      'protein': '-',
      'carbs': '-',
      'fat': '-',
      'confidence': 'high',
      'portionNotes': '',
      'items': const <Object>[],
      'isAdjusted': false,
      'sourceLabel': 'photoAi',
      ...fields,
    });

/// A barcode product without `product_name`, as every build since the OFF
/// integration names it.
final MealAnalysisResult _namelessProduct = _stored(<String, dynamic>{
  'mealName': 'Produkt 4001234567890 · Milka',
  'caloriesKcal': 265,
  'estimatedGrams': 50,
  'kcalPer100G': 530.0,
  'protein': '12,5 g',
  'carbs': '28,5 g',
  'fat': '15 g',
  'confidence': 'database',
  'sourceLabel': 'OpenFoodFacts',
  'barcode': '4001234567890',
  'brand': 'Milka',
});

/// A scan whose components the user confirmed: the model named one item
/// nothing ('Zutat') and the meal nothing ('Mahlzeit').
final MealAnalysisResult _confirmedScan = _stored(<String, dynamic>{
  'mealName': 'Mahlzeit',
  'protein': '12,5 g',
  'carbs': '40 g',
  'fat': '7,5 g',
  'isAdjusted': true,
  'portionNotes':
      'Einzelne Bestandteile wurden manuell bestätigt oder angepasst. '
      'Gesamtwerte wurden aus der Summe der Positionen neu berechnet.',
  'items': <Map<String, dynamic>>[
    <String, dynamic>{'name': 'Zutat', 'grams': 100, 'caloriesKcal': 150},
    <String, dynamic>{'name': 'Reis', 'grams': 200, 'caloriesKcal': 270},
  ],
});

Future<void> _pumpSaved(
  WidgetTester tester,
  MealAnalysisResult result,
  Locale locale,
) => pumpLocalized(
  tester,
  Column(
    children: [
      SavedMealHeader(
        result: result,
        expanded: false,
        justAdded: false,
        isFavorite: true,
        onTap: () {},
      ),
      SavedMealNutrients(result: result),
    ],
  ),
  locale: locale,
  scrollable: true,
);

Future<void> _pumpResultCard(
  WidgetTester tester,
  MealAnalysisResult result,
  Locale locale,
) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await pumpLocalized(
    tester,
    MealResultCard(
      result: result,
      addedToDailyTotal: false,
      onAdjustRequested: () {},
      onAddToDailyRequested: () {},
      showActions: false,
    ),
    locale: locale,
    scrollable: true,
    padding: const EdgeInsets.all(20),
  );
}

Future<void> _pumpDiary(
  WidgetTester tester,
  MealAnalysisResult result,
  Locale locale,
) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await pumpLocalized(
    tester,
    DiaryMealCard(
      slot: MealSlot.lunch,
      entries: <DiaryEntry>[
        DiaryEntry(
          LoggedMeal(
            id: 'm1',
            result: result,
            loggedAt: DateTime(2026, 9, 28, 12, 30),
            forcedSlot: MealSlot.lunch,
          ),
          0,
        ),
      ],
      onAddToSlot: (_) {},
      onRemoveMeal: (_) {},
    ),
    locale: locale,
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
  );
  await tester.pump();
  await expandFoodEntries(tester);
}

FitnessRecipe _userRecipe({
  required String title,
  String description = '',
  List<String> categories = const <String>['Eigene'],
  List<RecipeIngredient> structured = const <RecipeIngredient>[],
}) => FitnessRecipe(
  slug: 'user_fixture',
  title: title,
  description: description,
  portion: '',
  ingredients: '',
  preparation: '',
  professionalHint: '',
  imageAsset: '',
  caloriesKcal: 520,
  proteinG: 40,
  carbsG: 50,
  fatG: 15,
  estimatedGrams: structured.isEmpty ? 300 : 0,
  categories: categories,
  userCreated: true,
  structuredIngredients: structured,
);

Future<void> _pumpRecipe(
  WidgetTester tester,
  FitnessRecipe recipe,
  Locale locale,
) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await pumpLocalized(
    tester,
    RecipeDetailScreen(recipe: recipe, onAddMeal: (_, __) {}),
    locale: locale,
    settle: true,
  );
}

String _recipeTitle(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('recipe-detail-user_fixture')))
    .data!;

void main() {
  group('Favoriten: namenloses Barcode-Produkt und deutsche Makro-Texte', () {
    testWidgets('en zeigt Product <barcode> und Dezimalpunkte', (tester) async {
      await _pumpSaved(tester, _namelessProduct, _en);

      // The row splits the brand off the name into its muted line.
      expect(find.text('Product 4001234567890'), findsOneWidget);
      expect(find.textContaining('Milka ·'), findsOneWidget);
      expect(find.textContaining('Produkt'), findsNothing);
      expect(find.text('P 12.5 g'), findsOneWidget);
      expect(find.text('C 28.5 g'), findsOneWidget);
      expect(find.text('F 15 g'), findsOneWidget);
    });

    testWidgets('de bleibt byte-gleich', (tester) async {
      await _pumpSaved(tester, _namelessProduct, _de);

      expect(find.text('Produkt 4001234567890'), findsOneWidget);
      expect(find.textContaining('Milka ·'), findsOneWidget);
      expect(find.text('P 12,5 g'), findsOneWidget);
      expect(find.text('KH 28,5 g'), findsOneWidget);
    });
  });

  group('Tagebuch: Unbekannte Mahlzeit', () {
    final unknown = _stored(<String, dynamic>{
      'mealName': 'Unbekannte Mahlzeit',
      'sourceLabel': 'Foto-KI',
    });

    testWidgets('en: Slot-Titel und Zeile heissen Unknown meal', (
      tester,
    ) async {
      await _pumpDiary(tester, unknown, _en);

      expect(find.text('Unknown meal'), findsWidgets);
      expect(find.textContaining('Unbekannte'), findsNothing);
    });

    testWidgets('de bleibt Unbekannte Mahlzeit', (tester) async {
      await _pumpDiary(tester, unknown, _de);

      expect(find.text('Unbekannte Mahlzeit'), findsWidgets);
    });
  });

  group('Ergebniskarte: Name, Makros, Bestandteile, Hinweis', () {
    testWidgets('en loest alle vier Familien auf', (tester) async {
      await _pumpResultCard(tester, _confirmedScan, _en);

      expect(
        tester.widget<Text>(find.byKey(const ValueKey('analyse-meal-name'))).data,
        'Meal',
      );
      expect(find.text('12.5 g'), findsOneWidget);
      expect(find.text('7.5 g'), findsOneWidget);
      expect(find.text('Ingredient'), findsOneWidget);
      expect(find.text('Zutat'), findsNothing);
      expect(find.text('Reis'), findsOneWidget, reason: 'model text stays');

      await tester.tap(find.byKey(const ValueKey('analyse-info-button')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('analyse-portion-notes')))
            .data,
        'Individual items were confirmed or adjusted manually. Totals were '
        'recalculated from the sum of the items.',
      );
      expect(find.text('Meal'), findsNWidgets(2), reason: 'card + sheet title');
    });

    testWidgets('de bleibt byte-gleich', (tester) async {
      await _pumpResultCard(tester, _confirmedScan, _de);

      expect(
        tester.widget<Text>(find.byKey(const ValueKey('analyse-meal-name'))).data,
        'Mahlzeit',
      );
      expect(find.text('12,5 g'), findsOneWidget);
      expect(find.text('Zutat'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('analyse-info-button')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('analyse-portion-notes')))
            .data,
        'Einzelne Bestandteile wurden manuell bestätigt oder angepasst. '
        'Gesamtwerte wurden aus der Summe der Positionen neu berechnet.',
      );
    });
  });

  group('Protokolliertes eigenes Rezept: Hinweis im Info-Sheet', () {
    // Logged while the app was German, read back from storage.
    final logged = mealResultFromJson(
      mealResultToJson(
        _userRecipe(title: 'Linsensuppe').toMealResultForServings(2, deL10n),
      ),
    );

    testWidgets('en', (tester) async {
      await _pumpResultCard(tester, logged, _en);
      await tester.tap(find.byKey(const ValueKey('analyse-info-button')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('analyse-portion-notes')))
            .data,
        '2 servings · Your recipe Self-added. Values are based on what you '
        'entered.',
      );
    });

    testWidgets('de bleibt byte-gleich', (tester) async {
      await _pumpResultCard(tester, logged, _de);
      await tester.tap(find.byKey(const ValueKey('analyse-info-button')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('analyse-portion-notes')))
            .data,
        logged.portionNotes,
      );
      expect(
        logged.portionNotes,
        '2 Portionen · Eigenes Rezept Selbst angelegt. Werte beruhen auf '
        'deinen Angaben.',
      );
    });
  });

  group('Waechter: Nutzertext wird nie umgeschrieben', () {
    testWidgets('en: eigene Namen, die nur aehnlich aussehen, bleiben', (
      tester,
    ) async {
      // A manual entry the user typed as "Produkt 42": no barcode, so it can
      // not be the product fallback.
      await _pumpSaved(
        tester,
        _stored(<String, dynamic>{
          'mealName': 'Produkt 42',
          'sourceLabel': 'manual',
          'protein': '12 g',
        }),
        _en,
      );
      expect(find.text('Produkt 42'), findsOneWidget);

      // A real product name that merely starts like the fallback.
      await _pumpSaved(
        tester,
        _stored(<String, dynamic>{
          'mealName': 'Produkt 7 Vollkornbrot',
          'sourceLabel': 'OpenFoodFacts',
          'barcode': '7',
        }),
        _en,
      );
      expect(find.text('Produkt 7 Vollkornbrot'), findsOneWidget);

      await _pumpSaved(
        tester,
        _stored(<String, dynamic>{'mealName': 'Unbekannte Mahlzeit mit Reis'}),
        _en,
      );
      expect(find.text('Unbekannte Mahlzeit mit Reis'), findsOneWidget);

      await _pumpResultCard(
        tester,
        _stored(<String, dynamic>{
          'mealName': 'Mahlzeit am Abend',
          'portionNotes': 'Manuell angepasst: viel Soße.',
          'items': <Map<String, dynamic>>[
            <String, dynamic>{'name': 'Zutaten-Mix', 'grams': 80},
          ],
        }),
        _en,
      );
      expect(find.text('Mahlzeit am Abend'), findsOneWidget);
      expect(find.text('Zutaten-Mix'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('analyse-info-button')));
      await tester.pumpAndSettle();
      expect(find.text('Manuell angepasst: viel Soße.'), findsOneWidget);
    });

    testWidgets('en: ein eigenes Rezept mit aehnlichem Titel bleibt', (
      tester,
    ) async {
      await _pumpRecipe(
        tester,
        _userRecipe(title: 'Eigenes Rezept von Oma'),
        _en,
      );
      expect(_recipeTitle(tester), 'Eigenes Rezept von Oma');
    });
  });

  group('Rezepte: Titel-Fallback, Produkt-Zutat, Import-Quelle', () {
    final recipe = _userRecipe(
      title: 'Eigenes Rezept',
      description: 'Cremige Suppe\n\nQuelle: https://example.com/suppe',
      categories: <String>['Eigene', '${recipeIngredientsBasisPrefix}unspecified'],
      structured: <RecipeIngredient>[
        RecipeIngredient(
          name: 'Produkt 4001234567890 · Milka',
          grams: 50,
          per100g: const RecipeNutrition(caloriesKcal: 530),
          source: IngredientSource.openFoodFacts,
          productCode: '4001234567890',
        ),
      ],
    );

    testWidgets('en', (tester) async {
      await _pumpRecipe(tester, recipe, _en);

      expect(_recipeTitle(tester), 'Your recipe');
      expect(
        find.text('Cremige Suppe\n\nSource: https://example.com/suppe'),
        findsOneWidget,
      );
      expect(
        find.textContaining('50 g Product 4001234567890 · Milka'),
        findsOneWidget,
      );
      expect(find.textContaining('Produkt'), findsNothing);
      expect(find.textContaining('Quelle'), findsNothing);
    });

    testWidgets('de bleibt byte-gleich', (tester) async {
      await _pumpRecipe(tester, recipe, _de);

      expect(_recipeTitle(tester), 'Eigenes Rezept');
      expect(
        find.text('Cremige Suppe\n\nQuelle: https://example.com/suppe'),
        findsOneWidget,
      );
      expect(
        find.textContaining('50 g Produkt 4001234567890 · Milka'),
        findsOneWidget,
      );
    });
  });
}
