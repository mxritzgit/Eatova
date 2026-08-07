import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/search_credentials.dart';

// Laufzeit-Aufloesung der Mirror-Zugangsdaten (Cache -> Fetch ->
// Compile-Time-Default -> aus). Bewusst plain `test()` mit
// InMemoryKeyValueStore + Fake-Fetcher + steuerbarer Uhr: kein
// Plugin-Channel, kein Supabase, keine echten Wartezeiten.

class _FakeFetcher implements SearchKeyFetcher {
  _FakeFetcher({this.result, this.explodes = false});

  FetchedSearchCredentials? result;
  bool explodes;

  /// Blockiert [fetch], bis der Completer erfuellt ist — so laesst sich
  /// „waehrend das Netz noch haengt" deterministisch pruefen.
  Completer<void>? gate;

  int calls = 0;
  final List<Duration?> budgets = <Duration?>[];

  @override
  Future<FetchedSearchCredentials?> fetch({Duration? budget}) async {
    calls++;
    budgets.add(budget);
    final open = gate;
    if (open != null) await open.future;
    if (explodes) throw StateError('fetcher exploded');
    return result;
  }
}

/// Platte, die nie antwortet — fuer den Ablauf der Hydrations-Gnadenfrist.
class _HangingStore implements KeyValueStore {
  @override
  Future<String?> getString(String key) => Completer<String?>().future;

  @override
  Future<void> setString(String key, String value) async {}

  @override
  Future<void> remove(String key) async {}
}

class _Clock {
  DateTime value = DateTime.utc(2026, 8, 7, 12);

  DateTime call() => value;

  void advance(Duration by) => value = value.add(by);
}

FetchedSearchCredentials _fetched(
  String key, {
  String baseUrl = 'https://fresh.example/meili',
  Duration ttl = const Duration(hours: 12),
}) => FetchedSearchCredentials(baseUrl: baseUrl, searchKey: key, ttl: ttl);

String _entry({
  required DateTime fetchedAt,
  String baseUrl = 'https://cached.example/meili',
  String key = 'cached-key',
  int ttlSeconds = 43200,
}) => jsonEncode(<String, Object>{
  'base_url': baseUrl,
  'key': key,
  'fetched_at': fetchedAt.toIso8601String(),
  'ttl_seconds': ttlSeconds,
});

Map<String, dynamic> _persisted(InMemoryKeyValueStore disk) =>
    jsonDecode(disk.snapshot[SearchCredentialsStore.cacheKey]!)
        as Map<String, dynamic>;

/// Laesst alle bereits eingeplanten Microtasks durchlaufen, damit
/// Reihenfolge-Assertions nicht an der Fortsetzungs-Reihenfolge haengen.
Future<void> _drain() => Future<void>.delayed(Duration.zero);

void main() {
  test('frischer Install ohne Netz -> Compile-Time-Default, kein Crash', () async {
    final disk = InMemoryKeyValueStore();
    final fetcher = _FakeFetcher(); // liefert null = "nichts geholt"
    final store = SearchCredentialsStore(
      store: disk,
      fetcher: fetcher,
      clock: _Clock().call,
    );

    await store.warmUp();

    expect(store.current, SearchCredentials.compileTimeDefault);
    expect(await store.resolveForRequest(), SearchCredentials.compileTimeDefault);
    // Der einkompilierte Default muss fuer sich allein tragfaehig sein —
    // sonst waere ein frischer Install ohne Netz ohne Mirror-Suche.
    expect(SearchCredentials.compileTimeDefault.isUsable, isTrue);
    expect(fetcher.calls, 1);
    // Ein fehlgeschlagener Fetch darf nichts auf die Platte schreiben.
    expect(disk.snapshot, isEmpty);
  });

  test('gecachter, frischer Key wird benutzt — ohne einen einzigen Fetch', () async {
    final clock = _Clock();
    final disk = InMemoryKeyValueStore({
      SearchCredentialsStore.cacheKey: _entry(fetchedAt: clock.value),
    });
    final fetcher = _FakeFetcher(result: _fetched('should-not-be-used'));
    final store = SearchCredentialsStore(
      store: disk,
      fetcher: fetcher,
      clock: clock.call,
    );

    await store.warmUp();

    expect(store.current.searchKey, 'cached-key');
    expect(store.current.baseUrl, 'https://cached.example/meili');
    expect(store.current.source, SearchCredentialsOrigin.cache);
    expect(fetcher.calls, 0);
  });

  test('abgelaufener Key wird SOFORT geliefert und nur im Hintergrund erneuert',
      () async {
    final clock = _Clock();
    final disk = InMemoryKeyValueStore({
      SearchCredentialsStore.cacheKey: _entry(
        fetchedAt: clock.value.subtract(const Duration(days: 7)),
      ),
    });
    final gate = Completer<void>();
    final fetcher = _FakeFetcher(result: _fetched('fresh-key'))..gate = gate;
    final store = SearchCredentialsStore(
      store: disk,
      fetcher: fetcher,
      clock: clock.call,
    );

    final warm = store.warmUp();

    // Wer eine Woche offline war, sucht weiter: der abgelaufene Eintrag wird
    // ausgeliefert, waehrend der Refresh noch am Gate haengt.
    final resolved = await store.resolveForRequest();
    expect(resolved.searchKey, 'cached-key');
    await _drain();
    expect(fetcher.calls, 1, reason: 'Refresh laeuft, blockiert aber nicht');

    gate.complete();
    await warm;

    expect(store.current.searchKey, 'fresh-key');
    expect(store.current.source, SearchCredentialsOrigin.network);
  });

  test('resolveForRequest ist fertig, waehrend der Netz-Fetch noch haengt',
      () async {
    final clock = _Clock();
    final disk = InMemoryKeyValueStore({
      SearchCredentialsStore.cacheKey: _entry(
        fetchedAt: clock.value.subtract(const Duration(days: 3)),
      ),
    });
    // Gate, das NIE erfuellt wird -> der Netz-Pfad bleibt fuer immer offen.
    final fetcher = _FakeFetcher(result: _fetched('never-arrives'))
      ..gate = Completer<void>();
    final store = SearchCredentialsStore(
      store: disk,
      fetcher: fetcher,
      clock: clock.call,
    );

    unawaited(store.warmUp());
    final resolved = await store.resolveForRequest();

    expect(resolved.searchKey, 'cached-key');
    expect(resolved.source, SearchCredentialsOrigin.cache);
  });

  test('abgelaufene Hydrations-Gnadenfrist faellt auf den Default zurueck',
      () async {
    final fetcher = _FakeFetcher();
    final store = SearchCredentialsStore(
      store: _HangingStore(),
      fetcher: fetcher,
      clock: _Clock().call,
      hydrationGrace: const Duration(milliseconds: 20),
    );

    final watch = Stopwatch()..start();
    final resolved = await store.resolveForRequest();
    watch.stop();

    expect(resolved, SearchCredentials.compileTimeDefault);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('korrupte Cache-Eintraege gelten als nicht vorhanden', () async {
    // Kein JSON / kein Objekt / Felder fehlen / falscher Typ / kaputtes Datum.
    const broken = <String>[
      '{nicht wirklich json',
      '["array statt objekt"]',
      '{"base_url":"https://x"}',
      '{"base_url":"https://x","key":"k","fetched_at":"gestern","ttl_seconds":10}',
      '{"base_url":"https://x","key":"k","fetched_at":"2026-08-07T12:00:00Z","ttl_seconds":"viel"}',
      '{"base_url":42,"key":"k","fetched_at":"2026-08-07T12:00:00Z","ttl_seconds":10}',
    ];

    for (final raw in broken) {
      final disk = InMemoryKeyValueStore({
        SearchCredentialsStore.cacheKey: raw,
      });
      final fetcher = _FakeFetcher();
      final store = SearchCredentialsStore(
        store: disk,
        fetcher: fetcher,
        clock: _Clock().call,
      );

      await store.warmUp();

      expect(store.current, SearchCredentials.compileTimeDefault, reason: raw);
      expect(disk.snapshot, isEmpty, reason: 'korrupter Eintrag wird geraeumt');
      expect(fetcher.calls, 1, reason: 'wie "kein Cache" -> Refresh');
    }
  });

  test('geholter Key ueberlebt eine neue Store-Instanz', () async {
    final clock = _Clock();
    final disk = InMemoryKeyValueStore();

    final first = SearchCredentialsStore(
      store: disk,
      fetcher: _FakeFetcher(result: _fetched('persisted-key')),
      clock: clock.call,
    );
    await first.warmUp();
    expect(first.current.searchKey, 'persisted-key');

    final offline = _FakeFetcher();
    final second = SearchCredentialsStore(
      store: disk,
      fetcher: offline,
      clock: clock.call,
    );
    await second.warmUp();

    expect(second.current.searchKey, 'persisted-key');
    expect(second.current.baseUrl, 'https://fresh.example/meili');
    expect(second.current.source, SearchCredentialsOrigin.cache);
    expect(offline.calls, 0, reason: 'noch frisch -> kein Refresh');
  });

  test('Server-TTL wird clientseitig auf [1 h, 7 d] geklemmt', () async {
    Future<int> persistedTtl(Duration serverTtl) async {
      final disk = InMemoryKeyValueStore();
      final store = SearchCredentialsStore(
        store: disk,
        fetcher: _FakeFetcher(result: _fetched('k', ttl: serverTtl)),
        clock: _Clock().call,
      );
      await store.warmUp();
      return _persisted(disk)['ttl_seconds'] as int;
    }

    expect(await persistedTtl(const Duration(seconds: 10)), 3600);
    expect(await persistedTtl(const Duration(days: 30)), 604800);
    expect(await persistedTtl(const Duration(hours: 12)), 43200);
  });

  test('invalidate verwirft den Key, holt neu und liefert den Ersatz', () async {
    final clock = _Clock();
    final disk = InMemoryKeyValueStore({
      SearchCredentialsStore.cacheKey: _entry(fetchedAt: clock.value),
    });
    final fetcher = _FakeFetcher(result: _fetched('rotated-key'));
    final store = SearchCredentialsStore(
      store: disk,
      fetcher: fetcher,
      clock: clock.call,
    );
    await store.warmUp();

    final replacement = await store.invalidate(store.current);

    expect(replacement.searchKey, 'rotated-key');
    expect(replacement.baseUrl, 'https://fresh.example/meili');
    expect(store.current.searchKey, 'rotated-key');
    expect(fetcher.calls, 1);
    // Der 403-Pfad hat es eilig — knappes Budget statt der vollen Policy.
    expect(fetcher.budgets.single, const Duration(seconds: 3));
    expect(_persisted(disk)['key'], 'rotated-key');
  });

  test('invalidate ist single-flight', () async {
    final clock = _Clock();
    final disk = InMemoryKeyValueStore({
      SearchCredentialsStore.cacheKey: _entry(fetchedAt: clock.value),
    });
    final gate = Completer<void>();
    final fetcher = _FakeFetcher(result: _fetched('rotated-key'))..gate = gate;
    final store = SearchCredentialsStore(
      store: disk,
      fetcher: fetcher,
      clock: clock.call,
    );
    await store.warmUp();

    final rejected = store.current;
    final both = Future.wait(<Future<SearchCredentials>>[
      store.invalidate(rejected),
      store.invalidate(rejected),
    ]);
    gate.complete();
    final results = await both;

    expect(fetcher.calls, 1, reason: 'zwei Ablehnungen, EINE Edge-Anfrage');
    expect(results[0].searchKey, 'rotated-key');
    expect(results[1].searchKey, 'rotated-key');
  });

  test('Cooldown verhindert einen Edge-Function-Sturm', () async {
    final clock = _Clock();
    final disk = InMemoryKeyValueStore({
      SearchCredentialsStore.cacheKey: _entry(fetchedAt: clock.value),
    });
    final fetcher = _FakeFetcher(result: _fetched('rotated-key'));
    final store = SearchCredentialsStore(
      store: disk,
      fetcher: fetcher,
      clock: clock.call,
    );
    await store.warmUp();

    expect((await store.invalidate(store.current)).searchKey, 'rotated-key');
    expect(fetcher.calls, 1);

    // Der Mirror lehnt weiter ab (anderer Grund als Rotation): innerhalb der
    // Minute darf das KEINE weitere Anfrage ausloesen — sonst brennt das
    // 20/h-Limit bei einer Tastendruck-Salve in Sekunden ab.
    clock.advance(const Duration(seconds: 30));
    final blocked = await store.invalidate(store.current);
    expect(fetcher.calls, 1);
    expect(blocked.searchKey, 'rotated-key');

    clock.advance(const Duration(seconds: 31));
    fetcher.result = _fetched('rotated-again');
    final allowed = await store.invalidate(store.current);
    expect(fetcher.calls, 2);
    expect(allowed.searchKey, 'rotated-again');
  });

  test('eine bereits ueberholte Ablehnung loest keinen Fetch aus', () async {
    final clock = _Clock();
    final disk = InMemoryKeyValueStore({
      SearchCredentialsStore.cacheKey: _entry(fetchedAt: clock.value),
    });
    final fetcher = _FakeFetcher(result: _fetched('rotated-key'));
    final store = SearchCredentialsStore(
      store: disk,
      fetcher: fetcher,
      clock: clock.call,
    );
    await store.warmUp();

    const alreadyRotatedAway = SearchCredentials(
      baseUrl: 'https://cached.example/meili',
      searchKey: 'ur-alter-key',
      source: SearchCredentialsOrigin.cache,
    );
    final result = await store.invalidate(alreadyRotatedAway);

    expect(fetcher.calls, 0, reason: 'jemand anderes hat schon rotiert');
    expect(result.searchKey, 'cached-key');
  });

  test(
      'Fetch scheitert und der abgelehnte Key WAR der Compile-Time-Default '
      '-> unbrauchbar', () async {
    final disk = InMemoryKeyValueStore();
    final fetcher = _FakeFetcher(); // kein Ersatz erreichbar
    final store = SearchCredentialsStore(
      store: disk,
      fetcher: fetcher,
      clock: _Clock().call,
    );

    final result = await store.invalidate(SearchCredentials.compileTimeDefault);

    // Auf den Default zurueckzufallen waere garantiert der naechste 403.
    // Stattdessen unbrauchbar bleiben -> die naechste Suche ueberspringt den
    // Mirror ganz ohne Netz-Anfrage.
    expect(result.isUsable, isFalse);
    expect(store.current.isUsable, isFalse);
    expect(fetcher.calls, 1);
    expect(disk.snapshot, isEmpty, reason: 'toter Key auch von der Platte weg');
  });

  test('invalidate wirft nie, auch wenn der Fetcher explodiert', () async {
    final clock = _Clock();
    final disk = InMemoryKeyValueStore({
      SearchCredentialsStore.cacheKey: _entry(fetchedAt: clock.value),
    });
    final store = SearchCredentialsStore(
      store: disk,
      fetcher: _FakeFetcher(explodes: true),
      clock: clock.call,
    );
    await store.warmUp();

    // Wuerde invalidate die Fetcher-Exception durchreichen, schluege bereits
    // dieses await fehl — genau das ist die Zusicherung.
    final result = await store.invalidate(store.current);

    // Der tote Key ist trotzdem weg (Speicher UND Platte), es gibt nur
    // keinen Ersatz -> unbrauchbar, naechste Suche geht direkt zu OFF.
    expect(result.isUsable, isFalse);
    expect(store.current.isUsable, isFalse);
    expect(disk.snapshot, isEmpty);

    // Und der naechste Versuch laeuft nicht in eine tote Wiederholung:
    // der Cooldown greift.
    expect((await store.invalidate(store.current)).isUsable, isFalse);
  });

  test('Server-Kill-Switch (leere Credentials) schaltet den Mirror ab', () async {
    final disk = InMemoryKeyValueStore();
    final store = SearchCredentialsStore(
      store: disk,
      fetcher: _FakeFetcher(
        result: const FetchedSearchCredentials(
          baseUrl: '',
          searchKey: '',
          ttl: Duration(hours: 12),
        ),
      ),
      clock: _Clock().call,
    );

    await store.warmUp();

    expect(store.current.isUsable, isFalse);
    // Persistiert, damit der naechste Kaltstart nicht erst wieder den
    // Compile-Time-Default gegen den abgeschalteten Mirror wirft.
    expect(_persisted(disk)['key'], '');
    expect(_persisted(disk)['base_url'], '');
  });

  test('warmUp ist idempotent', () async {
    final fetcher = _FakeFetcher(result: _fetched('k'));
    final store = SearchCredentialsStore(
      store: InMemoryKeyValueStore(),
      fetcher: fetcher,
      clock: _Clock().call,
    );

    await Future.wait(<Future<void>>[
      store.warmUp(),
      store.warmUp(),
      store.warmUp(),
    ]);
    await store.warmUp();

    expect(fetcher.calls, 1);
  });
}
