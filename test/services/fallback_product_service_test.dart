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

  /// Konkreter Fehler statt des generischen `Exception('boom')` — dient den
  /// Tests, die die Fehler-KLASSIFIZIERUNG pruefen (Transport vs. Parse).
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
  // B7 — der Meilisearch-Pfad hatte gar keinen Energie-Filter.
  // `MeilisearchProductService` filtert seine Hits nur auf einen nicht
  // leeren Titel; die Gegenpruefung sitzt hier, an der Stelle, an der beide
  // Quellen zusammenlaufen.
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

    // Der brauchbare Treffer bleibt, der unmoegliche faellt raus — und weil
    // noch etwas uebrig ist, wird OFF gar nicht erst gefragt.
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
  // G2 — `catch (_) {}` schluckte JEDE Exception. Ein Netzfehler soll
  // geschluckt werden; ein Parse-Fehler heisst, dass die App die API nicht
  // mehr versteht, und muss sichtbar werden.
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
      // Was Sentry bekaeme, ist bereits sanitisiert (C1).
      expect(gemeldet.single, isA<SanitizedError>());
      expect('${gemeldet.single}', contains('FormatException'));
    });

    test('TypeError wird gemeldet — die API-Form hat sich geaendert',
        () async {
      // Genau die Form, die entsteht, wenn OFF ein Feld von num auf String
      // umstellt und ein `as double` im Parser darauf trifft.
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
