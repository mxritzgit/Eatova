// When is "nothing found" an answer, and when is it a lie?
//
// `OpenFoodFactsProductService.searchProducts` walks `de`, then `world`.
// P10-07 let ONE cleanly empty leg speak for the whole chain
// (`cleanlyEmpty || lastError == null`). Review 2026-08-31 (finding G)
// narrowed that: empty counts only when EVERY leg walked answered. A leg that
// failed leaves its catalog unknown, and unknown is not empty — the add sheet
// caches an authoritative `[]` as "known empty" for its whole lifetime, and
// the schema alarm in FallbackProductService only ever sees what is thrown.
//
// A leg that times out on the chain budget leaves the answer unknown as well
// (produktsuche_gesamtfrist_test.dart).
//
// Real loopback servers, real bytes: the whole point is the interplay of
// status code, JSON body and the loop's bookkeeping, which a Dart map fake
// would step right over.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/fallback_product_service.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';

/// Two search endpoints on one loopback server: `/de/cgi/search.pl` and
/// `/world/cgi/search.pl`, each with its own scripted status plus body.
class _SuchStub {
  _SuchStub._(this._server, this._antworten);

  final HttpServer _server;
  final Map<String, ({int status, String body})> _antworten;

  /// Which endpoint was asked, in order — the evidence that a leg ran at all.
  final List<String> gefragt = <String>[];

  static const String leer = '{"count":0,"products":[]}';
  static const String einTreffer =
      '{"count":1,"products":[{"code":"4000000000001",'
      '"product_name":"Eiweissbrot","brands":"Testmarke",'
      '"nutrition_data_per":"100g",'
      '"nutriments":{"energy-kcal_100g":240}}]}';

  static Future<_SuchStub> start(
    Map<String, ({int status, String body})> antworten,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final stub = _SuchStub._(server, antworten);
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
/// no hit — so the production chain moves on to OFF without a report of its
/// own.
class _LeererSpiegel implements ProductLookupService {
  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) =>
      throw UnsupportedError('Der Spiegel kennt keine Barcodes.');
}

void main() {
  test(
    'leeres de plus 502 bei world ist KEIN "nichts gefunden"',
    () async {
      final stub = await _SuchStub.start(<String, ({int status, String body})>{
        'de': (status: 200, body: _SuchStub.leer),
        'world': (status: 502, body: '<html>bad gateway</html>'),
      });
      addTearDown(stub.close);

      await expectLater(
        OpenFoodFactsProductService(
          searchBaseUrls: stub.searchBaseUrls,
        ).searchProducts('bauernmozzarella'),
        throwsA(isA<HttpException>()),
        reason: 'de kennt nur den deutschen Katalog — solange world schweigt, '
            'ist "gibt es nicht" eine Behauptung ueber einen Katalog, den '
            'niemand gelesen hat',
      );
      expect(stub.gefragt, <String>['de', 'world']);
    },
  );

  test('502 bei de plus leeres world ist ebenfalls kein "nichts gefunden"',
      () async {
    // The same rule the other way round: one clean answer does not heal the
    // leg next to it. The service only knows an ordered list of endpoints, not
    // a promise that the last one covers the first one's catalog.
    final stub = await _SuchStub.start(<String, ({int status, String body})>{
      'de': (status: 502, body: '<html>bad gateway</html>'),
      'world': (status: 200, body: _SuchStub.leer),
    });
    addTearDown(stub.close);

    await expectLater(
      OpenFoodFactsProductService(
        searchBaseUrls: stub.searchBaseUrls,
      ).searchProducts('bauernmozzarella'),
      throwsA(isA<HttpException>()),
    );
    expect(stub.gefragt, <String>['de', 'world']);
  });

  test('beide Beine sauber leer -> [] ohne Wurf', () async {
    // The counter-check against overcorrection: a genuine non-hit is the
    // search's normal outcome and must never come back as an error.
    final stub = await _SuchStub.start(<String, ({int status, String body})>{
      'de': (status: 200, body: _SuchStub.leer),
      'world': (status: 200, body: _SuchStub.leer),
    });
    addTearDown(stub.close);

    final treffer = await OpenFoodFactsProductService(
      searchBaseUrls: stub.searchBaseUrls,
    ).searchProducts('bauernmozzarella');

    expect(treffer, isEmpty);
    expect(stub.gefragt, <String>['de', 'world']);
  });

  test('kein Endpunkt antwortet sauber -> der Fehler bleibt ein Fehler',
      () async {
    final stub = await _SuchStub.start(<String, ({int status, String body})>{
      'de': (status: 500, body: 'boom'),
      'world': (status: 502, body: 'boom'),
    });
    addTearDown(stub.close);

    await expectLater(
      OpenFoodFactsProductService(
        searchBaseUrls: stub.searchBaseUrls,
      ).searchProducts('bauernmozzarella'),
      throwsA(isA<HttpException>()),
      reason: 'ohne saubere Antwort ist "nichts gefunden" eine Luege',
    );
  });

  test('200 ohne products-Liste ist keine Auskunft — der Fehler gewinnt',
      () async {
    // Die Gegenprobe zur ersten Behauptung: ein 2xx ohne Produktliste ist eine
    // Proxy-Fehlerseite oder ein Schema-Bruch, kein "nichts gefunden".
    final stub = await _SuchStub.start(<String, ({int status, String body})>{
      'de': (status: 200, body: '{"ok":true}'),
      'world': (status: 502, body: 'boom'),
    });
    addTearDown(stub.close);

    await expectLater(
      OpenFoodFactsProductService(
        searchBaseUrls: stub.searchBaseUrls,
      ).searchProducts('bauernmozzarella'),
      throwsA(isA<HttpException>()),
    );
    expect(stub.gefragt, <String>['de', 'world'],
        reason: 'der kaputte Endpunkt haelt den naechsten trotzdem nicht auf');
  });

  test('Treffer bei de laesst world unangetastet', () async {
    final stub = await _SuchStub.start(<String, ({int status, String body})>{
      'de': (status: 200, body: _SuchStub.einTreffer),
      'world': (status: 502, body: 'boom'),
    });
    addTearDown(stub.close);

    final treffer = await OpenFoodFactsProductService(
      searchBaseUrls: stub.searchBaseUrls,
    ).searchProducts('eiweissbrot');

    expect(treffer.single.code, '4000000000001');
    expect(stub.gefragt, <String>['de']);
  });

  // In the production wiring `FallbackProductService(mirror, OFF)` a parse
  // error on one OFF leg must reach the CrashReporter: hidden behind an empty
  // answer from the other leg, the schema alarm never heard of it.
  group('Schema-Alarm hinter einem leeren Bein', () {
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

    Future<List<ProductSearchResult>> suche(_SuchStub stub) =>
        FallbackProductService(
          _LeererSpiegel(),
          OpenFoodFactsProductService(searchBaseUrls: stub.searchBaseUrls),
        ).searchProducts('bauernmozzarella');

    test('Parse-Fehler bei de wird von einem leeren world nicht verdeckt',
        () async {
      // 2xx with a body that is not JSON — what a schema change or a
      // slipped-in error page looks like on the wire.
      final stub = await _SuchStub.start(<String, ({int status, String body})>{
        'de': (status: 200, body: '<html>wartungsarbeiten</html>'),
        'world': (status: 200, body: _SuchStub.leer),
      });
      addTearDown(stub.close);

      await expectLater(suche(stub), throwsA(isA<FormatException>()));
      await Future<void>.delayed(Duration.zero);

      expect(gemeldet, hasLength(1), reason: 'der Alarm muss feuern');
      expect(gemeldet.single, isA<SanitizedError>());
      expect(kontexte.single, 'product.search.fallback');
    });

    test('2xx ohne products-Liste auf beiden Beinen meldet die '
        'Schema-Aenderung', () async {
      // Valid JSON that simply is not a search response: reading it as an
      // empty hit list would invent an answer nobody gave.
      final stub = await _SuchStub.start(<String, ({int status, String body})>{
        'de': (status: 200, body: '{"ok":true}'),
        'world': (status: 200, body: '{"ok":true}'),
      });
      addTearDown(stub.close);

      await expectLater(suche(stub), throwsA(isA<FormatException>()));
      await Future<void>.delayed(Duration.zero);

      expect(gemeldet, hasLength(1));
      expect(kontexte.single, 'product.search.fallback');
    });
  });
}
