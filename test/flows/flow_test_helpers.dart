// Shared test infrastructure for the end-to-end flow tests in test/flows/:
// the testWidgetsRobust wrapper and the fake services several suites use.
// Deliberately no `_test` suffix — this file is not a suite.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_camera_launcher.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/theme/app_theme.dart';

import '../fixlauf_a_helpers.dart';

// testWidgets wrapper for the CI setup:
//
// 1. Pins the viewport to iPhone 14 portrait (393x852 @ DPR 3). The 800x600
//    default shifts grid rows and makes scroll drags non-deterministic.
// 2. Swallows RenderFlex overflow exceptions, which come from the headless
//    render pass; on a real device the app sits in scroll containers.
//
// `testWidgets` installs its own FlutterError.onError AFTER setUp and does
// not reset `tester.view`, so both must happen inside the test body.
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

/// Switches to the Today tab and checks the eaten tile of the calorie hero.
///
/// The flows' claim ("a logged meal reaches the daily total") moved here from
/// the Food tab's calorie card; the Today tab follows the same
/// `selectedFoodDate`, archive days included.
///
/// [kcal] is the bare number with thousands separator ("252", "1.234"): the
/// hero renders number and label as separate texts.
Future<void> expectTagestotalAufHeute(WidgetTester tester, String kcal) async {
  // An open confirmation snackbar covers the nav bar and would otherwise
  // catch the tap on `nav-Heute`.
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

// --- SHELL HELPERS ----------------------------------------------------------
//
// The suites that drive a shell WITH a real sync (lebenszyklus, offline_sync,
// tageswechsel, favorites_menu, coach_rezept) used to carry byte-identical
// copies of the four helpers below. They live here so a change to the boot
// path costs one edit instead of four.

/// The [HomeStore] behind the mounted [EatovaHomePage].
HomeStore storeOf(WidgetTester tester) =>
    (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
        .debugStore;

/// Bounded settle instead of `pumpAndSettle`.
///
/// A shell WITH sync never settles: the welcome gate orbits its comet with
/// `repeat()` and every progress indicator on the boot path animates forever.
/// The default 40 x 16 ms = 640 ms of fake time, well past the longest
/// animation involved (sheet 300 ms, slidable resize 220 ms).
///
/// Deliberately no `disableAnimations` either: reduced motion collapses the
/// sheets' `AnimatedSize` to `Duration.zero`, which then re-dirties itself
/// inside its own `performLayout` — a framework assert with nothing to do with
/// the flow under test.
Future<void> settleFrames(
  WidgetTester tester, {
  int rounds = 40,
  Duration step = const Duration(milliseconds: 16),
}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(step);
  }
}

/// Pumps until [done] holds; fails with [what] instead of hanging.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() done,
  String what, {
  int maxFrames = 900,
}) async {
  for (var i = 0; i < maxFrames && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(done(), isTrue, reason: '$what tritt nicht ein');
  await settleFrames(tester);
}

/// Boots the shell for a returning user (profile complete, no onboarding) over
/// [server] and waits out the welcome gate.
///
/// [store] is the backing key-value store of the injected [LocalCache]; pass
/// one to assert against the PERSISTED slots, otherwise a fresh in-memory
/// store is used.
Future<HomeStore> pumpSignedIn(
  WidgetTester tester,
  FixlaufServer server, {
  KeyValueStore? store,
}) async {
  // NOT disposed in a tearDown: `SupabaseClient.dispose()` awaits its REST,
  // functions and isolate layers, and a tearDown runs OUTSIDE the fake-async
  // zone, so that await never completes and the test hangs into the
  // ten-minute timeout. The MockClient holds no socket worth closing.
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: server.client(),
    // Or GoTrue's refresh ticker stays a pending timer past the test.
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );

  await tester.pumpWidget(MaterialApp(
    theme: buildEatovaTheme(Brightness.light),
    locale: const Locale('en'),
    supportedLocales: const [Locale('de'), Locale('en')],
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: EatovaHomePage(
      productService: FakeProductLookupService(),
      sync: EatovaSync.forUser(client, kFixlaufUser),
      debugCache: LocalCache(store ?? InMemoryKeyValueStore(), kFixlaufUser),
      showWelcome: false,
    ),
  ));
  await pumpUntil(
    tester,
    () => find.byKey(const ValueKey('screen-welcome')).evaluate().isEmpty,
    'das Boot-Gate verschwindet',
  );
  return storeOf(tester);
}

/// Logs the fake Salami (252 kcal) into [slot] through the add sheet.
Future<void> logSalami(WidgetTester tester, String slot) async {
  await tester.tap(find.byKey(ValueKey('food-slot-add-$slot')));
  await settleFrames(tester);
  await tester.enterText(
    find.byKey(const ValueKey('kcal-product-search-input')),
    'Dr Oetker Salami',
  );
  await tester.tap(find.byKey(const ValueKey('kcal-product-search-button')));
  await settleFrames(tester);
  await tester.tap(find.byKey(const ValueKey('kcal-product-suggestion-0')));
  await settleFrames(tester);
  final addButton = find.byKey(const ValueKey('kcal-product-suggestion-add-0'));
  await tester.ensureVisible(addButton);
  await settleFrames(tester);
  await tester.tap(addButton);
  await settleFrames(tester);
  await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
  await settleFrames(tester);
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

// 300 g / 30 g protein with no line items, so re-portioning creates a single
// synthetic item. 100 kcal/100 g keeps 300 g = 300 kcal exact.
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

// Replaces the untestable in-app camera: returns a canned photo in the given
// slot so the AI scan flow runs without hardware.
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
  static final MealAnalysisResult salamiPizza =
      MealAnalysisResult.fromOpenFoodFacts(const <String, dynamic>{
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
      }, '4001724012345');

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

/// Search never finds anything — the path to the manual-entry CTA.
class NeverFindsProductLookupService implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      FakeProductLookupService.salamiPizza;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];
}

/// Search always fails — the error hint must NOT show the CTA.
class AlwaysFailingProductLookupService implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      FakeProductLookupService.salamiPizza;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    throw Exception('OpenFoodFacts down');
  }
}
