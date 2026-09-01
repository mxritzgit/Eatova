import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/meilisearch_product_service.dart';
import 'package:eatova/src/services/search_credentials.dart';

// The mirror client's 403 rotation path against a real local HttpServer (plain
// `test()`, so dart:io stays untouched). Credentials come from a fake seam —
// no SharedPreferences, no Supabase, no Edge Function.

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

  /// What [invalidate] should return. `null` means "no replacement" and
  /// becomes unusable credentials, as in the real store.
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

/// Mirror stub: replays a status-code sequence and records the Authorization
/// header of EVERY request.
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
    // A 200 without a `hits` list (proxy error page, schema change) used to
    // mean "really no hits". The honest treatment is the 5xx one: throw, let
    // FallbackProductService classify/report and move on to OFF. A genuine
    // empty answer (`hits: []`) stays an answer.
    //
    // The type is part of the assurance: an HttpException would be an
    // IOException and therefore an expected network error for
    // FallbackProductService — the alarm would stay silent.
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
    // The central assurance: the second attempt carries the NEW key.
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
    // replacement null -> SearchCredentials.disabled (unusable).
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
      // Same key (e.g. cooldown active) -> a retry would be 403 again.
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

  test('Barcodes gehen NIE an den Spiegel — kein Request, kein Ergebnis',
      () async {
    // The index is a DE/AT/CH dump; a brand-new product is missing from it
    // while the OFF live API knows it. If the mirror ever answered barcodes
    // itself — for instance by running the code through its own text search —
    // the scanner would report "unknown" for exactly those products, and a
    // stale mirror row would silently beat the live record.
    //
    // Asserted on the wire, not on the exception type: a mutation that swaps
    // the throw for a text search on the barcode still throws (nothing found),
    // but it leaves a request behind.
    final stub = await _MirrorStub.start(<int>[200]);
    addTearDown(stub.close);
    final source = _FakeSource(_at(stub.baseUrl, _oldKey));

    // `() =>`, not the bare call: the service throws SYNCHRONOUSLY instead of
    // returning a failed Future. FallbackProductService awaits inside a `try`,
    // so both forms are caught there — but the matcher has to match the form.
    expect(
      () => MeilisearchProductService(credentials: source).lookupBarcode(
        '4104420030008',
      ),
      throwsUnsupportedError,
      reason: 'FallbackProductService stuft genau UnsupportedError als '
          'erwartet ein und faellt still auf die OFF-Live-API zurueck',
    );
    // Nothing may have been kicked off asynchronously either.
    await Future<void>.delayed(Duration.zero);
    expect(stub.requestCount, 0, reason: 'der Spiegel darf nicht befragt '
        'werden');
    expect(source.resolveCalls, 0);
  });
}
