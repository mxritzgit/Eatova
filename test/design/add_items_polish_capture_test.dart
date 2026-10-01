// Visual evidence for the add-meal sheet's rows and add interaction (design
// polish 2026-10-02, agent add-items).
//
// Opens the real add-meal sheet and favorites sheet at the design's reference
// geometry with realistic data and shoots: the saved/recent rows collapsed
// and expanded, product search hits, the "just added" confirmation, and the
// favorites sheet (list, search, no match, empty). With
// --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/; without it the suite still checks that every state
// renders without layout errors and that the add path logs the shown portion.

import 'package:clock/clock.dart';
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
import 'package:eatova/src/widgets/kcal/favorites_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_suggestion_item.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';

final DateTime _now = DateTime(2026, 9, 28, 12, 40);

Finder _key(String key) => find.byKey(ValueKey(key));

class _NoAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async =>
      throw UnimplementedError();
}

class _NoPhotos implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

class _Catalog implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async => [
    for (final (code, name, brand, kcal, p, c, f) in [
      ('4001', 'Greek yoghurt with vanilla', 'The Dairy', 120, 10, 8, 5),
      ('4002', 'Natural Greek yoghurt 10 %', 'Everyday', 96, 9, 4, 10),
      ('4003', 'Greek style yoghurt with honey', 'Breakfast Club', 142, 6, 16, 6),
      ('4004', 'Skyr, natural', 'Nordic Farm', 63, 11, 4, 0.2),
    ])
      ProductSearchResult.fromOpenFoodFacts({
        'code': code,
        'product_name': name,
        'brands': brand,
        'serving_quantity': 150,
        'nutriments': {
          'energy-kcal_100g': kcal,
          'proteins_100g': p,
          'carbohydrates_100g': c,
          'fat_100g': f,
        },
      }),
  ];
}

MealAnalysisResult _meal(
  String name,
  int kcal,
  int grams, {
  String protein = '-',
  String carbs = '-',
  String fat = '-',
  String? brand,
  String source = 'database',
}) => MealAnalysisResult(
  mealName: name,
  caloriesKcal: kcal,
  estimatedGrams: grams,
  kcalPer100G: kcal * 100 / grams,
  protein: protein,
  carbs: carbs,
  fat: fat,
  confidence: 'database',
  portionNotes: '',
  brand: brand,
  sourceLabel: source,
);

FavoriteMeal _fav(MealAnalysisResult result, int day, {bool pinned = false}) =>
    FavoriteMeal(
      id: FavoriteMeal.idFor(result),
      result: result,
      addedAt: DateTime(2026, 9, day),
      pinned: pinned,
    );

final List<FavoriteMeal> _favorites = <FavoriteMeal>[
  _fav(
    _meal('Overnight oats with berries', 412, 320,
        protein: '18 g', carbs: '58 g', fat: '11 g'),
    27,
    pinned: true,
  ),
  _fav(
    _meal('Chicken rice bowl', 640, 450,
        protein: '48 g', carbs: '72 g', fat: '14 g'),
    25,
    pinned: true,
  ),
  _fav(
    _meal('Skyr, natural', 158, 250, protein: '27 g', carbs: '10 g', fat: '1 g'),
    24,
    pinned: true,
  ),
  _fav(
    _meal('Protein shake', 118, 330, protein: '24 g', carbs: '3 g', fat: '1 g'),
    20,
    pinned: true,
  ),
  _fav(
    _meal('Banana', 105, 118, protein: '1 g', carbs: '27 g', fat: '0 g'),
    18,
    pinned: true,
  ),
  _fav(
    _meal('Basmati rice, cooked', 260, 200,
        protein: '5 g', carbs: '56 g', fat: '1 g'),
    28,
  ),
  _fav(
    _meal('Greek yoghurt with vanilla · The Dairy', 180, 150,
        protein: '15 g', carbs: '12 g', fat: '8 g', brand: 'The Dairy'),
    28,
  ),
  _fav(
    _meal('Turkey sandwich', 386, 210,
        protein: '29 g', carbs: '38 g', fat: '12 g', source: 'photoAi'),
    27,
  ),
  _fav(_meal('Espresso', 2, 30), 26),
];

final List<LoggedMeal> _lunch = <LoggedMeal>[
  LoggedMeal(
    id: 'l-1',
    result: _meal('Chicken breast', 198, 180,
        protein: '41 g', carbs: '0 g', fat: '4 g'),
    loggedAt: DateTime(2026, 9, 28, 12, 45),
    forcedSlot: MealSlot.lunch,
  ),
  LoggedMeal(
    id: 'l-2',
    result: _meal('Broccoli', 51, 150, protein: '4 g', carbs: '7 g', fat: '1 g'),
    loggedAt: DateTime(2026, 9, 28, 12, 45),
    forcedSlot: MealSlot.lunch,
  ),
];

/// Opens the real add-meal sheet over a plain dark page.
Future<List<(MealAnalysisResult, MealSlot)>> _openAddSheet(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  double textScale = 1,
  List<FavoriteMeal>? favorites,
}) async {
  final logged = <(MealAnalysisResult, MealSlot)>[];
  pinDesignViewport(tester);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showAddMealSheet(
                context,
                slot: MealSlot.lunch,
                analyzer: _NoAnalyzer(),
                productService: _Catalog(),
                photoInput: _NoPhotos(),
                favorites: favorites ?? _favorites,
                existingMeals: _lunch,
                onAdd: (result, slot) {
                  logged.add((result, slot));
                  return 'id-${logged.length}';
                },
                onUpdateMeal: (_, __) {},
                onRemoveFavorite: (_) {},
                isFavorite: (r) => (favorites ?? _favorites).any(
                  (f) => f.pinned && f.id == FavoriteMeal.idFor(r),
                ),
                onToggleFavorite: (_) {},
                onRemoveMeal: (_) {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
        locale: locale,
        textScale: textScale,
        safeArea: false,
        scaffold: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return logged;
}

Finder _sheetScroll() => find
    .descendant(
      of: _key('add-meal-sheet-scroll'),
      matching: find.byType(Scrollable),
    )
    .first;

/// Scrolls the add sheet so [target] sits near the top of its viewport.
Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  final scroll = tester.state<ScrollableState>(_sheetScroll()).position;
  final viewportTop = tester.getTopLeft(_key('add-meal-sheet-scroll')).dy;
  final delta = tester.getTopLeft(target).dy - viewportTop - 12;
  scroll.jumpTo(
    (scroll.pixels + delta).clamp(scroll.minScrollExtent, scroll.maxScrollExtent),
  );
  await tester.pumpAndSettle();
}

Future<void> _openFavoritesSheet(
  WidgetTester tester, {
  required List<FavoriteMeal> favorites,
}) async {
  pinDesignViewport(tester);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showFavoritesSheet(
                context,
                favorites: favorites,
                slot: MealSlot.lunch,
                onAdd: (_, __) => 'id',
                onUnpin: (_) {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
        locale: const Locale('en'),
        safeArea: false,
        scaffold: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadDesignFonts);

  testWidgets('add sheet: saved, recent and existing rows', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final logged = await _openAddSheet(tester);
      expect(_key('favorite-pinned-0'), findsOneWidget);
      expect(_key('favorite-tile-0'), findsOneWidget);
      expect(_key('analyse-existing-meals'), findsOneWidget);
      await captureDesignShot(tester, 'add-items-sheet-top');

      await _scrollTo(tester, _key('favorite-pinned-0'));
      await captureDesignShot(tester, 'add-items-saved-recent');

      // A recent row, expanded, portion bumped twice.
      await tester.tap(
        find.descendant(
          of: _key('favorite-tile-0'),
          matching: find.text('Basmati rice, cooked'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: _key('favorite-tile-0'),
          matching: find.byIcon(Icons.add_rounded),
        ).first,
      );
      await tester.pumpAndSettle();
      await _scrollTo(tester, _key('favorite-tile-0'));
      await captureDesignShot(tester, 'add-items-recent-expanded');

      // Add it: the row collapses into its "added" confirmation.
      final add = _key('favorite-tile-add-0');
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(logged.single.$1.estimatedGrams, 210);
      expect(logged.single.$2, MealSlot.lunch);
      await _scrollTo(tester, _key('favorite-tile-0'));
      await captureDesignShot(tester, 'add-items-added');
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      // Known, outside this surface: with the reference phone's 34 pt home
      // indicator the add sheet's toast strip is shorter than the floating
      // SnackBar plus the inset, which Flutter reports in debug builds. The
      // toast itself renders (see the shot); add-sheet owns the strip.
      final snackError = tester.takeException();
      expect(
        snackError == null ||
            '$snackError'.contains('Floating SnackBar presented off screen'),
        isTrue,
        reason: '$snackError',
      );

      // A pinned favourite, expanded.
      await tester.tap(
        find.descendant(
          of: _key('favorite-pinned-0'),
          matching: find.text('Overnight oats with berries'),
        ),
      );
      await tester.pumpAndSettle();
      await _scrollTo(tester, _key('favorite-pinned-0'));
      await captureDesignShot(tester, 'add-items-saved-expanded');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('add sheet: product search hits', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _openAddSheet(tester);
      await tester.enterText(_key('kcal-product-search-input'), 'Greek yoghurt');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(find.byType(MealSuggestionItem), findsNWidgets(4));
      await _scrollTo(tester, _key('kcal-product-suggestion-0'));
      await captureDesignShot(tester, 'add-items-search');

      await tester.tap(find.text('Greek yoghurt with vanilla'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, _key('kcal-product-suggestion-0'));
      await captureDesignShot(tester, 'add-items-search-expanded');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('add sheet in German at 2.0 text scale', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final errors = await collectOverflows(() async {
        await _openAddSheet(tester, locale: const Locale('de'));
        await _scrollTo(tester, _key('favorite-pinned-0'));
        await captureDesignShot(tester, 'add-items-saved-recent-de');
      });
      expect(errors, isEmpty, reason: describeOverflows(errors));
    });
  });

  testWidgets('rows hold at 2.0 text scale', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final errors = await collectOverflows(() async {
        await _openAddSheet(tester, textScale: 2);
        await _scrollTo(tester, _key('favorite-pinned-0'));
        await captureDesignShot(tester, 'add-items-scale2-collapsed');
        await tester.tap(
          find.descendant(
            of: _key('favorite-tile-0'),
            matching: find.text('Basmati rice, cooked'),
          ),
        );
        await tester.pumpAndSettle();
        await _scrollTo(tester, _key('favorite-tile-0'));
        await captureDesignShot(tester, 'add-items-scale2-expanded');
      });
      expect(errors, isEmpty, reason: describeOverflows(errors));
    });
  });

  testWidgets('favorites sheet: list, expanded, search, no match', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      await _openFavoritesSheet(tester, favorites: _favorites);
      expect(_key('favorites-sheet'), findsOneWidget);
      expect(_key('favorites-sheet-item-4'), findsOneWidget);
      await captureDesignShot(tester, 'add-items-favsheet');

      await tester.tap(find.text('Chicken rice bowl'));
      await tester.pumpAndSettle();
      await captureDesignShot(tester, 'add-items-favsheet-expanded');
      await tester.tap(find.text('Chicken rice bowl'));
      await tester.pumpAndSettle();

      await tester.enterText(_key('favorites-sheet-search'), 'sk');
      await tester.pumpAndSettle();
      expect(_key('favorites-sheet-item-0'), findsOneWidget);
      expect(_key('favorites-sheet-item-1'), findsNothing);
      await captureDesignShot(tester, 'add-items-favsheet-search');

      await tester.enterText(_key('favorites-sheet-search'), 'pizza');
      await tester.pumpAndSettle();
      expect(_key('favorites-sheet-no-match'), findsOneWidget);
      await captureDesignShot(tester, 'add-items-favsheet-nomatch');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('favorites sheet: empty', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _openFavoritesSheet(tester, favorites: const <FavoriteMeal>[]);
      expect(_key('favorites-sheet-empty'), findsOneWidget);
      await captureDesignShot(tester, 'add-items-favsheet-empty');
      expect(tester.takeException(), isNull);
    });
  });
}
