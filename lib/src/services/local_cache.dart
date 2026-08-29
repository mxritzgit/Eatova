import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:shared_preferences/shared_preferences.dart';

import '../models/favorite_meal.dart';
import '../models/fitness_recipe.dart';
import '../models/lifetime_stats.dart';
import '../models/logged_meal.dart';
import '../models/user_profile.dart';
import '../models/weight_log.dart';
import 'crash_reporter.dart';
import 'secure_cache_store.dart';
import 'sync_outbox.dart';

/// Minimal async key-value store behind [LocalCache]. Abstracts
/// SharedPreferences so the cache is unit-testable without a plugin channel
/// (see [InMemoryKeyValueStore]).
abstract class KeyValueStore {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

/// What the raw storage holds for a key — and, when it holds something the
/// caller could not use, whether a later read can do better.
///
/// P3-02c: the two occupied cases look identical from the outside (both end in
/// `null`) but call for opposite reactions, so they must not share a verdict.
enum RawSlotState {
  /// Nothing stored: overwriting or deleting loses nothing.
  empty,

  /// Bytes are there and the last read HANDED THEM OVER. If the caller still
  /// could not use them, the CONTENT is broken and no retry changes that.
  brokenContent,

  /// Bytes are there and the last read could not even EXECUTE the decryption
  /// (isolate spawn, OOM, RemoteError). The bytes are intact; the next read
  /// can succeed, so the slot must not be given up.
  unreadableForNow,
}

/// Extra capability of a store that TRANSFORMS values on read (decryption):
/// tells whether the underlying storage still holds bytes for a key, without
/// decoding them.
///
/// P3-02: such a store has to answer "slot unreadable" with the same `null` as
/// "slot empty" — a failed isolate spawn says nothing about the ciphertext, so
/// the slot must stay. For the `OrThrow` readers those two cases are opposites:
/// only "empty" allows overwriting and deleting the persisted blob. Asking the
/// STORAGE instead of the cipher keeps the answer independent of which error
/// class a future decryption failure falls into.
abstract class RawSlotProbe {
  /// State of [key] in the raw storage. Throws if the storage itself cannot
  /// answer — the caller must not read that as "empty".
  ///
  /// P3-02c: the store also reports WHY a read failed, which only it knows.
  /// Without that, [LocalCache._assertSlotEmpty] had to call every occupied
  /// slot equally unreadable, and the repair path could only bound itself by
  /// counting attempts.
  Future<RawSlotState> rawSlotState(String key);
}

/// Platform default: SharedPreferences, built in production via
/// [LocalCache.create]. Already a transitive dependency of supabase_flutter.
class SharedPreferencesStore implements KeyValueStore {
  SharedPreferencesStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<SharedPreferencesStore> create() async {
    final prefs = await SharedPreferences.getInstance();
    return SharedPreferencesStore(prefs);
  }

  @override
  Future<String?> getString(String key) async => _prefs.getString(key);

  @override
  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);

  @override
  Future<void> remove(String key) => _prefs.remove(key);
}

/// In-memory store for tests (no plugin channel needed).
class InMemoryKeyValueStore implements KeyValueStore {
  InMemoryKeyValueStore([Map<String, String>? initial])
      : _data = {...?initial};

  final Map<String, String> _data;

  Map<String, String> get snapshot => Map.unmodifiable(_data);

  @override
  Future<String?> getString(String key) async => _data[key];

  @override
  Future<void> setString(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _data.remove(key);
  }
}

/// Thin write-through cache (JSON in SharedPreferences) for one user's data
/// (DATA-3).
///
/// An offline cold start must not show the bare ctor defaults, and a following
/// save must not overwrite the real server row with them. HomePage hydrates
/// from this cache first, then from the network; every persisted mutation
/// writes here too.
///
/// Keyed per user (SharedPreferences is global). All reads/writes are
/// defensive: a corrupt entry yields null instead of crashing.
class LocalCache {
  LocalCache(this._store, this._userId) {
    _open.add(this);
  }

  final KeyValueStore _store;
  final String _userId;

  /// Every instance not yet closed, so a purge from OUTSIDE the store (the
  /// AuthGate builds its own instance on session loss) can silence the
  /// store's instance first — see [closeInstancesFor]. Instances are few
  /// (one per session) and leave the set on [close].
  static final Set<LocalCache> _open = <LocalCache>{};

  /// Lifecycle fence (review 2026-08-27, F1-02): once set, EVERY write path
  /// is a no-op, the debounce drain included. Reads keep working. Set by
  /// [clear] and [close]; never reset — a purged namespace is not reused by
  /// this instance.
  bool _closed = false;

  bool get isClosed => _closed;

  /// Closes this instance: drops pending debounced writes and turns every
  /// later write into a no-op. Idempotent. [clear] calls it first, so a
  /// straggling write (debounce timer, running snapshot, late live-op
  /// callback) cannot put PII back into a purged slot.
  void close() {
    _closed = true;
    _discardPendingWrites();
    _open.remove(this);
  }

  /// Closes every open instance of [userId] AND waits for the writes already
  /// inside the store — the AuthGate purge runs on a SECOND instance and must
  /// silence the store's own one, else its debounce timer and late callbacks
  /// write after the purge.
  ///
  /// P3-01: closing alone is not enough. The [_closed] fence only stops writes
  /// that have not STARTED; a blob already handed to the encryption isolate is
  /// past it and lands 200-400 ms later (see [writeDebounce]). The purge
  /// removes through the SECOND instance's own [EncryptedKeyValueStore], whose
  /// write queue serialises per key AND per instance, so that `remove` does not
  /// queue behind the running `setString` — the PII slot came back after the
  /// purge and survived the logout on the device. Waiting orders the two.
  ///
  /// Same reasoning as `HomeStore._clearCache`, which waits for a running
  /// snapshot; this is the AuthGate half of that protection. Bounded by
  /// [settleBudget] and never throws, so a hung store cannot block the auth
  /// transition — [_writeJson]'s own cleanup then takes over.
  static Future<void> closeInstancesFor(String userId) async {
    final betroffen =
        _open.where((cache) => cache._userId == userId).toList(growable: false);
    for (final cache in betroffen) {
      cache.close();
    }
    await Future.wait(betroffen.map((cache) => cache.settle()));
  }

  /// Upper bound for [settle]: local IO plus one isolate hop. Anything longer
  /// is a hung plugin, and a purge must not stall the auth transition behind
  /// it. Same value as `kCacheSnapshotWaitBudget` for the sibling wait.
  static const Duration settleBudget = Duration(seconds: 3);

  /// Writes that passed the [_closed] fence and are still running. Holds
  /// error-swallowing copies: [settle] only WAITS, the originating caller
  /// keeps its own error handling.
  final Set<Future<void>> _inFlightWrites = <Future<void>>{};

  /// Waits until every write that passed the fence has finished, at most
  /// [settleBudget]. Never throws.
  ///
  /// Needed by every purge that runs on a DIFFERENT instance, because only the
  /// store's per-key queue can order a `remove` behind a `setString` — and
  /// that queue is per instance ([closeInstancesFor]).
  Future<void> settle() {
    if (_inFlightWrites.isEmpty) return Future<void>.value();
    return _settleWrites().timeout(settleBudget, onTimeout: () {});
  }

  Future<void> _settleWrites() async {
    // A landing write can release the next one (the debounce drain walks its
    // slots one by one), so loop instead of waiting once.
    while (_inFlightWrites.isNotEmpty) {
      await Future.wait(_inFlightWrites.toList(growable: false));
    }
  }

  /// Registers [write] for [settle] and returns it UNCHANGED, so the caller
  /// still sees its result and its errors.
  Future<T> _trackWrite<T>(Future<T> write) {
    final Future<void> tracked =
        write.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _inFlightWrites.add(tracked);
    unawaited(tracked.whenComplete(() => _inFlightWrites.remove(tracked)));
    return write;
  }

  /// Drops pending debounced writes WITHOUT closing — `HomeStore.dispose`
  /// uses it: the instance may outlive the store, the store's last mirror
  /// state must not.
  void discardPendingWrites() => _discardPendingWrites();

  /// Builds the production cache on SharedPreferences, encrypted with the OS
  /// keystore DEK (SEC-1, secure_cache_store.dart). Returns null on plugin
  /// error or when the DEK is neither readable nor creatable, so the caller
  /// runs on without a cache. No plaintext fallback — no cache beats an
  /// unencrypted one.
  ///
  /// The decorator is added only here; the public constructor still takes a
  /// bare [KeyValueStore] so tests can drive plaintext values.
  static Future<LocalCache?> create(String userId) async {
    try {
      final base = await SharedPreferencesStore.create();
      final store = await EncryptedKeyValueStore.create(base);
      if (store == null) return null;
      final cache = LocalCache(store, userId);
      await cache.dropLegacySlots();
      return cache;
    } catch (e, s) {
      dev.log('LocalCache.create failed', error: e, stackTrace: s,
          name: 'local_cache');
      return null;
    }
  }

  /// Deletes slots that only exist in old installations.
  ///
  /// Currently [_legacyDailyKey]: pre-Today-tab installs still hold a
  /// daily_logs snapshot including the free-text mood note there, and the
  /// encrypting decorator would never touch it (it only encrypts on write).
  /// So the slot must go, not be encrypted.
  ///
  /// Public so it is testable through the plain constructor.
  Future<void> dropLegacySlots() => _store.remove(_legacyDailyKey);

  // Version prefix allows later schema migrations without crashing on old
  // entries (unknown keys are ignored).
  String get _profileKey => 'eatova.v1.profile.$_userId';

  /// Legacy slot of the former Today tab (daily_logs snapshot incl. mood
  /// note). No longer read or written, but still cleared in [clear] so old
  /// installs keep no PII after logout (M-1).
  String get _legacyDailyKey => 'eatova.v1.daily.$_userId';
  String get _statsKey => 'eatova.v1.stats.$_userId';
  String get _notificationsKey => 'eatova.v1.notifications_enabled.$_userId';

  // DATA-7 offline persistence: diary, favorites and weight log are mirrored
  // so an offline cold start does not begin with an empty diary. Plus the
  // write outbox and the pending lifetime-stats deltas, both of which must
  // survive an app kill. All slots are PII and are cleared in [clear].
  String get _loggedMealsKey => 'eatova.v1.logged_meals.$_userId';
  String get _favoritesKey => 'eatova.v1.favorites.$_userId';
  String get _weightLogKey => 'eatova.v1.weight_log.$_userId';
  String get _outboxKey => 'eatova.v1.outbox.$_userId';
  String get _pendingStatsKey => 'eatova.v1.pending_stats.$_userId';

  /// Gap A: user-created recipes, previously the only user collection with a
  /// single safety net (the outbox). Now the same write-through as diary and
  /// favorites. PII (ingredients, amounts) -> cleared in [clear].
  String get _userRecipesKey => 'eatova.v1.user_recipes.$_userId';

  /// Daily activity: steps plus estimated burned kcal per local calendar day
  /// (blob key: YYYY-MM-DD, see local_day.dart). Health data, so PII ->
  /// cleared in [clear]. Local only, no Supabase table: a server sync would
  /// upload health data that is never needed there.
  String get _dailyActivityKey => 'eatova.v1.daily_activity.$_userId';

  // ---- Reminders (PROD-1) -------------------------------------------------
  // Opt-in flag for the local retention nudges, persisted per user so a cold
  // start only re-schedules them if the user opted in. Reuses the JSON slot
  // instead of a bool channel to keep the wire path uniform and defensive.

  /// Writes the reminder opt-in flag. No-op on plugin error (see _writeJson).
  Future<void> writeNotificationsEnabled(bool enabled) =>
      _writeJson(_notificationsKey, <String, dynamic>{'enabled': enabled});

  /// Reads the opt-in flag. Missing or corrupt -> null; the caller picks its
  /// default (in the app: off until the user opts in).
  Future<bool?> readNotificationsEnabled() async {
    final json = await _readJson(_notificationsKey);
    if (json == null) return null;
    final v = json['enabled'];
    return v is bool ? v : null;
  }

  // ---- Profile ------------------------------------------------------------

  // The wire format (userProfileToJson/-FromJson) lives in sync_outbox.dart:
  // the profile has two persistence paths (this slot and the outbox op), and
  // two copies of the same mapping is exactly what the completeness test in
  // local_cache_test guards against.
  Future<void> writeProfile(UserProfile profile) =>
      _writeJson(_profileKey, userProfileToJson(profile));

  Future<UserProfile?> readProfile() async {
    final json = await _readJson(_profileKey);
    if (json == null) return null;
    try {
      final profile = userProfileFromJson(json);
      if (profile == null) {
        dev.log(
            'LocalCache.readProfile: Blob unvollstaendig (Zahlenfeld fehlt/'
            'unlesbar) — verworfen, Server-Load liefert die Wahrheit',
            name: 'local_cache');
      }
      return profile;
    } catch (e) {
      dev.log('LocalCache.readProfile parse failed', error: e,
          name: 'local_cache');
      return null;
    }
  }

  // ---- lifetime_stats -----------------------------------------------------

  Future<void> writeLifetimeStats(LifetimeStats stats) =>
      _writeJson(_statsKey, _statsToJson(stats));

  Future<LifetimeStats?> readLifetimeStats() async {
    final json = await _readJson(_statsKey);
    if (json == null) return null;
    try {
      return LifetimeStats.fromRow(json);
    } catch (e) {
      dev.log('LocalCache.readLifetimeStats parse failed', error: e,
          name: 'local_cache');
      return null;
    }
  }

  // ---- Diary / favorites / weight (DATA-7) --------------------------------
  // Lists are wrapped as {'items': [...]} so the defensive map-based wire
  // path (_readJson/_writeJson) carries them unchanged.

  Future<void> writeLoggedMeals(List<LoggedMeal> meals) =>
      _writeJson(_loggedMealsKey, <String, dynamic>{
        'items': meals.map(loggedMealToJson).toList(),
      });

  Future<List<LoggedMeal>?> readLoggedMeals() async {
    final items = await _readItems(_loggedMealsKey);
    if (items == null) return null;
    try {
      return items.map(loggedMealFromJson).toList();
    } catch (e) {
      dev.log('LocalCache.readLoggedMeals parse failed', error: e,
          name: 'local_cache');
      return null;
    }
  }

  Future<void> writeFavorites(List<FavoriteMeal> favorites) =>
      _writeJson(_favoritesKey, <String, dynamic>{
        'items': favorites.map(favoriteMealToJson).toList(),
      });

  Future<List<FavoriteMeal>?> readFavorites() async {
    final items = await _readItems(_favoritesKey);
    if (items == null) return null;
    try {
      return items.map(favoriteMealFromJson).toList();
    } catch (e) {
      dev.log('LocalCache.readFavorites parse failed', error: e,
          name: 'local_cache');
      return null;
    }
  }

  /// User recipes (gap A). The wire format is deliberately the server row
  /// ([FitnessRecipe.toRow]/[FitnessRecipe.fromRow]), so a cached recipe is
  /// byte-identical to a freshly loaded one, including the fields `fromRow`
  /// synthesizes.
  Future<void> writeUserRecipes(List<FitnessRecipe> recipes) =>
      _writeJson(_userRecipesKey, _userRecipesToJson(recipes));

  static Map<String, dynamic> _userRecipesToJson(List<FitnessRecipe> recipes) =>
      <String, dynamic>{
        'items': recipes.map((r) => r.toRow()).toList(),
      };

  Future<List<FitnessRecipe>?> readUserRecipes() async {
    final items = await _readItems(_userRecipesKey);
    if (items == null) return null;
    try {
      return items.map(FitnessRecipe.fromRow).toList();
    } catch (e) {
      // Like diary/favorites: the whole slot drops out (null); the server
      // load or next write fixes it. A recipe without a slug throws in
      // fromRow — the slug is the upsert conflict key and must never be
      // invented (S4).
      dev.log('LocalCache.readUserRecipes parse failed', error: e,
          name: 'local_cache');
      return null;
    }
  }

  /// Daily activity (see [_dailyActivityKey]). Wire format:
  /// `{'days': {'2026-08-11': {'steps': 8123, 'kcal': 312}}}`.
  Future<void> writeDailyActivity(
    Map<String, ({int steps, int kcal})> days,
  ) =>
      _writeJson(_dailyActivityKey, <String, dynamic>{
        'days': <String, dynamic>{
          for (final e in days.entries)
            e.key: <String, dynamic>{
              'steps': e.value.steps,
              'kcal': e.value.kcal,
            },
        },
      });

  /// Reads the daily activity. Missing or corrupt -> null; single unreadable
  /// days are skipped rather than dropping the whole slot (as in
  /// [readOutbox]).
  Future<Map<String, ({int steps, int kcal})>?> readDailyActivity() async {
    final json = await _readJson(_dailyActivityKey);
    final days = json?['days'];
    if (days is! Map) return null;
    final result = <String, ({int steps, int kcal})>{};
    for (final entry in days.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      result['${entry.key}'] = (
        steps: _int(value['steps'], 0),
        kcal: _int(value['kcal'], 0),
      );
    }
    return result;
  }

  Future<void> writeWeightLog(WeightLog log) =>
      _writeJson(_weightLogKey, _weightLogToJson(log));

  static Map<String, dynamic> _weightLogToJson(WeightLog log) =>
      <String, dynamic>{
        'items': log.entries
            .map((e) => <String, dynamic>{
                  't': e.timestamp.toIso8601String(),
                  'kg': e.weightKg,
                })
            .toList(),
      };

  Future<WeightLog?> readWeightLog() async {
    final items = await _readItems(_weightLogKey);
    if (items == null) return null;
    try {
      final entries = items
          .map((j) => WeightLogEntry(
                timestamp: DateTime.parse(j['t'] as String),
                weightKg: (j['kg'] as num).toDouble(),
              ))
          .toList();
      return WeightLog(entries: entries);
    } catch (e) {
      dev.log('LocalCache.readWeightLog parse failed', error: e,
          name: 'local_cache');
      return null;
    }
  }

  // ---- Write outbox + pending stats deltas (DATA-7) -----------------------
  //
  // These two slots go through [_writeDurable], not [_writeJson]: they are
  // the kill safeguard itself, not a speed-up cache.

  /// Writes the outbox. `true` = the blob is on disk, `false` = it is not and
  /// the ops will not survive an app kill.
  ///
  /// The return value is the signal [_writeJson] lacks; existing callers may
  /// keep ignoring it.
  Future<bool> writeOutbox(List<SyncOp> ops) =>
      _writeDurable(_outboxKey, 'outbox', <String, dynamic>{
        'items': ops.map((o) => o.toJson()).toList(),
      });

  /// Reads the persisted outbox. Corrupt or unknown ops are skipped
  /// (SyncOp.tryFromJson) instead of dropping the whole queue.
  Future<List<SyncOp>?> readOutbox() async {
    final items = await _readItems(_outboxKey);
    if (items == null) return null;
    final ops = <SyncOp>[];
    for (final item in items) {
      final op = SyncOp.tryFromJson(item);
      if (op != null) ops.add(op);
    }
    return ops;
  }

  /// Like [readOutbox], but reports a READ ERROR instead of swallowing it.
  ///
  /// Boot hydration is the only reader for which "slot empty" and "slot
  /// unreadable" differ: only in the second case must the next enqueue not
  /// overwrite the persisted blob (up to [kOutboxMaxOps] undelivered writes
  /// hang on it; the guard itself is in `_persistOutbox`,
  /// home_store_sync.dart). All other readers stay on [readOutbox], where a
  /// broken slot is simply "no cache".
  Future<List<SyncOp>?> readOutboxOrThrow() async {
    final ops = await readOutbox();
    if (ops != null) return ops;
    await _assertSlotEmpty(_outboxKey, 'outbox');
    return null;
  }

  /// Writes the pending lifetime deltas together with their request id.
  ///
  /// [requestId] is the bundle's idempotency key
  /// (`increment_lifetime_stats(p_request_id)`). It must be stored WITH the
  /// numbers: a retry only works if it sends the SAME id — a fresh one would
  /// count a second time on the server.
  ///
  /// `null` is written as a MISSING key, not `'request_id': null`, so an
  /// empty bundle keeps the old wire shape and older builds can still read
  /// the slot.
  ///
  /// Return value as in [writeOutbox]: `false` means the deltas are only in
  /// memory and a kill loses these meals' lifetime counters.
  Future<bool> writePendingStatsDeltas({
    required int meals,
    required int weightLogs,
    String? requestId,
  }) =>
      _writeDurable(_pendingStatsKey, 'pending_stats', <String, dynamic>{
        'meals': meals,
        'weight_logs': weightLogs,
        if (requestId != null) 'request_id': requestId,
      });

  /// Reads the pending deltas. [requestId] is `null` for slots from an older
  /// build; the caller assigns one then.
  Future<({int meals, int weightLogs, String? requestId})?>
      readPendingStatsDeltas() async {
    final json = await _readJson(_pendingStatsKey);
    if (json == null) return null;
    final rid = json['request_id'];
    return (
      meals: _int(json['meals'], 0),
      weightLogs: _int(json['weight_logs'], 0),
      requestId: rid is String && rid.isNotEmpty ? rid : null,
    );
  }

  /// Like [readPendingStatsDeltas], but reports a read error (see
  /// [readOutboxOrThrow]). The next flush rewrites the slot wholesale, so a
  /// swallowed read error would restart it at 0 and leave the lifetime
  /// counters short by the stranded meals.
  Future<({int meals, int weightLogs, String? requestId})?>
      readPendingStatsDeltasOrThrow() async {
    final deltas = await readPendingStatsDeltas();
    if (deltas != null) return deltas;
    await _assertSlotEmpty(_pendingStatsKey, 'pending_stats');
    return null;
  }

  /// Clears the user slots.
  ///
  /// [preserveOutbox] `true` keeps exactly [_outboxKey] and [_pendingStatsKey]
  /// and deletes everything else (A2): sign-out must not destroy unsynced
  /// meals — they replay on the same user's next login. Both slots are
  /// encrypted and namespaced by user id, so the M-1 PII argument no longer
  /// applies to them.
  ///
  /// Default `false` = account deletion clears everything.
  Future<void> clear({bool preserveOutbox = false}) async {
    // Close BEFORE clearing: drops pending debounced writes (G9b) and turns
    // every later write into a no-op, so nothing running past this point can
    // write the just-deleted PII straight back (F1-02).
    close();

    await _store.remove(_profileKey);
    await _store.remove(_legacyDailyKey);
    await _store.remove(_statsKey);
    await _store.remove(_notificationsKey);
    await _store.remove(_loggedMealsKey);
    await _store.remove(_favoritesKey);
    await _store.remove(_weightLogKey);
    // User recipes are user content (ingredients, amounts): same M-1 reason
    // as the diary, even with [preserveOutbox].
    await _store.remove(_userRecipesKey);
    // Steps/burned kcal are health data — same M-1 reason.
    await _store.remove(_dailyActivityKey);
    if (preserveOutbox) return;
    await _store.remove(_outboxKey);
    await _store.remove(_pendingStatsKey);
  }

  // ---- Debounced blob writes (G9b) ----------------------------------------
  // Diary, favorites, weight log and user recipes are mirrors of the server
  // state and get fully rewritten on every mutation: the whole blob through
  // jsonEncode + AES-GCM + base64, measured at 91.5 ms for 210 meals on
  // desktop JIT (mobile AOT 2-4x slower). The debounced variants collapse all
  // calls within [writeDebounce] into one write per slot.
  //
  // Deliberately NOT debounced: outbox and pending stats deltas — they are
  // the kill safeguard (DATA-7) and must hit disk at once. Losing a mirror
  // slot only costs a network load. Profile and lifetime_stats stay immediate
  // too: small maps, negligible crypto cost.

  /// Window in which several debounced writes collapse into one. Runs from
  /// the FIRST call (no cancel+restart), so a long series cannot push the
  /// write out indefinitely.
  static const Duration writeDebounce = Duration(milliseconds: 400);

  final Map<String, Map<String, dynamic>> _pendingWrites =
      <String, Map<String, dynamic>>{};
  Timer? _debounceTimer;

  /// True while at least one debounced write is pending.
  bool get hasPendingWrites => _pendingWrites.isNotEmpty;

  /// Debounced write-through for the diary; replaces [writeLoggedMeals] on
  /// the hot mutation path.
  void writeLoggedMealsDebounced(List<LoggedMeal> meals) =>
      _scheduleWrite(_loggedMealsKey, <String, dynamic>{
        'items': meals.map(loggedMealToJson).toList(),
      });

  /// Debounced write-through for the favorites.
  void writeFavoritesDebounced(List<FavoriteMeal> favorites) =>
      _scheduleWrite(_favoritesKey, <String, dynamic>{
        'items': favorites.map(favoriteMealToJson).toList(),
      });

  /// Debounced write-through for the weight log.
  void writeWeightLogDebounced(WeightLog log) =>
      _scheduleWrite(_weightLogKey, _weightLogToJson(log));

  /// Debounced write-through for the user recipes (gap A). Same reasoning:
  /// the slot is rewritten on every mutation and losing it only costs a
  /// network load.
  void writeUserRecipesDebounced(List<FitnessRecipe> recipes) =>
      _scheduleWrite(_userRecipesKey, _userRecipesToJson(recipes));

  /// Flushes all pending debounced writes immediately.
  ///
  /// Must run on app pause/hidden/detach (and before any logout [clear] does
  /// not cover), or a kill inside the [writeDebounce] window loses the last
  /// mirror state.
  Future<void> flush() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _drainPendingWrites();
  }

  void _scheduleWrite(String key, Map<String, dynamic> value) {
    if (_closed) return;
    // Last state wins: the slot is always written whole, so an older blob of
    // the same slot is worthless.
    _pendingWrites[key] = value;
    _debounceTimer ??= Timer(writeDebounce, () {
      _debounceTimer = null;
      unawaited(_drainPendingWrites());
    });
  }

  Future<void> _drainPendingWrites() async {
    if (_pendingWrites.isEmpty) return;
    final batch = Map<String, Map<String, dynamic>>.of(_pendingWrites);
    _pendingWrites.clear();
    for (final entry in batch.entries) {
      // Re-checked per slot: a clear() can land between two awaits.
      if (_closed) return;
      await _writeJson(entry.key, entry.value);
    }
  }

  void _discardPendingWrites() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _pendingWrites.clear();
  }

  // ---- Low-level ----------------------------------------------------------

  Future<void> _writeJson(String key, Map<String, dynamic> value) {
    if (_closed) return Future<void>.value();
    // An immediate write to the same slot invalidates a pending debounced
    // one, which would otherwise overwrite the fresher state later.
    _pendingWrites.remove(key);
    // Tracked so a purge on ANOTHER instance can wait for it ([settle]).
    return _trackWrite(_writeJsonNow(key, value));
  }

  Future<void> _writeJsonNow(String key, Map<String, dynamic> value) async {
    try {
      await _store.setString(key, jsonEncode(value));
      // P3-01, second fence: the instance can be closed DURING the write. The
      // one above only stops writes that have not started, and the encryption
      // runs in an isolate. Whoever closed is purging, and every slot on this
      // path is cleared unconditionally (see [clear]), so take the blob back
      // out. The `remove` rides the store's OWN per-key queue and therefore
      // lands after this write. Deliberately not in [_writeDurable]: a purge
      // with `preserveOutbox` keeps exactly those two slots.
      if (_closed) await _store.remove(key);
    } catch (e) {
      // A cache write must never kill the UI path — it is pure speed-up for
      // the next cold start, so failures are dropped silently.
      //
      // This holds only for the mirror slots, whose content also lives on the
      // server. Sync-state slots go through [_writeDurable] instead: what is
      // lost there exists nowhere else.
      dev.log('LocalCache write failed ($key)', error: e, name: 'local_cache');
    }
  }

  /// Write path for the sync-state slots (outbox, pending stats deltas).
  ///
  /// Separate from [_writeJson] because these two slots ARE the kill
  /// safeguard (DATA-7), not a speed-up cache: their content exists nowhere
  /// else, so a silently swallowed failure is data loss without any signal.
  ///
  /// Hence two differences: the failure goes (sanitized) to the
  /// [CrashReporter], and the caller gets `false`. Still never throws — the
  /// callers run `unawaited` on the UI path.
  Future<bool> _writeDurable(
    String key,
    String slot,
    Map<String, dynamic> value,
  ) {
    // Closed = not on disk, and the caller is told so; the outbox keeps its
    // in-memory copy and replays on the next login (A2).
    if (_closed) return Future<bool>.value(false);
    // Same invariant as in [_writeJson]: it belongs to the slot, not the
    // caller. A no-op for the two sync slots, which are never debounced.
    _pendingWrites.remove(key);
    // Tracked like [_writeJson]: an account deletion purges these slots too,
    // so it has to wait for a running write (P3-01).
    return _trackWrite(_writeDurableNow(key, slot, value));
  }

  Future<bool> _writeDurableNow(
    String key,
    String slot,
    Map<String, dynamic> value,
  ) async {
    try {
      await _store.setString(key, jsonEncode(value));
      return true;
    } catch (e, s) {
      dev.log('LocalCache durable write failed ($slot)',
          error: e, stackTrace: s, name: 'local_cache');
      // Only slot name and error type leave: never the key (holds the user
      // id) and never the value (health data). Even a FormatException carries
      // its source in the message.
      unawaited(CrashReporter.capture(
        UnwritableCacheSlot(slot, e.runtimeType.toString()),
        s,
        context: 'cache_durable_write',
      ));
      return false;
    }
  }

  /// Reads a list slot wrapped as {'items': [...]} and returns its map
  /// entries. Missing or structurally broken -> null ("no cache").
  Future<List<Map<String, dynamic>>?> _readItems(String key) async {
    final json = await _readJson(key);
    final items = json?['items'];
    if (items is! List) return null;
    return items
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
  }

  Future<Map<String, dynamic>?> _readJson(String key) async {
    // A pending debounced write is the newest state; without this passthrough
    // the slot would have a read-after-write hole between schedule and write.
    final pending = _pendingWrites[key];
    if (pending != null) return pending;
    try {
      final raw = await _store.getString(key);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } catch (e) {
      dev.log('LocalCache read failed ($key)', error: e, name: 'local_cache');
      return null;
    }
  }

  /// Throws [UnreadableCacheSlot] if [key] does carry a raw value, or if the
  /// store refuses to hand it over.
  ///
  /// Counter-check for the `OrThrow` readers: their tolerant path returns
  /// `null` for both an empty slot and a swallowed read error; the raw look
  /// separates the two.
  ///
  /// Deliberately AFTER, not before: the healthy case costs no second store
  /// access. Only empty and broken slots pay.
  ///
  /// Under [EncryptedKeyValueStore] the look goes to the RAW storage
  /// ([RawSlotProbe]), not through the decorator again (P3-02): a read that
  /// failed at EXECUTING the decryption — isolate spawn, OOM, RemoteError —
  /// leaves the slot in place and still answers `null`, so a second read
  /// through the decorator would return `null` once more and this check would
  /// wave the loss through. The raw look needs no cipher and cannot.
  ///
  /// A provably broken ciphertext stays "empty": the decorator PURGES such a
  /// slot on read, so the raw look finds nothing — correct, since nothing is
  /// left that overwriting could lose.
  ///
  /// P3-02c: the throw carries [UnreadableCacheSlot.transient], so the caller
  /// can tell a slot that is merely unreadable RIGHT NOW from one whose
  /// content is provably beyond repair.
  Future<void> _assertSlotEmpty(String key, String slot) async {
    final store = _store;
    // `is` does not promote to an unrelated interface, hence the cast.
    final probe = store is RawSlotProbe ? store as RawSlotProbe : null;
    final RawSlotState zustand;
    try {
      zustand = probe != null
          ? await probe.rawSlotState(key)
          // No transforming store, hence no transient decryption failure:
          // whatever is there is exactly what the reader could not parse.
          : ((await store.getString(key))?.isNotEmpty ?? false)
              ? RawSlotState.brokenContent
              : RawSlotState.empty;
    } catch (e) {
      // Only the error type leaves. The caller reports the throw to the
      // CrashReporter, and e.g. a FormatException carries its source in the
      // message — here the decrypted slot content, i.e. health data.
      //
      // Transient, fail-closed: a storage that refuses to answer may answer
      // next time, and giving the slot up on a guess overwrites data.
      throw UnreadableCacheSlot(slot, e.runtimeType.toString(),
          transient: true);
    }
    switch (zustand) {
      case RawSlotState.empty:
        return;
      case RawSlotState.unreadableForNow:
        throw UnreadableCacheSlot(slot, 'Entschluesselung nicht ausfuehrbar',
            transient: true);
      case RawSlotState.brokenContent:
        throw UnreadableCacheSlot(slot, 'Inhalt nicht lesbar',
            transient: false);
    }
  }

  // ---- (De)serialization --------------------------------------------------
  // Here rather than on the models: the cache owns its own versioned wire
  // format. The profile mapping is the exception — it lives in
  // sync_outbox.dart because cache and outbox op need the same bytes.

  static Map<String, dynamic> _statsToJson(LifetimeStats s) => <String, dynamic>{
        'workouts_completed': s.workoutsCompleted,
        'meals_logged': s.mealsLogged,
        'water_total_ml': s.waterTotalMl,
        'steps_recorded': s.stepsRecorded,
        'weight_logs': s.weightLogs,
        'current_streak': s.currentStreak,
        'longest_streak': s.longestStreak,
        'last_workout_date':
            s.lastTrackedDate == null ? null : _dateOnly(s.lastTrackedDate!),
      };

  static int _int(Object? v, int fallback) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  static String _dateOnly(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }
}

/// A sync-state slot was occupied but unreadable (store error or structurally
/// broken content). Thrown only by [LocalCache.readOutboxOrThrow] and
/// [LocalCache.readPendingStatsDeltasOrThrow].
///
/// Carries only the short slot name and the error type: never the storage key
/// (holds the user id) and never the value (health data), because the object
/// goes into the crash report.
class UnreadableCacheSlot implements Exception {
  const UnreadableCacheSlot(this.slot, this.reason, {this.transient = true});

  /// Short name like `outbox`, deliberately not the storage key.
  final String slot;

  /// Error type or short reason, never a value.
  final String reason;

  /// Whether a LATER read of the same slot can succeed (P3-02c).
  ///
  /// `true` — the read failed at executing the decryption, or the storage
  /// refused to answer at all. The bytes are intact, so the slot must keep its
  /// protection for as long as it takes; the loss on giving up early is up to
  /// [kOutboxMaxOps] undelivered writes.
  ///
  /// `false` — the bytes handed themselves over and the reader still could not
  /// use them. That is a statement about the CONTENT and it is permanent, so
  /// the caller may give up at once instead of protecting a slot that will
  /// never open.
  ///
  /// Defaults to `true`, fail-closed: not knowing is not a licence to
  /// overwrite.
  final bool transient;

  @override
  String toString() =>
      'UnreadableCacheSlot($slot, ${transient ? 'transient' : 'dauerhaft'}): '
      '$reason';
}

/// A sync-state slot could not be WRITTEN — counterpart to
/// [UnreadableCacheSlot] and the only way to learn about a lost outbox or
/// deltas write (see [LocalCache._writeDurable]).
///
/// Same restriction: only slot name and error type, never the storage key
/// (user id) and never the value (health data).
class UnwritableCacheSlot implements Exception {
  const UnwritableCacheSlot(this.slot, this.reason);

  /// Short name like `outbox`, deliberately not the storage key.
  final String slot;

  /// Error type, never a value.
  final String reason;

  @override
  String toString() => 'UnwritableCacheSlot($slot): $reason';
}
