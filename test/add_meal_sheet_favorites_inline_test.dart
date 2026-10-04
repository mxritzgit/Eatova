// Favorites section of the add-meal sheet (feature 2026-08-27): only the top
// three pinned by recency sit inline, the "All (N)" button opens the favorites
// sheet, and unpins/adds made there flow back into the add sheet.

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
import 'support/meal_slot_picker.dart';

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

class _FotoProduktdienst implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async => [
    ProductSearchResult.fromOpenFoodFacts(<String, dynamic>{
      'code': '4000540000108',
      'product_name': 'Proteinriegel',
      'nutrition_data_per': '100g',
      'serving_quantity': 60,
      'nutriments': <String, dynamic>{'energy-kcal_100g': 353},
      'image_front_small_url': _riegelFoto,
    }),
  ];
}

const _riegelFoto =
    'https://images.openfoodfacts.org/images/products/400/054/000/0108/front_de.273.200.jpg';

class _StummeFotoquelle implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

MealAnalysisResult _mahlzeit(String name, {int kcal = 250}) {
  return MealAnalysisResult(
    mealName: name,
    caloriesKcal: kcal,
    estimatedGrams: 100,
    kcalPer100G: kcal.toDouble(),
    protein: '-',
    carbs: '-',
    fat: '-',
    confidence: 'Datenbank',
    portionNotes: '',
  );
}

FavoriteMeal _favorit(String name, {required int tag, bool gepinnt = true}) {
  final result = _mahlzeit(name);
  return FavoriteMeal(
    id: FavoriteMeal.idFor(result),
    result: result,
    addedAt: DateTime(2026, 8, tag),
    pinned: gepinnt,
  );
}

/// Five pinned, deliberately NOT in recency order in the list: the sheet
/// must sort, not trust the incoming order.
final List<FavoriteMeal> _fuenfGepinnt = <FavoriteMeal>[
  _favorit('Haferbrei', tag: 3),
  _favorit('Skyr', tag: 20),
  _favorit('Banane', tag: 1),
  _favorit('Reis', tag: 12),
  _favorit('Lachs', tag: 7),
];

Future<void> _pumpe(
  WidgetTester tester, {
  required List<FavoriteMeal> favoriten,
  String Function(MealAnalysisResult, MealSlot)? onAdd,
  ValueChanged<MealAnalysisResult>? onToggleFavorite,
  Locale locale = const Locale('de'),
  ProductLookupService? productService,
}) async {
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    AddMealSheet(
      slot: MealSlot.snack,
      analyzer: _StummerAnalyzer(),
      productService: productService ?? _StummerProduktdienst(),
      photoInput: _StummeFotoquelle(),
      favorites: favoriten,
      onAdd: onAdd ?? (_, __) => 'id-1',
      onUpdateMeal: (_, __) {},
      onRemoveFavorite: (_) {},
      onToggleFavorite: onToggleFavorite,
    ),
    locale: locale,
    // Motion stays on: with duration 0 the sheet's AnimatedSize re-dirties
    // itself inside its own performLayout.
    reducedMotion: false,
    settle: true,
  );
}

Finder _alleKnopf() => find.byKey(const ValueKey('add-meal-favorites-all'));

Finder _favoritenSheet() => find.byKey(const ValueKey('favorites-sheet'));

String _nameInKachel(WidgetTester tester, Finder kachel) {
  final texte = tester
      .widgetList<Text>(find.descendant(of: kachel, matching: find.byType(Text)))
      .map((t) => t.data)
      .whereType<String>()
      .toList();
  return texte.first;
}

Future<void> _oeffneFavoritenSheet(WidgetTester tester) async {
  await tester.ensureVisible(_alleKnopf());
  await tester.tap(_alleKnopf());
  await tester.pumpAndSettle();
  expect(_favoritenSheet(), findsOneWidget);
}

Future<void> _schliesseFavoritenSheet(WidgetTester tester) async {
  Navigator.of(tester.element(_favoritenSheet())).pop();
  await tester.pumpAndSettle();
  expect(_favoritenSheet(), findsNothing);
}

void main() {
  // Since 2026-10-03 the add sheet shows no inline top 3: one "Favorites"
  // row with the count opens the favorites menu.
  testWidgets('gepinnte Favoriten stehen nicht inline, eine Zeile führt hin',
      (tester) async {
    await _pumpe(tester, favoriten: _fuenfGepinnt);

    expect(find.byKey(const ValueKey('favorite-pinned-0')), findsNothing);
    for (final name in ['Skyr', 'Reis', 'Lachs', 'Banane', 'Haferbrei']) {
      expect(find.text(name), findsNothing, reason: name);
    }
    expect(_alleKnopf(), findsOneWidget);
    expect(
      find.descendant(of: _alleKnopf(), matching: find.text('Favoriten')),
      findsOneWidget,
    );
  });

  testWidgets('englisch heißt sie „Favorites · 5 saved"', (tester) async {
    await _pumpe(
      tester,
      favoriten: _fuenfGepinnt,
      locale: const Locale('en'),
    );
    expect(
      find.descendant(of: _alleKnopf(), matching: find.text('Favorites')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _alleKnopf(), matching: find.text('5 saved')),
      findsOneWidget,
    );
  });

  testWidgets('ohne gepinnte Favoriten gibt es keine Zeile, Recents bleiben',
      (tester) async {
    await _pumpe(tester, favoriten: <FavoriteMeal>[
      _favorit('Apfel', tag: 5, gepinnt: false),
      _favorit('Brot', tag: 4, gepinnt: false),
    ]);

    expect(_alleKnopf(), findsNothing);
    // Recents keep their keys and their incoming order.
    expect(find.byKey(const ValueKey('favorite-tile-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('favorite-tile-1')), findsOneWidget);
    expect(
      _nameInKachel(tester, find.byKey(const ValueKey('favorite-tile-0'))),
      'Apfel',
    );
  });

  testWidgets('schon bei einem gepinnten Favoriten ist die Zeile da',
      (tester) async {
    await _pumpe(tester, favoriten: <FavoriteMeal>[
      _favorit('Skyr', tag: 20),
      _favorit('Apfel', tag: 5, gepinnt: false),
    ]);

    expect(
      find.descendant(of: _alleKnopf(), matching: find.text('1 gespeichert')),
      findsOneWidget,
    );
    expect(find.text('Skyr'), findsNothing, reason: 'not inline');
  });

  testWidgets('die Zeile ist mindestens 44 pt hoch (Tap-Ziel)',
      (tester) async {
    await _pumpe(tester, favoriten: _fuenfGepinnt);

    expect(tester.getSize(_alleKnopf()).height, greaterThanOrEqualTo(44));
  });

  testWidgets('Tap auf die Zeile öffnet das Favoriten-Sheet mit allen 5',
      (tester) async {
    await _pumpe(tester, favoriten: _fuenfGepinnt);

    await _oeffneFavoritenSheet(tester);
    expect(find.text('Favoriten (5)'), findsOneWidget);
    for (var i = 0; i < 5; i++) {
      expect(
        find.byKey(ValueKey('favorites-sheet-item-$i')),
        findsOneWidget,
        reason: 'Zeile $i',
      );
    }
  });

  testWidgets(
      'Entpinnen im Favoriten-Sheet: der Zähler sinkt, der Favorit wird zum '
      'Recent, onToggleFavorite wurde genau einmal gerufen',
      (tester) async {
    final getoggelt = <MealAnalysisResult>[];
    await _pumpe(
      tester,
      favoriten: _fuenfGepinnt,
      onToggleFavorite: getoggelt.add,
    );

    await _oeffneFavoritenSheet(tester);
    // Row 0 in the sheet is the newest pinned: Skyr.
    await tester.tap(find.byKey(const ValueKey('favorites-sheet-fav-0')));
    await tester.pump();
    await _schliesseFavoritenSheet(tester);

    expect(getoggelt, hasLength(1));
    expect(getoggelt.single.mealName, 'Skyr');
    expect(
      find.descendant(of: _alleKnopf(), matching: find.text('4 gespeichert')),
      findsOneWidget,
    );
    // The unpinned one is now an auto-recent, not gone.
    expect(
      _nameInKachel(tester, find.byKey(const ValueKey('favorite-tile-0'))),
      'Skyr',
    );
  });

  testWidgets(
      'Entpinnen ohne Store-Anbindung (onToggleFavorite null) wirkt lokal',
      (tester) async {
    await _pumpe(tester, favoriten: _fuenfGepinnt);

    await _oeffneFavoritenSheet(tester);
    await tester.tap(find.byKey(const ValueKey('favorites-sheet-fav-0')));
    await tester.pump();
    await _schliesseFavoritenSheet(tester);

    expect(
      find.descendant(of: _alleKnopf(), matching: find.text('4 gespeichert')),
      findsOneWidget,
    );
  });

  testWidgets(
      'Hinzufügen im Favoriten-Sheet nimmt den im Add-Sheet gewählten Slot',
      (tester) async {
    final geloggt = <(MealAnalysisResult, MealSlot)>[];
    await _pumpe(
      tester,
      favoriten: _fuenfGepinnt,
      onAdd: (result, slot) {
        geloggt.add((result, slot));
        return 'id-1';
      },
    );

    // Sheet opened with snack; switch to lunch first.
    await chooseMealSlot(tester, 'slot-select-lunch');
    await tester.pumpAndSettle();

    await _oeffneFavoritenSheet(tester);
    await tester.tap(find.byKey(const ValueKey('favorites-sheet-item-1')));
    await tester.pumpAndSettle();
    final knopf = find.byKey(const ValueKey('favorites-sheet-add-1'));
    await tester.ensureVisible(knopf);
    await tester.tap(knopf);
    await tester.pump();

    expect(geloggt, hasLength(1));
    expect(geloggt.single.$1.mealName, 'Reis');
    expect(geloggt.single.$2, MealSlot.lunch);

    await _schliesseFavoritenSheet(tester);
    // Nothing changed in the add sheet's favorites after a plain add.
    expect(
      find.descendant(of: _alleKnopf(), matching: find.text('5 gespeichert')),
      findsOneWidget,
    );
  });

  testWidgets(
      'Hinzufügen im Favoriten-Sheet macht den Favoriten beim nächsten Öffnen '
      'zum neuesten', (tester) async {
    await _pumpe(tester, favoriten: _fuenfGepinnt);

    await _oeffneFavoritenSheet(tester);
    // Item 3 in the sheet = Haferbrei (4th by recency).
    await tester.tap(find.byKey(const ValueKey('favorites-sheet-item-3')));
    await tester.pumpAndSettle();
    final knopf = find.byKey(const ValueKey('favorites-sheet-add-3'));
    await tester.ensureVisible(knopf);
    await tester.tap(knopf);
    await tester.pump();
    await _schliesseFavoritenSheet(tester);

    // Review A (2026-08-27): "most recently used first" holds within the
    // session.
    await _oeffneFavoritenSheet(tester);
    expect(
      _nameInKachel(
        tester,
        find.byKey(const ValueKey('favorites-sheet-item-0')),
      ),
      'Haferbrei',
    );
  });

  testWidgets('die Favoriten-Zeile ist fuer den Screenreader ein Button MIT '
      'Tap-Action', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpe(tester, favoriten: _fuenfGepinnt);
    // Read first, dispose, then assert: a red expectation must not also leak
    // the handle (end-of-test check runs before tearDowns).
    final knoten = tester.getSemantics(_alleKnopf());
    handle.dispose();
    expect(
      knoten,
      isSemantics(
        isButton: true,
        hasTapAction: true,
        label: 'Favoriten, 5 gespeichert',
      ),
      reason: 'excludeSemantics verschluckt die Tap-Action des InkWell; '
          'Semantics(onTap:) muss sie neu deklarieren (Review B)',
    );
  });

  testWidgets('Ein-Tipp-Plus im Favoriten-Menü loggt in die im Add-Sheet '
      'gewählte Mahlzeit', (tester) async {
    final geloggt = <(MealAnalysisResult, MealSlot)>[];
    await _pumpe(
      tester,
      favoriten: _fuenfGepinnt,
      onAdd: (result, slot) {
        geloggt.add((result, slot));
        return 'id-${geloggt.length}';
      },
    );
    await chooseMealSlot(tester, 'slot-select-lunch');
    await _oeffneFavoritenSheet(tester);
    await tester.tap(find.byKey(const ValueKey('favorites-sheet-quick-0')));
    await tester.pumpAndSettle();

    final skyr = _fuenfGepinnt.firstWhere((f) => f.result.mealName == 'Skyr');
    expect(geloggt, hasLength(1));
    expect(identical(geloggt.single.$1, skyr.result), isTrue);
    expect(geloggt.single.$2, MealSlot.lunch);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('„Zuletzt gegessen" zeigt das Produktfoto', (tester) async {
    const foto =
        'https://images.openfoodfacts.org/images/products/400/054/000/0108/front_de.273.200.jpg';
    final riegel = _mahlzeit('Proteinriegel').withImageUrl(foto);
    await _pumpe(
      tester,
      favoriten: [
        FavoriteMeal(
          id: FavoriteMeal.idFor(riegel),
          result: riegel,
          addedAt: DateTime(2026, 8, 2),
        ),
      ],
    );
    final bild = find.descendant(
      of: find.byKey(const ValueKey('favorite-tile-0')),
      matching: find.byType(Image),
    );
    expect(bild, findsOneWidget);
    final provider = tester.widget<Image>(bild).image as ResizeImage;
    expect((provider.imageProvider as NetworkImage).url, foto);
  });

  testWidgets('ein Hinzufügen schiebt die Zeilen darunter nicht weg', (
    tester,
  ) async {
    // The meal joins the "already added" list above; the sheet scrolls by
    // that height so the rows below stay under the finger (review 2026-10-03).
    await _pumpe(
      tester,
      favoriten: [
        _favorit('Skyr', tag: 20),
        for (var i = 0; i < 5; i++)
          _favorit('Recent $i', tag: 10 - i, gepinnt: false),
      ],
    );
    final zeile = find.byKey(const ValueKey('favorite-tile-2'));
    await tester.ensureVisible(zeile);
    await tester.pumpAndSettle();
    await tester.tap(zeile);
    await tester.pumpAndSettle();
    final knopf = find.byKey(const ValueKey('favorite-tile-add-2'));
    await tester.ensureVisible(knopf);
    await tester.pumpAndSettle();
    final vorher = tester.getTopLeft(_alleKnopf());
    await tester.tap(knopf);
    await tester.pump(const Duration(milliseconds: 300));
    // The logged meal now also shows in the "already added" list above.
    expect(find.text('Recent 2'), findsNWidgets(2));
    expect((tester.getTopLeft(_alleKnopf()) - vorher).distance, lessThan(1));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('ein Herz auf einem Suchtreffer gibt dem alten Favoriten sein '
      'Foto, auch ohne Store', (tester) async {
    const alt = MealAnalysisResult(
      mealName: 'Proteinriegel',
      caloriesKcal: 212,
      estimatedGrams: 60,
      kcalPer100G: 353,
      protein: '-',
      carbs: '-',
      fat: '-',
      confidence: 'database',
      portionNotes: '',
      barcode: '4000540000108',
    );
    await _pumpe(
      tester,
      favoriten: [
        FavoriteMeal(
          id: FavoriteMeal.idFor(alt),
          result: alt,
          addedAt: DateTime(2026, 8, 2),
          pinned: true,
        ),
      ],
      onToggleFavorite: (_) {},
      productService: _FotoProduktdienst(),
    );
    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Proteinriegel',
    );
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pumpAndSettle();
    // The hit is the pinned favorite: its heart unpins it.
    await tester.tap(find.byKey(const ValueKey('kcal-product-suggestion-fav-0')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      '',
    );
    await tester.pumpAndSettle();

    final bild = find.descendant(
      of: find.byKey(const ValueKey('favorite-tile-0')),
      matching: find.byType(Image),
    );
    expect(bild, findsOneWidget, reason: 'the recent now has the photo');
    final provider = tester.widget<Image>(bild).image as ResizeImage;
    expect((provider.imageProvider as NetworkImage).url, _riegelFoto);
    // The stored portion stays the favorite's own.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('favorite-tile-0')),
        matching: find.textContaining('60 g'),
      ),
      findsOneWidget,
    );
  });
}
