// DESIGN_REFACTOR §7.2 for the food sheets: at least one widget test per screen
// pumps it under buildEatovaTheme(Brightness.light) AND (Brightness.dark).
//
// The existing sheet suites only pump dark, since they test flows. This covers
// the missing half: do both modes render without exception and without
// RenderFlex overflow? Overflows are COLLECTED, not swallowed.
//
// Camera and barcode sheets are deliberately absent: their surfaces sit on a
// live camera image and are dark in both modes, and their states depend on
// platform fakes that meal_camera_sheet_test already provides.

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
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/edit_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_analysis_sheet.dart';

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

const MealAnalysisResult _resultat = MealAnalysisResult(
  mealName: 'Linsensuppe',
  caloriesKcal: 420,
  estimatedGrams: 350,
  kcalPer100G: 120,
  protein: '24 g',
  carbs: '48 g',
  fat: '9 g',
  confidence: 'Hoch',
  portionNotes: 'Ein tiefer Teller.',
  sourceLabel: 'Foto-KI',
);

final FavoriteMeal _favorit = FavoriteMeal(
  id: 'name:linsensuppe',
  addedAt: DateTime(2026, 8, 1),
  result: _resultat,
);

const Size _viewport = Size(393, 852);

/// Pumps [inhalt] in the Eatova theme and returns the errors reported.
Future<List<Object>> _pump(
  WidgetTester tester,
  Brightness brightness,
  Widget inhalt,
) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = _viewport * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final fehler = <Object>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    fehler.add(details.exception);
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(brightness),
      // The sheets read context.l10n.
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: Align(alignment: Alignment.bottomCenter, child: inhalt),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fehler;
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('Das Add-Sheet rendert in $brightness sauber', (tester) async {
      final fehler = await _pump(
        tester,
        brightness,
        AddMealSheet(
          slot: MealSlot.lunch,
          analyzer: _StummerAnalyzer(),
          productService: _StummerProduktdienst(),
          photoInput: _StummeFotoquelle(),
          favorites: <FavoriteMeal>[_favorit],
          existingMeals: <LoggedMeal>[
            LoggedMeal(
              id: 'm1',
              result: _resultat,
              loggedAt: DateTime.now(),
              forcedSlot: MealSlot.lunch,
            ),
          ],
          onAdd: (_, __) => 'id-1',
          onUpdateMeal: (_, __) {},
          onRemoveFavorite: (_) {},
        ),
      );

      expect(tester.takeException(), isNull);
      expect(fehler, isEmpty);
      // Slot header and the already-added list show in both modes — the card
      // takes its surface from the tokens, not from a constant.
      expect(find.text('Mittagessen'), findsWidgets);
      expect(
        find.byKey(const ValueKey('analyse-existing-meals')),
        findsOneWidget,
      );
    });

    testWidgets('Das Analyse-Sheet rendert in $brightness sauber',
        (tester) async {
      final fehler = await _pump(
        tester,
        brightness,
        MealAnalysisSheet(
          slot: MealSlot.dinner,
          resultFuture: Future<MealAnalysisResult>.value(_resultat),
          previewImage: null,
          onAdd: (_, __) => 'id-1',
          onUpdateMeal: (_, __) {},
          failureMessage: 'Analyse fehlgeschlagen.',
        ),
      );

      expect(tester.takeException(), isNull);
      expect(fehler, isEmpty);
      expect(find.byKey(const ValueKey('analyse-result-card')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('analyse-add-daily-button')),
        findsOneWidget,
      );
    });

    testWidgets('Das Bearbeiten-Sheet rendert in $brightness sauber',
        (tester) async {
      final fehler = await _pump(
        tester,
        brightness,
        EditMealSheet(
          meal: LoggedMeal(
            id: 'm1',
            result: _resultat,
            loggedAt: DateTime.now(),
            forcedSlot: MealSlot.dinner,
          ),
          // No real update needed: this test only renders, never saves.
          onUpdateMeal: (_, {result, slot, day}) => null,
          onRemoveMeal: (_) {},
        ),
      );

      expect(tester.takeException(), isNull);
      expect(fehler, isEmpty);
      expect(find.byKey(const ValueKey('edit-meal-sheet')), findsOneWidget);
      expect(find.text('Mahlzeit bearbeiten'), findsOneWidget);
    });
  }
}
