// E3 (improvement review 2026-10-18): the add sheet's search shows the
// user's own foods ("Von dir") above the product database, offline and
// before the network answers; one tap on "+" logs the newest portion. The
// store keeps 30 recents now, so the recents list shows five and the rest
// behind "Alle anzeigen".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/food_history_results.dart';

import '../support/harness.dart';

class _SilentAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async =>
      throw UnimplementedError();
}

class _SilentPhotos implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

class _Products implements ProductLookupService {
  _Products(this.hits);

  final List<ProductSearchResult> hits;
  int searches = 0;

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    searches++;
    return hits;
  }
}

class _Offline implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw Exception('offline');

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      throw Exception('SocketException: network unreachable');
}

MealAnalysisResult _meal(String name, {int kcal = 300, int grams = 200}) =>
    MealAnalysisResult(
      mealName: name,
      caloriesKcal: kcal,
      estimatedGrams: grams,
      kcalPer100G: kcal * 100 / grams,
      protein: '10 g',
      carbs: '20 g',
      fat: '5 g',
      confidence: 'manual',
      portionNotes: '',
      sourceLabel: 'manual',
    );

int _ids = 0;

LoggedMeal _log(MealAnalysisResult result, int day) => LoggedMeal(
  id: 'meal-${_ids++}',
  result: result,
  loggedAt: DateTime(2026, 10, day, 8),
);

FavoriteMeal _recent(MealAnalysisResult result, int day) => FavoriteMeal(
  id: FavoriteMeal.idFor(result),
  result: result,
  addedAt: DateTime(2026, 10, day, 9),
);

final List<ProductSearchResult> _dbHit = <ProductSearchResult>[
  ProductSearchResult(
    code: '4000000000001',
    title: 'Overnight Oats Schoko · Testmarke',
    kcalPer100G: 380,
    result: _meal('Overnight Oats Schoko', kcal: 380, grams: 100),
  ),
];

Future<BuildContext> _pump(
  WidgetTester tester, {
  required ProductLookupService products,
  List<FavoriteMeal> favorites = const <FavoriteMeal>[],
  List<LoggedMeal> diary = const <LoggedMeal>[],
  List<FitnessRecipe> recipes = const <FitnessRecipe>[],
  List<(MealAnalysisResult, MealSlot)>? added,
  double textScale = 1.0,
  Size? surfaceSize,
}) async {
  if (surfaceSize == null) pinPhoneViewport(tester);
  return pumpLocalizedContext(
    tester,
    AddMealSheet(
      slot: MealSlot.breakfast,
      analyzer: _SilentAnalyzer(),
      productService: products,
      photoInput: _SilentPhotos(),
      favorites: favorites,
      diaryMeals: () => diary,
      ownRecipes: () => recipes,
      onAdd: (result, slot) {
        added?.add((result, slot));
        return 'id-${added?.length ?? 0}';
      },
      onUpdateMeal: (_, __) {},
      onRemoveFavorite: (_) {},
      onToggleFavorite: (_) {},
    ),
    textScale: textScale,
    surfaceSize: surfaceSize,
    // Motion stays on: with duration 0 the sheet's AnimatedSize re-dirties
    // itself inside its own performLayout.
    reducedMotion: false,
    safeArea: false,
    settle: true,
  );
}

Finder _input() => find.byKey(const ValueKey('kcal-product-search-input'));
Finder _section() => find.byKey(const ValueKey('food-history-section'));
Finder _hit(int i) => find.byKey(ValueKey('food-history-hit-$i'));

/// The sheet's build fingerprint: only `_AddMealSheetState.build` creates
/// this Padding (see add_meal_sheet_keystroke_rebuild_test.dart).
Widget _sheetFrame(WidgetTester tester) =>
    tester.widget(find.byKey(const ValueKey('add-meal-slot-select')));

/// Lets the just-added check and the toast run out.
Future<void> _drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('„Von dir“ steht über den Datenbanktreffern, und ein Tipp auf '
      '„+“ trägt die neueste Portion ein', (tester) async {
    final newest = _meal('Overnight Oats', kcal: 450, grams: 300);
    final added = <(MealAnalysisResult, MealSlot)>[];
    final products = _Products(_dbHit);
    final l10n = (await _pump(
      tester,
      products: products,
      diary: [
        _log(_meal('Overnight Oats', kcal: 375, grams: 250), 1),
        _log(newest, 5),
        _log(_meal('Rührei'), 4),
      ],
      added: added,
    )).l10n;

    await tester.enterText(_input(), 'overnight');
    await tester.pump();

    // Local: there in the same frame, long before the 1 s product debounce.
    expect(_section(), findsOneWidget);
    expect(
      find.text(l10n.foodHistorySectionTitle.toUpperCase()),
      findsOneWidget,
    );
    expect(_hit(0), findsOneWidget);
    expect(
      _hit(1),
      findsNothing,
      reason: 'Rührei passt nicht, Oats nur einmal',
    );
    expect(products.searches, 0);

    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pumpAndSettle();
    final dbRow = find.byKey(const ValueKey('kcal-product-suggestion-0'));
    expect(dbRow, findsOneWidget);
    expect(
      tester.getTopLeft(_hit(0)).dy,
      lessThan(tester.getTopLeft(dbRow).dy),
      reason: 'eigene Treffer stehen über der Produktdatenbank',
    );
    expect(
      tester.getBottomLeft(_section()).dy,
      lessThanOrEqualTo(
        tester
            .getTopLeft(find.text(l10n.foodSectionSearchResults.toUpperCase()))
            .dy,
      ),
    );

    final quickAdd = find.byKey(const ValueKey('food-history-hit-quick-0'));
    await tester.ensureVisible(quickAdd);
    await tester.tap(quickAdd);
    await tester.pump();

    expect(added, hasLength(1));
    expect(
      identical(added.single.$1, newest),
      isTrue,
      reason: 'der neueste Eintrag gewinnt mit seiner Portion',
    );
    expect(added.single.$2, MealSlot.breakfast);
    await _drain(tester);
  });

  testWidgets('offline bleibt „Von dir“ da, auch wenn die Produktsuche '
      'scheitert', (tester) async {
    await _pump(
      tester,
      products: _Offline(),
      favorites: [_recent(_meal('Käsebrot', kcal: 280, grams: 100), 3)],
    );

    await tester.enterText(_input(), 'kaese');
    await tester.pump(const Duration(seconds: 25));
    await tester.pumpAndSettle();

    expect(_section(), findsOneWidget);
    expect(find.text('Käsebrot'), findsOneWidget);
  });

  testWidgets('weitere Zeichen bauen nur den Abschnitt neu, nie das Sheet '
      '(B3)', (tester) async {
    await _pump(
      tester,
      products: _Products(const <ProductSearchResult>[]),
      diary: [
        _log(_meal('Overnight Oats'), 1),
        _log(_meal('Oatmeal Bowl', kcal: 410), 2),
      ],
    );

    await tester.enterText(_input(), 'oat');
    await tester.pump();
    final frame = _sheetFrame(tester);
    expect(_hit(1), findsOneWidget, reason: 'beide passen auf „oat“');

    await tester.enterText(_input(), 'oatm');
    await tester.pump();
    expect(_hit(1), findsOneWidget, reason: 'der Debounce läuft noch');
    await tester.pump(FoodHistoryResults.debounce);
    expect(_hit(1), findsNothing);
    expect(find.text('Oatmeal Bowl'), findsOneWidget);
    expect(
      identical(_sheetFrame(tester), frame),
      isTrue,
      reason: 'die neue Trefferliste kam ohne Neubau des ganzen Sheets',
    );

    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pumpAndSettle();
  });

  testWidgets('eigene Rezepte stehen in „Von dir“', (tester) async {
    const chili = FitnessRecipe(
      slug: 'user_chili',
      title: 'Chili sin Carne',
      description: '',
      portion: '',
      ingredients: '',
      preparation: '',
      professionalHint: '',
      imageAsset: '',
      caloriesKcal: 520,
      proteinG: 28,
      carbsG: 60,
      fatG: 14,
      estimatedGrams: 450,
      categories: <String>[],
      userCreated: true,
    );
    await _pump(
      tester,
      products: _Products(const <ProductSearchResult>[]),
      recipes: const [chili],
    );

    await tester.enterText(_input(), 'chili');
    await tester.pump();
    expect(_hit(0), findsOneWidget);
    expect(find.text('Chili sin Carne'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pumpAndSettle();
  });

  testWidgets('mehr als drei eigene Treffer: drei sichtbar, der Rest hinter '
      '„Alle anzeigen“', (tester) async {
    final l10n = (await _pump(
      tester,
      products: _Products(const <ProductSearchResult>[]),
      diary: [
        for (var i = 0; i < 5; i++) _log(_meal('Reis $i', kcal: 200 + i), 1),
      ],
    )).l10n;

    await tester.enterText(_input(), 'reis');
    await tester.pump();
    expect(_hit(2), findsOneWidget);
    expect(_hit(3), findsNothing);

    final toggle = find.byKey(const ValueKey('food-history-toggle'));
    expect(find.text(l10n.foodHistoryShowAll(5)), findsOneWidget);
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump();
    expect(_hit(4), findsOneWidget);
    expect(find.text(l10n.foodHistoryShowLess), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pumpAndSettle();
  });

  testWidgets('die Zuletzt-Liste zeigt fünf, „Alle anzeigen“ zeigt alle', (
    tester,
  ) async {
    final recents = <FavoriteMeal>[
      for (var i = 0; i < 8; i++)
        _recent(_meal('Mahlzeit $i', kcal: 300 + i), 20 - i),
    ];
    final l10n = (await _pump(
      tester,
      products: _Products(const <ProductSearchResult>[]),
      favorites: recents,
    )).l10n;

    expect(find.byKey(const ValueKey('favorite-tile-4')), findsOneWidget);
    expect(find.byKey(const ValueKey('favorite-tile-5')), findsNothing);
    expect(find.text('Mahlzeit 5'), findsNothing);

    final toggle = find.byKey(const ValueKey('add-meal-recents-toggle'));
    expect(find.text(l10n.foodHistoryShowAll(8)), findsOneWidget);
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('favorite-tile-7')), findsOneWidget);

    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('favorite-tile-5')), findsNothing);
  });

  testWidgets('genau fünf Zuletzt-Einträge: kein Schalter', (tester) async {
    await _pump(
      tester,
      products: _Products(const <ProductSearchResult>[]),
      favorites: [
        for (var i = 0; i < kFoodHistoryVisibleRecents; i++)
          _recent(_meal('Mahlzeit $i', kcal: 300 + i), 20 - i),
      ],
    );
    expect(find.byKey(const ValueKey('add-meal-recents-toggle')), findsNothing);
  });

  testWidgets('doppelte Schrift bei 320 px: Abschnitt und Schalter laufen '
      'nicht über', (tester) async {
    final overflows = await collectOverflows(() async {
      await _pump(
        tester,
        products: _Products(const <ProductSearchResult>[]),
        favorites: [
          for (var i = 0; i < 8; i++)
            _recent(_meal('Haferflocken mit Beeren $i', kcal: 300 + i), 20 - i),
        ],
        textScale: 2.0,
        surfaceSize: const Size(320, 900),
      );
      final recentsToggle = find.byKey(
        const ValueKey('add-meal-recents-toggle'),
      );
      await tester.ensureVisible(recentsToggle);
      await tester.pumpAndSettle();

      await tester.enterText(_input(), 'haferflocken');
      await tester.pump();
      final toggle = find.byKey(const ValueKey('food-history-toggle'));
      expect(toggle, findsOneWidget);
      await tester.ensureVisible(toggle);
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pumpAndSettle();
    });
    expect(overflows, isEmpty, reason: describeOverflows(overflows));
  });

  testWidgets('der Schalter ist für Screenreader ein Knopf mit Zustand', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final l10n = (await _pump(
      tester,
      products: _Products(const <ProductSearchResult>[]),
      favorites: [
        for (var i = 0; i < 6; i++)
          _recent(_meal('Mahlzeit $i', kcal: 300 + i), 20 - i),
      ],
    )).l10n;

    final toggle = find.descendant(
      of: find.byKey(const ValueKey('add-meal-recents-toggle')),
      matching: find.byType(InkWell),
    );
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(toggle),
      matchesSemantics(
        label: l10n.foodHistoryShowAll(6),
        isButton: true,
        hasExpandedState: true,
        isExpanded: false,
        hasTapAction: true,
        isFocusable: true,
        hasFocusAction: true,
      ),
    );
    handle.dispose();
  });
}
