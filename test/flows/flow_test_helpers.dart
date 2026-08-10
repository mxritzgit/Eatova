// Gemeinsame Testinfrastruktur der End-to-End-Flow-Tests in test/flows/
// (frueher Monolith test/widget_test.dart, 2026-08 thematisch aufgeteilt).
// Enthaelt den testWidgetsRobust-Wrapper und die Fake-Services, die mehrere
// Flow-Suiten teilen. Bewusst KEIN `_test`-Suffix: die Datei ist keine Suite.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_camera_launcher.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';

// Wrapper um testWidgets fuer das CI-Setup:
//
// 1. Pinnt das Test-Viewport auf iPhone 14 portrait (393x852 logical @
//    DPR 3). Default ist 800x600, das verschiebt Grid-Reihen und macht
//    Scroll-Drags non-deterministic (z.B. greift `drag(0, -700)` ein
//    anderes Item als auf dem Device).
// 2. Schluckt RenderFlex-Overflow-Exceptions — die kommen vom Render-
//    Pass im Test-Headless-Renderer, auf dem echten Geraet sitzt die
//    App in Scroll-Containern und overflowt dort nicht.
//
// `testWidgets` setzt intern NACH setUp einen eigenen FlutterError.onError
// und resettet `tester.view` nicht — beides muss daher hier im Test-Body
// gemacht werden, damit es wirkt.
void testWidgetsRobust(
  String description,
  WidgetTesterCallback callback, {
  String? skip,
}) {
  testWidgets(description, skip: skip != null, (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    await callback(tester);
  });
}

/// Wechselt auf den Tab „Heute" und prueft dort die GEGESSEN-Kachel des
/// Kalorien-Heroes.
///
/// WARUM: Bis zum 2026-08-10 lasen die Flows das Tagestotal aus
/// `analyse-daily-kcal-total` — der Kalorien-Karte im Food-Tab. Die Karte ist
/// auf Nutzer-Entscheid entfallen („das haben wir ja im Heute-Tab schon"). Die
/// AUSSAGE der Flows („eine geloggte Mahlzeit kommt im Tagestotal an") ist
/// damit nicht weg, sondern umgezogen: sie steht in `today-stat-eaten`, und
/// der Heute-Tab folgt demselben `selectedFoodDate` wie der Food-Tab — auch
/// auf einem Archivtag.
///
/// [kcal] ist die reine Zahl mit Tausenderpunkt („252", „1.234"): der Hero
/// setzt Zahl und Beschriftung als getrennte Texte.
Future<void> expectTagestotalAufHeute(
  WidgetTester tester,
  String kcal,
) async {
  // Eine offene Bestaetigungs-Snackbar liegt ueber der Navigationsleiste und
  // finge sonst den Tap auf `nav-Heute`.
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(const ValueKey('nav-Heute')));
  await tester.pumpAndSettle();

  expect(
    find.descendant(
      of: find.byKey(const ValueKey('today-stat-eaten')),
      matching: find.text(kcal),
    ),
    findsOneWidget,
    reason: 'der Heute-Hero nennt nicht „$kcal" gegessene kcal',
  );
}

class FakeMealAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return const MealAnalysisResult(
      mealName: 'Teller mit Steak, Kartoffeln und Brokkoli',
      caloriesKcal: 855,
      estimatedGrams: 600,
      kcalPer100G: 142.5,
      protein: '64 g',
      carbs: '42 g',
      fat: '38 g',
      confidence: 'Mittel',
      portionNotes:
          'Die KI hat sichtbare Bestandteile getrennt geschätzt. Bitte Gramm pro Bestandteil bestätigen.',
      sourceLabel: 'Foto-KI',
      items: [
        MealComponent(
          name: 'Kartoffeln',
          grams: 200,
          caloriesKcal: 160,
          kcalPer100G: 80,
        ),
        MealComponent(
          name: 'Steak',
          grams: 300,
          caloriesKcal: 660,
          kcalPer100G: 220,
        ),
        MealComponent(
          name: 'Brokkoli',
          grams: 100,
          caloriesKcal: 35,
          kcalPer100G: 35,
        ),
      ],
    );
  }
}

// 300 g / 30 g Protein, OHNE Einzelposten -> die Re-Portionierung erzeugt im
// Anpassen-Sheet einen einzelnen synthetischen Posten. 100 kcal/100 g, damit
// 300 g = 300 kcal und 400 g = 400 kcal sauber aufgehen.
class MacroMealAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return const MealAnalysisResult(
      mealName: 'Protein-Bowl',
      caloriesKcal: 300,
      estimatedGrams: 300,
      kcalPer100G: 100,
      protein: '30 g',
      carbs: '50 g',
      fat: '20 g',
      confidence: 'Mittel',
      portionNotes: 'Test-Mahlzeit ohne Einzelposten.',
      sourceLabel: 'Foto-KI',
    );
  }
}

// Ersetzt die echte In-App-Kamera (camera-Package, nicht test-bar): liefert
// sofort ein kanned Foto im uebergebenen Slot zurueck, damit der KI-Scan-Flow
// (Kamera -> Analyse-Sheet) ohne Hardware getestet werden kann.
class FakeMealCameraLauncher implements MealCameraLauncher {
  @override
  Future<MealCameraCapture?> launch(
    BuildContext context, {
    required MealSlot initialSlot,
  }) async {
    return MealCameraCapture(
      request: const MealAnalysisRequest(imageId: 'test-photo'),
      previewBytes: null,
      slot: initialSlot,
    );
  }
}

class FakeProductLookupService implements ProductLookupService {
  static final MealAnalysisResult salamiPizza = MealAnalysisResult.fromOpenFoodFacts(
    const <String, dynamic>{
      'code': '4001724012345',
      'product_name': 'Die Ofenfrische Salami',
      'brands': 'Dr. Oetker',
      'quantity': '390 g',
      'serving_quantity': 100,
      'nutriments': <String, dynamic>{
        'energy-kcal_100g': 252,
        'proteins_100g': 10,
        'carbohydrates_100g': 31,
        'fat_100g': 9,
      },
    },
    '4001724012345',
  );

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async => salamiPizza;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return productSuggestions;
  }

  static List<ProductSearchResult> get productSuggestions =>
      <ProductSearchResult>[
        ProductSearchResult(
          code: '4001724012345',
          title: 'Die Ofenfrische Salami · Dr. Oetker',
          subtitle: 'Dr. Oetker · 390 g · 252 kcal / 100 g',
          kcalPer100G: 252,
          result: salamiPizza,
        ),
      ];
}

class FlakyProductLookupService implements ProductLookupService {
  int searchAttempts = 0;

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      FakeProductLookupService.salamiPizza;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    searchAttempts++;
    if (searchAttempts <= 2) {
      throw Exception('temporary OpenFoodFacts failure');
    }
    return FakeProductLookupService.productSuggestions;
  }
}

class EmptyThenSuccessProductLookupService implements ProductLookupService {
  int searchAttempts = 0;

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      FakeProductLookupService.salamiPizza;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    searchAttempts++;
    if (searchAttempts <= 2) {
      return const <ProductSearchResult>[];
    }
    return FakeProductLookupService.productSuggestions;
  }
}
