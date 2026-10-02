// Visual evidence for the add-meal sheet polish (design polish 2026-10-02).
//
// Mounts the real home page on the Food design scenario, seeds favorites and
// recents, and opens the add sheet the two ways the Food tab offers: the
// bottom "Search food or meals" capsule and a slot's "+ Add to …" row. Every
// sheet state gets a shot: idle with favorites/recents, product results,
// loading, the slow hint, nothing found, unreachable, no history, German and
// 2.0x text. Three other sheets that share `design/sheets.dart` (favorites
// sheet, manual entry, date picker) are shot as regression evidence.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/; without it every state still checks its key widgets
// and that nothing overflowed.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';

import '../flows/flow_test_helpers.dart' show storeOf;
import '../support/design_capture.dart';
import '../support/food_design_fixture.dart';
import '../support/harness.dart';

enum _Mode { results, empty, hang, error }

/// Search stub: answers by [mode], never touches the network.
class _Products implements ProductLookupService {
  _Mode mode = _Mode.results;
  final Completer<List<ProductSearchResult>> _never =
      Completer<List<ProductSearchResult>>();

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    switch (mode) {
      case _Mode.results:
        return _products;
      case _Mode.empty:
        return const <ProductSearchResult>[];
      case _Mode.hang:
        return _never.future;
      case _Mode.error:
        throw Exception('socket closed');
    }
  }
}

MealAnalysisResult _meal(
  String name,
  int grams,
  int kcal, {
  required int p,
  required int c,
  required int f,
  String? brand,
  String? barcode,
}) => MealAnalysisResult(
  mealName: name,
  caloriesKcal: kcal,
  estimatedGrams: grams,
  kcalPer100G: kcal * 100 / grams,
  protein: '$p g',
  carbs: '$c g',
  fat: '$f g',
  confidence: 'database',
  portionNotes: '',
  sourceLabel: 'OpenFoodFacts',
  brand: brand,
  barcode: barcode,
);

final List<ProductSearchResult> _products = <ProductSearchResult>[
  for (final (code, name, brand, kcal100) in <(String, String, String, int)>[
    ('4025500168021', 'Skyr natural', 'Arla', 63),
    ('4056489012345', 'Skyr vanilla', 'Milbona', 78),
    ('4002971123456', 'Icelandic skyr, strawberry', 'Siggi\'s', 92),
    ('4008452012345', 'Skyr drink, blueberry', 'Ehrmann', 71),
  ])
    ProductSearchResult(
      code: code,
      title: '$name · $brand',
      subtitle: '$brand · 450 g · $kcal100 kcal / 100 g',
      kcalPer100G: kcal100.toDouble(),
      result: _meal(
        name,
        150,
        (kcal100 * 1.5).round(),
        p: 16,
        c: 6,
        f: 0,
        brand: brand,
        barcode: code,
      ),
    ),
];

List<FavoriteMeal> _favorites() {
  FavoriteMeal fav(MealAnalysisResult r, int minutesAgo, {bool pinned = false}) =>
      FavoriteMeal(
        id: FavoriteMeal.idFor(r),
        result: r,
        addedAt: foodDesignNow.subtract(Duration(minutes: minutesAgo)),
        pinned: pinned,
      );
  return <FavoriteMeal>[
    fav(_meal('Skyr bowl with berries', 320, 310, p: 32, c: 30, f: 5), 30,
        pinned: true),
    fav(_meal('Overnight oats', 280, 420, p: 18, c: 58, f: 12), 300,
        pinned: true),
    fav(_meal('Chicken rice bowl', 450, 620, p: 48, c: 72, f: 14), 900,
        pinned: true),
    fav(_meal('Protein bar', 60, 220, p: 20, c: 22, f: 7), 1300, pinned: true),
    fav(_meal('Banana', 118, 105, p: 1, c: 27, f: 0), 130),
    fav(_meal('Whey shake', 30, 118, p: 24, c: 4, f: 2), 140),
    fav(_meal('Basmati rice, cooked', 200, 260, p: 5, c: 56, f: 1), 350),
    fav(_meal('Greek yogurt 2%', 170, 124, p: 17, c: 7, f: 3), 1500),
    fav(_meal('Wholegrain toast', 45, 112, p: 4, c: 19, f: 2), 1600),
  ];
}

Future<_Products> _pumpFood(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  double textScale = 1.0,
  bool withFavorites = true,
}) async {
  final products = _Products();
  pinDesignViewport(tester);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        EatovaHomePage(productService: products),
        locale: locale,
        textScale: textScale,
        safeArea: false,
        scaffold: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
  storeOf(tester)
    ..profile = foodDesignProfile
    ..loggedMeals = foodDesignMeals()
    ..favorites = withFavorites ? _favorites() : const <FavoriteMeal>[];
  await tester.tap(find.byKey(const ValueKey('nav-Food')));
  await tester.pumpAndSettle();
  return products;
}

Future<void> _openFromCapsule(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('food-search')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('add-meal-sheet')), findsOneWidget);
}

Future<void> _openFromSlot(WidgetTester tester, String slot) async {
  final add = find.byKey(ValueKey('food-slot-add-$slot'));
  await tester.ensureVisible(add);
  await tester.pumpAndSettle();
  await tester.tap(add);
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('add-meal-sheet')), findsOneWidget);
}

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(
    find.byKey(const ValueKey('kcal-product-search-input')),
    query,
  );
  await tester.tap(find.byKey(const ValueKey('kcal-product-search-button')));
  await tester.pump();
}

Finder _sheetScroll() => find.descendant(
  of: find.byKey(const ValueKey('add-meal-sheet-scroll')),
  matching: find.byType(Scrollable),
);

/// Shoots [name] and checks the frame rendered without a layout error.
Future<void> _shot(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull);
  await captureDesignShot(tester, name);
}

void main() {
  setUpAll(loadDesignFonts);

  Future<void> run(Future<void> Function() body) =>
      withClock(Clock.fixed(foodDesignNow), body);

  group('add sheet', () {
    testWidgets('from the capsule: favorites and recents', (tester) async {
      await run(() async {
        await _pumpFood(tester);
        await _openFromCapsule(tester);
        expect(find.byKey(const ValueKey('kcal-product-search-card')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('add-meal-favorites-all')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('favorite-pinned-0')), findsOneWidget);
        await _shot(tester, 'add-sheet-capsule');
        await scrollDesignTabBy(tester, 600, scrollable: _sheetScroll());
        expect(find.byKey(const ValueKey('favorite-tile-4')), findsOneWidget);
        await _shot(tester, 'add-sheet-capsule-scrolled');
      });
    });

    testWidgets('from "+ Add to Breakfast"', (tester) async {
      await run(() async {
        await _pumpFood(tester);
        await _openFromSlot(tester, 'breakfast');
        expect(find.byKey(const ValueKey('analyse-existing-meals')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('manual-entry-button')),
            findsOneWidget);
        await _shot(tester, 'add-sheet-breakfast');
        await scrollDesignTabBy(tester, 700, scrollable: _sheetScroll());
        await _shot(tester, 'add-sheet-breakfast-scrolled');
      });
    });

    testWidgets('after adding: the toast above the home indicator', (
      tester,
    ) async {
      await run(() async {
        await _pumpFood(tester);
        await _openFromCapsule(tester);
        final row = find.byKey(const ValueKey('favorite-tile-0'));
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        await tester.tap(row);
        await tester.pumpAndSettle();
        await _shot(tester, 'add-sheet-recent-expanded');
        final add = find.byKey(const ValueKey('favorite-tile-add-0'));
        await tester.ensureVisible(add);
        await tester.pumpAndSettle();
        await tester.tap(add);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(SnackBar), findsOneWidget);
        await _shot(tester, 'add-sheet-added-toast');
        await tester.pumpAndSettle(const Duration(seconds: 5));
      });
    });

    testWidgets('German, densest state', (tester) async {
      await run(() async {
        await _pumpFood(tester, locale: const Locale('de'));
        await _openFromSlot(tester, 'breakfast');
        await _shot(tester, 'add-sheet-breakfast-de');
      });
    });

    testWidgets('text scale 2.0', (tester) async {
      await run(() async {
        await _pumpFood(tester, textScale: 2.0);
        await _openFromSlot(tester, 'breakfast');
        await _shot(tester, 'add-sheet-breakfast-x2');
        await scrollDesignTabBy(tester, 900, scrollable: _sheetScroll());
        await _shot(tester, 'add-sheet-breakfast-x2-scrolled');
        await _search(tester, 'skyr');
        await tester.pumpAndSettle();
        await _shot(tester, 'add-sheet-results-x2');
      });
    });

    testWidgets('product results', (tester) async {
      await run(() async {
        await _pumpFood(tester);
        await _openFromCapsule(tester);
        await _search(tester, 'skyr');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('kcal-product-suggestion-0')),
            findsOneWidget);
        await _shot(tester, 'add-sheet-results');
        await tester.tap(find.byKey(const ValueKey('kcal-product-suggestion-0')));
        await tester.pumpAndSettle();
        await _shot(tester, 'add-sheet-results-expanded');
      });
    });

    testWidgets('loading, then the slow hint', (tester) async {
      await run(() async {
        final products = await _pumpFood(tester);
        products.mode = _Mode.hang;
        await _openFromCapsule(tester);
        await _search(tester, 'skyr');
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const ValueKey('product-search-spinner')),
            findsOneWidget);
        await _shot(tester, 'add-sheet-loading');
        await tester.pump(const Duration(seconds: 7));
        expect(find.byKey(const ValueKey('product-search-slow-hint')),
            findsOneWidget);
        await _shot(tester, 'add-sheet-slow');
        // Let the 18 s budget run out so no timer outlives the test.
        await tester.pump(const Duration(seconds: 12));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('manual-entry-cta')), findsOneWidget);
        await _shot(tester, 'add-sheet-timeout');
      });
    });

    testWidgets('nothing found', (tester) async {
      await run(() async {
        final products = await _pumpFood(tester);
        products.mode = _Mode.empty;
        await _openFromCapsule(tester);
        await _search(tester, 'quarkkeulchen');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('manual-entry-cta')), findsOneWidget);
        await _shot(tester, 'add-sheet-empty-results');
      });
    });

    testWidgets('search unreachable', (tester) async {
      await run(() async {
        final products = await _pumpFood(tester);
        products.mode = _Mode.error;
        await _openFromCapsule(tester);
        await _search(tester, 'skyr');
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        // The error state rendered, and it offers no manual-entry CTA.
        expect(find.text(enL10n.foodSearchUnreachableHint), findsOneWidget);
        expect(find.byKey(const ValueKey('manual-entry-cta')), findsNothing);
        await _shot(tester, 'add-sheet-error');
      });
    });

    testWidgets('no history yet', (tester) async {
      await run(() async {
        await _pumpFood(tester, withFavorites: false);
        await _openFromSlot(tester, 'dinner');
        await _shot(tester, 'add-sheet-no-history');
      });
    });
  });

  group('other sheets on design/sheets.dart', () {
    testWidgets('favorites sheet (showEatovaSheet + FieldCapsule)', (
      tester,
    ) async {
      await run(() async {
        await _pumpFood(tester);
        await _openFromCapsule(tester);
        await tester.tap(find.byKey(const ValueKey('add-meal-favorites-all')));
        await tester.pumpAndSettle();
        await _shot(tester, 'other-favorites-sheet');
      });
    });

    testWidgets('manual entry sheet (FieldCapsule)', (tester) async {
      await run(() async {
        await _pumpFood(tester);
        await _openFromSlot(tester, 'breakfast');
        await tester.tap(find.byKey(const ValueKey('manual-entry-button')));
        await tester.pumpAndSettle();
        await _shot(tester, 'other-manual-sheet');
      });
    });

    testWidgets('date picker sheet (showEatovaSheet)', (tester) async {
      await run(() async {
        await _pumpFood(tester);
        await tester.tap(find.byKey(const ValueKey('food-date-calendar')));
        await tester.pumpAndSettle();
        await _shot(tester, 'other-date-sheet');
      });
    });
  });
}
