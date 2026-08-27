// Favorites section of the add-meal sheet (feature 2026-08-27): only the top
// three pinned by recency sit inline, the "All (N)" button opens the favorites
// sheet, and unpins/adds made there flow back into the add sheet.

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
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';

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

void _telefon(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpe(
  WidgetTester tester, {
  required List<FavoriteMeal> favoriten,
  String Function(MealAnalysisResult, MealSlot)? onAdd,
  ValueChanged<MealAnalysisResult>? onToggleFavorite,
  Locale locale = const Locale('de'),
}) async {
  _telefon(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      locale: locale,
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: AddMealSheet(
          slot: MealSlot.snack,
          analyzer: _StummerAnalyzer(),
          productService: _StummerProduktdienst(),
          photoInput: _StummeFotoquelle(),
          favorites: favoriten,
          onAdd: onAdd ?? (_, __) => 'id-1',
          onUpdateMeal: (_, __) {},
          onRemoveFavorite: (_) {},
          onToggleFavorite: onToggleFavorite,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _inlineKachel(int index) =>
    find.byKey(ValueKey('favorite-pinned-$index'));

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
  testWidgets('5 gepinnte Favoriten: nur die 3 neuesten stehen inline',
      (tester) async {
    await _pumpe(tester, favoriten: _fuenfGepinnt);

    expect(_inlineKachel(0), findsOneWidget);
    expect(_inlineKachel(1), findsOneWidget);
    expect(_inlineKachel(2), findsOneWidget);
    expect(_inlineKachel(3), findsNothing);
    expect(_inlineKachel(4), findsNothing);

    // Newest first, regardless of the incoming list order.
    expect(_nameInKachel(tester, _inlineKachel(0)), 'Skyr');
    expect(_nameInKachel(tester, _inlineKachel(1)), 'Reis');
    expect(_nameInKachel(tester, _inlineKachel(2)), 'Lachs');
    expect(find.text('Banane'), findsNothing);
    expect(find.text('Haferbrei'), findsNothing);
  });

  testWidgets('der Alle-Knopf zählt ALLE gepinnten, nicht nur die inline',
      (tester) async {
    await _pumpe(tester, favoriten: _fuenfGepinnt);

    expect(_alleKnopf(), findsOneWidget);
    expect(
      find.descendant(of: _alleKnopf(), matching: find.text('Alle (5)')),
      findsOneWidget,
    );
  });

  testWidgets('englisch heißt der Knopf „All (5)"', (tester) async {
    await _pumpe(
      tester,
      favoriten: _fuenfGepinnt,
      locale: const Locale('en'),
    );

    expect(
      find.descendant(of: _alleKnopf(), matching: find.text('All (5)')),
      findsOneWidget,
    );
  });

  testWidgets('ohne gepinnte Favoriten gibt es keinen Knopf, Recents bleiben',
      (tester) async {
    await _pumpe(tester, favoriten: <FavoriteMeal>[
      _favorit('Apfel', tag: 5, gepinnt: false),
      _favorit('Brot', tag: 4, gepinnt: false),
    ]);

    expect(_alleKnopf(), findsNothing);
    expect(find.text('FAVORITEN'), findsNothing);
    expect(_inlineKachel(0), findsNothing);
    // Recents keep their keys and their incoming order.
    expect(find.byKey(const ValueKey('favorite-tile-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('favorite-tile-1')), findsOneWidget);
    expect(
      _nameInKachel(tester, find.byKey(const ValueKey('favorite-tile-0'))),
      'Apfel',
    );
  });

  testWidgets('schon bei einem gepinnten Favoriten ist der Knopf da',
      (tester) async {
    await _pumpe(tester, favoriten: <FavoriteMeal>[
      _favorit('Skyr', tag: 20),
      _favorit('Apfel', tag: 5, gepinnt: false),
    ]);

    expect(_inlineKachel(0), findsOneWidget);
    expect(_inlineKachel(1), findsNothing);
    expect(
      find.descendant(of: _alleKnopf(), matching: find.text('Alle (1)')),
      findsOneWidget,
    );
  });

  testWidgets('der Knopf ist mindestens 44 pt hoch (Tap-Ziel)',
      (tester) async {
    await _pumpe(tester, favoriten: _fuenfGepinnt);

    expect(tester.getSize(_alleKnopf()).height, greaterThanOrEqualTo(44));
  });

  testWidgets('Tap auf den Knopf öffnet das Favoriten-Sheet mit allen 5',
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
      'Entpinnen im Favoriten-Sheet: danach fehlt der Favorit inline, der '
      'Zähler sinkt, onToggleFavorite wurde genau einmal gerufen',
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

    // Top 3 moved up by one: Reis, Lachs, Haferbrei.
    expect(_nameInKachel(tester, _inlineKachel(0)), 'Reis');
    expect(_nameInKachel(tester, _inlineKachel(1)), 'Lachs');
    expect(_nameInKachel(tester, _inlineKachel(2)), 'Haferbrei');
    expect(_inlineKachel(3), findsNothing);
    expect(
      find.descendant(of: _alleKnopf(), matching: find.text('Alle (4)')),
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

    expect(_nameInKachel(tester, _inlineKachel(0)), 'Reis');
    expect(
      find.descendant(of: _alleKnopf(), matching: find.text('Alle (4)')),
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
    await tester.tap(find.byKey(const ValueKey('slot-select-lunch')));
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
      find.descendant(of: _alleKnopf(), matching: find.text('Alle (5)')),
      findsOneWidget,
    );
  });

  testWidgets(
      'Hinzufügen im Favoriten-Sheet macht den Favoriten inline zum neuesten',
      (tester) async {
    await _pumpe(tester, favoriten: _fuenfGepinnt);
    // Recency before: Skyr, Reis, Lachs | Haferbrei, Banane.
    expect(_nameInKachel(tester, _inlineKachel(0)), 'Skyr');

    await _oeffneFavoritenSheet(tester);
    // Item 3 in the sheet = Haferbrei (4th by recency, not inline yet).
    await tester.tap(find.byKey(const ValueKey('favorites-sheet-item-3')));
    await tester.pumpAndSettle();
    final knopf = find.byKey(const ValueKey('favorites-sheet-add-3'));
    await tester.ensureVisible(knopf);
    await tester.tap(knopf);
    await tester.pump();
    await _schliesseFavoritenSheet(tester);

    // Review A (2026-08-27): "most recently used first" must hold within the
    // session, not only after reopening the add sheet.
    expect(_nameInKachel(tester, _inlineKachel(0)), 'Haferbrei');
    expect(_nameInKachel(tester, _inlineKachel(1)), 'Skyr');
    expect(_nameInKachel(tester, _inlineKachel(2)), 'Reis');
    expect(_inlineKachel(3), findsNothing);
    expect(
      find.descendant(of: _alleKnopf(), matching: find.text('Alle (5)')),
      findsOneWidget,
    );
  });

  testWidgets('„Alle (N)" ist fuer den Screenreader ein Button MIT Tap-Action',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpe(tester, favoriten: _fuenfGepinnt);
    // Read first, dispose, then assert: a red expectation must not also leak
    // the handle (end-of-test check runs before tearDowns).
    final knoten = tester.getSemantics(_alleKnopf());
    handle.dispose();
    expect(
      knoten,
      isSemantics(isButton: true, hasTapAction: true, label: 'Alle (5)'),
      reason: 'excludeSemantics verschluckt die Tap-Action des InkWell; '
          'Semantics(onTap:) muss sie neu deklarieren (Review B)',
    );
  });
}
