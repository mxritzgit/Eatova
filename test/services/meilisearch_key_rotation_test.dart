import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/meilisearch_product_service.dart';
import 'package:eatova/src/services/search_credentials.dart';

// Der 403-Rotations-Pfad des Mirror-Clients gegen einen echten lokalen
// HttpServer (Muster aus eatova_http_test.dart: plain `test()`, damit
// dart:io unangetastet bleibt). Die Zugangsdaten kommen aus einem Fake-Seam
// — kein SharedPreferences, kein Supabase, keine Edge Function.

const String _hitsBody =
    '{"hits":[{"code":"111","product_name":"Salami",'
    '"nutriments":{"energy-kcal_100g":250}}]}';

const SearchCredentials _oldKey = SearchCredentials(
  baseUrl: '',
  searchKey: 'old-key',
  source: SearchCredentialsOrigin.cache,
);

const SearchCredentials _newKey = SearchCredentials(
  baseUrl: '',
  searchKey: 'new-key',
  source: SearchCredentialsOrigin.network,
);

class _FakeSource extends SearchCredentialsSource {
  _FakeSource(this.active, {this.replacement});

  SearchCredentials active;

  /// Was [invalidate] liefern soll. `null` steht fuer „kein Ersatz" und
  /// wird — wie im echten Store — zu unbrauchbaren Credentials.
  SearchCredentials? replacement;

  int resolveCalls = 0;
  int invalidateCalls = 0;
  final List<SearchCredentials> rejected = <SearchCredentials>[];

  @override
  Future<SearchCredentials> resolve() async {
    resolveCalls++;
    return active;
  }

  @override
  Future<SearchCredentials> invalidate(SearchCredentials credentials) async {
    invalidateCalls++;
    rejected.add(credentials);
    final next = replacement ?? SearchCredentials.disabled;
    active = next;
    return next;
  }
}

/// Mirror-Attrappe: spielt eine Statuscode-Folge ab und protokolliert den
/// Authorization-Header JEDES Requests.
class _MirrorStub {
  _MirrorStub._(this._server, this.auths, this.paths);

  final HttpServer _server;
  final List<String> auths;
  final List<String> paths;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';
  int get requestCount => auths.length;

  static Future<_MirrorStub> start(
    List<int> statuses, {
    String body200 = _hitsBody,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final auths = <String>[];
    final paths = <String>[];
    server.listen((request) async {
      auths.add(request.headers.value(HttpHeaders.authorizationHeader) ?? '');
      paths.add(request.uri.path);
      await utf8.decoder.bind(request).join();
      final index = auths.length - 1;
      final status = index < statuses.length ? statuses[index] : statuses.last;
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(status == 200 ? body200 : '{"message":"nein"}');
      await request.response.close();
    });
    return _MirrorStub._(server, auths, paths);
  }

  Future<void> close() => _server.close(force: true);
}

SearchCredentials _at(String baseUrl, SearchCredentials template) =>
    SearchCredentials(
      baseUrl: baseUrl,
      searchKey: template.searchKey,
      source: template.source,
    );

void main() {
  test(
      'Sentinel-Rest D: 2xx mit kaputtem Body (ohne hits) wirft statt eine '
      'leere Trefferliste zu erfinden', () async {
    // Ein 200 ohne `hits`-Liste (Proxy-Fehlerseite, Schema-Aenderung) hiess
    // frueher „wirklich keine Treffer": leere Liste, kein Report. Ehrlich
    // ist dieselbe Behandlung wie beim 5xx — werfen, der
    // FallbackProductService klassifiziert/meldet und zieht zu OFF weiter.
    // Eine ECHTE leere Antwort (`hits: []`) bleibt dagegen eine Antwort.
    //
    // Der Typ ist Teil der Zusicherung: eine HttpException waere eine
    // IOException und damit fuer den FallbackProductService ein erwarteter
    // Netzfehler — der Alarm bliebe still.
    final stub = await _MirrorStub.start(<int>[200], body200: '{"ok":true}');
    addTearDown(stub.close);
    final source = _FakeSource(_at(stub.baseUrl, _oldKey));

    await expectLater(
      MeilisearchProductService(credentials: source).searchProducts('salami'),
      throwsA(isA<MirrorSchemaException>()),
    );
  });

  test('403 -> invalidate -> Retry mit dem NEUEN Key -> Erfolg', () async {
    final stub = await _MirrorStub.start(<int>[403, 200]);
    addTearDown(stub.close);
    final source = _FakeSource(
      _at(stub.baseUrl, _oldKey),
      replacement: _at(stub.baseUrl, _newKey),
    );

    final results =
        await MeilisearchProductService(credentials: source)
            .searchProducts('salami');

    expect(results, hasLength(1));
    expect(results.single.title, 'Salami');
    expect(stub.requestCount, 2);
    // DIE zentrale Zusicherung: der zweite Versuch traegt den NEUEN Key.
    expect(stub.auths[0], 'Bearer old-key');
    expect(stub.auths[1], 'Bearer new-key');
    expect(stub.paths, everyElement('/indexes/products/search'));
    expect(source.invalidateCalls, 1);
    expect(source.rejected.single.searchKey, 'old-key');
  });

  test('401 verhaelt sich wie 403 (fehlender statt falscher Header)', () async {
    final stub = await _MirrorStub.start(<int>[401, 200]);
    addTearDown(stub.close);
    final source = _FakeSource(
      _at(stub.baseUrl, _oldKey),
      replacement: _at(stub.baseUrl, _newKey),
    );

    final results =
        await MeilisearchProductService(credentials: source)
            .searchProducts('salami');

    expect(results, hasLength(1));
    expect(stub.requestCount, 2);
    expect(stub.auths[1], 'Bearer new-key');
    expect(source.invalidateCalls, 1);
  });

  test('kein Ersatz-Key -> wirft, Server sah GENAU EINEN Request', () async {
    final stub = await _MirrorStub.start(<int>[403]);
    addTearDown(stub.close);
    // replacement null -> SearchCredentials.disabled (unbrauchbar).
    final source = _FakeSource(_at(stub.baseUrl, _oldKey));

    await expectLater(
      MeilisearchProductService(credentials: source).searchProducts('salami'),
      throwsA(isA<Exception>()),
    );

    expect(stub.requestCount, 1, reason: 'kein sinnloser Retry');
    expect(source.invalidateCalls, 1);
  });

  test('invalidate liefert DENSELBEN Key -> kein zweiter Request', () async {
    final stub = await _MirrorStub.start(<int>[403]);
    addTearDown(stub.close);
    final source = _FakeSource(
      _at(stub.baseUrl, _oldKey),
      // Gleicher Key (z.B. Cooldown greift) -> ein Retry waere garantiert
      // wieder 403.
      replacement: _at(stub.baseUrl, _oldKey),
    );

    await expectLater(
      MeilisearchProductService(credentials: source).searchProducts('salami'),
      throwsA(isA<Exception>()),
    );

    expect(stub.requestCount, 1);
    expect(source.invalidateCalls, 1);
  });

  test('hoechstens EIN Retry — der zweite 403 fliegt raus', () async {
    final stub = await _MirrorStub.start(<int>[403, 403]);
    addTearDown(stub.close);
    final source = _FakeSource(
      _at(stub.baseUrl, _oldKey),
      replacement: _at(stub.baseUrl, _newKey),
    );

    await expectLater(
      MeilisearchProductService(credentials: source).searchProducts('salami'),
      throwsA(isA<Exception>()),
    );

    expect(stub.requestCount, 2, reason: '_searchOnce rekursiert nie');
    expect(source.invalidateCalls, 1, reason: 'keine zweite Invalidierung');
  });

  test('unbrauchbare Credentials -> NULL HTTP-Requests', () async {
    final stub = await _MirrorStub.start(<int>[200]);
    addTearDown(stub.close);
    final source = _FakeSource(SearchCredentials.disabled);

    await expectLater(
      MeilisearchProductService(credentials: source).searchProducts('salami'),
      throwsA(isA<HttpException>()),
    );

    expect(stub.requestCount, 0, reason: 'Mirror aus -> direkt zu OFF');
    expect(source.invalidateCalls, 0);
  });

  test('5xx ist KEIN Rotations-Signal', () async {
    final stub = await _MirrorStub.start(<int>[500]);
    addTearDown(stub.close);
    final source = _FakeSource(
      _at(stub.baseUrl, _oldKey),
      replacement: _at(stub.baseUrl, _newKey),
    );

    await expectLater(
      MeilisearchProductService(credentials: source).searchProducts('salami'),
      throwsA(isA<HttpException>()),
    );

    expect(stub.requestCount, 1);
    expect(
      source.invalidateCalls,
      0,
      reason: 'ein Server-Wackler darf keinen gueltigen Key wegwerfen',
    );
  });

  test('Happy Path bleibt unveraendert', () async {
    final stub = await _MirrorStub.start(<int>[200]);
    addTearDown(stub.close);
    final source = _FakeSource(_at(stub.baseUrl, _oldKey));

    final results =
        await MeilisearchProductService(credentials: source)
            .searchProducts('salami');

    expect(results, hasLength(1));
    expect(results.single.kcalPer100G, 250);
    expect(stub.requestCount, 1);
    expect(stub.auths.single, 'Bearer old-key');
    expect(source.invalidateCalls, 0);
    expect(source.resolveCalls, 1);
  });

  test('zu kurze Query fragt weder Credentials noch Server', () async {
    final stub = await _MirrorStub.start(<int>[200]);
    addTearDown(stub.close);
    final source = _FakeSource(_at(stub.baseUrl, _oldKey));

    expect(
      await MeilisearchProductService(credentials: source).searchProducts('a'),
      isEmpty,
    );
    expect(stub.requestCount, 0);
    expect(source.resolveCalls, 0);
  });
}
