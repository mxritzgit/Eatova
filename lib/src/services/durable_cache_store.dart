import 'dart:developer' as dev;

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'key_value_store.dart';
import 'secure_cache_store.dart';
import 'sqlite_key_value_store.dart';

/// Every account cache slot, including slots introduced after the original
/// plaintext migration. Auth, appearance and search preferences are excluded.
const durableCacheSlotNames = {
  ...legacyCacheSlotNames,
  'meal_plans',
  'training_history',
  'training_history_deletions',
  'training_plans',
  'training_heads',
  'training_selection',
  'training_session',
  'recipe_versions',
  'sync_session',
  'sync_claim',
};

bool isDurableCacheSlotKey(String key) {
  final parts = key.split('.');
  return parts.length >= 4 &&
      parts[0] == 'eatova' &&
      parts[1] == 'v1' &&
      durableCacheSlotNames.contains(parts[2]) &&
      parts.skip(3).join('.').isNotEmpty;
}

const _migrationKey = 'eatova.storage.preferences_imported.v1';
const _metadataPrefix = 'eatova.storage.dek.';

/// Read-only until SQLite has committed the complete migration. A cleanup
/// failure is retryable; it never makes stale preferences authoritative again.
abstract interface class LegacyCacheSource {
  Future<Map<String, String>> readSlots();
  Future<Map<String, String>> readKeyMetadata();
  Future<void> removeSlots(Iterable<String> keys);
}

class PreferencesCacheSource implements LegacyCacheSource {
  @override
  Future<Map<String, String>> readSlots() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return {
      for (final key in prefs.getKeys())
        if (isDurableCacheSlotKey(key) && prefs.get(key) is String)
          key: prefs.getString(key)!,
    };
  }

  @override
  Future<Map<String, String>> readKeyMetadata() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      for (final key in _sentinelKeys)
        if (prefs.get(key) case final Object value) key: value.toString(),
    };
  }

  @override
  Future<void> removeSlots(Iterable<String> keys) async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in keys) {
      if (!isDurableCacheSlotKey(key)) {
        throw ArgumentError('Not an account cache slot');
      }
      if (!await prefs.remove(key)) {
        throw const DurableStorageException('legacy cleanup failed');
      }
    }
  }
}

const _sentinelKeys = {
  CacheKeyProvider.dekProvisionedKey,
  CacheKeyProvider.dekVanishStrikesKey,
  CacheKeyProvider.cacheResetNoticeKey,
  CacheKeyProvider.plaintextMigrationClosedKey,
};

class _DatabaseSentinel implements DekSentinelStore {
  _DatabaseSentinel(this.database, this.legacy);
  final SqliteKeyValueStore database;
  final Map<String, String> legacy;

  String _key(String key) => '$_metadataPrefix$key';

  Future<String?> _read(String key) async {
    final snapshot = await database.readSnapshot([_key(key)]);
    // A tombstone is an explicit absence, never a reason to resurrect a
    // preference value such as an old strike counter or reset notice.
    if (snapshot.versions[_key(key)] != 0) return snapshot.values[_key(key)];
    return legacy[key];
  }

  Future<void> _write(String key, String? value) async {
    await database.writeBatch({_key(key): value});
  }

  Future<bool> _readBool(String key) async {
    final value = await _read(key);
    if (value == null || value == 'false') return false;
    if (value == 'true') return true;
    throw const DurableStorageException('invalid key metadata');
  }

  @override
  Future<bool> isProvisioned() => _readBool(CacheKeyProvider.dekProvisionedKey);
  @override
  Future<void> markProvisioned() =>
      _write(CacheKeyProvider.dekProvisionedKey, 'true');
  @override
  Future<int> vanishStrikes() async {
    final value = await _read(CacheKeyProvider.dekVanishStrikesKey);
    if (value == null) return 0;
    final parsed = int.tryParse(value);
    if (parsed == null || parsed < 0) {
      throw const DurableStorageException('invalid key metadata');
    }
    return parsed;
  }

  @override
  Future<void> setVanishStrikes(int value) => _write(
    CacheKeyProvider.dekVanishStrikesKey,
    value <= 0 ? null : '$value',
  );
  @override
  Future<void> raiseCacheResetNotice() =>
      _write(CacheKeyProvider.cacheResetNoticeKey, 'true');
  @override
  Future<bool> isPlaintextMigrationClosed() =>
      _readBool(CacheKeyProvider.plaintextMigrationClosedKey);
  @override
  Future<void> closePlaintextMigration() =>
      _write(CacheKeyProvider.plaintextMigrationClosedKey, 'true');

  Future<bool> consumeResetNotice() async {
    final key = _key(CacheKeyProvider.cacheResetNoticeKey);
    while (true) {
      final snapshot = await database.readSnapshot([key]);
      if (snapshot.values[key] != 'true') return false;
      try {
        await database.writeBatch({
          key: null,
        }, expectedVersions: snapshot.versions);
        return true;
      } on KeyValueConflict {
        // Another engine consumed or changed the notice. Reread its truth.
      }
    }
  }
}

class _CombinedCiphertextProbe implements CacheCiphertextProbe {
  _CombinedCiphertextProbe(this.database, this.legacy);
  final SqliteKeyValueStore database;
  final Map<String, String> legacy;
  final Set<String> purged = {};

  @override
  Future<List<String>> encryptedKeys() async {
    final stored = await database.readAll();
    return {
      for (final entry in legacy.entries)
        if (entry.value.startsWith(cacheCipherMagic)) entry.key,
      for (final entry in stored.values.entries)
        if (entry.value?.startsWith(cacheCipherMagic) == true) entry.key,
    }.toList();
  }

  @override
  Future<void> purge(Iterable<String> keys) async {
    // Preferences cannot participate in the SQLite transaction. Defer their
    // deletion until its commit, including the existing key-loss recovery.
    purged.addAll(keys);
    await database.writeBatch({for (final key in keys) key: null});
  }
}

/// Bootstraps under a real cross-process write lock. An interrupted migration
/// leaves either the full old preferences or the complete new SQLite state.
Future<EncryptedKeyValueStore?> migrateDurableCache({
  required SqliteKeyValueStore database,
  required LegacyCacheSource legacySource,
  SecureKeyStore? keyStore,
  bool background = false,
}) async {
  var cleanup = <String>[];
  _DatabaseSentinel? sentinel;
  final EncryptedKeyValueStore? store;
  try {
    store = await database.initializeExclusively(() async {
      final migrated = await database.getString(_migrationKey) == 'true';
      if (background) {
        if (!migrated) return null;
        final dek = await CacheKeyProvider.readExisting(keyStore: keyStore);
        return dek == null
            ? null
            : EncryptedKeyValueStore(
                database,
                createCacheCipher(dek),
                acceptLegacyPlaintext: false,
              );
      }
      Map<String, String> legacy;
      try {
        legacy = await legacySource.readSlots();
      } catch (_) {
        if (!migrated) rethrow;
        legacy = {};
      }
      cleanup = legacy.keys.toList();
      final metadata = migrated
          ? <String, String>{}
          : await legacySource.readKeyMetadata();
      final keyState = sentinel = _DatabaseSentinel(database, metadata);
      final probe = _CombinedCiphertextProbe(database, migrated ? {} : legacy);
      final dek = await CacheKeyProvider.obtain(
        keyStore: keyStore,
        sentinelStore: keyState,
        probe: probe,
      );
      if (dek == null) return null;
      final cipher = createCacheCipher(dek);
      if (!migrated) {
        final snapshot = await database.readAll();
        final imported = <String, String?>{};
        for (final entry in legacy.entries) {
          if (!isDurableCacheSlotKey(entry.key)) {
            throw const DurableStorageException(
              'invalid legacy cache namespace',
            );
          }
          if (probe.purged.contains(entry.key) ||
              entry.key.startsWith('eatova.v1.daily.')) {
            continue;
          }
          // Existing SQLite state (including a tombstone) wins on a retry.
          if (snapshot.versions.containsKey(entry.key)) continue;
          final raw = entry.value;
          if (raw.startsWith(cacheCipherMagic)) {
            imported[entry.key] = raw;
          } else if (CacheKeyProvider.legacyPlaintextAccepted) {
            imported[entry.key] = await cipher.encrypt(entry.key, raw);
          } else {
            // Closed plaintext migration is an integrity fence, not an excuse
            // to accept unsigned data. Keep the source for explicit recovery.
            throw const DurableStorageException('unexpected legacy plaintext');
          }
        }
        for (final key in _sentinelKeys) {
          final target = '$_metadataPrefix$key';
          if (!snapshot.versions.containsKey(target)) {
            imported[target] = metadata[key];
          }
        }
        imported['$_metadataPrefix${CacheKeyProvider.dekProvisionedKey}'] =
            'true';
        imported['$_metadataPrefix${CacheKeyProvider.plaintextMigrationClosedKey}'] =
            'true';
        imported[_migrationKey] = 'true';
        await database.writeBatch(imported);
      }
      return EncryptedKeyValueStore(
        database,
        cipher,
        acceptLegacyPlaintext: false,
      );
    });
  } catch (_) {
    if (!background) CacheKeyProvider.invalidateRolledBackBootstrap();
    rethrow;
  }
  if (store == null) return null;
  if (background) return store;
  CacheKeyProvider.setResetNoticeReader(sentinel!.consumeResetNotice);
  try {
    await legacySource.removeSlots(cleanup);
  } catch (error) {
    // Migration already committed. A later boot retries only cleanup.
    dev.log(
      'Legacy cache cleanup deferred (${error.runtimeType})',
      name: 'local_cache',
    );
  }
  return store;
}

/// One database/cipher queue per app isolate. Other engines open their own
/// connection to the same file; SQLite transactions and CAS are authoritative.
class DurableCacheStore {
  static final Map<String, Future<_DatabaseEntry?>> _open = {};
  static Future<void> _poolTail = Future<void>.value();

  static Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _poolTail.then((_) => action());
    _poolTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  static Future<String> _path(String? path) async =>
      path ??
      '${(await getApplicationSupportDirectory()).path}/eatova-cache.sqlite';

  /// Process-lifetime access. Short-lived workers should use [acquire].
  static Future<EncryptedKeyValueStore?> open({
    String? databasePath,
    bool background = false,
  }) async {
    final path = await _path(databasePath);
    return _serialize(() async {
      final entry = await _entry(path, background);
      if (entry == null) return null;
      entry.retained = true;
      return entry.store;
    });
  }

  static Future<DurableCacheConnection?> acquire({
    String? databasePath,
    bool background = false,
  }) async {
    final path = await _path(databasePath);
    return _serialize(() async {
      final entry = await _entry(path, background);
      if (entry == null) return null;
      entry.references++;
      return DurableCacheConnection._(
        entry.store,
        () => _serialize(() async {
          entry.references--;
          if (entry.references == 0 && !entry.retained) {
            final current = _open[path];
            if (current != null && identical(await current, entry)) {
              _open.remove(path);
            }
            await entry.database.close();
          }
        }),
      );
    });
  }

  static Future<_DatabaseEntry?> _entry(String path, bool background) async {
    // Even when an engine has a foreground handle, headless work must not
    // bypass a currently locked/missing keystore via that handle's RAM key.
    if (background && await CacheKeyProvider.readExisting() == null) {
      return null;
    }
    final pending = _open.putIfAbsent(path, () async {
      final database = await SqliteKeyValueStore.open(path);
      try {
        final encrypted = await migrateDurableCache(
          database: database,
          legacySource: PreferencesCacheSource(),
          background: background,
        );
        if (encrypted == null) {
          await database.close();
          return null;
        }
        return _DatabaseEntry(database, encrypted);
      } catch (_) {
        await database.close();
        rethrow;
      }
    });
    try {
      final entry = await pending;
      if (entry == null && identical(_open[path], pending)) _open.remove(path);
      return entry;
    } catch (_) {
      if (identical(_open[path], pending)) _open.remove(path);
      rethrow;
    }
  }

  /// Test/process shutdown only. Account logout purges its namespace, not the
  /// app-wide connection used by other account namespaces.
  static Future<void> closeAll() => _serialize(() async {
    final pending = _open.values.toList();
    _open.clear();
    for (final future in pending) {
      final entry = await future;
      await entry?.database.close();
    }
  });
}

class _DatabaseEntry {
  _DatabaseEntry(this.database, this.store);
  final SqliteKeyValueStore database;
  final EncryptedKeyValueStore store;
  int references = 0;
  bool retained = false;
}

class DurableCacheConnection {
  DurableCacheConnection._(this.store, this._release);
  final EncryptedKeyValueStore store;
  final Future<void> Function() _release;
  Future<void>? _released;

  Future<void> release() => _released ??= _release();
}
