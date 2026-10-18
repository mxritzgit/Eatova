import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/fallback_product_service.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';

// Review 2026-08-31, finding G: an empty product search must not pass as
// authoritative while a leg of the chain failed.
//
// `OpenFoodFactsProductService.searchProducts` walked `de`, then `world`, and
// returned `[]` as soon as ONE leg had answered cleanly
// (`if (cleanlyEmpty || lastError == null) return []`). Two things hid behind
// that empty list, and this file pins both at the level where they hurt — the
// production wiring `FallbackProductService(mirror, OFF)`, which is where
// errors get classified:
//
//   1. A failed `world` behind an empty `de`. The caller got an authoritative
//      "not found" for a product that is listed only on `world` (Austrian and
//      Swiss articles, `de` carries the German facet). `add_meal_sheet` puts
//      such a query into `_emptyQueryCache` for the sheet's whole lifetime, so
//      it is never asked again — not even after `world` recovers.
//   2. A parse error on one leg behind an empty answer from the other. The
//      error never left the service, so `FallbackProductService` had nothing
//      to classify and the CrashReporter never heard about the schema change.
//
// The counter-check belongs in here too: a genuinely empty result (every leg
// 2xx, every leg empty) is the search's normal outcome and must still come
// back without a throw and without a report.

/// Two OFF endpoints on one loopback server (`/de/...`, `/world/...`), each
/// with its own scripted status and body.
class _OffStub {
  _OffStub._(this._server, this._antworten);

  final HttpServer _server;
  final Map<String, ({int status, String body})> _antworten;

  final List<String> gefragt = <String>[];

  static const String leer = '{"count":0,"products":[]}';

  static Future<_OffStub> start(
    Map<String, ({int status, String body})> antworten,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final stub = _OffStub._(server, antworten);
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      final zweig = request.uri.pathSegments.first;
      stub.gefragt.add(zweig);
      final antwort =
          stub._antworten[zweig] ?? (status: 404, body: '{"products":[]}');
      request.response
        ..statusCode = antwort.status
        ..headers.contentType = ContentType.json
        ..write(antwort.body);
      await request.response.close();
    });
    return stub;
  }

  List<String> get searchBaseUrls => <String>[
    'http://127.0.0.1:${_server.port}/de/cgi/search.pl',
    'http://127.0.0.1:${_server.port}/world/cgi/search.pl',
  ];

  Future<void> close() => _server.close(force: true);
}

/// The mirror as it behaves in the case that matters: it answers, it just has
/// no hit — so the chain moves on to OFF without a report of its own.
class _LeererSpiegel implements ProductLookupService {
  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) =>
      throw UnsupportedError('Der Spiegel kennt keine Barcodes.');
}

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

  Future<List<ProductSearchResult>> suche(_OffStub stub) =>
      FallbackProductService(
        _LeererSpiegel(),
        OpenFoodFactsProductService(searchBaseUrls: stub.searchBaseUrls),
      ).searchProducts('bauernmozzarella');

  test('leeres de plus 502 bei world erreicht den Aufrufer als Fehler',
      () async {
    final stub = await _OffStub.start(<String, ({int status, String body})>{
      'de': (status: 200, body: _OffStub.leer),
      'world': (status: 502, body: '<html>bad gateway</html>'),
    });
    addTearDown(stub.close);

    await expectLater(
      suche(stub),
      throwsA(isA<HttpException>()),
      reason: 'nur so bleibt die Anfrage aus dem Leer-Cache des Sheets '
          'heraus — ein autoritatives [] merkt sich das Sheet fuer seine '
          'ganze Lebensdauer als bekannt leer',
    );
    await pumpe();

    expect(stub.gefragt, <String>['de', 'world']);
    expect(
      gemeldet,
      isEmpty,
      reason: 'ein 502 ist Netzrauschen und kein Vorfall — gemeldet wird nur '
          'Unerwartetes',
    );
  });

  test('Parse-Fehler bei de wird von einem leeren world nicht verdeckt',
      () async {
    // 2xx with a body that is not JSON — what a schema change or a slipped-in
    // error page actually looks like on the wire.
    final stub = await _OffStub.start(<String, ({int status, String body})>{
      'de': (status: 200, body: '<html>wartungsarbeiten</html>'),
      'world': (status: 200, body: _OffStub.leer),
    });
    addTearDown(stub.close);

    await expectLater(suche(stub), throwsA(isA<FormatException>()));
    await pumpe();

    expect(gemeldet, hasLength(1), reason: 'der Alarm muss feuern');
    expect(gemeldet.single, isA<SanitizedError>());
    expect('${gemeldet.single}', contains('FormatException'));
    expect(kontexte.single, 'product.search.fallback');
  });

  test('2xx ohne products-Liste meldet die Schema-Aenderung', () async {
    // No transport error at all: 200 with valid JSON that simply is not a
    // search response. Reading that as an empty hit list would invent an
    // answer nobody gave.
    final stub = await _OffStub.start(<String, ({int status, String body})>{
      'de': (status: 200, body: '{"ok":true}'),
      'world': (status: 200, body: '{"ok":true}'),
    });
    addTearDown(stub.close);

    await expectLater(suche(stub), throwsA(isA<FormatException>()));
    await pumpe();

    expect(gemeldet, hasLength(1));
    expect(kontexte.single, 'product.search.fallback');
  });

  test('beide Beine sauber leer bleiben ein stiller Nichttreffer', () async {
    // The counter-check against overcorrection: throwing here would tip every
    // genuine non-hit search into error behavior.
    final stub = await _OffStub.start(<String, ({int status, String body})>{
      'de': (status: 200, body: _OffStub.leer),
      'world': (status: 200, body: _OffStub.leer),
    });
    addTearDown(stub.close);

    expect(await suche(stub), isEmpty);
    await pumpe();

    expect(stub.gefragt, <String>['de', 'world']);
    expect(gemeldet, isEmpty);
  });
}
