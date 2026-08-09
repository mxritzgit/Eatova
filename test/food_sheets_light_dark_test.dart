// Pflicht aus DESIGN_REFACTOR §7.2 fuer die Sheets des Food-Pakets:
// „Mindestens ein Widget-Test pro Screen pumpt ihn unter
// buildEatovaTheme(Brightness.light) UND (Brightness.dark)."
//
// Die bestehenden Sheet-Suiten (add/analyse/edit) pumpen ausschliesslich
// Dunkel — sie pruefen Ablaeufe, und dafuer genuegt ein Modus. Dieser Test
// deckt die fehlende Haelfte ab: rendern beide Modi ueberhaupt, ohne Ausnahme
// und ohne RenderFlex-Overflow? Overflows werden hier bewusst GESAMMELT statt
// geschluckt — ein Hell-Modus, der eine Zeile sprengt, soll auffallen.
//
// Kamera- und Barcode-Sheet fehlen absichtlich: ihre Flaechen liegen auf einem
// Live-Kamerabild und sind in beiden Modi dunkel (im Code begruendet); ihre
// Zustaende haengen zudem an Plattform-Fakes, die meal_camera_sheet_test
// bereits stellt.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

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

/// Pumpt [inhalt] im Eatova-Theme und liefert die dabei gemeldeten Fehler.
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
      // Der Slot-Kopf und die „Schon hinzugefuegt"-Liste stehen in beiden
      // Modi — die Karte liest ihre Flaeche aus den Tokens, nicht aus einer
      // Konstanten.
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
          // Kein echtes Update noetig: das Sheet zeigt nur an, gespeichert
          // wird in diesem Test nichts.
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
