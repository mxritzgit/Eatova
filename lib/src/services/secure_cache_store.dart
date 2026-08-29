import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/api.dart'
    show AEADParameters, InvalidCipherTextException, KeyParameter;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crash_reporter.dart';
import 'local_cache.dart';

// SEC-1: encryption layer under LocalCache, which holds health data in
// plaintext in SharedPreferences (GDPR Art. 9). Envelope encryption: only a
// 32-byte DEK lives in the OS keystore, the blobs stay in prefs under
// AES-256-GCM, because every meal edit rewrites the whole ~78 kB blob and
// writes overlap — the plugin's weak spot.

/// Wire format: `"EATOVA1:" + base64(nonce ‖ ct ‖ tag)`. A positive magic,
/// since a `{`-vs-base64 heuristic would misclassify a non-object write and
/// DELETE it via the undecryptable path.
const String cacheCipherMagic = 'EATOVA1:';

/// Seam for encrypting one cache slot. Implementations MUST bind [key] as
/// AAD. `Future`-valued so production can compute in an isolate (PERF-G9).
abstract class CacheCipher {
  /// Encrypts [plaintext] bound to [key] into [cacheCipherMagic] format.
  Future<String> encrypt(String key, String plaintext);

  /// Decrypts [armored] bound to [key]; throws on wrong key, slot or tag.
  Future<String> decrypt(String key, String armored);
}

/// Transport object for the isolate hop: plain data only.
class _CipherJob {
  const _CipherJob(this.dek, this.key, this.payload);

  final Uint8List dek;
  final String key;
  final String payload;
}

// `compute()` needs a top-level or static function, not a closure.
String _encryptInIsolate(_CipherJob job) =>
    AesGcmCacheCipher.encryptSync(job.dek, job.key, job.payload);

String _decryptInIsolate(_CipherJob job) =>
    AesGcmCacheCipher.decryptSync(job.dek, job.key, job.payload);

/// AES-256-GCM via pointycastle, using the DEK from [CacheKeyProvider].
class AesGcmCacheCipher implements CacheCipher {
  AesGcmCacheCipher(this._dek) {
    if (_dek.length != dekLengthBytes) {
      throw ArgumentError.value(
          _dek.length, 'dek', 'DEK muss genau $dekLengthBytes Bytes haben');
    }
  }

  /// AES-256.
  static const int dekLengthBytes = 32;

  /// 96-bit nonce, GCM's intended length; anything else is slower, not safer.
  static const int nonceLengthBytes = 12;

  /// 128-bit auth tag (full, not truncated).
  static const int tagLengthBits = 128;

  final Uint8List _dek;

  /// CSPRNG, backed by the OS on Android/iOS.
  static final Random _rng = Random.secure();

  // PERF-G9: no "small blobs synchronous" threshold — the isolate overhead
  // is a constant ~0.13 ms against 0.29 ms of crypto for the smallest real
  // slot, so it would win at no size.
  @override
  Future<String> encrypt(String key, String plaintext) => compute(
        _encryptInIsolate,
        _CipherJob(_dek, key, plaintext),
        debugLabel: 'cache-encrypt',
      );

  @override
  Future<String> decrypt(String key, String armored) => compute(
        _decryptInIsolate,
        _CipherJob(_dek, key, armored),
        debugLabel: 'cache-decrypt',
      );

  /// Pure, so it can run in the isolate; the golden blob pins the format.
  static String encryptSync(Uint8List dek, String key, String plaintext) {
    // 12 FRESH random bytes per encryption, never derived, never a counter:
    // reuse under one GCM key leaks the authentication subkey.
    final nonce = Uint8List(nonceLengthBytes);
    for (var i = 0; i < nonceLengthBytes; i++) {
      nonce[i] = _rng.nextInt(256);
    }

    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
            KeyParameter(dek), tagLengthBits, nonce, _associatedData(key)),
      );
    // For GCM, process() returns ciphertext ‖ tag.
    final sealed = cipher.process(_bytes(plaintext));

    final framed = Uint8List(nonce.length + sealed.length)
      ..setRange(0, nonce.length, nonce)
      ..setRange(nonce.length, nonce.length + sealed.length, sealed);
    return '$cacheCipherMagic${base64.encode(framed)}';
  }

  /// Counterpart to [encryptSync], likewise pure and isolate-safe.
  static String decryptSync(Uint8List dek, String key, String armored) {
    if (!armored.startsWith(cacheCipherMagic)) {
      throw const FormatException('Cache-Slot ohne EATOVA1-Magic');
    }
    // No ciphertext in the error text: base64's FormatException embeds its
    // source, which would reach the crash report.
    final Uint8List framed;
    try {
      framed = base64.decode(armored.substring(cacheCipherMagic.length));
    } on FormatException {
      throw const FormatException('Cache-Slot ist kein gueltiges base64');
    }
    if (framed.length < nonceLengthBytes + tagLengthBits ~/ 8) {
      throw const FormatException('Cache-Slot zu kurz fuer nonce+tag');
    }

    final nonce = Uint8List.sublistView(framed, 0, nonceLengthBytes);
    final sealed = Uint8List.fromList(framed.sublist(nonceLengthBytes));

    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
            KeyParameter(dek), tagLengthBits, nonce, _associatedData(key)),
      );
    // Tag mismatch = wrong DEK, wrong slot (AAD) or tampered blob.
    return utf8.decode(cipher.process(sealed));
  }

  /// AAD = the storage key, so moving a value to another slot or user
  /// namespace fails the tag check.
  static Uint8List _associatedData(String key) => _bytes(key);

  static Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));
}

/// Seam over the OS keystore, testable without a plugin channel.
abstract class SecureKeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Production implementation: flutter_secure_storage.
class PluginSecureKeyStore implements SecureKeyStore {
  const PluginSecureKeyStore();

  // These options decide whether the DEK survives everyday device use.
  // Public because the session storage (C5) needs the same stance.
  static const AndroidOptions androidOptions = AndroidOptions(
    // SEC/A1: the 10.x default TRUE deletes the entry on any keystore error
    // and reports success, leaving Dart a `null` it cannot tell from a first
    // start — and the bootstrap then orphans every slot.
    resetOnError: false,
    // Otherwise plugin defaults: biometrics set
    // setUserAuthenticationRequired, letting a new fingerprint destroy the
    // cache, and the threat model is a device at rest.
  );

  /// `first_unlock` so lifecycle and notification paths can read the DEK
  /// after a reboot; `_this_device` keeps it off iCloud and other devices.
  /// PRICE, and the reason for the give-up logic in [CacheKeyProvider]: such
  /// items are excluded from every backup, so a restored device loses the DEK
  /// while the prefs travel along.
  static const IOSOptions iosOptions =
      IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device);

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: androidOptions,
    iOptions: iosOptions,
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// A1: plaintext marker "a DEK was already minted here", separating the two
/// states the keystore maps onto `null`: a fresh install (minting is right)
/// from a lost entry (minting destroys data). A claim about DURABILITY, not
/// integrity.
abstract class DekSentinelStore {
  Future<bool> isProvisioned();
  Future<void> markProvisioned();

  /// App starts that missed the DEK despite a set sentinel. 0 = no incident.
  Future<int> vanishStrikes();

  /// Sets the counter. `<= 0` removes the entry.
  Future<void> setVanishStrikes(int value);

  /// Records "cache abandoned" for the UI; consumed once by the caller.
  Future<void> raiseCacheResetNotice();

  /// See [CacheKeyProvider.plaintextMigrationClosedKey].
  Future<bool> isPlaintextMigrationClosed();

  /// Sets the marker. One-way, short of losing the blobs too.
  Future<void> closePlaintextMigration();
}

/// A1/iOS: lists the encrypted cache slots WITHOUT the DEK, so the bootstrap
/// can tell whether minting would orphan anything. Membership is decided by
/// [cacheCipherMagic] alone, never by key name.
abstract class CacheCiphertextProbe {
  /// Storage keys whose value starts with [cacheCipherMagic].
  Future<List<String>> encryptedKeys();

  /// Deletes EXACTLY [keys], only ever [encryptedKeys]' own result.
  Future<void> purge(Iterable<String> keys);
}

/// Production implementation: SharedPreferences.
class PrefsCacheCiphertextProbe implements CacheCiphertextProbe {
  const PrefsCacheCiphertextProbe();

  @override
  Future<List<String>> encryptedKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final hits = <String>[];
    for (final key in prefs.getKeys()) {
      // `get`, not `getString`: the namespace also holds bool/int/List
      // values, on which `getString` throws.
      final value = prefs.get(key);
      if (value is String && value.startsWith(cacheCipherMagic)) hits.add(key);
    }
    return hits;
  }

  @override
  Future<void> purge(Iterable<String> keys) async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in keys) {
      await prefs.remove(key);
    }
  }
}

/// W7a: lists slots that may still hold PLAINTEXT from an install predating
/// encryption, reading prefs directly because the slots nobody reads are the
/// sweep's point.
abstract class LegacyPlaintextProbe {
  /// Keys matching [isLegacyCacheSlotKey] with a non-empty, magic-less value.
  Future<List<String>> plaintextCacheKeys();
}

/// The `LocalCache` slot names, repeated as an allowlist: the same namespace
/// holds `locale`, `theme_mode` and `search_credentials`, read WITHOUT the
/// decorator, which a prefix-wide sweep would encrypt and destroy.
const Set<String> legacyCacheSlotNames = <String>{
  'profile',
  'daily',
  'stats',
  'notifications_enabled',
  'logged_meals',
  'favorites',
  'weight_log',
  'outbox',
  'pending_stats',
  'user_recipes',
  'daily_activity',
};

/// Whether [key] is a cache slot `eatova.v1.<slot>.<uid>`. Checks prefix and
/// slot name only; keys with fewer than four segments are control bits.
@visibleForTesting
bool isLegacyCacheSlotKey(String key) {
  final parts = key.split('.');
  if (parts.length < 4) return false;
  if (parts[0] != 'eatova' || parts[1] != 'v1') return false;
  return legacyCacheSlotNames.contains(parts[2]);
}

/// Production implementation: SharedPreferences.
class PrefsLegacyPlaintextProbe implements LegacyPlaintextProbe {
  const PrefsLegacyPlaintextProbe();

  @override
  Future<List<String>> plaintextCacheKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final hits = <String>[];
    for (final key in prefs.getKeys()) {
      if (!isLegacyCacheSlotKey(key)) continue;
      // `get`, not `getString`: the namespace also holds bool/int/List
      // values, on which `getString` throws.
      final value = prefs.get(key);
      if (value is! String || value.isEmpty) continue;
      if (value.startsWith(cacheCipherMagic)) continue;
      hits.add(key);
    }
    return hits;
  }
}

/// Production implementation: SharedPreferences, NOT the secure storage,
/// because the sentinel must survive the incident it reports and a
/// `deleteAll()` wipes that namespace. Prefs holds the blobs too, so the two
/// are lost only together — when a fresh DEK is correct again.
class PrefsDekSentinelStore implements DekSentinelStore {
  const PrefsDekSentinelStore();

  @override
  Future<bool> isProvisioned() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(CacheKeyProvider.dekProvisionedKey) ?? false;
  }

  @override
  Future<void> markProvisioned() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(CacheKeyProvider.dekProvisionedKey, true);
  }

  @override
  Future<int> vanishStrikes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(CacheKeyProvider.dekVanishStrikesKey) ?? 0;
  }

  @override
  Future<void> setVanishStrikes(int value) async {
    final prefs = await SharedPreferences.getInstance();
    // Store 0 as absence, not as a value: the normal case leaves no entry.
    if (value <= 0) {
      await prefs.remove(CacheKeyProvider.dekVanishStrikesKey);
      return;
    }
    await prefs.setInt(CacheKeyProvider.dekVanishStrikesKey, value);
  }

  @override
  Future<void> raiseCacheResetNotice() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(CacheKeyProvider.cacheResetNoticeKey, true);
  }

  @override
  Future<bool> isPlaintextMigrationClosed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(CacheKeyProvider.plaintextMigrationClosedKey) ?? false;
  }

  @override
  Future<void> closePlaintextMigration() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(CacheKeyProvider.plaintextMigrationClosedKey, true);
  }
}

/// Crash-report object for a DEK that vanished despite a set sentinel.
class VanishedCacheKey implements Exception {
  const VanishedCacheKey({required this.strike, required this.budget});

  /// Which consecutive app start this was.
  final int strike;

  /// See [CacheKeyProvider.vanishStrikeBudget].
  final int budget;

  @override
  String toString() =>
      'VanishedCacheKey($strike/$budget): DEK fehlt trotz gesetztem Sentinel — '
      'Bootstrap abgebrochen statt neu gepraegt';
}

/// Crash-report object for a DEK READ that threw (see
/// [CacheKeyProvider._handleUnreadableDek]). Carries the error's runtime TYPE
/// only, never its message, which can hold the raw OS reason.
class UnreadableCacheKey implements Exception {
  const UnreadableCacheKey({
    required this.strike,
    required this.budget,
    required this.errorType,
  });

  /// Which consecutive app start without an available DEK this was.
  final int strike;

  /// See [CacheKeyProvider.vanishStrikeBudget].
  final int budget;

  /// Type name only, never the error text.
  final String errorType;

  @override
  String toString() =>
      'UnreadableCacheKey($strike/$budget): DEK-Read warf $errorType — '
      'Bootstrap abgebrochen, Key nicht ueberschrieben';
}

/// Crash-report object for a spent strike budget: the DEK counts as lost,
/// dead ciphertexts were purged and a fresh one minted. Where the app lands
/// after an iOS device restore.
class AbandonedCacheKey implements Exception {
  const AbandonedCacheKey({required this.purgedSlots, required this.budget});

  final int purgedSlots;
  final int budget;

  @override
  String toString() =>
      'AbandonedCacheKey: DEK nach $budget Starts als verloren behandelt — '
      '$purgedSlots tote Slots geraeumt, frischer DEK gepraegt';
}

/// Bootstrap of the data encryption key (DEK) — memoized and single-flight.
class CacheKeyProvider {
  const CacheKeyProvider._();

  /// ONE app-wide DEK: keys are already namespaced per user and the threat
  /// model is device-level extraction, so a per-user key would only add a
  /// bootstrap per login switch.
  static const String dekStorageKey = 'eatova.v1.cache_dek';

  /// A1 sentinel; in SharedPreferences, see [PrefsDekSentinelStore].
  static const String dekProvisionedKey = 'eatova.v1.dek_provisioned';

  /// App starts without an available DEK, missing or unreadable; both end in
  /// the same dead end, so they share counter and budget.
  static const String dekVanishStrikesKey = 'eatova.v1.dek_vanish_strikes';

  /// UI flag, read and cleared by [consumeCacheResetNotice].
  static const String cacheResetNoticeKey = 'eatova.v1.cache_reset_notice';

  /// SEC/W7a: marker "the plaintext migration path is closed". Without it a
  /// magic-less slot would count as migratable legacy forever; after it, it
  /// is dropped and reported. It bounds that path and provides NO integrity,
  /// sharing a prefs file with the slots it guards.
  ///
  /// SET ONLY AFTER THE SWEEP ([EncryptedKeyValueStore.migrateAllLegacySlots])
  /// and only if every found slot is then verifiably encrypted. Never
  /// alongside the sentinel, which is GLOBAL while slots are PER UID: user
  /// A's bootstrap would close the path before B's slots were read.
  static const String plaintextMigrationClosedKey =
      'eatova.v1.cache_plaintext_migrated';

  /// Consecutive aborts before the DEK counts as permanently lost; the same
  /// budget covers [_handleUnreadableDek]. 3 and not 1 because "a `null` is
  /// definitive" rests on plugin sources, not a law of nature, and the budget
  /// costs two cold starts against a purged outbox blob.
  static const int vanishStrikeBudget = 3;

  /// Memoized bootstrap; MUST be assigned synchronously, see [obtain].
  static Future<Uint8List?>? _pending;

  /// A strike is an APP START, not an [obtain] call: `LocalCache.create` runs
  /// from boot and logout, so one session would spend the whole budget.
  static bool _vanishStrikeCounted = false;

  /// The plaintext marker BEFORE this process's bootstrap; fail-closed.
  static bool _legacyPlaintextAccepted = false;

  /// Whether this app start may still adopt legacy plaintext, deciding both
  /// the sweep and per-slot migration. The snapshot predates the sweep, so
  /// the migrating run sees `true`.
  static bool get legacyPlaintextAccepted => _legacyPlaintextAccepted;

  /// Returns the DEK (32 bytes), or null if it could be neither read nor
  /// created. SINGLE-FLIGHT, not optional: boot and logout both reach
  /// `LocalCache.create` and can overlap, and two unmemoized bootstraps would
  /// each mint a DEK, the second silently orphaning the first's writes.
  static Future<Uint8List?> obtain({
    SecureKeyStore? keyStore,
    DekSentinelStore? sentinelStore,
    CacheCiphertextProbe? probe,
  }) {
    final started = _pending ??= _bootstrap(
      keyStore ?? const PluginSecureKeyStore(),
      sentinelStore ?? const PrefsDekSentinelStore(),
      probe ?? const PrefsCacheCiphertextProbe(),
    );
    // A FAILED bootstrap is not memoized, or one transient error would kill
    // the cache for the process. Race-free: nothing was written.
    unawaited(started.then((dek) {
      if (dek == null && identical(_pending, started)) _pending = null;
    }, onError: (_, __) {
      if (identical(_pending, started)) _pending = null;
    }));
    return started;
  }

  /// Reads and clears the "cache abandoned" notice; the caller shows it once.
  ///
  /// WIRED UP: `HomeStore._hydrateThenBoot` (home_store.dart) is the sole
  /// consumer. It calls this unawaited during boot and emits a snack, so a
  /// silent fresh start does not leave the user believing the offline diary is
  /// still there. Reading clears the flag, hence exactly one showing.
  static Future<bool> consumeCacheResetNotice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(cacheResetNoticeKey) != true) return false;
      await prefs.remove(cacheResetNoticeKey);
      return true;
    } catch (e, s) {
      dev.log('CacheKeyProvider: Cache-Reset-Hinweis nicht lesbar',
          error: e, stackTrace: s, name: 'secure_cache_store');
      return false;
    }
  }

  /// Resets the memoization and per-process strike (tests only).
  @visibleForTesting
  static void debugReset() {
    _pending = null;
    _vanishStrikeCounted = false;
    _legacyPlaintextAccepted = false;
  }

  static Future<Uint8List?> _bootstrap(
    SecureKeyStore keyStore,
    DekSentinelStore sentinel,
    CacheCiphertextProbe probe,
  ) async {
    // The pre-sweep state governs this start, which closes the marker itself.
    _legacyPlaintextAccepted = !await _plaintextMigrationClosed(sentinel);

    final String? stored;
    try {
      stored = await keyStore.read(dekStorageKey);
    } catch (e, s) {
      // A FAILED read is not "no key there": minting would overwrite a merely
      // unreadable DEK and orphan the cache.
      dev.log('CacheKeyProvider: DEK-Read fehlgeschlagen',
          error: e, stackTrace: s, name: 'secure_cache_store');
      return _handleUnreadableDek(keyStore, sentinel, probe, e);
    }

    if (stored != null && stored.isNotEmpty) {
      final decoded = _tryDecodeDek(stored);
      if (decoded != null) {
        // Bring installs predating the sentinel in line, since it would
        // otherwise wait for a never-happening first mint.
        await _markProvisioned(sentinel);
        // Without this reset, independent glitches would accumulate.
        await _clearVanishStrikes(sentinel);
        return decoded;
      }
      // A structurally broken DEK: its data is lost anyway, so minting heals
      // the app. The sentinel does not apply, the key is here.
      dev.log('CacheKeyProvider: DEK-Eintrag korrupt, wird neu erzeugt',
          name: 'secure_cache_store');
    } else if (await _wasProvisioned(sentinel)) {
      // A1: "no key" although one was minted here — abort only if something
      // could be orphaned.
      if (!await _mayMintAfterVanishedDek(sentinel, probe)) return null;
    }

    return _mintFreshDek(keyStore, sentinel);
  }

  /// Mints and stores a fresh DEK. null = not storable, so no cache this
  /// session.
  static Future<Uint8List?> _mintFreshDek(
    SecureKeyStore keyStore,
    DekSentinelStore sentinel,
  ) async {
    final fresh = _generateDek();
    try {
      await keyStore.write(dekStorageKey, base64.encode(fresh));
    } catch (e, s) {
      dev.log('CacheKeyProvider: DEK-Write fehlgeschlagen',
          error: e, stackTrace: s, name: 'secure_cache_store');
      // NEVER fall back to plaintext: it would work while falsifying the
      // compliance claim.
      return null;
    }
    // ORDER: DEK first — a failed write would otherwise leave a sentinel
    // without a key and abort every future start.
    await _markProvisioned(sentinel);
    return fresh;
  }

  /// Handles "the DEK read THREW", where unlike [_mayMintAfterVanishedDek] it
  /// is UNKNOWN whether a key still exists, so the response is to retry — but
  /// a damaged wrapping key throws on EVERY start, so it shares budget and
  /// counter with [vanishStrikeBudget]. ORDER when giving up is the opposite
  /// of the vanish path: mint FIRST, then purge.
  static Future<Uint8List?> _handleUnreadableDek(
    SecureKeyStore keyStore,
    DekSentinelStore sentinel,
    CacheCiphertextProbe probe,
    Object error,
  ) async {
    final int? strike = await _recordVanishStrike(sentinel);
    // Already decided in this process; `create` runs from boot AND logout.
    if (strike == null) return null;

    if (strike < vanishStrikeBudget) {
      unawaited(CrashReporter.capture(
        UnreadableCacheKey(
          strike: strike,
          budget: vanishStrikeBudget,
          errorType: error.runtimeType.toString(),
        ),
        StackTrace.current,
        context: 'cache_dek_unreadable',
      ));
      return null;
    }

    final Uint8List? fresh = await _mintFreshDek(keyStore, sentinel);
    if (fresh == null) return null;

    // The old key is replaced, so its data is unreadable for good. Purge:
    // `_onUndecryptable` only catches the CURRENT user's slots.
    final List<String>? orphans = await _encryptedSlots(probe);
    final int purged = orphans?.length ?? 0;
    if (orphans != null && orphans.isNotEmpty) {
      await _purgeSlots(probe, orphans);
    }
    await _raiseCacheResetNotice(sentinel);
    await _clearVanishStrikes(sentinel);
    dev.log(
        'CacheKeyProvider: DEK-Read warf $vanishStrikeBudget Starts in Folge — '
        'Key als verloren behandelt, $purged tote Slots geraeumt, neu gepraegt',
        name: 'secure_cache_store');
    unawaited(CrashReporter.capture(
      AbandonedCacheKey(purgedSlots: purged, budget: vanishStrikeBudget),
      StackTrace.current,
      context: 'cache_dek_given_up',
    ));
    return fresh;
  }

  /// Handles "sentinel set, but the keystore has no DEK"; `true` = mint.
  /// With no `EATOVA1:` slot there is nothing to orphan, so mint at once; with
  /// slots present (the iOS restore case) they are permanently undecryptable
  /// and only block the cache, so that case aborts but COUNTS and after
  /// [vanishStrikeBudget] purges, mints and leaves a notice.
  static Future<bool> _mayMintAfterVanishedDek(
    DekSentinelStore sentinel,
    CacheCiphertextProbe probe,
  ) async {
    // null = probe unusable. FAIL CLOSED: unknown means "blobs present".
    final List<String>? orphans = await _encryptedSlots(probe);

    if (orphans != null && orphans.isEmpty) {
      await _clearVanishStrikes(sentinel);
      dev.log(
          'CacheKeyProvider: DEK fehlt trotz Sentinel, aber kein EATOVA1-Slot '
          '— Praegen ist gefahrlos',
          name: 'secure_cache_store');
      return true;
    }

    final int? strike = await _recordVanishStrike(sentinel);
    // Already decided in this process: do not count or report twice.
    if (strike == null) return false;

    if (strike < vanishStrikeBudget) {
      dev.log(
          'CacheKeyProvider: DEK fehlt trotz Sentinel (Start $strike von '
          '$vanishStrikeBudget) — kein Neu-Praegen, Ciphertexte bleiben liegen',
          name: 'secure_cache_store');
      unawaited(CrashReporter.capture(
        VanishedCacheKey(strike: strike, budget: vanishStrikeBudget),
        StackTrace.current,
        context: 'cache_dek_vanished',
      ));
      return false;
    }

    // Budget spent. Purge actively, since `_onUndecryptable` only catches
    // the current user's slots.
    final int purged = orphans?.length ?? 0;
    if (orphans != null) await _purgeSlots(probe, orphans);
    await _raiseCacheResetNotice(sentinel);
    await _clearVanishStrikes(sentinel);
    dev.log(
        'CacheKeyProvider: DEK nach $vanishStrikeBudget Starts als verloren '
        'behandelt — $purged tote Slots geraeumt, praege neu',
        name: 'secure_cache_store');
    unawaited(CrashReporter.capture(
      AbandonedCacheKey(purgedSlots: purged, budget: vanishStrikeBudget),
      StackTrace.current,
      context: 'cache_dek_given_up',
    ));
    return true;
  }

  /// Increments the strike counter once per process; null if already done.
  static Future<int?> _recordVanishStrike(DekSentinelStore sentinel) async {
    if (_vanishStrikeCounted) return null;
    _vanishStrikeCounted = true;
    final int next = await _vanishStrikes(sentinel) + 1;
    await _setVanishStrikes(sentinel, next);
    return next;
  }

  /// Determines the encrypted slots. null = could not be determined.
  static Future<List<String>?> _encryptedSlots(
      CacheCiphertextProbe probe) async {
    try {
      return await probe.encryptedKeys();
    } catch (e, s) {
      dev.log('CacheKeyProvider: Ciphertext-Probe fehlgeschlagen — fail closed',
          error: e, stackTrace: s, name: 'secure_cache_store');
      return null;
    }
  }

  static Future<void> _purgeSlots(
      CacheCiphertextProbe probe, List<String> keys) async {
    try {
      await probe.purge(keys);
    } catch (e, s) {
      // Harmless: leftovers hit `_onUndecryptable` on the next read.
      dev.log('CacheKeyProvider: Purge toter Slots fehlgeschlagen',
          error: e, stackTrace: s, name: 'secure_cache_store');
    }
  }

  /// Reads the strike counter; 0 on error, which stalls the budget but only
  /// when prefs are broken as a whole, where the blobs live too.
  static Future<int> _vanishStrikes(DekSentinelStore sentinel) async {
    try {
      return await sentinel.vanishStrikes();
    } catch (e, s) {
      dev.log('CacheKeyProvider: Strike-Zaehler nicht lesbar',
          error: e, stackTrace: s, name: 'secure_cache_store');
      return 0;
    }
  }

  static Future<void> _setVanishStrikes(
      DekSentinelStore sentinel, int value) async {
    try {
      await sentinel.setVanishStrikes(value);
    } catch (e, s) {
      dev.log('CacheKeyProvider: Strike-Zaehler nicht schreibbar',
          error: e, stackTrace: s, name: 'secure_cache_store');
    }
  }

  /// Only writes when there is something to clear, since the success path
  /// runs through here on every cold start.
  static Future<void> _clearVanishStrikes(DekSentinelStore sentinel) async {
    if (await _vanishStrikes(sentinel) == 0) return;
    await _setVanishStrikes(sentinel, 0);
  }

  static Future<void> _raiseCacheResetNotice(DekSentinelStore sentinel) async {
    try {
      await sentinel.raiseCacheResetNotice();
    } catch (e, s) {
      dev.log('CacheKeyProvider: Cache-Reset-Hinweis nicht schreibbar',
          error: e, stackTrace: s, name: 'secure_cache_store');
    }
  }

  /// Reads the sentinel, FAIL CLOSED: not knowing whether a DEK ever existed
  /// forbids minting one. Costs a session without cache, not data.
  static Future<bool> _wasProvisioned(DekSentinelStore sentinel) async {
    try {
      return await sentinel.isProvisioned();
    } catch (e, s) {
      dev.log('CacheKeyProvider: Sentinel-Read fehlgeschlagen — fail closed',
          error: e, stackTrace: s, name: 'secure_cache_store');
      return true;
    }
  }

  /// Reads the marker, FAIL CLOSED: not knowing whether the migration ran
  /// forbids adopting plaintext, and a failed prefs read means there is none.
  static Future<bool> _plaintextMigrationClosed(
      DekSentinelStore sentinel) async {
    try {
      return await sentinel.isPlaintextMigrationClosed();
    } catch (e, s) {
      dev.log('CacheKeyProvider: Klartext-Marker nicht lesbar — fail closed',
          error: e, stackTrace: s, name: 'secure_cache_store');
      return true;
    }
  }

  /// Best effort: a failed write degrades to "next keystore reset mints
  /// fresh". The plaintext marker does NOT ride along, being global while
  /// slots are per uid ([plaintextMigrationClosedKey]).
  static Future<void> _markProvisioned(DekSentinelStore sentinel) async {
    try {
      await sentinel.markProvisioned();
    } catch (e, s) {
      dev.log('CacheKeyProvider: Sentinel-Write fehlgeschlagen',
          error: e, stackTrace: s, name: 'secure_cache_store');
    }
  }

  /// Closes the plaintext path; only called by
  /// [EncryptedKeyValueStore.migrateAllLegacySlots] once nothing is left to
  /// inherit. Best effort — the sweep is idempotent.
  static Future<void> _closePlaintextMigration(
      DekSentinelStore sentinel) async {
    try {
      await sentinel.closePlaintextMigration();
    } catch (e, s) {
      dev.log('CacheKeyProvider: Klartext-Marker nicht schreibbar',
          error: e, stackTrace: s, name: 'secure_cache_store');
    }
  }

  static Uint8List _generateDek() {
    final rng = Random.secure();
    final key = Uint8List(AesGcmCacheCipher.dekLengthBytes);
    for (var i = 0; i < key.length; i++) {
      key[i] = rng.nextInt(256);
    }
    return key;
  }

  static Uint8List? _tryDecodeDek(String stored) {
    try {
      final bytes = base64.decode(stored);
      if (bytes.length != AesGcmCacheCipher.dekLengthBytes) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }
}

/// Decorator over a [KeyValueStore]: writes encrypted only, reads encrypted
/// AND (migrating once) plaintext. Sits BELOW [LocalCache], wired only in
/// `LocalCache.create`, so the cache and its serializers stay unchanged.
class EncryptedKeyValueStore implements KeyValueStore, RawSlotProbe {
  /// [acceptLegacyPlaintext] is the migration path from
  /// [CacheKeyProvider.plaintextMigrationClosedKey]. `true` by default, since
  /// production only builds via [create].
  EncryptedKeyValueStore(this._inner, this._cipher,
      {bool acceptLegacyPlaintext = true})
      : _acceptLegacyPlaintext = acceptLegacyPlaintext;

  final KeyValueStore _inner;
  final CacheCipher _cipher;
  final bool _acceptLegacyPlaintext;

  /// Reported once per process: a broken DEK makes every slot unreadable.
  static bool _undecryptableReported = false;

  /// SEC: own one-shot flag for [ExpiredPlaintextCacheSlot], the last signal
  /// against write access; a shared one a broken ciphertext could silence.
  static bool _expiredPlaintextReported = false;

  /// Third one-shot flag: reads that fail at EXECUTING the decryption, not
  /// at the ciphertext — opposite reactions, so a separate flag.
  static bool _cipherUnavailableReported = false;

  /// Resets all one-shot flags (tests only), which are per process.
  @visibleForTesting
  static void debugResetReportGuards() {
    _undecryptableReported = false;
    _expiredPlaintextReported = false;
    _cipherUnavailableReported = false;
  }

  /// Builds the decorator on the OS-keystore DEK; null means the app runs
  /// without cache. NO plaintext fallback.
  static Future<EncryptedKeyValueStore?> create(
    KeyValueStore inner, {
    SecureKeyStore? keyStore,
    DekSentinelStore? sentinelStore,
    CacheCiphertextProbe? probe,
    LegacyPlaintextProbe? legacyProbe,
  }) async {
    final dek = await CacheKeyProvider.obtain(
      keyStore: keyStore,
      sentinelStore: sentinelStore,
      probe: probe,
    );
    if (dek == null) return null;
    final store = EncryptedKeyValueStore(
      inner,
      AesGcmCacheCipher(dek),
      acceptLegacyPlaintext: CacheKeyProvider.legacyPlaintextAccepted,
    );
    // W7a: the sweep runs BEFORE returning, so no caller gets a store stuck
    // mid-migration. One prefs pass while the marker is open.
    if (CacheKeyProvider.legacyPlaintextAccepted) {
      await store.migrateAllLegacySlots(
        legacyProbe ?? const PrefsLegacyPlaintextProbe(),
        sentinelStore ?? const PrefsDekSentinelStore(),
      );
    }
    return store;
  }

  /// PERF-G9: with encryption in an isolate, overlapping writes to the SAME
  /// slot could land in reverse order. Serialized PER KEY only.
  final Map<String, Future<void>> _writeQueue = <String, Future<void>>{};

  @override
  Future<String?> getString(String key) async {
    final raw = await _inner.getString(key);
    if (raw == null || raw.isEmpty) return null;

    if (raw.startsWith(cacheCipherMagic)) {
      try {
        return await _cipher.decrypt(key, raw);
      } catch (e, s) {
        // Not every throw is a statement ABOUT THE SLOT, so
        // [_provesBrokenCiphertext] decides whether to purge.
        if (_provesBrokenCiphertext(e)) {
          await _onUndecryptable(key, e, s);
        } else {
          _onCipherUnavailable(key, e, s);
        }
        return null;
      }
    }

    // After the migration a magic-less slot has neither tag nor AAD: same
    // path as a broken ciphertext.
    if (!_acceptLegacyPlaintext) {
      await _onUndecryptable(
          key, const ExpiredPlaintextCacheSlot(), StackTrace.current);
      return null;
    }

    // Legacy plaintext: [migrateAllLegacySlots] handles what existed at
    // start, this branch what appears during it.
    try {
      await _migrateLegacyPlaintext(key, raw);
    } catch (e) {
      // A migration failure degrades to "stays plaintext, next read retries",
      // never to a lost read; setString is atomic per key.
      dev.log('EncryptedKeyValueStore: Migration fehlgeschlagen ($key)',
          error: e, name: 'secure_cache_store');
    }
    return raw;
  }

  /// P3-02: whether the slot still HOLDS bytes — no cipher, no purge, no
  /// report.
  ///
  /// [getString] cannot answer this: it returns `null` both for an empty slot
  /// and for one whose decryption was not executable ([_onCipherUnavailable]
  /// leaves that slot in place on purpose). The `OrThrow` readers in
  /// [LocalCache] need the difference, or an unreadable outbox counts as empty
  /// and the next write overwrites it.
  ///
  /// A failing inner read propagates: "cannot say" must not become "empty".
  @override
  Future<bool> hasRawValue(String key) async {
    final raw = await _inner.getString(key);
    return raw != null && raw.isNotEmpty;
  }

  /// W7a: adopts ALL inherited plaintext slots, then closes the migration
  /// path ([CacheKeyProvider.plaintextMigrationClosedKey]).
  ///
  /// A sweep, not a marker PER UID: this file does not know the uid, only a
  /// read reveals plaintext (and some slots are never read), and a uid that
  /// never returns would keep the path open forever. PRICE: a PLANTED slot is
  /// adopted too, since inherited plaintext has no signature.
  Future<void> migrateAllLegacySlots(
      LegacyPlaintextProbe probe, DekSentinelStore sentinel) async {
    final List<String> keys;
    try {
      keys = await probe.plaintextCacheKeys();
    } catch (e, s) {
      // Do NOT set the marker: without enumeration there is no telling what
      // was left to inherit. The next start retries.
      dev.log('EncryptedKeyValueStore: Klartext-Sweep nicht aufzaehlbar',
          error: e, stackTrace: s, name: 'secure_cache_store');
      return;
    }

    for (final key in keys) {
      final String? raw;
      try {
        raw = await _inner.getString(key);
      } catch (e, s) {
        dev.log('EncryptedKeyValueStore: Klartext-Sweep, Read fehlgeschlagen',
            error: e, stackTrace: s, name: 'secure_cache_store');
        return;
      }
      // A regular write may have run between enumeration and read.
      if (raw == null || raw.isEmpty || raw.startsWith(cacheCipherMagic)) {
        continue;
      }
      try {
        await _migrateLegacyPlaintext(key, raw);
        // Verify: the marker is one-way, and a silently failed write would
        // tip the slot into the drop path next start.
        final after = await _inner.getString(key);
        if (after != null &&
            after.isNotEmpty &&
            !after.startsWith(cacheCipherMagic)) {
          dev.log('EncryptedKeyValueStore: Klartext-Sweep unvollstaendig',
              name: 'secure_cache_store');
          return;
        }
      } catch (e, s) {
        dev.log('EncryptedKeyValueStore: Klartext-Sweep, Write fehlgeschlagen',
            error: e, stackTrace: s, name: 'secure_cache_store');
        return;
      }
    }

    await CacheKeyProvider._closePlaintextMigration(sentinel);
  }

  /// Writes a magic-less value back encrypted; throws on failure.
  Future<void> _migrateLegacyPlaintext(String key, String raw) =>
      _enqueueWrite(key, () async {
        // The isolate hop lets a regular setString rewrite the slot first;
        // the stale plaintext must not win.
        if (await _inner.getString(key) != raw) return;
        await _inner.setString(key, await _cipher.encrypt(key, raw));
      });

  @override
  Future<void> setString(String key, String value) =>
      _enqueueWrite(key, () async {
        await _inner.setString(key, await _cipher.encrypt(key, value));
      });

  /// Appends [task] to the chain for [key]. A predecessor's failure reaches
  /// its own caller but does NOT block successors, which one plugin error
  /// would otherwise stall for the process.
  Future<void> _enqueueWrite(String key, Future<void> Function() task) {
    final previous = _writeQueue[key];
    final Future<void> queued = previous == null
        ? task()
        : previous.then<void>((_) => task(),
            onError: (Object _, StackTrace __) => task());
    _writeQueue[key] = queued;
    unawaited(queued.then<void>(
      (_) => _releaseWriteSlot(key, queued),
      onError: (Object _, StackTrace __) => _releaseWriteSlot(key, queued),
    ));
    return queued;
  }

  void _releaseWriteSlot(String key, Future<void> queued) {
    if (identical(_writeQueue[key], queued)) _writeQueue.remove(key);
  }

  /// Runs on the SAME chain as [setString], or a `remove` could overtake an
  /// encryption in the isolate and the value reappear — at
  /// `LocalCache.clear()`, PII surviving logout.
  @override
  Future<void> remove(String key) => _enqueueWrite(key, () => _inner.remove(key));

  /// Whether [error] PROVES a ciphertext or format problem — only then may
  /// the slot be purged. Both types arise only in
  /// [AesGcmCacheCipher.decryptSync] and their verdict is permanent. Any
  /// OTHER error is transport (a failed isolate spawn), which says nothing
  /// about the ciphertext, so deleting on it destroys readable data.
  static bool _provesBrokenCiphertext(Object error) =>
      error is InvalidCipherTextException || error is FormatException;

  /// The read failed through no fault of the slot (see
  /// [_provesBrokenCiphertext]), so the slot STAYS and the caller gets `null`.
  /// Same error type as the purge path but its own context tag, because
  /// `crash_reporter.dart` allowlists it by type name.
  void _onCipherUnavailable(String key, Object error, StackTrace s) {
    dev.log(
        'EncryptedKeyValueStore: Entschluesselung nicht ausfuehrbar ($key) — '
        'Slot bleibt liegen',
        error: error,
        name: 'secure_cache_store');
    if (_cipherUnavailableReported) return;
    _cipherUnavailableReported = true;
    unawaited(CrashReporter.capture(
      UndecryptableCacheSlot(
        errorType: error.runtimeType.toString(),
        storageKey: redactUserSegment(key),
      ),
      s,
      context: 'cache_decrypt_unavailable',
    ));
  }

  /// A slot is provably undecryptable (invalidated keystore key, restored
  /// backup, tampering) or lost its magic after the migration closed — ONLY
  /// these cases, see [_provesBrokenCiphertext]. Purges PER KEY.
  Future<void> _onUndecryptable(String key, Object error, StackTrace s) async {
    try {
      await _inner.remove(key);
    } catch (e) {
      dev.log('EncryptedKeyValueStore: remove nach Decrypt-Fehler scheiterte',
          error: e, name: 'secure_cache_store');
    }
    if (error is ExpiredPlaintextCacheSlot) {
      if (_expiredPlaintextReported) return;
      _expiredPlaintextReported = true;
    } else {
      if (_undecryptableReported) return;
      _undecryptableReported = true;
    }
    // Error type and key name ONLY: a raw error message can carry the
    // ciphertext.
    final sanitized = UndecryptableCacheSlot(
      errorType: error is InvalidCipherTextException
          ? 'InvalidCipherTextException'
          : error.runtimeType.toString(),
      storageKey: redactUserSegment(key),
    );
    unawaited(CrashReporter.capture(sanitized, s, context: 'cache_decrypt'));
  }
}

/// Replaces the user segment of `eatova.v1.<slot>.<userId>` before the key
/// enters a crash report: the slot is the diagnostic value, the UUID a stable
/// user identifier. Keys with &lt;= 3 parts are unchanged.
@visibleForTesting
String redactUserSegment(String key) {
  final parts = key.split('.');
  if (parts.length <= 3) return key;
  return '${parts.sublist(0, parts.length - 1).join('.')}.<uid>';
}

/// A slot without [cacheCipherMagic] after the migration closed. Its own
/// type, not a FormatException, so the crash report can tell it from a broken
/// ciphertext: the only case here hinting at outside WRITE access.
class ExpiredPlaintextCacheSlot implements Exception {
  const ExpiredPlaintextCacheSlot();

  @override
  String toString() => 'ExpiredPlaintextCacheSlot: Klartext-Slot nach '
      'abgeschlossener Migration — verworfen statt uebernommen';
}

/// Crash-report object carrying error type and slot name only.
class UndecryptableCacheSlot implements Exception {
  const UndecryptableCacheSlot({
    required this.errorType,
    required this.storageKey,
  });

  final String errorType;
  final String storageKey;

  @override
  String toString() => 'UndecryptableCacheSlot($storageKey): $errorType';
}
