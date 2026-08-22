import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/search_config.dart';
import '../config/supabase_config.dart';
import 'eatova_http.dart';
import 'local_cache.dart' show KeyValueStore, SharedPreferencesStore;

/// Where the active search credentials came from. Diagnostics only — the
/// search treats every source alike.
enum SearchCredentialsOrigin {
  /// Compiled-in `String.fromEnvironment` default.
  compileTime,

  /// Hydrated from SharedPreferences (last known state).
  cache,

  /// Freshly fetched from the `search-key` edge function.
  network,

  /// Mirror deliberately off: server kill switch or a rejected key with no
  /// replacement. The search then goes straight to OpenFoodFacts.
  disabled,
}

/// Base URL plus search-only key of the Meilisearch mirror. The two always
/// travel together, so moving the mirror is one secret update and cannot end
/// up as "new URL, old key".
class SearchCredentials {
  const SearchCredentials({
    required this.baseUrl,
    required this.searchKey,
    required this.source,
  });

  final String baseUrl;
  final String searchKey;
  final SearchCredentialsOrigin source;

  /// The compiled-in last resort (see [SearchConfig]).
  static const SearchCredentials compileTimeDefault = SearchCredentials(
    baseUrl: SearchConfig.fallbackMirrorBaseUrl,
    searchKey: SearchConfig.fallbackMirrorSearchKey,
    source: SearchCredentialsOrigin.compileTime,
  );

  /// Mirror off. Empty values -> [isUsable] false -> the search goes to the
  /// OpenFoodFacts fallback without a single network request.
  static const SearchCredentials disabled = SearchCredentials(
    baseUrl: '',
    searchKey: '',
    source: SearchCredentialsOrigin.disabled,
  );

  /// The mirror base URL is the only app endpoint that arrives from outside
  /// at runtime, so an `http://` value would send the search key in the
  /// clear. `https` is therefore enforced at both untrusted entry points
  /// (fetch parse in [EdgeFunctionSearchKeyFetcher], cache parse in
  /// [_CachedEntry.tryParse]; audit 2026-08-09): a non-`https` mirror never
  /// becomes a [SearchCredentials] and falls back to OpenFoodFacts.
  /// `isUsable` stays a pure emptiness check — directly injected creds
  /// (loopback tests) bypass the entry points on purpose.
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

  // Deliberately without the key: this object reaches logs and error
  // messages via toString().
  @override
  String toString() =>
      'SearchCredentials(${source.name}, baseUrl: $baseUrl, key: '
      '${searchKey.isEmpty ? "<leer>" : "<${searchKey.length} Zeichen>"})';
}

/// Edge function response: credentials plus the server-supplied TTL.
class FetchedSearchCredentials {
  const FetchedSearchCredentials({
    required this.baseUrl,
    required this.searchKey,
    required this.ttl,
  });

  final String baseUrl;
  final String searchKey;
  final Duration ttl;

  /// The server switched the mirror off: BOTH fields empty on HTTP 200. Only
  /// both — a half-empty response is a broken server, not a kill switch, and
  /// the fetcher already discards it.
  bool get isKillSwitch => baseUrl.trim().isEmpty && searchKey.trim().isEmpty;
}

/// Test seam for fetching fresh credentials.
///
/// Contract: [fetch] never throws and returns `null` on any failure. `null`
/// means only "nothing fetched this time", NEVER "switch the mirror off".
///
/// The server says "switch off" on exactly one path: 200 with both fields
/// empty, returned as a non-`null` [FetchedSearchCredentials] with
/// [FetchedSearchCredentials.isKillSwitch], because the store must adopt it
/// and evict the old key from memory AND disk.
///
/// The off state survives a restart: it is persisted as an empty/empty entry
/// and read back as [SearchCredentials.disabled], otherwise the kill switch
/// would only hold for the running session.
abstract class SearchKeyFetcher {
  const SearchKeyFetcher();

  /// [budget] caps the whole round trip (the 403 path is in a hurry).
  Future<FetchedSearchCredentials?> fetch({Duration? budget});
}

/// Production fetcher against the `search-key` edge function.
///
/// Raw dart:io via [sendTextRequest] instead of `functions.invoke`, so every
/// phase carries a timeout.
///
/// The three optional parameters are the seam for the runtime wire test
/// (search_key_fetcher_wire_test.dart). Production uses the argument-less
/// const constructor; the defaults resolve to the globals at runtime.
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
    // The fetch never throws; the budget only caps the caller's wait. A late
    // result is discarded.
    return work.timeout(budget, onTimeout: () => null);
  }

  Future<FetchedSearchCredentials?> _fetch() async {
    HttpClient? client;
    try {
      // All Supabase access sits inside the try: without
      // `Supabase.initialize` even `Supabase.instance` throws, which here
      // simply means "no fetch possible".
      final token = _tokenProvider != null
          ? _tokenProvider()
          : Supabase.instance.client.auth.currentSession?.accessToken;
      if (token == null || token.isEmpty) {
        // No token = cold-start window while a restored session refreshes.
        // Keep what is there, do not switch off.
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

      // Any non-2xx means "keep what you have": a missing server secret must
      // not switch off a working search on an installed build.
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

      // Both fields empty = the function's kill switch. Must come BEFORE the
      // https check: an empty URL is not `https`, so the check would turn the
      // shutdown into `null`, which means "keep what you have".
      if (trimmedBaseUrl.isEmpty && trimmedKey.isEmpty) {
        dev.log('search-key meldet Kill-Switch — Mirror wird abgeschaltet',
            name: 'search_credentials');
        return FetchedSearchCredentials(baseUrl: '', searchKey: '', ttl: ttl);
      }
      // Only one field empty is not a kill switch but a broken server (half
      // a secret update). Keep what is there.
      if (trimmedBaseUrl.isEmpty || trimmedKey.isEmpty) {
        dev.log('search-key lieferte halb leere Credentials — verworfen',
            name: 'search_credentials');
        return null;
      }
      // A non-https mirror is never adopted: no plaintext key on the wire,
      // nothing written to disk.
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

/// Runtime resolution of the mirror credentials.
///
/// Chain: **cache -> fetch -> compile-time default -> mirror off.** The
/// search must never hard-fail just because the key endpoint is unreachable;
/// worst case it lands in the OpenFoodFacts fallback.
///
/// Three properties carry the design:
///
///  * [current] is synchronous and never blocks — the Food tab's build path
///    reruns on every `notifyListeners()` and tolerates no `await`.
///  * [resolveForRequest] waits only on the running DISK hydration (capped by
///    [_hydrationGrace]), never on the network.
///  * [invalidate] is the real rotation mechanism (401/403 from the mirror),
///    single-flight and with a cooldown.
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

  /// Process-wide singleton. Construction is pure allocation: no plugin
  /// channel, no `Supabase.instance`, no I/O.
  static SearchCredentialsStore get instance =>
      _instance ??= SearchCredentialsStore();
  static SearchCredentialsStore? _instance;

  /// Persistence slot, deliberately without a user suffix: the search-only
  /// key is device-global config, not PII, and `LocalCache.clear()` would
  /// throw a working key away on every sign-out.
  static const String cacheKey = 'eatova.v1.search_credentials';

  /// TTL bounds, catching a server that sends nonsense (0 s -> fetch storm,
  /// 10 years -> never rotates again).
  static const Duration minTtl = Duration(hours: 1);
  static const Duration maxTtl = Duration(days: 7);

  /// Time budget of the 403 path: the search is already waiting, so beyond
  /// ~3 s the detour is not worth it and OpenFoodFacts wins.
  static const Duration _invalidateBudget = Duration(seconds: 3);

  /// Mandatory, not cosmetic: the add sheet retries a search up to 3x and the
  /// 1000 ms debounce fires one per typing pause. Without a cooldown a mirror
  /// returning 403 for unrelated reasons would burn the 20/h edge-function
  /// limit in seconds.
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

  /// Counts every invalidation, so a background refresh started BEFORE a
  /// rotation cannot overwrite the fresh key with its stale result.
  int _generation = 0;

  /// Synchronous, never null, never blocks. Before hydration (and with
  /// nothing cached) the compile-time default.
  SearchCredentials get current =>
      _memory ?? SearchCredentials.compileTimeDefault;

  /// Idempotent warm-up: read disk, then the network if needed.
  /// Fire-and-forget — never throws, never blocks a UI path.
  Future<void> warmUp() {
    final existing = _warmUp;
    if (existing != null) return existing;
    final started = _warmUpInternal();
    _warmUp = started;
    return started;
  }

  /// What the next search request should use. Waits only on the running disk
  /// hydration (capped), never on the network.
  Future<SearchCredentials> resolveForRequest() async {
    // Starts the hydration itself if needed — this runs on the async search
    // path, so the search does not depend on the warm-up to see the cache.
    final hydration = _hydrateFromDisk();
    try {
      await hydration.timeout(_hydrationGrace);
    } catch (_) {
      // Disk too slow or broken -> carry on with what is there.
    }
    return current;
  }

  /// The mirror rejected [rejected] with 401/403. Evicts the key from memory
  /// AND disk and fetches a replacement. Returns the new credentials (or
  /// unusable ones if there is no replacement). Never throws.
  Future<SearchCredentials> invalidate(SearchCredentials rejected) async {
    try {
      // 1. Single-flight: share a running invalidation's result instead of
      //    firing a second edge-function request.
      //
      //    Must come before the stale check: a running invalidation already
      //    cleared `_memory`, so a parallel caller would wrongly see "already
      //    rotated" and get empty credentials.
      final inFlight = _invalidateInFlight;
      if (inFlight != null) return await inFlight;

      // 2. Already rotated? Another caller was faster; the retry takes the
      //    new key without fetching anything.
      if (!_isCurrent(rejected)) return current;

      // 3. Cooldown (see [_invalidateCooldown]).
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

      // Log once when the rotation actually took, otherwise a broken
      // rotation is invisible: FallbackProductService returns plausible OFF
      // hits either way.
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

  // --- internal -------------------------------------------------------------

  Future<void> _warmUpInternal() async {
    try {
      await _hydrateFromDisk();
      // Expired entries are still USED (already in `_memory`) and only
      // refreshed in the background, so a week offline still searches.
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

  /// Single-flight background refresh. A failure changes nothing; an expired
  /// cache entry in particular stays in use.
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
    // A rotation happened during the fetch -> this result is stale.
    if (fetched == null || generation != _generation) return current;
    return _adopt(fetched);
  }

  Future<SearchCredentials> _dropAndRefetch(SearchCredentials rejected) async {
    _generation++;
    // Evict the dead key from memory and disk FIRST: a crash mid-refetch
    // must not resurrect it.
    _memory = SearchCredentials.disabled;
    _diskEntry = null;
    await _removeFromDisk();

    final fetched = await _fetcher.fetch(budget: _invalidateBudget);
    if (fetched != null) return _adopt(fetched);

    // No replacement reachable. The compile-time default is only an option
    // if it is not itself the rejected key — otherwise the retry is a
    // guaranteed 403.
    const fallback = SearchCredentials.compileTimeDefault;
    if (fallback.isUsable && fallback.searchKey != rejected.searchKey) {
      _memory = fallback;
      return fallback;
    }

    // Deliberately left unusable: the next search skips the mirror without a
    // pointless request, and the next app start refetches via [warmUp].
    return current;
  }

  Future<SearchCredentials> _adopt(FetchedSearchCredentials fetched) async {
    // The kill switch is adopted like any other response, disk included:
    // only overwriting the slot takes the old key's last home.
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
        // Corrupt or unknown schema -> treat as absent and clear it (same
        // defensive stance as LocalCache._readJson).
        await store.remove(cacheKey);
        return;
      }
      _diskEntry = entry;
      // A value already in memory (just fetched or just invalidated) always
      // beats the disk.
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

  /// Own [SharedPreferencesStore] instance, deliberately not [LocalCache]'s:
  /// its `clear()` wipes everything on sign-out.
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

  /// Clamps the TTL to [minTtl]..[maxTtl].
  ///
  /// The TTL is not the rotation mechanism — the 403 path is, and it
  /// converges within one search. Its only remaining job is propagating a
  /// base-URL change, which yields connection errors instead of 403 and so
  /// cannot heal itself.
  static Duration clampTtl(Duration ttl) {
    if (ttl < minTtl) return minTtl;
    if (ttl > maxTtl) return maxTtl;
    return ttl;
  }
}

/// Persisted entry. Wire format:
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

  /// Anything missing, mistyped or unparsable invalidates the WHOLE entry
  /// (null) — never a crash, never a half-loaded key.
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
      // Both fields empty means the same as in the server response: kill
      // switch. Such an entry only comes from [_adopt] and must survive a
      // restart; rejecting it here would make every cold start fall back to
      // the compiled-in key the switch was pulled for. Half-empty entries
      // stay invalid (broken disk, not a switch) via the https check below.
      //
      // A tampered or legacy-http entry with a non-https mirror is invalid.
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

/// Seam between [MeilisearchProductService] and the store.
///
/// Exists so the service stays `const`-constructible: the search needs
/// runtime values, but its default parameters must be compile-time
/// constants. A `const` instance may read mutable statics in its METHODS,
/// which is what [GlobalSearchCredentialsSource] does.
abstract class SearchCredentialsSource {
  const SearchCredentialsSource();

  Future<SearchCredentials> resolve();

  Future<SearchCredentials> invalidate(SearchCredentials rejected);
}

/// Production seam: delegates to [SearchCredentialsStore.instance].
class GlobalSearchCredentialsSource extends SearchCredentialsSource {
  const GlobalSearchCredentialsSource();

  @override
  Future<SearchCredentials> resolve() =>
      SearchCredentialsStore.instance.resolveForRequest();

  @override
  Future<SearchCredentials> invalidate(SearchCredentials rejected) =>
      SearchCredentialsStore.instance.invalidate(rejected);
}
