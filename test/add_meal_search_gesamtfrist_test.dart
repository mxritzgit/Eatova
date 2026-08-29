// P10-02 — the product search had a timeout per stage but no ceiling over the
// chain.
//
// Old arithmetic per attempt: mirror 16 s + key rotation 3 s + mirror retry
// 16 s + OFF-de 32 s + OFF-world 32 s = 99 s, times three attempts plus two
// 600 ms pauses = 298.2 s. During all of it the user saw a bare spinner: no
// cancel, no "taking longer" line.
//
// These tests pin the ceiling, and they pin it the only way that cannot be
// faked: a service that NEVER answers. Everything downstream (per-request
// ceiling, mirror chain, OFF chain) is proven in
// `test/services/produktsuche_gesamtfrist_test.dart`; here the subject is
// what the user gets to see and to do.

import 'dart:async';

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

const String _zuLange =
    'Die Suche hat zu lange gedauert. Trag das Produkt so lange manuell ein.';
const String _abgebrochen = 'Suche abgebrochen.';
const String _langsam = 'Dauert länger als üblich …';

class _StummerAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async =>
      throw UnimplementedError();
}

class _StummeFotoquelle implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

/// Accepts the search and never answers — the chain that hangs at every stage,
/// condensed into one stub.
class _HaengenderDienst implements ProductLookupService {
  int aufrufe = 0;
  final List<Completer<List<ProductSearchResult>>> offen =
      <Completer<List<ProductSearchResult>>>[];

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) {
    aufrufe++;
    final completer = Completer<List<ProductSearchResult>>();
    offen.add(completer);
    return completer.future;
  }
}

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
  await tester.pump();
}

/// Types a term and lets the 1000 ms debounce fire — attempt 1 is now in
/// flight and the whole ceiling starts counting from here.
Future<void> _sucheStarten(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('kcal-product-search-input')),
    'Bauernmozzarella',
  );
  await tester.pump(const Duration(milliseconds: 1100));
}

void main() {
  testWidgets('haengende Kette endet nach der Gesamt-Frist, nicht nach Minuten',
      (tester) async {
    final dienst = _HaengenderDienst();
    await _pumpeSheet(tester, dienst);
    await _sucheStarten(tester);

    expect(dienst.aufrufe, 1);
    expect(find.byKey(const ValueKey('product-search-spinner')), findsOneWidget);

    // Kurz vor der Frist laeuft die Suche noch.
    await tester.pump(const Duration(seconds: 17));
    expect(find.byKey(const ValueKey('product-search-spinner')), findsOneWidget);

    // ... und danach ist sie vorbei.
    await tester.pump(const Duration(seconds: 2));
    expect(
      find.byKey(const ValueKey('product-search-spinner')),
      findsNothing,
      reason: 'nach 18 s gibt die Suche auf statt 298 s weiterzudrehen',
    );
    expect(find.text(_zuLange), findsOneWidget);
    expect(
      find.byKey(const ValueKey('manual-entry-cta')),
      findsOneWidget,
      reason: 'nach dem Aufgeben braucht der Nutzer einen Weg nach vorn',
    );
    expect(
      dienst.aufrufe,
      1,
      reason: 'die abgelaufene Frist startet keinen weiteren Versuch',
    );

    // Auch lange danach passiert nichts mehr — kein Nachzuegler-Zyklus.
    await tester.pump(const Duration(minutes: 5));
    expect(dienst.aufrufe, 1);
  });

  testWidgets('nach sechs Sekunden erscheinen Hinweis und Abbruch-Knopf',
      (tester) async {
    final dienst = _HaengenderDienst();
    await _pumpeSheet(tester, dienst);
    await _sucheStarten(tester);

    expect(
      find.byKey(const ValueKey('product-search-slow-hint')),
      findsNothing,
      reason: 'eine normale Suche soll keinen Hinweis bekommen',
    );

    await tester.pump(const Duration(seconds: 7));
    expect(find.byKey(const ValueKey('product-search-slow-hint')),
        findsOneWidget);
    expect(find.text(_langsam), findsOneWidget);
    expect(find.byKey(const ValueKey('product-search-cancel')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('product-search-spinner')),
      findsOneWidget,
      reason: 'der Hinweis ersetzt die Suche nicht, er begleitet sie',
    );

    // Der Zyklus laeuft hier noch — bis ans Ende der Frist pumpen, sonst
    // haengt sein Timer beim Testende noch in der Luft.
    await tester.pump(const Duration(seconds: 12));
  });

  testWidgets('Abbrechen beendet die Suche sofort und bietet das Formular an',
      (tester) async {
    final dienst = _HaengenderDienst();
    await _pumpeSheet(tester, dienst);
    await _sucheStarten(tester);
    await tester.pump(const Duration(seconds: 7));

    await tester.tap(find.byKey(const ValueKey('product-search-cancel')));
    await tester.pump();

    expect(find.byKey(const ValueKey('product-search-spinner')), findsNothing);
    expect(find.text(_abgebrochen), findsOneWidget);
    expect(find.byKey(const ValueKey('manual-entry-cta')), findsOneWidget);

    // Die abgebrochene Antwort darf spaeter nichts mehr umwerfen.
    dienst.offen.single.complete(const <ProductSearchResult>[]);
    await tester.pump(const Duration(seconds: 30));
    expect(find.text(_abgebrochen), findsOneWidget);
    expect(dienst.aufrufe, 1);
  });
}
