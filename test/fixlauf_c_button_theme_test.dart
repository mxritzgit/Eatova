// Fix run for review 2026-08-27, F8-10 (Food part): the primary buttons of
// the suggestion tile, the edit sheet and the manual-entry sheet overrode the
// theme with `FilledButton.styleFrom(backgroundColor: forest …)`. They now
// inherit the app-wide filledButtonTheme — one primary language, set once.

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
import 'package:eatova/src/widgets/kcal/manual_meal_sheet.dart';

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

const MealAnalysisResult _apfel = MealAnalysisResult(
  mealName: 'Apfel',
  caloriesKcal: 52,
  estimatedGrams: 100,
  kcalPer100G: 52,
  protein: '0 g',
  carbs: '14 g',
  fat: '0 g',
  confidence: 'Datenbank',
  portionNotes: '',
);

LoggedMeal? _update(
  String id, {
  MealAnalysisResult? result,
  MealSlot? slot,
  DateTime? day,
}) =>
    null;

Widget _app(Widget body) => MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(body: body),
    );

void _telefon(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// A button is "unstyled" when it neither overrides its fill nor its ink.
void _expectThemed(WidgetTester tester, Finder button) {
  final style = tester.widget<FilledButton>(button).style;
  expect(style?.backgroundColor, isNull, reason: 'eigene Füllung');
  expect(style?.foregroundColor, isNull, reason: 'eigene Textfarbe');
}

void main() {
  testWidgets('Hinzufügen-Knopf der Vorschlagskachel nimmt das Theme',
      (tester) async {
    _telefon(tester);
    await tester.pumpWidget(
      _app(
        AddMealSheet(
          slot: MealSlot.snack,
          analyzer: _StummerAnalyzer(),
          productService: _StummerProduktdienst(),
          photoInput: _StummeFotoquelle(),
          favorites: [
            FavoriteMeal(
              id: FavoriteMeal.idFor(_apfel),
              result: _apfel,
              addedAt: DateTime(2026, 8, 20),
              pinned: false,
            ),
          ],
          onAdd: (_, __) => 'id-1',
          onUpdateMeal: (_, __) {},
          onRemoveFavorite: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('favorite-tile-0')));
    await tester.pumpAndSettle();

    _expectThemed(tester, find.byKey(const ValueKey('favorite-tile-add-0')));
  });

  testWidgets('Speichern-Knopf des Bearbeiten-Sheets nimmt das Theme',
      (tester) async {
    _telefon(tester);
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showEditMealSheet(
                context,
                meal: LoggedMeal(
                  id: 'meal-1',
                  result: _apfel,
                  loggedAt: DateTime.now(),
                  forcedSlot: MealSlot.breakfast,
                ),
                onUpdateMeal: _update,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    _expectThemed(tester, find.byKey(const ValueKey('edit-meal-save-button')));
  });

  testWidgets('Speichern-Knopf des Manuell-Sheets nimmt das Theme',
      (tester) async {
    _telefon(tester);
    await tester.pumpWidget(_app(const ManualMealSheet()));
    await tester.pumpAndSettle();

    _expectThemed(tester, find.byKey(const ValueKey('manual-meal-save')));
  });
}
