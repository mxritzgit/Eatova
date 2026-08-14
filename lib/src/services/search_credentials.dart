import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/search_config.dart';
import '../config/supabase_config.dart';
import 'eatova_http.dart';
import 'local_cache.dart' show KeyValueStore, SharedPreferencesStore;

/// Woher die gerade aktiven Such-Credentials stammen. Reine Diagnose —
/// die Suche behandelt alle Quellen gleich.
enum SearchCredentialsOrigin {
  /// Einkompilierter `String.fromEnvironment`-Default (frischer Install
  /// ohne Netz, oder Fetch noch nicht durch).
  compileTime,

  /// Aus SharedPreferences hydratisiert (letzter bekannter Stand).
  cache,

  /// Frisch von der Edge Function `search-key` geholt.
  network,

  /// Mirror bewusst aus: Server-Kill-Switch oder abgelehnter Key ohne
  /// Ersatz. Die Suche geht dann direkt zu OpenFoodFacts.
  disabled,
}

/// Basis-URL + Search-only-Key des Meilisearch-Mirrors. URL und Key reisen
/// IMMER zusammen: ein Umzug des Mirrors ist dadurch ein einziges
/// Secret-Update und kann nicht in den Zustand "neue URL, alter Key" fallen.
class SearchCredentials {
  const SearchCredentials({
    required this.baseUrl,
    required this.searchKey,
    required this.source,
  });

  final String baseUrl;
  final String searchKey;
  final SearchCredentialsOrigin source;

  /// Die einkompilierte letzte Rueckfallebene (siehe [SearchConfig]).
  static const SearchCredentials compileTimeDefault = SearchCredentials(
    baseUrl: SearchConfig.fallbackMirrorBaseUrl,
    searchKey: SearchConfig.fallbackMirrorSearchKey,
    source: SearchCredentialsOrigin.compileTime,
  );

  /// Mirror aus. Leere Werte -> [isUsable] false -> die Suche laeuft ohne
  /// eine einzige Netz-Anfrage direkt in den OpenFoodFacts-Fallback.
  static const SearchCredentials disabled = SearchCredentials(
    baseUrl: '',
    searchKey: '',
    source: SearchCredentialsOrigin.disabled,
  );

  /// Die Mirror-Basis-URL ist der einzige App-Endpunkt, der zur Laufzeit von
  /// aussen kommt (Edge-Function-Antwort ODER SharedPreferences-Cache). Wird
  /// sie je auf `http://` gesetzt — versehentlich im Server-Secret oder durch
  /// einen lokalen Schreibzugriff auf den (bewusst unverschluesselten)
  /// Credentials-Slot — ginge die Suche samt Search-Key im Klartext raus.
  /// Deshalb wird `https` an den beiden untrusted EINGAENGEN erzwungen
  /// (Fetch-Parse in [EdgeFunctionSearchKeyFetcher] und Cache-Parse in
  /// [_CachedEntry.tryParse], Sicherheits-Audit 2026-08-09): ein
  /// non-`https`-Mirror wird gar nicht erst zu einem [SearchCredentials] und
  /// faellt still auf OpenFoodFacts zurueck. `isUsable` bleibt bewusst der
  /// reine Leer-Check — direkt injizierte Creds (Loopback-Tests) laufen
  /// nicht ueber die Eingaenge und sollen nicht doppelt geprueft werden.
  static bool isSecureBaseUrl(String url) =>
      Uri.tryParse(url.trim())?.scheme == 'https';

  bool get isUsable => baseUrl.trim().isNotEmpty && searchKey.trim().isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is SearchCredentials &&
      other.baseUrl == baseUrl &&
      other.searchKey == searchKey &&
      other.source == source;

  @override
  int get hashCode => Object.hash(baseUrl, searchKey, source);

  // Bewusst OHNE den Key im String — dieses Objekt landet sonst ueber
  // toString() in Logs/Fehlermeldungen.
  @override
  String toString() =>
      'SearchCredentials(${source.name}, baseUrl: $baseUrl, key: '
      '${searchKey.isEmpty ? "<leer>" : "<${searchKey.length} Zeichen>"})';
}

/// Antwort der Edge Function: Credentials plus die server-vorgegebene TTL.
class FetchedSearchCredentials {
  const FetchedSearchCredentials({
    required this.baseUrl,
    required this.searchKey,
    required this.ttl,
  });

  final String baseUrl;
  final String searchKey;
  final Duration ttl;

  /// Der Server hat den Mirror ausdruecklich abgeschaltet: BEIDE Felder leer
  /// (Secret `EATOVA_MIRROR_SEARCH_KEY=disabled`, HTTP 200). Nur beide —
  /// eine halb leere Antwort ist ein kaputter Server, kein Kill-Switch, und
  /// wird bereits im Fetcher verworfen.
  bool get isKillSwitch => baseUrl.trim().isEmpty && searchKey.trim().isEmpty;
}

/// Test-Seam fuer das Holen frischer Credentials.
///
/// Vertrag: [fetch] wirft NIE und liefert bei jedem Fehler (kein Netz, kein
/// Token, 4xx/5xx, kaputtes JSON) `null`. `null` heisst ausschliesslich
/// „diesmal nichts geholt" — NIE „Mirror abschalten".
///
/// „Mirror abschalten" sagt der Server auf dem EINEN dafuer vorgesehenen Weg:
/// 200 mit beiden Feldern leer. Das kommt als [FetchedSearchCredentials] mit
/// [FetchedSearchCredentials.isKillSwitch] zurueck — ein NICHT-`null`-Wert,
/// weil der Store ihn uebernehmen und den alten Key aus Speicher UND Platte
/// werfen muss. Waere auch das `null`, liefe der Kill-Switch ins Leere und
/// jeder installierte Build suchte mit dem abgeflossenen Key weiter.
///
/// Der abgeschaltete Zustand ueberlebt den Neustart: er wird als Leer/Leer-
/// Eintrag persistiert und von [_CachedEntry.tryParse] wieder als
/// [SearchCredentials.disabled] gelesen. Ohne das griffe der Hebel nur fuer
/// die laufende Sitzung — jeder Kaltstart faende den Slot ungueltig, raeumte
/// ihn weg und suchte bis zum Ende des Fetches wieder mit dem
/// einkompilierten [SearchConfig.fallbackMirrorSearchKey].
abstract class SearchKeyFetcher {
  const SearchKeyFetcher();

  /// [budget] deckelt den gesamten Roundtrip (der 403-Pfad hat es eilig).
  Future<FetchedSearchCredentials?> fetch({Duration? budget});
}

/// Production-Fetcher gegen die Edge Function `search-key`.
///
/// Rohes dart:io ueber [sendTextRequest] statt `functions.invoke` — wie
/// [EdgeFunctionMealAnalyzer]: nur so liegt auf JEDER Phase ein Timeout.
///
/// Die drei optionalen Parameter sind die Testnaht fuer den Laufzeit-
/// Wire-Test (search_key_fetcher_wire_test.dart): vorher war der komplette
/// HTTP-Pfad (Header-Bau, Statuscode-Weichen, JSON-Vertrag) nur per
/// Quelltext-Abgleich gedeckt, weil Basis-URL, anon-Key und Token fest an
/// den globalen Statics hingen. Produktion nutzt weiter den argumentlosen
/// const-Konstruktor — die Defaults loesen zur Laufzeit auf die Statics auf.
class EdgeFunctionSearchKeyFetcher extends SearchKeyFetcher {
  const EdgeFunctionSearchKeyFetcher({
    String? baseUrl,
    String? anonKey,
    String? Function()? tokenProvider,
  })  : _baseUrlOverride = baseUrl,
        _anonKeyOverride = anonKey,
        _tokenProvider = tokenProvider;

  final String? _baseUrlOverride;
  final String? _anonKeyOverride;
  final String? Function()? _tokenProvider;

  static const String _functionPath = '/functions/v1/search-key';
  static const Duration _fallbackTtl = Duration(hours: 12);

  @override
  Future<FetchedSearchCredentials?> fetch({Duration? budget}) {
    final work = _fetch();
    if (budget == null) return work;
    // Der Fetch selbst wirft nie; das Budget kappt nur die Wartezeit des
    // Aufrufers. Ein danach noch eintrudelndes Ergebnis wird verworfen.
    return work.timeout(budget, onTimeout: () => null);
  }

  Future<FetchedSearchCredentials?> _fetch() async {
    HttpClient? client;
    try {
      // Der KOMPLETTE Supabase-Zugriff liegt im try: ohne
      // `Supabase.initialize` (Preview/Test) wirft schon `Supabase.instance`.
      // Das ist hier kein Fehler, sondern schlicht „kein Fetch moeglich".
      final token = _tokenProvider != null
          ? _tokenProvider()
          : Supabase.instance.client.auth.currentSession?.accessToken;
      if (token == null || token.isEmpty) {
        // Kein Token = Kaltstart-Fenster, in dem eine wiederhergestellte
        // Session gerade refresht wird. Behalten was da ist, nicht abschalten.
        return null;
      }

      client = createHttpClient(HttpTimeoutPolicy.mirror);
      final response = await sendTextRequest(
        client,
        method: 'GET',
        uri: Uri.parse(
            '${_baseUrlOverride ?? EatovaSupabaseConfig.url}$_functionPath'),
        policy: HttpTimeoutPolicy.mirror,
        operation: 'search-key',
        configure: (request) {
          request.headers
              .set('apikey', _anonKeyOverride ?? EatovaSupabaseConfig.anonKey);
          request.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer $token',
          );
        },
      );

      // Jeder Nicht-2xx (inkl. 500 `server_misconfigured`) heisst „behalte,
      // was du hast" — ein fehlendes Server-Secret darf die funktionierende
      // Suche eines Bestands-Builds nicht abschalten.
      if (response.statusCode < 200 || response.statusCode >= 300) {
        dev.log(
          'search-key antwortete ${response.statusCode}',
          name: 'search_credentials',
        );
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return null;
      final baseUrl = decoded['mirrorBaseUrl'];
      final searchKey = decoded['searchKey'];
      if (baseUrl is! String || searchKey is! String) return null;
      final ttlRaw = decoded['ttlSeconds'];
      final ttl =
          ttlRaw is num ? Duration(seconds: ttlRaw.round()) : _fallbackTtl;
      final trimmedBaseUrl = baseUrl.trim();
      final trimmedKey = searchKey.trim();

      // Beide Felder leer = Kill-Switch der Function. Der muss VOR dem
      // https-Zwang stehen: eine leere URL ist nicht `https`, der Zwang
      // machte aus der Abschaltung sonst ein `null` — und `null` heisst
      // „behalte, was du hast". Genau daran scheiterte der Kill-Switch
      // vorher still: Log sagte „disabled", jedes Geraet suchte weiter.
      if (trimmedBaseUrl.isEmpty && trimmedKey.isEmpty) {
        dev.log('search-key meldet Kill-Switch — Mirror wird abgeschaltet',
            name: 'search_credentials');
        return FetchedSearchCredentials(baseUrl: '', searchKey: '', ttl: ttl);
      }
      // Nur EINES der beiden Felder leer ist kein Kill-Switch, sondern ein
      // kaputter Server (halbes Secret-Update). Bestand behalten.
      if (trimmedBaseUrl.isEmpty || trimmedKey.isEmpty) {
        dev.log('search-key lieferte halb leere Credentials — verworfen',
            name: 'search_credentials');
        return null;
      }
      // Ein non-https-Mirror aus der Server-Antwort wird gar nicht erst
      // uebernommen (kein Klartext-Key-Versand, kein Wegschreiben auf Platte).
      if (!SearchCredentials.isSecureBaseUrl(trimmedBaseUrl)) {
        dev.log('search-key lieferte non-https mirrorBaseUrl — verworfen',
            name: 'search_credentials');
        return null;
      }

      return FetchedSearchCredentials(
        baseUrl: trimmedBaseUrl,
        searchKey: trimmedKey,
        ttl: ttl,
      );
    } catch (e, st) {
      dev.log(
        'search-key fetch fehlgeschlagen',
        error: e,
        stackTrace: st,
        name: 'search_credentials',
      );
      return null;
    } finally {
      client?.close(force: true);
    }
  }
}

/// Laufzeit-Aufloesung der Mirror-Zugangsdaten.
///
/// Kette: **Cache -> Fetch -> Compile-Time-Default -> Mirror aus.** Die Suche
/// darf NIE hart scheitern, nur weil der Key-Endpunkt nicht erreichbar ist —
/// im schlimmsten Fall landet sie im OpenFoodFacts-Fallback.
///
/// Drei Eigenschaften tragen den ganzen Entwurf:
///
///  * [current] ist **synchron und blockiert nie** — der Konstruktionspfad
///    des Food-Tabs laeuft bei jedem `notifyListeners()` erneut durch und
///    vertraegt weder `await` noch einen SharedPreferences-Zugriff.
///  * [resolveForRequest] wartet ausschliesslich auf die laufende
///    PLATTEN-Hydration (max. [_hydrationGrace]) — nie aufs Netz. Die
///    eigentliche Suche startet ohnehin erst ~1 s nach dem ersten Tastendruck
///    (Debounce im Add-Sheet), der Warmlauf hat also reichlich Vorsprung.
///  * [invalidate] ist der echte Rotations-Mechanismus (401/403 vom Mirror),
///    single-flight und mit Cooldown.
class SearchCredentialsStore {
  SearchCredentialsStore({
    KeyValueStore? store,
    SearchKeyFetcher? fetcher,
    DateTime Function()? clock,
    Duration hydrationGrace = const Duration(milliseconds: 300),
  }) : _injectedStore = store,
       _fetcher = fetcher ?? const EdgeFunctionSearchKeyFetcher(),
       _clock = clock ?? DateTime.now,
       _hydrationGrace = hydrationGrace;

  /// Prozessweiter Singleton. Die Konstruktion ist reine Allokation —
  /// kein Plugin-Channel, kein `Supabase.instance`, kein I/O.
  static SearchCredentialsStore get instance =>
      _instance ??= SearchCredentialsStore();
  static SearchCredentialsStore? _instance;

  /// Persistenz-Slot. BEWUSST OHNE User-Suffix:
  ///
  ///  * Der Search-only-Key ist geraete-globale Konfiguration, keine PII —
  ///    er sagt nichts ueber den Nutzer aus.
  ///  * `LocalCache.clear()` raeumt beim Sign-out alle User-Slots; laege der
  ///    Key dort mit drin, wuerfe jeder Logout einen funktionierenden Key
  ///    weg und der naechste Login muesste ihn neu holen.
  static const String cacheKey = 'eatova.v1.search_credentials';

  /// TTL-Grenzen. Ein Server, der Unsinn liefert (0 s -> Fetch-Sturm,
  /// 10 Jahre -> nie wieder Rotation), wird hier eingefangen.
  static const Duration minTtl = Duration(hours: 1);
  static const Duration maxTtl = Duration(days: 7);

  /// Zeitbudget des 403-Pfads: die Suche wartet bereits auf ein Ergebnis,
  /// laenger als ~3 s lohnt der Umweg nicht — dann lieber OpenFoodFacts.
  static const Duration _invalidateBudget = Duration(seconds: 3);

  /// PFLICHT, nicht Kosmetik: das Add-Sheet wiederholt eine Suche bis zu 3x
  /// (600 ms Abstand) und der 1000-ms-Debounce feuert pro Tipp-Pause eine
  /// neue Suche. Ohne Cooldown wuerde ein Mirror, der aus einem ganz anderen
  /// Grund 403 liefert, pro Tastendruck-Salve eine Edge-Function-Anfrage
  /// ausloesen und das 20/h-Limit in Sekunden verbrennen.
  static const Duration _invalidateCooldown = Duration(minutes: 1);

  final KeyValueStore? _injectedStore;
  final SearchKeyFetcher _fetcher;
  final DateTime Function() _clock;
  final Duration _hydrationGrace;

  KeyValueStore? _resolvedStore;
  SearchCredentials? _memory;
  _CachedEntry? _diskEntry;
  Future<void>? _hydration;
  Future<void>? _warmUp;
  Future<SearchCredentials>? _refreshInFlight;
  Future<SearchCredentials>? _invalidateInFlight;
  DateTime? _lastInvalidateAt;

  /// Zaehlt jede Invalidierung. Ein Hintergrund-Refresh, der VOR einer
  /// Rotation losgeschickt wurde, darf den frisch geholten Key nicht mit
  /// seinem (dann veralteten) Ergebnis ueberschreiben.
  int _generation = 0;

  /// Synchron, nie null, blockiert nie. Vor der Hydration (und wenn nichts
  /// zwischengespeichert ist) der Compile-Time-Default.
  SearchCredentials get current =>
      _memory ?? SearchCredentials.compileTimeDefault;

  /// Idempotenter Warmlauf: Platte lesen, danach bei Bedarf das Netz.
  /// Fire-and-forget — wirft nie, blockiert keinen UI-Pfad.
  Future<void> warmUp() {
    final existing = _warmUp;
    if (existing != null) return existing;
    final started = _warmUpInternal();
    _warmUp = started;
    return started;
  }

  /// Was der naechste Such-Request benutzen soll. Wartet NUR auf die
  /// laufende Platten-Hydration (gedeckelt), NIE aufs Netz.
  Future<SearchCredentials> resolveForRequest() async {
    // Startet die Hydration notfalls selbst — wir laufen hier im async
    // Such-Pfad, nicht im Widget-Konstruktor. Ohne das waere die Suche auf
    // den Warmlauf angewiesen, um den Cache ueberhaupt zu sehen.
    final hydration = _hydrateFromDisk();
    try {
      await hydration.timeout(_hydrationGrace);
    } catch (_) {
      // Platte zu langsam/kaputt -> mit dem weitermachen, was da ist.
    }
    return current;
  }

  /// Der Mirror hat [rejected] mit 401/403 abgelehnt. Wirft den Key aus
  /// Speicher UND Platte und holt Ersatz. Liefert die neuen Credentials
  /// (oder unbrauchbare, wenn es keinen Ersatz gibt). Wirft nie.
  Future<SearchCredentials> invalidate(SearchCredentials rejected) async {
    try {
      // 1. Single-flight: laeuft bereits eine Invalidierung, deren Ergebnis
      //    teilen statt eine zweite Edge-Function-Anfrage zu feuern.
      //
      //    MUSS vor der Stale-Pruefung stehen: eine laufende Invalidierung
      //    hat `_memory` bereits geleert, ein paralleler Aufrufer wuerde
      //    sonst faelschlich „schon rotiert" sehen und leere Credentials
      //    zurueckbekommen, statt auf den neuen Key zu warten.
      final inFlight = _invalidateInFlight;
      if (inFlight != null) return await inFlight;

      // 2. Schon rotiert? Dann war ein anderer Aufrufer schneller — der
      //    Retry soll den neuen Key nehmen, ohne irgendetwas zu holen.
      if (!_isCurrent(rejected)) return current;

      // 3. Cooldown (siehe [_invalidateCooldown]).
      final last = _lastInvalidateAt;
      if (last != null &&
          _clock().difference(last) < _invalidateCooldown) {
        return current;
      }
      _lastInvalidateAt = _clock();

      final future = _dropAndRefetch(rejected);
      _invalidateInFlight = future;
      final SearchCredentials replacement;
      try {
        replacement = await future;
      } finally {
        _invalidateInFlight = null;
      }

      // Einmal loggen, wenn die Rotation wirklich griff. Ohne diese Zeile
      // waere eine kaputte Rotation unsichtbar: der FallbackProductService
      // liefert in beiden Faellen plausible OFF-Treffer.
      if (replacement.isUsable && replacement.searchKey != rejected.searchKey) {
        dev.log(
          'Such-Key rotiert (${replacement.source.name}, '
          'baseUrl: ${replacement.baseUrl})',
          name: 'search_credentials',
        );
      }
      return replacement;
    } catch (e, st) {
      dev.log(
        'invalidate fehlgeschlagen',
        error: e,
        stackTrace: st,
        name: 'search_credentials',
      );
      return current;
    }
  }

  // --- intern ---------------------------------------------------------------

  Future<void> _warmUpInternal() async {
    try {
      await _hydrateFromDisk();
      // Abgelaufene Eintraege werden trotzdem BENUTZT (oben schon in
      // `_memory`) und hier nur im Hintergrund erneuert — wer eine Woche
      // offline war, sucht weiter.
      final entry = _diskEntry;
      if (entry == null || entry.isExpired(_clock())) {
        await _refresh();
      }
    } catch (e, st) {
      dev.log(
        'warmUp fehlgeschlagen',
        error: e,
        stackTrace: st,
        name: 'search_credentials',
      );
    }
  }

  /// Single-flight-Hintergrund-Refresh. Ein Fehlschlag laesst alles, wie es
  /// ist — insbesondere bleibt ein abgelaufener Cache-Eintrag in Benutzung.
  Future<SearchCredentials> _refresh() {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;
    final future = _fetchAndAdopt();
    _refreshInFlight = future;
    return future.whenComplete(() => _refreshInFlight = null);
  }

  Future<SearchCredentials> _fetchAndAdopt() async {
    final generation = _generation;
    final fetched = await _fetcher.fetch();
    // Waehrend des Fetches wurde rotiert -> das hier ist der alte Stand.
    if (fetched == null || generation != _generation) return current;
    return _adopt(fetched);
  }

  Future<SearchCredentials> _dropAndRefetch(SearchCredentials rejected) async {
    _generation++;
    // Toten Key ZUERST aus Speicher und Platte werfen. Ein Absturz mitten im
    // Refetch darf ihn nicht wieder auferstehen lassen.
    _memory = SearchCredentials.disabled;
    _diskEntry = null;
    await _removeFromDisk();

    final fetched = await _fetcher.fetch(budget: _invalidateBudget);
    if (fetched != null) return _adopt(fetched);

    // Kein Ersatz erreichbar. Der Compile-Time-Default ist nur dann noch
    // eine Option, wenn er nicht SELBST der abgelehnte Key ist — sonst
    // waere der Retry garantiert wieder ein 403.
    const fallback = SearchCredentials.compileTimeDefault;
    if (fallback.isUsable && fallback.searchKey != rejected.searchKey) {
      _memory = fallback;
      return fallback;
    }

    // Bewusst unbrauchbar lassen: die naechste Suche ueberspringt den Mirror
    // dann ohne eine einzige sinnlose Netz-Anfrage. Der naechste App-Start
    // holt via [warmUp] wieder frische Credentials.
    return current;
  }

  Future<SearchCredentials> _adopt(FetchedSearchCredentials fetched) async {
    // Der Kill-Switch wird wie jede andere Antwort uebernommen — auch auf die
    // Platte: erst das Ueberschreiben des Slots nimmt dem alten Key seine
    // letzte Bleibe. Nur die Herkunft ist eine andere.
    final credentials = fetched.isKillSwitch
        ? SearchCredentials.disabled
        : SearchCredentials(
            baseUrl: fetched.baseUrl.trim(),
            searchKey: fetched.searchKey.trim(),
            source: SearchCredentialsOrigin.network,
          );
    final entry = _CachedEntry(
      credentials: credentials,
      fetchedAt: _clock(),
      ttl: clampTtl(fetched.ttl),
    );
    _memory = credentials;
    _diskEntry = entry;
    await _writeToDisk(entry);
    return credentials;
  }

  bool _isCurrent(SearchCredentials candidate) {
    final active = current;
    return active.baseUrl == candidate.baseUrl &&
        active.searchKey == candidate.searchKey;
  }

  Future<void> _hydrateFromDisk() {
    final existing = _hydration;
    if (existing != null) return existing;
    final started = _readFromDisk();
    _hydration = started;
    return started;
  }

  Future<void> _readFromDisk() async {
    try {
      final store = await _resolveStore();
      if (store == null) return;
      final raw = await store.getString(cacheKey);
      if (raw == null || raw.isEmpty) return;
      final entry = _CachedEntry.tryParse(raw);
      if (entry == null) {
        // Korrupt/unbekanntes Schema -> wie „nicht vorhanden" behandeln und
        // wegraeumen (gleicher defensiver Geist wie LocalCache._readJson).
        await store.remove(cacheKey);
        return;
      }
      _diskEntry = entry;
      // Ein bereits im Speicher stehender Wert (frisch geholt oder gerade
      // invalidiert) gewinnt IMMER gegen die Platte.
      _memory ??= entry.credentials;
    } catch (e, st) {
      dev.log(
        'Such-Credentials lesen fehlgeschlagen',
        error: e,
        stackTrace: st,
        name: 'search_credentials',
      );
    }
  }

  Future<void> _writeToDisk(_CachedEntry entry) async {
    try {
      final store = await _resolveStore();
      await store?.setString(cacheKey, entry.encode());
    } catch (e, st) {
      dev.log(
        'Such-Credentials schreiben fehlgeschlagen',
        error: e,
        stackTrace: st,
        name: 'search_credentials',
      );
    }
  }

  Future<void> _removeFromDisk() async {
    try {
      final store = await _resolveStore();
      await store?.remove(cacheKey);
    } catch (e, st) {
      dev.log(
        'Such-Credentials loeschen fehlgeschlagen',
        error: e,
        stackTrace: st,
        name: 'search_credentials',
      );
    }
  }

  /// Eigene [SharedPreferencesStore]-Instanz — bewusst NICHT die von
  /// [LocalCache]: dessen `clear()` raeumt beim Sign-out alles.
  Future<KeyValueStore?> _resolveStore() async {
    final injected = _injectedStore;
    if (injected != null) return injected;
    final cached = _resolvedStore;
    if (cached != null) return cached;
    try {
      final created = await SharedPreferencesStore.create();
      _resolvedStore = created;
      return created;
    } catch (e, st) {
      dev.log(
        'SharedPreferences fuer Such-Credentials nicht verfuegbar',
        error: e,
        stackTrace: st,
        name: 'search_credentials',
      );
      return null;
    }
  }

  /// TTL auf [minTtl]..[maxTtl] begrenzen.
  ///
  /// Die TTL ist NICHT der Rotations-Mechanismus — das ist der 403-Pfad, und
  /// der konvergiert innerhalb einer einzigen Suche. Ihr einziger
  /// verbliebener Job ist, einen Wechsel der Basis-URL zu verbreiten: der
  /// erzeugt Verbindungsfehler statt 403 und kann sich deshalb nicht selbst
  /// heilen.
  static Duration clampTtl(Duration ttl) {
    if (ttl < minTtl) return minTtl;
    if (ttl > maxTtl) return maxTtl;
    return ttl;
  }
}

/// Persistierter Eintrag. Wire-Format:
/// `{"base_url":..,"key":..,"fetched_at":<iso>,"ttl_seconds":<int>}`.
class _CachedEntry {
  const _CachedEntry({
    required this.credentials,
    required this.fetchedAt,
    required this.ttl,
  });

  final SearchCredentials credentials;
  final DateTime fetchedAt;
  final Duration ttl;

  bool isExpired(DateTime now) => !now.isBefore(fetchedAt.add(ttl));

  String encode() => jsonEncode(<String, Object>{
    'base_url': credentials.baseUrl,
    'key': credentials.searchKey,
    'fetched_at': fetchedAt.toIso8601String(),
    'ttl_seconds': ttl.inSeconds,
  });

  /// Alles Fehlende/Falsch-Getypte/Unparsbare macht den GESAMTEN Eintrag
  /// ungueltig (null) — nie ein Crash, nie ein halb geladener Key.
  static _CachedEntry? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final baseUrl = decoded['base_url'];
      final key = decoded['key'];
      final fetchedAtRaw = decoded['fetched_at'];
      final ttlRaw = decoded['ttl_seconds'];
      if (baseUrl is! String || key is! String) return null;
      if (fetchedAtRaw is! String || ttlRaw is! num) return null;
      final trimmedBaseUrl = baseUrl.trim();
      final abgeschaltet = trimmedBaseUrl.isEmpty && key.trim().isEmpty;
      // Beide Felder leer heisst hier dasselbe wie in der Server-Antwort:
      // Kill-Switch. Der Eintrag entsteht ausschliesslich aus [_adopt] — der
      // Store schreibt sonst nie leer — und muss den Neustart UEBERLEBEN.
      // Fiele er hier durch, raeumte ihn `_readFromDisk` weg und jeder
      // Kaltstart fuehre den Mirror bis zum Ende des Fetches wieder mit dem
      // einkompilierten [SearchConfig.fallbackMirrorSearchKey] an — also
      // womoeglich mit genau dem Key, dessentwegen der Hebel gezogen wurde.
      // Halb leere Eintraege bleiben ungueltig (kaputte Platte, kein Hebel):
      // sie scheitern unveraendert am https-Zwang.
      //
      // Ein auf Platte manipulierter (oder aus einer alten http-Version
      // stammender) Eintrag mit non-https-Mirror ist ungueltig.
      if (!abgeschaltet && !SearchCredentials.isSecureBaseUrl(baseUrl)) {
        return null;
      }
      final fetchedAt = DateTime.tryParse(fetchedAtRaw);
      if (fetchedAt == null) return null;
      return _CachedEntry(
        credentials: abgeschaltet
            ? SearchCredentials.disabled
            : SearchCredentials(
                baseUrl: baseUrl,
                searchKey: key,
                source: SearchCredentialsOrigin.cache,
              ),
        fetchedAt: fetchedAt,
        ttl: SearchCredentialsStore.clampTtl(Duration(seconds: ttlRaw.round())),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Seam zwischen [MeilisearchProductService] und dem Store.
///
/// Existiert, damit der Service `const`-konstruierbar bleibt: die Suche
/// braucht Laufzeit-Werte, aber ihre Default-Parameter muessen
/// Compile-Zeit-Konstanten sein. Eine `const`-Instanz darf in ihren
/// METHODEN sehr wohl veraenderliche Statics lesen — genau das nutzt
/// [GlobalSearchCredentialsSource].
abstract class SearchCredentialsSource {
  const SearchCredentialsSource();

  Future<SearchCredentials> resolve();

  Future<SearchCredentials> invalidate(SearchCredentials rejected);
}

/// Production-Seam: delegiert an [SearchCredentialsStore.instance].
class GlobalSearchCredentialsSource extends SearchCredentialsSource {
  const GlobalSearchCredentialsSource();

  @override
  Future<SearchCredentials> resolve() =>
      SearchCredentialsStore.instance.resolveForRequest();

  @override
  Future<SearchCredentials> invalidate(SearchCredentials rejected) =>
      SearchCredentialsStore.instance.invalidate(rejected);
}
