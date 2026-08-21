// Nutzer-Befund 2026-08-21 (iPhone 14 Pro): Tipp auf „Dinner" im Food-Tab —
// das Add-Meal-Sheet oeffnet, aber sein Kopf mit Kamera/Galerie/Barcode liegt
// unter der Dynamic Island und ist nicht zu sehen.
//
// Ursache: `maxHeight = size.height * 0.92` ueber `Padding(bottom:
// viewInsets.bottom)`. Mit offener Suchfeld-Tastatur (336 pt) war
// 0,92 * 844 + 336 > 844; die Modal-Route klemmte das Sheet auf
// `Bildschirm minus Tastatur` und schob es damit bis an y = 0.
//
// Der Test oeffnet das Sheet ueber die ECHTE Route (`showAddMealSheet`) —
// nur dort greift `MediaQuery.removePadding(removeTop: true)`, das die
// Safe-Area aus der MediaQuery entfernt — und misst die gerenderte Geometrie
// gegen die Formel aus `sheetMaxHeight`.

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
import 'package:eatova/src/widgets/design/sheets.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';

import 'widgets/design/design_harness.dart' show pinIphone14Pro;

const double _hoehe = 844;
const double _safeAreaOben = 59;
const double _tastatur = 336;

class _StummerAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async =>
      throw UnimplementedError();
}

class _StummeFotoquelle implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

class _StummerProduktdienst implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];
}

MealAnalysisResult _produkt(int i) => MealAnalysisResult.fromOpenFoodFacts(
      <String, dynamic>{
        'code': '400000000${i.toString().padLeft(4, '0')}',
        'product_name': 'Testprodukt $i',
        'brands': 'Testmarke',
        'serving_quantity': 100,
        'nutriments': <String, dynamic>{
          'energy-kcal_100g': 200 + i,
          'proteins_100g': 10,
          'carbohydrates_100g': 20,
          'fat_100g': 5,
        },
      },
      '400000000${i.toString().padLeft(4, '0')}',
    );

/// Genug Favoriten, dass der Scrollbereich jeden Deckel reisst — nur dann
/// entscheidet der Deckel ueberhaupt, wo der Kopf landet.
final List<FavoriteMeal> _vieleFavoriten = List<FavoriteMeal>.generate(
  24,
  (i) => FavoriteMeal(
    id: 'fav-$i',
    addedAt: DateTime(2026, 8, 1 + (i % 20)),
    result: _produkt(i),
  ),
);

Future<void> _oeffneSheet(WidgetTester tester) async {
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
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showAddMealSheet(
                context,
                slot: MealSlot.dinner,
                analyzer: _StummerAnalyzer(),
                productService: _StummerProduktdienst(),
                photoInput: _StummeFotoquelle(),
                favorites: _vieleFavoriten,
                onAdd: (_, __) => 'id-1',
                onUpdateMeal: (_, __) {},
                onRemoveFavorite: (_) {},
              ),
              child: const Text('Dinner'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Dinner'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

/// Beweis, dass der Deckel wirklich greift: der Scrollbereich hat Restweg,
/// der Inhalt waere also hoeher als das, was das Sheet zeigt.
void _erwarteGedeckelt(WidgetTester tester) {
  final rest = tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey('add-meal-sheet-scroll')),
          matching: find.byType(Scrollable),
        ),
      )
      .position
      .maxScrollExtent;
  expect(rest, greaterThan(0),
      reason: 'Der Testinhalt muss den Deckel reissen, sonst misst der Test '
          'nur die Inhaltshoehe und nicht den Deckel.');
}

void main() {
  testWidgets(
      'mit offener Tastatur bleibt der Kopf (Kamera) unter der Dynamic Island',
      (tester) async {
    pinIphone14Pro(tester, keyboard: true);
    await _oeffneSheet(tester);
    _erwarteGedeckelt(tester);

    final sheet = tester.getRect(find.byKey(const ValueKey('add-meal-sheet')));
    const deckel = _hoehe - _safeAreaOben - _tastatur - kSheetTopGap;
    expect(sheet.height, lessThanOrEqualTo(deckel));
    expect(sheet.top, greaterThanOrEqualTo(_safeAreaOben + kSheetTopGap));
    // Das Sheet steht ueber der Tastatur, nicht dahinter.
    expect(sheet.bottom, lessThanOrEqualTo(_hoehe - _tastatur));

    // Der eigentliche Befund: der Kamera-Knopf im Kopf liegt im sichtbaren
    // Bereich unterhalb der Safe-Area.
    final kamera =
        tester.getRect(find.byKey(const ValueKey('analyse-camera-button')));
    expect(kamera.top, greaterThanOrEqualTo(_safeAreaOben));
    // Und auch Galerie/Barcode/Schliessen — derselbe Kopf, eine Zeile.
    for (final key in const <String>[
      'analyse-gallery-button',
      'analyse-barcode-button',
      'add-meal-sheet-close',
    ]) {
      expect(
        tester.getRect(find.byKey(ValueKey(key))).top,
        greaterThanOrEqualTo(_safeAreaOben),
        reason: key,
      );
    }
  });

  testWidgets('ohne Tastatur ragt das Sheet ebenfalls nicht in die Safe-Area',
      (tester) async {
    pinIphone14Pro(tester);
    await _oeffneSheet(tester);
    _erwarteGedeckelt(tester);

    final sheet = tester.getRect(find.byKey(const ValueKey('add-meal-sheet')));
    expect(
      sheet.height,
      lessThanOrEqualTo(_hoehe - _safeAreaOben - kSheetTopGap),
    );
    expect(sheet.top, greaterThanOrEqualTo(_safeAreaOben + kSheetTopGap));
    expect(
      tester.getRect(find.byKey(const ValueKey('analyse-camera-button'))).top,
      greaterThanOrEqualTo(_safeAreaOben),
    );
  });
}
