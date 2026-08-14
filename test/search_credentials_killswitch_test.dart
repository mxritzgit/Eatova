// Der Server-Kill-Switch der Produktsuche (Audit 2026-08-14).
//
// Steht `EATOVA_MIRROR_SEARCH_KEY` auf 'disabled', antwortet die Edge
// Function mit HTTP 200 und BEIDEN Feldern leer. Genau diese Antwort blieb im
// Client wirkungslos: die leere URL scheiterte am https-Zwang,
// `EdgeFunctionSearchKeyFetcher._fetch()` gab `null` zurueck — und `null`
// heisst per Vertrag „behalte, was du hast". Der (moeglicherweise
// abgeflossene) Key blieb in SharedPreferences liegen, jedes installierte
// Geraet suchte weiter, waehrend das Function-Log „disabled" meldete.
//
// Deshalb laeuft hier der ECHTE HTTP-Pfad ueber einen Loopback-Server, nicht
// ein eingesteckter Fake-Fetcher: der Fehler sass im Fetcher, ein Fake haette
// ihn uebersprungen (test/services/search_credentials_test.dart deckt die
// Store-Seite mit einem Fake ab).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/search_credentials.dart';

/// Der Key, der laut Annahme abgeflossen ist — er darf den Kill-Switch
/// nirgends ueberleben.
const String _abgeflossenerKey = 'abgeflossener-key';
const String _alteBasisUrl = 'https://alt.example/meili';

class _KeyServer {
  _KeyServer._(this._server, this.baseUrl);

  final HttpServer _server;

  /// Einmal beim Binden festgehalten, NICHT als Getter ueber `_server.port`:
  /// die Tests brauchen die (dann tote) Adresse gerade NACH [close], und
  /// `port` wirft auf einem geschlossenen Server.
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

/// Antwort der Function im Kill-Switch-Fall — Feldnamen und `ttlSeconds`
/// genau wie in supabase/functions/search-key/index.ts.
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
    // Abgelaufen, damit `warmUp` ueberhaupt ans Netz geht — der Eintrag
    // bleibt bis dahin trotzdem in Benutzung.
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

    // Kaltstart auf derselben Platte, ohne erreichbares Netz. `isUsable`
    // statt nur „nicht mehr der alte Key": der abgeschaltete Zustand muss den
    // Neustart selbst UEBERLEBEN. Faellt der Leer/Leer-Eintrag beim Parsen
    // durch, greift naemlich der Compile-Time-Default — und der traegt einen
    // einkompilierten Meilisearch-Key, womoeglich genau den abgeflossenen.
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
