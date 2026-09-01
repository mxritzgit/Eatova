import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/fallback_product_service.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';

class _FakeService implements ProductLookupService {
  _FakeService({
    this.searchResults = const <ProductSearchResult>[],
    this.searchThrows = false,
    this.searchError,
    this.barcodeResult,
    this.barcodeThrows = false,
    this.barcodeError,
  });

  final List<ProductSearchResult> searchResults;
  final bool searchThrows;

  /// Concrete error instead of the generic `Exception('boom')`, for the tests
  /// that check error CLASSIFICATION (transport vs. parse).
  final Object? searchError;
  final MealAnalysisResult? barcodeResult;
  final bool barcodeThrows;
  final Object? barcodeError;
  int searchCalls = 0;
  int barcodeCalls = 0;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    searchCalls++;
    if (searchError != null) {
      throw searchError!;
    }
    if (searchThrows) {
      throw Exception('boom');
    }
    return searchResults;
  }

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async {
    barcodeCalls++;
    if (barcodeError != null) {
      throw barcodeError!;
    }
    if (barcodeThrows) {
      throw Exception('boom');
    }
    return barcodeResult!;
  }
}

MealAnalysisResult _meal(String name, {double kcalPer100G = 100}) =>
    MealAnalysisResult(
      mealName: name,
      caloriesKcal: kcalPer100G.round(),
      estimatedGrams: 100,
      kcalPer100G: kcalPer100G,
      protein: '1 g',
      carbs: '1 g',
      fat: '1 g',
      confidence: 'Datenbank',
      portionNotes: '',
    );

ProductSearchResult _hit(String title, {double kcalPer100G = 100}) =>
    ProductSearchResult(
      code: '1',
      title: title,
      subtitle: '',
      kcalPer100G: kcalPer100G,
      result: _meal(title, kcalPer100G: kcalPer100G),
    );

void main() {
  test('search: primary results are used, fallback not called', () async {
    final primary = _FakeService(searchResults: [_hit('Mirror')]);
    final fallback = _FakeService(searchResults: [_hit('OFF')]);
    final svc = FallbackProductService(primary, fallback);

    final r = await svc.searchProducts('milch');

    expect(r.single.title, 'Mirror');
    expect(fallback.searchCalls, 0);
  });

  test('search: primary throws -> fallback used', () async {
    final primary = _FakeService(searchThrows: true);
    final fallback = _FakeService(searchResults: [_hit('OFF')]);
    final svc = FallbackProductService(primary, fallback);

    final r = await svc.searchProducts('milch');

    expect(r.single.title, 'OFF');
    expect(fallback.searchCalls, 1);
  });

  test('search: primary empty -> fallback used', () async {
    final primary = _FakeService(searchResults: const <ProductSearchResult>[]);
    final fallback = _FakeService(searchResults: [_hit('OFF')]);
    final svc = FallbackProductService(primary, fallback);

    final r = await svc.searchProducts('milch');

    expect(r.single.title, 'OFF');
    expect(fallback.searchCalls, 1);
  });

  test('barcode: primary not found -> fallback used', () async {
    final primary = _FakeService(barcodeThrows: true);
    final fallback = _FakeService(barcodeResult: _meal('OFF product'));
    final svc = FallbackProductService(primary, fallback);

    final r = await svc.lookupBarcode('123');

    expect(r.mealName, 'OFF product');
    expect(fallback.barcodeCalls, 1);
  });

  test('barcode: primary success -> fallback not called', () async {
    final primary = _FakeService(barcodeResult: _meal('Mirror product'));
    final fallback = _FakeService(barcodeResult: _meal('OFF product'));
    final svc = FallbackProductService(primary, fallback);

    final r = await svc.lookupBarcode('123');

    expect(r.mealName, 'Mirror product');
    expect(fallback.barcodeCalls, 0);
  });

  // ---------------------------------------------------------------------
  // B7 — the Meilisearch path had no energy filter at all; it only checks for
  // a non-empty title. The counter-check sits here, where both sources meet.
  // ---------------------------------------------------------------------

  test('search: Mirror-Treffer ohne Energie werden verworfen, OFF uebernimmt',
      () async {
    final primary = _FakeService(searchResults: [_hit('Riegel', kcalPer100G: 0)]);
    final fallback = _FakeService(searchResults: [_hit('OFF')]);
    final svc = FallbackProductService(primary, fallback);

    final r = await svc.searchProducts('riegel');

    expect(r.single.title, 'OFF');
    expect(fallback.searchCalls, 1);
  });

  test('search: unplausible Mirror-Treffer (2180 kcal) werden verworfen',
      () async {
    final primary = _FakeService(
      searchResults: [
        _hit('Keks', kcalPer100G: 2180),
        _hit('Milch', kcalPer100G: 64),
      ],
    );
    final fallback = _FakeService(searchResults: [_hit('OFF')]);
    final svc = FallbackProductService(primary, fallback);

    final r = await svc.searchProducts('keks');

    // The usable hit stays, the impossible one drops — and since something is
    // left, OFF is not asked at all.
    expect(r.map((t) => t.title), ['Milch']);
    expect(fallback.searchCalls, 0);
  });

  test('search: OFF-Treffer werden ebenfalls gefiltert', () async {
    final primary = _FakeService(searchResults: const <ProductSearchResult>[]);
    final fallback = _FakeService(
      searchResults: [
        _hit('Keks', kcalPer100G: 2180),
        _hit('Milch', kcalPer100G: 64),
      ],
    );
    final svc = FallbackProductService(primary, fallback);

    final r = await svc.searchProducts('keks');

    expect(r.map((t) => t.title), ['Milch']);
  });

  // The two tests above build their hits by hand, so they never exercise the
  // step that decides whether a 0 means "measured" or "unknown". These two do:
  // they run a raw mirror document through the real
  // `ProductSearchResult.fromOpenFoodFacts`. Deriving `explicitZeroKcal` from
  // `kcalPer100G == 0` alone — without `offMeldetExplizitNullKcal` — left the
  // whole T5 suite green, and a bar with no nutriments at all would have gone
  // into the diary as a 0-kcal meal.

  test(
      'search: Spiegel-Dokument OHNE Naehrwerte gilt nicht als gemessene 0 — '
      'OFF uebernimmt', () async {
    final ohneEnergie = ProductSearchResult.fromOpenFoodFacts(
      <String, dynamic>{
        'code': '111',
        'product_name': 'Riegel ohne Angaben',
        'nutriments': <String, dynamic>{},
      },
    );
    expect(ohneEnergie.kcalPer100G, 0);
    expect(ohneEnergie.result.explicitZeroKcal, isFalse,
        reason: 'fehlende Felder sind "unbekannt", nicht "0 gemessen"');

    final primary = _FakeService(searchResults: [ohneEnergie]);
    final fallback = _FakeService(searchResults: [_hit('OFF')]);

    final r = await FallbackProductService(primary, fallback)
        .searchProducts('riegel');

    expect(r.single.title, 'OFF');
    expect(fallback.searchCalls, 1);
  });

  test(
      'search: Spiegel-Dokument mit EXPLIZITEN 0 kcal (Wasser) bleibt — und '
      'OFF wird gar nicht erst gefragt', () async {
    // The counter-check: without it the test above could be satisfied by
    // dropping every 0-kcal hit, which would make water unloggable.
    final wasser = ProductSearchResult.fromOpenFoodFacts(<String, dynamic>{
      'code': '222',
      'product_name': 'Mineralwasser',
      'nutriments': <String, dynamic>{'energy-kcal_100g': 0},
    });
    expect(wasser.kcalPer100G, 0);
    expect(wasser.result.explicitZeroKcal, isTrue);

    final primary = _FakeService(searchResults: [wasser]);
    final fallback = _FakeService(searchResults: [_hit('OFF')]);

    final r = await FallbackProductService(primary, fallback)
        .searchProducts('wasser');

    expect(r.single.title, contains('Mineralwasser'));
    expect(fallback.searchCalls, 0);
  });

  test('barcode: Primaer-Treffer ohne Energie -> OFF wird gefragt', () async {
    final primary = _FakeService(
      barcodeResult: _meal('Mirror product', kcalPer100G: 0),
    );
    final fallback = _FakeService(barcodeResult: _meal('OFF product'));
    final svc = FallbackProductService(primary, fallback);

    final r = await svc.lookupBarcode('123');

    expect(r.mealName, 'OFF product');
    expect(fallback.barcodeCalls, 1);
  });

  test('barcode: unplausibler Primaer-Treffer -> OFF wird gefragt', () async {
    final primary = _FakeService(
      barcodeResult: _meal('Mirror product', kcalPer100G: 2180),
    );
    final fallback = _FakeService(barcodeResult: _meal('OFF product'));
    final svc = FallbackProductService(primary, fallback);

    final r = await svc.lookupBarcode('123');

    expect(r.mealName, 'OFF product');
  });

  // ---------------------------------------------------------------------
  // G2 — `catch (_) {}` swallowed EVERY exception. A network error should be
  // swallowed; a parse error means the app no longer understands the API and
  // must become visible.
  // ---------------------------------------------------------------------

  group('Fehler-Klassifizierung beim Zurueckfallen', () {
    late List<Object> gemeldet;

    setUp(() {
      gemeldet = <Object>[];
      CrashReporter.debugSentrySink = (error, stack, context) {
        gemeldet.add(error);
      };
    });

    tearDown(() => CrashReporter.debugSentrySink = null);

    Future<void> pumpeMikrotasks() => Future<void>.delayed(Duration.zero);

    test('Transportfehler werden still geschluckt', () async {
      for (final fehler in <Object>[
        const SocketException('no route'),
        const HttpException('Mirror search failed: 503'),
        TimeoutException('zu langsam', const Duration(seconds: 6)),
      ]) {
        final primary = _FakeService(searchError: fehler);
        final fallback = _FakeService(searchResults: [_hit('OFF')]);

        final r = await FallbackProductService(
          primary,
          fallback,
        ).searchProducts('milch');

        expect(r.single.title, 'OFF');
      }
      await pumpeMikrotasks();

      expect(gemeldet, isEmpty);
    });

    test('Mirror-Barcode-UnsupportedError wird nicht gemeldet', () async {
      final primary = _FakeService(
        barcodeError: UnsupportedError(
          'Barcode-Lookup laeuft ueber die OFF-Live-API (Fallback).',
        ),
      );
      final fallback = _FakeService(barcodeResult: _meal('OFF product'));

      await FallbackProductService(primary, fallback).lookupBarcode('123');
      await pumpeMikrotasks();

      expect(gemeldet, isEmpty);
    });

    test('"nicht gefunden" wird nicht gemeldet', () async {
      final primary = _FakeService(
        barcodeError: const ProductNotFoundException('123'),
      );
      final fallback = _FakeService(barcodeResult: _meal('OFF product'));

      await FallbackProductService(primary, fallback).lookupBarcode('123');
      await pumpeMikrotasks();

      expect(gemeldet, isEmpty);
    });

    test('Parse-Fehler wird gemeldet und der Fallback laeuft trotzdem',
        () async {
      final primary = _FakeService(
        searchError: const FormatException('Unexpected character'),
      );
      final fallback = _FakeService(searchResults: [_hit('OFF')]);

      final r = await FallbackProductService(
        primary,
        fallback,
      ).searchProducts('milch');
      await pumpeMikrotasks();

      expect(r.single.title, 'OFF');
      expect(gemeldet, hasLength(1));
      // What Sentry would get is already sanitised (C1).
      expect(gemeldet.single, isA<SanitizedError>());
      expect('${gemeldet.single}', contains('FormatException'));
    });

    test('TypeError wird gemeldet — die API-Form hat sich geaendert',
        () async {
      // Exactly what happens when OFF switches a field from num to String and
      // an `as double` in the parser hits it.
      final primary = _FakeService(
        barcodeError: TypeError(),
      );
      final fallback = _FakeService(barcodeResult: _meal('OFF product'));

      final r = await FallbackProductService(
        primary,
        fallback,
      ).lookupBarcode('123');
      await pumpeMikrotasks();

      expect(r.mealName, 'OFF product');
      expect(gemeldet, hasLength(1));
    });
  });
}
