// P10-02, Dienst-Ebene — jede Etappe hatte ihre eigene Frist, die KETTE hatte
// keine.
//
// Alte Rechnung pro Versuch: Mirror 16 s + `invalidate` 3 s + Mirror-Retry
// 16 s + OFF-de 32 s + OFF-world 32 s = 99 s. Jede einzelne Etappe lag dabei
// brav in ihrem Limit — genau deshalb faellt so etwas ohne diesen Test nicht
// auf.
//
// Die Server hier ANTWORTEN NIE. Das ist der Punkt: nur eine Kette, in der
// jede Etappe haengt, zeigt, ob es eine Obergrenze ueber die Kette gibt. Die
// Budgets sind als Konstruktor-Parameter auf Millisekunden gesetzt, damit der
// Test in einer Sekunde laeuft statt in einer Minute; die Produktionswerte
// stehen weiter unten in einem eigenen Fall.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/eatova_http.dart';
import 'package:eatova/src/services/fallback_product_service.dart';
import 'package:eatova/src/services/meilisearch_product_service.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/services/search_credentials.dart';

const Duration _winziges = Duration(milliseconds: 300);

/// Nimmt jede Anfrage an und antwortet nie — die haengende Etappe.
class _StummerServer {
  _StummerServer._(this._server);

  final HttpServer _server;
  final List<HttpRequest> offen = <HttpRequest>[];

  static Future<_StummerServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final stub = _StummerServer._(server);
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      // Bewusst kein `response.close()`: der Aufrufer wartet.
      stub.offen.add(request);
    });
    return stub;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}';
  List<String> get searchBaseUrls => <String>['$baseUrl/cgi/search.pl'];

  Future<void> close() => _server.close(force: true);
}

/// Antwortet auf `/de/...` sofort und laesst `/world/...` haengen.
class _LeeresDeStummesWorld {
  _LeeresDeStummesWorld._(this._server);

  final HttpServer _server;
  final List<String> gefragt = <String>[];

  static Future<_LeeresDeStummesWorld> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final stub = _LeeresDeStummesWorld._(server);
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      final zweig = request.uri.pathSegments.first;
      stub.gefragt.add(zweig);
      if (zweig != 'de') return; // world haengt
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('{"count":0,"products":[]}');
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

/// Immer 403 (Rotations-Signal), und `invalidate` antwortet nie — das Loch in
/// der Mirror-Kette.
class _NieAntwortendeCredentials extends SearchCredentialsSource {
  _NieAntwortendeCredentials(this.active);

  final SearchCredentials active;
  int invalidateCalls = 0;

  @override
  Future<SearchCredentials> resolve() async => active;

  @override
  Future<SearchCredentials> invalidate(SearchCredentials rejected) {
    invalidateCalls++;
    return Completer<SearchCredentials>().future;
  }
}

/// Antwortet nie — als reiner Dart-Dienst, damit `fakeAsync` die Uhr stellen
/// kann (echte Sockets kann es nicht).
class _HaengenderDienst implements ProductLookupService {
  int aufrufe = 0;

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) =>
      Completer<MealAnalysisResult>().future;

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) {
    aufrufe++;
    return Completer<List<ProductSearchResult>>().future;
  }
}

void main() {
  group('ChainDeadline', () {
    test('gibt eine haengende Etappe nach dem Budget frei', () {
      fakeAsync((async) {
        Object? fehler;
        final deadline = ChainDeadline(
          const Duration(seconds: 5),
          operation: 'test.chain',
        );
        unawaited(deadline.guard(Completer<int>().future).then<void>(
          (_) {},
          onError: (Object e) => fehler = e,
        ));

        async.elapse(const Duration(seconds: 4));
        expect(fehler, isNull);
        expect(deadline.isExpired, isFalse);

        async.elapse(const Duration(seconds: 2));
        expect(fehler, isA<TimeoutException>());
        expect(deadline.isExpired, isTrue);
        deadline.dispose();
      });
    });

    test('eine abgelaufene Frist laesst keine Etappe mehr warten', () {
      fakeAsync((async) {
        final deadline = ChainDeadline(
          const Duration(seconds: 1),
          operation: 'test.chain',
        );
        async.elapse(const Duration(seconds: 2));

        Object? fehler;
        unawaited(deadline.guard(Completer<int>().future).then<void>(
          (_) {},
          onError: (Object e) => fehler = e,
        ));
        async.flushMicrotasks();

        expect(
          fehler,
          isA<TimeoutException>(),
          reason: 'sofort, ohne einen weiteren Tick zu warten',
        );
        deadline.dispose();
      });
    });

    test('dispose vor Ablauf laesst die Etappe in Ruhe zu Ende laufen', () {
      fakeAsync((async) {
        final deadline = ChainDeadline(
          const Duration(seconds: 1),
          operation: 'test.chain',
        );
        final completer = Completer<int>();
        int? ergebnis;
        Object? fehler;
        unawaited(deadline.guard(completer.future).then<void>(
          (v) => ergebnis = v,
          onError: (Object e) => fehler = e,
        ));

        deadline.dispose();
        async.elapse(const Duration(seconds: 10));
        completer.complete(7);
        async.flushMicrotasks();

        expect(fehler, isNull);
        expect(ergebnis, 7);
      });
    });
  });

  group('Mirror-Kette', () {
    test('403 plus haengendes invalidate endet am Ketten-Budget', () async {
      final server = await _StummerServer.start();
      addTearDown(server.close);
      // 403 auf alles: der Rotationspfad, der danach im `invalidate` haengt.
      final antworter = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => antworter.close(force: true));
      antworter.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.statusCode = 403;
        await request.response.close();
      });
      final creds = _NieAntwortendeCredentials(
        SearchCredentials(
          baseUrl: 'http://127.0.0.1:${antworter.port}',
          searchKey: 'search-key',
          source: SearchCredentialsOrigin.cache,
        ),
      );

      final uhr = Stopwatch()..start();
      await expectLater(
        MeilisearchProductService(
          credentials: creds,
          searchChainBudget: _winziges,
        ).searchProducts('salami'),
        throwsA(isA<TimeoutException>()),
      );
      uhr.stop();

      expect(creds.invalidateCalls, 1);
      expect(uhr.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'die Kette endet am Budget, nicht an den Phasen-Timeouts');
    });

    test('stummer Mirror endet am Ketten-Budget, nicht am Phasen-Timeout',
        () async {
      final server = await _StummerServer.start();
      addTearDown(server.close);
      final creds = _NieAntwortendeCredentials(
        SearchCredentials(
          baseUrl: server.baseUrl,
          searchKey: 'search-key',
          source: SearchCredentialsOrigin.cache,
        ),
      );

      final uhr = Stopwatch()..start();
      await expectLater(
        MeilisearchProductService(
          credentials: creds,
          searchChainBudget: _winziges,
        ).searchProducts('salami'),
        throwsA(isA<TimeoutException>()),
      );
      uhr.stop();

      // Das Antwort-Phasen-Timeout des Mirrors liegt bei 6 s.
      expect(uhr.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('OFF-Kette', () {
    test('stumme Endpunkte enden am Ketten-Budget', () async {
      final server = await _StummerServer.start();
      addTearDown(server.close);

      final uhr = Stopwatch()..start();
      await expectLater(
        OpenFoodFactsProductService(
          searchBaseUrls: server.searchBaseUrls,
          searchChainBudget: _winziges,
        ).searchProducts('salami'),
        throwsA(isA<TimeoutException>()),
      );
      uhr.stop();

      expect(uhr.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'sonst waeren es 12 s Antwort-Phase je Endpunkt');
    });

    test('sauber leeres de ueberlebt ein haengendes world', () async {
      // P10-02 und P10-07 zusammen: die Frist laeuft im zweiten Endpunkt ab,
      // aber der erste hat sauber geantwortet — das bleibt "nichts gefunden".
      final stub = await _LeeresDeStummesWorld.start();
      addTearDown(stub.close);

      final treffer = await OpenFoodFactsProductService(
        searchBaseUrls: stub.searchBaseUrls,
        searchChainBudget: _winziges,
      ).searchProducts('bauernmozzarella');

      expect(treffer, isEmpty);
      expect(stub.gefragt, <String>['de', 'world']);
    });
  });

  group('Fallback-Kette', () {
    test('beide Beine haengen -> Abbruch am Budget statt nie', () {
      fakeAsync((async) {
        final primaer = _HaengenderDienst();
        final zweit = _HaengenderDienst();
        Object? fehler;
        unawaited(FallbackProductService(primaer, zweit)
            .searchProducts('milch')
            .then<void>((_) {}, onError: (Object e) => fehler = e));

        async.elapse(FallbackProductService.defaultSearchChainBudget -
            const Duration(seconds: 1));
        expect(fehler, isNull);

        async.elapse(const Duration(seconds: 2));
        expect(fehler, isA<TimeoutException>());
        expect(primaer.aufrufe, 1);
        expect(zweit.aufrufe, 0,
            reason: 'das erste Bein haengt noch — es gibt kein zweites');
      });
    });
  });

  test('die abgestimmten Ketten-Budgets stehen fest', () {
    // Die Zahlen der Zeitrechnung: jede Ebene deckelt die SUMME der Ebene
    // darunter, statt sie sich addieren zu lassen.
    expect(MeilisearchProductService.defaultSearchChainBudget,
        const Duration(seconds: 12));
    expect(OpenFoodFactsProductService.defaultSearchChainBudget,
        const Duration(seconds: 24));
    expect(FallbackProductService.defaultSearchChainBudget,
        const Duration(seconds: 30));
  });
}
