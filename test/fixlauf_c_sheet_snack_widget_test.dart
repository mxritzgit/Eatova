// Fix run for review 2026-08-27, F3-02 (widget level, no app shell): the
// add-meal sheet hosts its own toast surface above the modal scrim. Sheet
// toasts AND context-free toasts fired from below the sheet (the store's
// undo) land inside it and stay tappable; the host must not swallow taps on
// the sheet content, and it steps aside once the sheet closes.

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
import 'package:eatova/src/widgets/common/app_snack.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';

import 'support/harness.dart';

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

const MealAnalysisResult _skyr = MealAnalysisResult(
  mealName: 'Skyr',
  caloriesKcal: 90,
  estimatedGrams: 150,
  kcalPer100G: 60,
  protein: '16 g',
  carbs: '6 g',
  fat: '0 g',
  confidence: 'Datenbank',
  portionNotes: '',
);

bool _hasFocus(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).focusNode!.hasFocus;

/// Home page stand-in: opens the sheet and can fire a context-free toast the
/// way the store does (home context, undo action).
late BuildContext _homeContext;
int _undoCalls = 0;

Future<void> _pumpHome(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  _undoCalls = 0;

  await pumpLocalized(
    tester,
    Builder(
      builder: (context) {
        _homeContext = context;
        return Center(
          child: TextButton(
            key: const ValueKey('open'),
            onPressed: () => showAddMealSheet(
              context,
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
                // Pinned -> "All (1)" opens the favorites sheet.
                FavoriteMeal(
                  id: FavoriteMeal.idFor(_skyr),
                  result: _skyr,
                  addedAt: DateTime(2026, 8, 21),
                  pinned: true,
                ),
              ],
              onAdd: (_, __) => 'id-1',
              onUpdateMeal: (_, __) {},
              onRemoveFavorite: (_) {},
              onRemoveMeal: (_) => showAppSnack(
                _homeContext,
                'Mahlzeit gelöscht',
                tone: SnackTone.error,
                action: SnackBarAction(
                  label: 'Rückgängig',
                  onPressed: () => _undoCalls++,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        );
      },
    ),
    // Motion on: the favorites list sits in an AnimatedSize, and a zero
    // duration makes it re-dirty itself during layout.
    reducedMotion: false,
  );
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('add-meal-sheet')), findsOneWidget);
}

Future<void> _addApfel(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('favorite-tile-0')));
  await tester.pumpAndSettle();
  final add = find.byKey(const ValueKey('favorite-tile-add-0'));
  await tester.ensureVisible(add);
  await tester.tap(add);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(SnackHost.debugResetHosts);

  testWidgets('der Erfolgs-Toast des Sheets liegt über dem Scrim',
      (tester) async {
    await _pumpHome(tester);
    await _addApfel(tester);

    final toast = find.text('52 kcal zu Snacks hinzugefügt.');
    expect(toast, findsOneWidget);
    expect(toast.hitTestable(), findsOneWidget);
    // Inside the sheet's ground, not in the home scaffold.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('add-meal-sheet')),
        matching: toast,
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(of: toast, matching: find.byType(SnackHost)),
      findsOneWidget,
    );
  });

  testWidgets('ein kontextfreier Store-Toast (Undo) landet im Sheet und '
      'sein Knopf funktioniert', (tester) async {
    await _pumpHome(tester);
    await _addApfel(tester);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // The mirrored row's X calls onRemoveMeal, which toasts from the HOME
    // context like HomeStore does.
    await tester.tap(find.byKey(const ValueKey('analyse-existing-remove-id-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final undo = find.text('Rückgängig');
    expect(undo.hitTestable(), findsOneWidget);
    expect(find.text('Mahlzeit gelöscht').hitTestable(), findsOneWidget);
    await tester.tap(undo);
    await tester.pumpAndSettle();
    expect(_undoCalls, 1);
  });

  testWidgets('der Host schluckt keine Taps auf den Sheet-Inhalt',
      (tester) async {
    await _pumpHome(tester);

    // Tapping a tile expands it — through the transparent host overlay.
    await tester.tap(find.byKey(const ValueKey('favorite-tile-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('favorite-tile-add-0')), findsOneWidget);
    // And the close button works.
    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-meal-sheet')), findsNothing);
  });

  testWidgets('der Toast liegt UNTER der letzten Zeile, die bleibt tappbar',
      (tester) async {
    await _pumpHome(tester);
    await _addApfel(tester);

    final toast = tester.getRect(find.byType(SnackBar));
    final tile = tester.getRect(find.byKey(const ValueKey('favorite-tile-0')));
    expect(toast.top, greaterThanOrEqualTo(tile.bottom - 0.5),
        reason: 'der Toast deckt die letzte Zeile');
    // Inside the sheet's ground, not below it.
    final sheet = tester.getRect(find.byKey(const ValueKey('add-meal-sheet')));
    expect(toast.bottom, lessThanOrEqualTo(sheet.bottom + 0.5));

    // While the toast shows, the row still takes the tap (expands again).
    await tester.tap(find.byKey(const ValueKey('favorite-tile-0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('favorite-tile-add-0')), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('Suchfelder bekommen per TAP durch den Host den Fokus',
      (tester) async {
    await _pumpHome(tester);
    // autofocus set it; drop it so the tap has to earn it back.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(_hasFocus(tester, 'kcal-product-search-input'), isFalse);

    await tester.tap(find.byKey(const ValueKey('kcal-product-search-input')));
    await tester.pump();
    expect(_hasFocus(tester, 'kcal-product-search-input'), isTrue);

    // Same while a toast is up.
    await _addApfel(tester);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('kcal-product-search-input')));
    await tester.pump();
    expect(_hasFocus(tester, 'kcal-product-search-input'), isTrue);
    expect(find.byType(SnackBar), findsOneWidget);

    // Favorites sheet on top: its own host, its own search field.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    final alle = find.byKey(const ValueKey('add-meal-favorites-all'));
    await tester.ensureVisible(alle);
    await tester.tap(alle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('favorites-sheet')), findsOneWidget);
    expect(_hasFocus(tester, 'favorites-sheet-search'), isFalse);
    await tester.tap(find.byKey(const ValueKey('favorites-sheet-search')));
    await tester.pump();
    expect(_hasFocus(tester, 'favorites-sheet-search'), isTrue);
  });

  testWidgets('nach dem Schließen gehen Toasts wieder an den Root-Messenger',
      (tester) async {
    await _pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await tester.pump();
    // Mid exit animation: the sheet is still in the tree, but popped.
    showAppSnack(_homeContext, 'Nach dem Sheet');
    await tester.pump();
    await tester.pumpAndSettle();

    final toast = find.text('Nach dem Sheet');
    expect(toast, findsOneWidget);
    expect(find.ancestor(of: toast, matching: find.byType(SnackHost)),
        findsNothing);
    expect(toast.hitTestable(), findsOneWidget);
  });
}
