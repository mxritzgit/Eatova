import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/fallback_product_service.dart';
import 'package:eatova/src/services/meilisearch_product_service.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/services/search_credentials.dart';

// Error classification of the product search — two gaps from review 2026-08-19:
//
//  * The mirror's schema-drift alarm threw an HttpException, which is an
//    IOException and thus an expected network error in FallbackProductService:
//    the alarm never fired.
//  * Only the PRIMARY leg was classified, while in production OFF is always the
//    fallback leg — the very source whose format changes the classification is
//    supposed to surface.
//
// Plain `test()`: dart:io is untouched and the mirror is a real local
// HttpServer.

// ─── Stubs ─────────────────────────────────────────────────────────────────

class _FakeProduktService implements ProductLookupService {
  _FakeProduktService({
    this.searchResults = const <ProductSearchResult>[],
    this.searchError,
    this.barcodeError,
  });

  final List<ProductSearchResult> searchResults;
  final Object? searchError;
  final Object? barcodeError;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async {
    if (searchError != null) throw searchError!;
    return searchResults;
  }

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async {
    if (barcodeError != null) throw barcodeError!;
    // The barcode path only serves as an error source here; no hit is needed.
    throw UnimplementedError('lookupBarcode-Treffer wird hier nicht gebraucht');
  }
}

class _FakeCredentials extends SearchCredentialsSource {
  _FakeCredentials(this.active);

  SearchCredentials active;
  int invalidateCalls = 0;

  @override
  Future<SearchCredentials> resolve() async => active;

  @override
  Future<SearchCredentials> invalidate(SearchCredentials rejected) async {
    invalidateCalls++;
    active = SearchCredentials.disabled;
    return active;
  }
}

/// Mirror stub with a fixed status and body.
class _MirrorStub {
  _MirrorStub._(this._server);

  final HttpServer _server;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_MirrorStub> start({
    required int status,
    required String body,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(body);
      await request.response.close();
    });
    return _MirrorStub._(server);
  }

  Future<void> close() => _server.close(force: true);
}

MealAnalysisResult _meal(String name) => MealAnalysisResult(
      mealName: name,
      caloriesKcal: 100,
      estimatedGrams: 100,
      kcalPer100G: 100,
      protein: '1 g',
      carbs: '1 g',
      fat: '1 g',
      confidence: 'Datenbank',
      portionNotes: '',
    );

ProductSearchResult _hit(String title) => ProductSearchResult(
      code: '1',
      title: title,
      subtitle: '',
      kcalPer100G: 100,
      result: _meal(title),
    );

void main() {
  late List<Object> gemeldet;
  late List<String?> kontexte;

  setUp(() {
    gemeldet = <Object>[];
    kontexte = <String?>[];
    CrashReporter.debugSentrySink = (error, stack, context) {
      gemeldet.add(error);
      kontexte.add(context);
    };
  });

  tearDown(() => CrashReporter.debugSentrySink = null);

  // capture() runs unawaited; one microtask pass is enough.
  Future<void> pumpe() => Future<void>.delayed(Duration.zero);

  // ─────────────────────────────────────────────────────────────────────────
  // Finding 1 — the mirror's schema-drift alarm must not pass as a network
  // error.
  // ─────────────────────────────────────────────────────────────────────────

  group('Mirror-Schema-Drift', () {
    test('2xx ohne hits-Liste wird GEMELDET, OFF uebernimmt trotzdem',
        () async {
      // The case the alarm was built for: the mirror answers 200 but the body
      // is no search response (proxy error page, changed index schema).
      // Previously an HttpException and thus a silent "expected" network error.
      final stub = await _MirrorStub.start(status: 200, body: '{"ok":true}');
      addTearDown(stub.close);
      final creds = _FakeCredentials(
        SearchCredentials(
          baseUrl: stub.baseUrl,
          searchKey: 'search-key',
          source: SearchCredentialsOrigin.cache,
        ),
      );

      final treffer = await FallbackProductService(
        MeilisearchProductService(credentials: creds),
        _FakeProduktService(searchResults: [_hit('OFF')]),
      ).searchProducts('salami');
      await pumpe();

      expect(treffer.single.title, 'OFF', reason: 'Fallback laeuft weiter');
      expect(gemeldet, hasLength(1));
      expect('${gemeldet.single}', contains('MirrorSchemaException'));
      expect(kontexte.single, 'product.search.primary');
      expect(creds.invalidateCalls, 0, reason: 'kein Rotations-Signal');
    });

    test('MirrorSchemaException ist bewusst KEINE IOException', () {
      // The one property everything hangs on: if the type ever becomes an
      // IOException again, the alarm is silently dead.
      const fehler = MirrorSchemaException('malformed');
      expect(fehler, isA<Exception>());
      expect(fehler, isNot(isA<IOException>()));
    });

    test('5xx vom Mirror bleibt still — ein Serverwackler ist kein Vorfall',
        () async {
      final stub = await _MirrorStub.start(status: 500, body: '{}');
      addTearDown(stub.close);
      final creds = _FakeCredentials(
        SearchCredentials(
          baseUrl: stub.baseUrl,
          searchKey: 'search-key',
          source: SearchCredentialsOrigin.cache,
        ),
      );

      final treffer = await FallbackProductService(
        MeilisearchProductService(credentials: creds),
        _FakeProduktService(searchResults: [_hit('OFF')]),
      ).searchProducts('salami');
      await pumpe();

      expect(treffer.single.title, 'OFF');
      expect(gemeldet, isEmpty);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Finding 2 — the fallback leg (always OFF in production) bypassed the
  // classification.
  // ─────────────────────────────────────────────────────────────────────────

  group('Klassifizierung des Fallback-Beins', () {
    test('Suche: Parse-Fehler bei OFF wird gemeldet und weitergereicht',
        () async {
      final svc = FallbackProductService(
        _FakeProduktService(searchResults: const <ProductSearchResult>[]),
        _FakeProduktService(
          searchError: const FormatException('Unexpected character'),
        ),
      );

      await expectLater(
        svc.searchProducts('milch'),
        throwsA(isA<FormatException>()),
        reason: 'kein Bein mehr uebrig -> der Aufrufer muss es sehen',
      );
      await pumpe();

      expect(gemeldet, hasLength(1));
      expect(gemeldet.single, isA<SanitizedError>());
      expect('${gemeldet.single}', contains('FormatException'));
      expect(kontexte.single, 'product.search.fallback');
    });

    test('Suche: Netzfehler bei OFF bleibt still', () async {
      final svc = FallbackProductService(
        _FakeProduktService(searchResults: const <ProductSearchResult>[]),
        _FakeProduktService(searchError: const SocketException('no route')),
      );

      await expectLater(
        svc.searchProducts('milch'),
        throwsA(isA<SocketException>()),
      );
      await pumpe();

      expect(gemeldet, isEmpty);
    });

    test('Barcode: TypeError bei OFF wird gemeldet und weitergereicht',
        () async {
      // What happens when OFF switches a nutrient field from num to String and
      // an `as double` in the parser hits it.
      final svc = FallbackProductService(
        _FakeProduktService(
          barcodeError: UnsupportedError('Mirror kann keine Barcodes'),
        ),
        _FakeProduktService(barcodeError: TypeError()),
      );

      await expectLater(
        svc.lookupBarcode('123'),
        throwsA(isA<TypeError>()),
      );
      await pumpe();

      // The mirror's UnsupportedError is normal operation and stays silent;
      // only the OFF error is reported.
      expect(gemeldet, hasLength(1));
      expect(kontexte.single, 'product.barcode.fallback');
    });

    test('Barcode: "nicht gefunden" bei OFF bleibt still', () async {
      // The normal case: a scan of a product OFF does not know.
      final svc = FallbackProductService(
        _FakeProduktService(
          barcodeError: UnsupportedError('Mirror kann keine Barcodes'),
        ),
        _FakeProduktService(
          barcodeError: const ProductNotFoundException('123'),
        ),
      );

      await expectLater(
        svc.lookupBarcode('123'),
        throwsA(isA<ProductNotFoundException>()),
      );
      await pumpe();

      expect(gemeldet, isEmpty);
    });

    test('beide Beine kaputt -> zwei Reports mit getrennten Kontexten',
        () async {
      final svc = FallbackProductService(
        _FakeProduktService(searchError: const FormatException('primary')),
        _FakeProduktService(searchError: const FormatException('fallback')),
      );

      await expectLater(
        svc.searchProducts('milch'),
        throwsA(isA<FormatException>()),
      );
      await pumpe();

      expect(gemeldet, hasLength(2));
      expect(kontexte, ['product.search.primary', 'product.search.fallback']);
    });

    test('erfolgreicher Fallback meldet nichts', () async {
      final svc = FallbackProductService(
        _FakeProduktService(searchResults: const <ProductSearchResult>[]),
        _FakeProduktService(searchResults: [_hit('OFF')]),
      );

      expect((await svc.searchProducts('milch')).single.title, 'OFF');
      await pumpe();

      expect(gemeldet, isEmpty);
    });
  });
}
