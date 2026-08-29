// P10-07 — a clean empty answer must not be overwritten by a later error.
//
// `OpenFoodFactsProductService.searchProducts` walks `de` and then `world`.
// `lastError` used to live OUTSIDE that loop, so an empty (but perfectly
// valid) `de` answer followed by a 502 from `world` threw: the user got an
// error message instead of the empty view with the "add manually" offer — and
// the error dragged the sheet's three retries along with it.
//
// Real loopback servers, real bytes: the whole point is the interplay of
// status code, JSON body and the loop's bookkeeping, which a Dart map fake
// would step right over.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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

void main() {
  test(
    'leeres de plus 502 bei world ergibt "nichts gefunden", keinen Fehler',
    () async {
      final stub = await _SuchStub.start(<String, ({int status, String body})>{
        'de': (status: 200, body: _SuchStub.leer),
        'world': (status: 502, body: '<html>bad gateway</html>'),
      });
      addTearDown(stub.close);

      final treffer = await OpenFoodFactsProductService(
        searchBaseUrls: stub.searchBaseUrls,
      ).searchProducts('bauernmozzarella');

      expect(
        treffer,
        isEmpty,
        reason: 'de hat sauber geantwortet — das ist eine Auskunft, '
            'kein Fehler',
      );
      expect(stub.gefragt, <String>['de', 'world']);
    },
  );

  test('502 bei de plus leeres world ergibt ebenfalls "nichts gefunden"',
      () async {
    final stub = await _SuchStub.start(<String, ({int status, String body})>{
      'de': (status: 502, body: '<html>bad gateway</html>'),
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
}
