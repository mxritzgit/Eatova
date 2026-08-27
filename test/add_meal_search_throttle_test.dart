// Up to nine requests per fruitless AddMealSheet search (review 2026-08-19):
// the debounce fired from two characters on, an empty answer counted as
// transient and got retried, and one attempt fans out over mirror + OFF-de +
// OFF-world; a 429 was never recognised. These tests pin the three
// countermeasures via the CALL COUNT, since the message alone would look
// right either way.

import 'dart:io';

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
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';

import 'support/harness.dart';

const String _keineTreffer =
    'Keine passenden Produkte gefunden. Versuche Marke + Produktname.';
const String _gedrosselt =
    'Zu viele Suchanfragen — versuch es gleich noch einmal.';

class _StummerAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async =>
      throw UnimplementedError();
}

class _StummeFotoquelle implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

/// Counts how often the service chain is actually hit.
class _ZaehlenderProduktdienst implements ProductLookupService {
  _ZaehlenderProduktdienst({
    this.treffer = const <ProductSearchResult>[],
    this.fehler,
  });

  final List<ProductSearchResult> treffer;
  final Object? fehler;
  int aufrufe = 0;

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    aufrufe++;
    if (fehler != null) {
      throw fehler!;
    }
    return treffer;
  }
}

final MealAnalysisResult _eiweissbrot = MealAnalysisResult.fromOpenFoodFacts(
  const <String, dynamic>{
    'code': '4000000000001',
    'product_name': 'Eiweissbrot',
    'brands': 'Testmarke',
    'serving_quantity': 100,
    'nutriments': <String, dynamic>{
      'energy-kcal_100g': 240,
      'proteins_100g': 20,
      'carbohydrates_100g': 8,
      'fat_100g': 10,
    },
  },
  '4000000000001',
);

final List<ProductSearchResult> _einTreffer = <ProductSearchResult>[
  ProductSearchResult(
    code: '4000000000001',
    title: 'Eiweissbrot · Testmarke',
    subtitle: 'Testmarke · 240 kcal / 100 g',
    kcalPer100G: 240,
    result: _eiweissbrot,
  ),
];

Future<void> _pumpeSheet(
  WidgetTester tester,
  ProductLookupService dienst,
) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await pumpLocalized(
    tester,
    AddMealSheet(
      slot: MealSlot.snack,
      analyzer: _StummerAnalyzer(),
      productService: dienst,
      photoInput: _StummeFotoquelle(),
      favorites: const <FavoriteMeal>[],
      onAdd: (_, __) => 'id-1',
      onUpdateMeal: (_, __) {},
      onRemoveFavorite: (_) {},
    ),
    reducedMotion: false,
    safeArea: false,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('leeres Ergebnis wird nicht wiederholt — leer ist eine Antwort', (
    tester,
  ) async {
    final dienst = _ZaehlenderProduktdienst();
    await _pumpeSheet(tester, dienst);

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Bauernmozzarella',
    );
    // Debounce (1000 ms) plus the room two retries would need — room that
    // must now stay unused.
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pumpAndSettle();

    expect(
      dienst.aufrufe,
      1,
      reason: 'jeder weitere Versuch kostet Mirror + OFF-de + OFF-world',
    );
    expect(find.text(_keineTreffer), findsOneWidget);
    // Definitively empty still offers the manual form.
    expect(find.byKey(const ValueKey('manual-entry-cta')), findsOneWidget);
  });

  testWidgets('429 wird benannt statt als leeres Ergebnis gezeigt', (
    tester,
  ) async {
    final dienst = _ZaehlenderProduktdienst(
      fehler: const HttpException('OpenFoodFacts search failed: 429'),
    );
    await _pumpeSheet(tester, dienst);

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Bauernmozzarella',
    );
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pumpAndSettle();

    expect(
      dienst.aufrufe,
      1,
      reason: 'eine Drosselung wird vom Wiederholen schlimmer, nicht besser',
    );
    expect(find.text(_gedrosselt), findsOneWidget);
    expect(
      find.text(_keineTreffer),
      findsNothing,
      reason: 'ein 429 ist keine Auskunft ueber das Produkt',
    );
    expect(
      find.byKey(const ValueKey('manual-entry-cta')),
      findsNothing,
      reason: 'kein „gibt es nicht" -> kein Weg ins Formular',
    );
  });

  testWidgets('Netz-Fehler ohne Drosselung behaelt seine Retries', (
    tester,
  ) async {
    final dienst = _ZaehlenderProduktdienst(
      fehler: const SocketException('OpenFoodFacts unreachable'),
    );
    await _pumpeSheet(tester, dienst);

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Bauernmozzarella',
    );
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pumpAndSettle();

    expect(
      dienst.aufrufe,
      3,
      reason: 'ein Wackler darf weiterhin dreimal versucht werden',
    );
  });

  testWidgets('Zweibuchstaben-Fragment loest von selbst keine Suche aus', (
    tester,
  ) async {
    final dienst = _ZaehlenderProduktdienst(treffer: _einTreffer);
    await _pumpeSheet(tester, dienst);

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Ei',
    );
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pumpAndSettle();

    expect(
      dienst.aufrufe,
      0,
      reason: 'der Debounce schickt erst ab drei Zeichen los',
    );
    expect(
      find.byKey(const ValueKey('manual-entry-button')),
      findsOneWidget,
      reason: 'unterhalb der Auto-Schwelle bleibt der Favoriten-Bereich stehen',
    );

    // The magnifier still releases the same fragment on demand.
    await tester.tap(find.byKey(const ValueKey('kcal-product-search-button')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(dienst.aufrufe, 1);
    expect(
      find.byKey(const ValueKey('kcal-product-suggestion-0')),
      findsOneWidget,
    );
  });

  testWidgets('drittes Zeichen loest die Suche wie bisher aus', (tester) async {
    final dienst = _ZaehlenderProduktdienst(treffer: _einTreffer);
    await _pumpeSheet(tester, dienst);

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Eiw',
    );
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pumpAndSettle();

    expect(dienst.aufrufe, 1);
    expect(
      find.byKey(const ValueKey('kcal-product-suggestion-0')),
      findsOneWidget,
    );
  });
}
