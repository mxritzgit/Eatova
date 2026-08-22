// Gap 2 from B1 (docs/REVIEW-2026-08-08.md): the last-resort guard in
// AddMealSheet. Legacy `favorite_meals` rows with `calories_kcal = 0` (the
// constraint allows `>= 0`) could still be logged. New ones can no longer be
// created, but existing data remains.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/meals_sync.dart'
    show mealResultFromJson, mealResultToJson;
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';

class _StummerAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async =>
      throw UnimplementedError();
}

class _StummerProduktdienst implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];
}

class _StummeFotoquelle implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

/// A legacy row as the pre-fix code wrote it: name and portion present,
/// calories 0.
final FavoriteMeal altlast = FavoriteMeal(
  id: 'name:proteinriegel',
  addedAt: DateTime(2026, 8, 1),
  result: const MealAnalysisResult(
    mealName: 'Proteinriegel',
    caloriesKcal: 0,
    estimatedGrams: 60,
    kcalPer100G: 0,
    protein: '-',
    carbs: '-',
    fat: '-',
    confidence: 'Datenbank',
    portionNotes: 'OpenFoodFacts ohne Energieangabe.',
  ),
);

void main() {
  testWidgets('0-kcal-Favorit lässt sich nicht ins Tagebuch legen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final geloggt = <MealAnalysisResult>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(Brightness.dark),
        // AddMealSheet reads context.l10n.
        locale: const Locale('de'),
        supportedLocales: const [Locale('de'), Locale('en')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: AddMealSheet(
            slot: MealSlot.snack,
            analyzer: _StummerAnalyzer(),
            productService: _StummerProduktdienst(),
            photoInput: _StummeFotoquelle(),
            favorites: <FavoriteMeal>[altlast],
            onAdd: (result, slot) {
              geloggt.add(result);
              return 'id-1';
            },
            onUpdateMeal: (_, __) {},
            onRemoveFavorite: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('favorite-tile-0')));
    await tester.pumpAndSettle();

    final knopf = find.byKey(const ValueKey('favorite-tile-add-0'));
    await tester.ensureVisible(knopf);
    await tester.tap(knopf);
    await tester.pumpAndSettle();

    expect(geloggt, isEmpty, reason: '0 kcal dürfen nicht geloggt werden');
    expect(find.text('0 kcal zu Snacks hinzugefügt.'), findsNothing);
    expect(find.textContaining('Kalorienangabe'), findsOneWidget);
  });

  // B7: the guard targets the "0 = unknown" sentinel, not the product. A
  // MEASURED 0 must pass, or water would be unloggable by barcode forever.
  testWidgets('Wasser-Favorit (gemessene 0 kcal) lässt sich ins Tagebuch legen',
      (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final wasser = FavoriteMeal(
      id: 'name:volvic naturelle',
      addedAt: DateTime(2026, 8, 8),
      result: const MealAnalysisResult(
        mealName: 'Volvic Naturelle',
        caloriesKcal: 0,
        estimatedGrams: 250,
        kcalPer100G: 0,
        protein: '0 g',
        carbs: '0 g',
        fat: '0 g',
        confidence: 'Datenbank',
        portionNotes: 'OpenFoodFacts: 0 kcal / 100 g.',
        explicitZeroKcal: true,
      ),
    );

    final geloggt = <MealAnalysisResult>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(Brightness.dark),
        // AddMealSheet reads context.l10n.
        locale: const Locale('de'),
        supportedLocales: const [Locale('de'), Locale('en')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: AddMealSheet(
            slot: MealSlot.snack,
            analyzer: _StummerAnalyzer(),
            productService: _StummerProduktdienst(),
            photoInput: _StummeFotoquelle(),
            favorites: <FavoriteMeal>[wasser],
            onAdd: (result, slot) {
              geloggt.add(result);
              return 'id-1';
            },
            onUpdateMeal: (_, __) {},
            onRemoveFavorite: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('favorite-tile-0')));
    await tester.pumpAndSettle();
    final knopf = find.byKey(const ValueKey('favorite-tile-add-0'));
    await tester.ensureVisible(knopf);
    await tester.tap(knopf);
    await tester.pumpAndSettle();

    expect(geloggt, hasLength(1),
        reason: 'die gemessene 0 ist eine Kalorienangabe, keine fehlende');
    expect(find.textContaining('Kalorienangabe'), findsNothing);
  });

  test('explicitZeroKcal überlebt den Payload-Roundtrip — sonst blockiert der '
      'Auto-Recent-Favorit desselben Wassers nach dem nächsten Boot', () {
    const wasser = MealAnalysisResult(
      mealName: 'Volvic Naturelle',
      caloriesKcal: 0,
      estimatedGrams: 250,
      kcalPer100G: 0,
      protein: '0 g',
      carbs: '0 g',
      fat: '0 g',
      confidence: 'Datenbank',
      portionNotes: 'OpenFoodFacts: 0 kcal / 100 g.',
      explicitZeroKcal: true,
    );

    final wieder = mealResultFromJson(mealResultToJson(wasser));
    expect(wieder.explicitZeroKcal, isTrue);
    // Legacy rows without the key read false — the sentinel stays a sentinel.
    final altlastJson = mealResultToJson(wasser)..remove('explicitZeroKcal');
    expect(mealResultFromJson(altlastJson).explicitZeroKcal, isFalse);
  });
}
