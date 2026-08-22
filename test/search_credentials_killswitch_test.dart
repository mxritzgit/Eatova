// Server kill switch of the product search (audit 2026-08-14).
//
// With `EATOVA_MIRROR_SEARCH_KEY` set to 'disabled' the edge function answers
// HTTP 200 with BOTH fields empty. That answer used to be inert: the empty URL
// failed the https requirement, the fetcher returned `null`, and `null` means
// "keep what you have" — so a possibly leaked key stayed on every device.
//
// Hence the REAL HTTP path over a loopback server, not a fake fetcher: the bug
// sat in the fetcher (search_credentials_test.dart covers the store side).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/search_credentials.dart';

/// The assumed-leaked key — it must not survive the kill switch anywhere.
const String _abgeflossenerKey = 'abgeflossener-key';
const String _alteBasisUrl = 'https://alt.example/meili';

class _KeyServer {
  _KeyServer._(this._server, this.baseUrl);

  final HttpServer _server;

  /// Captured once at bind time, NOT as a getter over `_server.port`: the
  /// tests need the (then dead) address after [close], and `port` throws on a
  /// closed server.
  final String baseUrl;

  bool _closed = false;
  Object? body;

  static Future<_KeyServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ks = _KeyServer._(server, 'http://127.0.0.1:${server.port}');
    server.listen((request) async {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(ks.body));
      await request.response.close();
    });
    return ks;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close(force: true);
  }
}

/// Function response shape — field names and `ttlSeconds` exactly as in
/// supabase/functions/search-key/index.ts.
Map<String, dynamic> _antwort({
  required String mirrorBaseUrl,
  required String searchKey,
}) => <String, dynamic>{
  'mirrorBaseUrl': mirrorBaseUrl,
  'searchKey': searchKey,
  'ttlSeconds': 43200,
  'requestId': 'test-request',
};

String _cacheEintrag(DateTime fetchedAt) => jsonEncode(<String, Object>{
  'base_url': _alteBasisUrl,
  'key': _abgeflossenerKey,
  'fetched_at': fetchedAt.toIso8601String(),
  'ttl_seconds': 43200,
});

void main() {
  late _KeyServer server;
  late InMemoryKeyValueStore disk;
  late DateTime jetzt;

  setUp(() async {
    server = await _KeyServer.start();
    jetzt = DateTime.utc(2026, 8, 14, 12);
    // Expired so that `warmUp` hits the network at all; the entry stays in use
    // until then.
    disk = InMemoryKeyValueStore(<String, String>{
      SearchCredentialsStore.cacheKey:
          _cacheEintrag(jetzt.subtract(const Duration(days: 8))),
    });
  });

  tearDown(() => server.close());

  SearchCredentialsStore storeGegen(String edgeBaseUrl) =>
      SearchCredentialsStore(
        store: disk,
        fetcher: EdgeFunctionSearchKeyFetcher(
          baseUrl: edgeBaseUrl,
          anonKey: 'anon-key-test',
          tokenProvider: () => 'jwt-abc',
        ),
        clock: () => jetzt,
      );

  String persistiert() => disk.snapshot.values.join('\n');

  test('Kill-Switch (beide Felder leer) verwirft den Key aus Speicher UND '
      'von der Platte', () async {
    server.body = _antwort(mirrorBaseUrl: '', searchKey: '');
    final store = storeGegen(server.baseUrl);

    await store.warmUp();

    expect(store.current.isUsable, isFalse);
    expect(store.current.source, SearchCredentialsOrigin.disabled);
    expect(
      persistiert(),
      isNot(contains(_abgeflossenerKey)),
      reason: 'Bleibt der Key in SharedPreferences liegen, ist der Hebel '
          'wertlos: der naechste Start sucht wieder mit ihm.',
    );

    // Cold start on the same disk, no reachable network. `isUsable`, not just
    // "no longer the old key": the disabled state must SURVIVE the restart. If
    // the empty/empty entry failed to parse, the compile-time default would
    // kick in — carrying a baked-in key, possibly the leaked one.
    await server.close();
    final nachNeustart = storeGegen(server.baseUrl);
    await nachNeustart.warmUp();

    expect(nachNeustart.current.searchKey, isNot(_abgeflossenerKey));
    expect(nachNeustart.current.isUsable, isFalse);
    expect(nachNeustart.current.source, SearchCredentialsOrigin.disabled);
    expect(persistiert(), isNot(contains(_abgeflossenerKey)));
  });

  test('halb leere Antwort ist ein kaputter Server, kein Kill-Switch — der '
      'Bestand bleibt', () async {
    for (final halb in <Map<String, dynamic>>[
      _antwort(mirrorBaseUrl: 'https://mirror.example', searchKey: ''),
      _antwort(mirrorBaseUrl: '', searchKey: 'nur-der-key'),
    ]) {
      disk = InMemoryKeyValueStore(<String, String>{
        SearchCredentialsStore.cacheKey:
            _cacheEintrag(jetzt.subtract(const Duration(days: 8))),
      });
      server.body = halb;
      final store = storeGegen(server.baseUrl);

      await store.warmUp();

      expect(store.current.searchKey, _abgeflossenerKey, reason: '$halb');
      expect(store.current.baseUrl, _alteBasisUrl, reason: '$halb');
      expect(store.current.source, SearchCredentialsOrigin.cache);
      expect(persistiert(), contains(_abgeflossenerKey), reason: '$halb');
    }
  });

  test('Netzfehler laesst den Bestand unangetastet — „null heisst behalten" '
      'gilt weiter', () async {
    await server.close();
    final store = storeGegen(server.baseUrl);

    await store.warmUp();

    expect(store.current.searchKey, _abgeflossenerKey);
    expect(store.current.source, SearchCredentialsOrigin.cache);
    expect(persistiert(), contains(_abgeflossenerKey));
  });

  test('vollstaendige, aber http-Antwort bleibt verworfen — der https-Zwang '
      'gilt nur nicht mehr fuer die LEERE URL', () async {
    server.body = _antwort(
      mirrorBaseUrl: 'http://mirror.example',
      searchKey: 'frischer-key',
    );
    final store = storeGegen(server.baseUrl);

    await store.warmUp();

    expect(store.current.searchKey, _abgeflossenerKey,
        reason: 'ein http-Mirror truege den Search-Key im Klartext raus');
    expect(persistiert(), isNot(contains('frischer-key')));
  });
}
