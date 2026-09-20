import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:eatova/src/services/durable_cache_store.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
import 'package:eatova/src/services/sqlite_key_value_store.dart';

final _testKey = Uint8List.fromList(List.generate(32, (i) => i));
const _outbox = 'eatova.v1.outbox.account-a';
const _profile = 'eatova.v1.profile.account-b';
const _receipt = 'eatova.v1.training_history_deletions.account-b';
const _marker = 'eatova.storage.preferences_imported.v1';
const _cleanup = 'eatova.storage.preferences_cleanup.v1';
const _conflict = 'eatova.storage.legacy_conflict.v1';

class _Keys implements SecureKeyStore {
  String? value = base64Encode(_testKey);
  bool locked = false;
  int writes = 0;
  @override
  Future<String?> read(String key) async {
    if (locked) throw StateError('locked');
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    this.value = value;
  }

  @override
  Future<void> delete(String key) async => value = null;
}

class _Legacy implements LegacyCacheSource {
  final slots = <String, String>{};
  final metadata = <String, String>{};
  bool failCleanup = false;
  bool failRead = false;
  void Function()? beforeCleanup;
  int cleanups = 0;
  @override
  Future<Map<String, String>> readSlots() async {
    if (failRead) throw StateError('legacy unavailable');
    return Map.of(slots);
  }

  @override
  Future<Map<String, String>> readKeyMetadata() async => Map.of(metadata);
  @override
  Future<void> removeSlots(Map<String, String> expectedValues) async {
    cleanups++;
    if (failCleanup) throw StateError('cleanup failed');
    beforeCleanup?.call();
    for (final entry in expectedValues.entries) {
      if (!slots.containsKey(entry.key)) continue;
      if (slots[entry.key] != entry.value) throw const LegacyStorageConflict();
      slots.remove(entry.key);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SqliteKeyValueStore database;
  late _Legacy legacy;
  late _Keys keys;

  Future<EncryptedKeyValueStore?> migrate({bool background = false}) =>
      migrateDurableCache(
        database: database,
        legacySource: legacy,
        keyStore: keys,
        background: background,
      );

  setUp(() async {
    CacheKeyProvider.debugReset();
    directory = await Directory.systemTemp.createTemp(
      'eatova_cache_migration_',
    );
    database = await SqliteKeyValueStore.open('${directory.path}/cache.sqlite');
    legacy = _Legacy();
    keys = _Keys();
  });
  tearDown(() async {
    CacheKeyProvider.debugReset();
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'old storage upgrade downgrade offline write re-upgrade preserves both stores',
    () async {
      final cipher = AesGcmCacheCipher(_testKey);
      legacy.slots[_outbox] = await cipher.encrypt(
        _outbox,
        '{"items":[{"operation_id":"original-operation"}]}',
      );
      final cache = (await migrate())!;
      await cache.setString(
        _outbox,
        '{"items":[{"operation_id":"sqlite-operation"}]}',
      );
      final before = await database.readAll();
      // An older installed binary has no knowledge of SQLite's cutover.
      final rollbackWrite = await cipher.encrypt(
        _outbox,
        '{"items":[{"operation_id":"rollback-offline-operation"}]}',
      );
      legacy.slots[_outbox] = rollbackWrite;
      await database.close();
      CacheKeyProvider.debugReset();
      database = await SqliteKeyValueStore.open(
        '${directory.path}/cache.sqlite',
      );

      await expectLater(migrate(), throwsA(isA<LegacyStorageConflict>()));
      expect(legacy.slots[_outbox], rollbackWrite);
      final after = await database.readAll();
      expect({...after.values}..remove(_conflict), before.values);
      expect({...after.versions}..remove(_conflict), before.versions);
      expect(after.values[_conflict], 'true');
      expect(await migrate(background: true), isNull);
      expect(legacy.slots[_outbox], rollbackWrite);
    },
  );

  test(
    'imports every account and authoritative slot without changing cipher AAD',
    () async {
      final encrypted = await AesGcmCacheCipher(
        _testKey,
      ).encrypt(_outbox, '{"items":["pending"]}');
      legacy.slots.addAll({
        _outbox: encrypted,
        _profile: '{"weightKg":82}',
        _receipt: '{"ids":["deletion"]}',
        'eatova.v1.daily.account-a': '{"mood":"legacy private note"}',
      });
      final cache = (await migrate())!;
      expect(legacy.slots, isEmpty);
      expect(await database.getString(_outbox), encrypted);
      expect(await cache.getString(_outbox), '{"items":["pending"]}');
      expect(await cache.getString(_profile), '{"weightKg":82}');
      expect(await cache.getString(_receipt), '{"ids":["deletion"]}');
      expect(await database.getString('eatova.v1.daily.account-a'), isNull);
      expect(await database.getString(_marker), 'true');
      for (final key in [_outbox, _profile, _receipt]) {
        expect(await database.getString(key), startsWith(cacheCipherMagic));
      }
    },
  );

  test(
    'failed migration rolls back all rows and keeps every legacy byte',
    () async {
      legacy.slots[_outbox] = '{"items":["pending"]}';
      legacy.slots[_profile] = '{"weightKg":82}';
      final original = Map.of(legacy.slots);
      final connection = sqlite3.open('${directory.path}/cache.sqlite');
      connection.execute(
        "CREATE TRIGGER fail_migration BEFORE INSERT ON cache_slots "
        "WHEN NEW.key = '$_marker' BEGIN SELECT RAISE(ABORT, 'test failure'); END",
      );
      connection.close();
      await expectLater(migrate(), throwsA(isA<DurableStorageException>()));
      expect(legacy.slots, original);
      expect(legacy.cleanups, 0);
      expect((await database.readAll()).values, isEmpty);
      final retryConnection = sqlite3.open('${directory.path}/cache.sqlite');
      retryConnection.execute('DROP TRIGGER fail_migration');
      retryConnection.close();
      final cache = (await migrate())!;
      expect(await cache.getString(_outbox), original[_outbox]);
      expect(legacy.slots, isEmpty);
    },
  );

  test(
    'committed marker prevents stale preferences resurrecting a deleted row',
    () async {
      legacy.slots[_outbox] = '{"items":["old"]}';
      legacy.failCleanup = true;
      await migrate();
      expect(legacy.slots, isNotEmpty);
      await database.remove(_outbox);
      await database.close();
      CacheKeyProvider.debugReset();
      database = await SqliteKeyValueStore.open(
        '${directory.path}/cache.sqlite',
      );
      legacy.failCleanup = false;
      final reopened = (await migrate())!;
      expect(await reopened.getString(_outbox), isNull);
      expect(legacy.slots, isEmpty);
    },
  );

  for (final coldRetry in [false, true]) {
    test(
      'key minted before failed COMMIT survives ${coldRetry ? 'cold' : 'same-session'} retry',
      () async {
        keys.value = null;
        legacy.slots[_outbox] = '{"items":["pending"]}';
        final original = Map.of(legacy.slots);
        final connection = sqlite3.open('${directory.path}/cache.sqlite');
        connection.execute(
          'CREATE TABLE migration_parent (id INTEGER PRIMARY KEY)',
        );
        connection.execute(
          'CREATE TABLE migration_child (parent_id INTEGER '
          'REFERENCES migration_parent(id) DEFERRABLE INITIALLY DEFERRED)',
        );
        connection.execute(
          'CREATE TRIGGER fail_commit AFTER INSERT ON cache_slots '
          "WHEN NEW.key = '$_marker' BEGIN "
          'INSERT INTO migration_child VALUES (1); END',
        );
        connection.close();

        // Every INSERT succeeds; the deferred constraint rejects COMMIT itself.
        await expectLater(migrate(), throwsA(isA<DurableStorageException>()));
        final minted = keys.value;
        expect(minted, isNotNull);
        expect(keys.writes, 1);
        expect(legacy.slots, original);
        expect(legacy.cleanups, 0);
        expect((await database.readAll()).values, isEmpty);
        expect(CacheKeyProvider.legacyPlaintextAccepted, isFalse);

        final retryConnection = sqlite3.open('${directory.path}/cache.sqlite');
        retryConnection.execute('DROP TRIGGER fail_commit');
        retryConnection.close();
        if (coldRetry) {
          await database.close();
          CacheKeyProvider.debugReset();
          database = await SqliteKeyValueStore.open(
            '${directory.path}/cache.sqlite',
          );
        }
        final cache = (await migrate())!;
        expect(keys.value, minted);
        expect(keys.writes, 1);
        expect(await cache.getString(_outbox), original[_outbox]);
        expect(await database.getString(_marker), 'true');
        expect(legacy.slots, isEmpty);
      },
    );
  }

  test(
    'SQLite remains authoritative when obsolete preferences become unreadable',
    () async {
      legacy.slots[_outbox] = '{"items":["pending"]}';
      await migrate();
      legacy.failRead = true;
      CacheKeyProvider.debugReset();
      expect(
        await (await migrate())!.getString(_outbox),
        '{"items":["pending"]}',
      );
    },
  );

  test(
    'locked key never imports, deletes or writes a replacement key',
    () async {
      legacy.slots[_outbox] = await AesGcmCacheCipher(
        _testKey,
      ).encrypt(_outbox, 'pending');
      final original = Map.of(legacy.slots);
      keys.locked = true;
      expect(await migrate(), isNull);
      expect(legacy.slots, original);
      expect(legacy.cleanups, 0);
      expect(keys.writes, 0);
      expect(await database.getString(_marker), isNull);
      expect(await database.getString(_outbox), isNull);
    },
  );

  test(
    'background locked or absent key never spends recovery strikes or purges data',
    () async {
      legacy.slots[_outbox] = 'pending';
      await migrate();
      final before = await database.readAll();
      keys.locked = true;
      for (var i = 0; i < 4; i++) {
        CacheKeyProvider.debugReset();
        expect(await migrate(background: true), isNull);
      }
      keys.locked = false;
      keys.value = null;
      expect(await migrate(background: true), isNull);
      final after = await database.readAll();
      expect(after.values, before.values);
      expect(after.versions, before.versions);
      expect(keys.writes, 0);
    },
  );

  test(
    'background requires completed migration and never reads old preferences',
    () async {
      legacy.failRead = true;
      expect(await migrate(background: true), isNull);
      expect((await database.readAll()).values, isEmpty);
      expect(keys.writes, 0);
    },
  );

  test(
    'closed plaintext migration rejects unsigned legacy without deleting it',
    () async {
      legacy.metadata[CacheKeyProvider.plaintextMigrationClosedKey] = 'true';
      legacy.slots[_outbox] = 'unsigned';
      await expectLater(migrate(), throwsA(isA<DurableStorageException>()));
      expect(legacy.slots[_outbox], 'unsigned');
      expect((await database.readAll()).values, isEmpty);
    },
  );

  test(
    'failed conflict fence write preserves the actionable error and both stores',
    () async {
      legacy.slots[_outbox] = 'imported';
      await migrate();
      legacy.slots[_outbox] = 'rollback-offline';
      final connection = sqlite3.open('${directory.path}/cache.sqlite');
      connection.execute(
        "CREATE TRIGGER reject_conflict BEFORE INSERT ON cache_slots "
        "WHEN NEW.key = '$_conflict' BEGIN SELECT RAISE(ABORT, 'test failure'); END",
      );
      connection.close();
      final before = await database.readAll();
      await expectLater(migrate(), throwsA(isA<LegacyStorageConflict>()));
      expect(legacy.slots[_outbox], 'rollback-offline');
      expect((await database.readAll()).values, before.values);
    },
  );

  test(
    'cleanup receipt is encrypted and committed with the initial data',
    () async {
      legacy.slots[_outbox] = '{"items":["pending"]}';
      legacy.failCleanup = true;
      await migrate();
      final raw = (await database.getString(_cleanup))!;
      expect(raw, startsWith(cacheCipherMagic));
      expect(raw, isNot(contains(_outbox)));
      final receipt =
          jsonDecode(await AesGcmCacheCipher(_testKey).decrypt(_cleanup, raw))
              as Map;
      expect(receipt.keys, [_outbox]);
      legacy.failCleanup = false;
      await migrate();
      expect(legacy.slots, isEmpty);
      expect(await database.getString(_cleanup), isNull);
    },
  );

  test(
    'first SQLite release without cleanup receipts never deletes remaining preferences',
    () async {
      legacy.slots[_outbox] = '{"items":["pending"]}';
      legacy.failCleanup = true;
      final cache = (await migrate())!;
      await database.remove(_cleanup);
      final original = Map.of(legacy.slots);
      legacy.failCleanup = false;
      await expectLater(migrate(), throwsA(isA<LegacyStorageConflict>()));
      expect(legacy.slots, original);
      expect(await cache.getString(_outbox), original[_outbox]);
    },
  );

  test(
    'write between import commit and cleanup survives and blocks background',
    () async {
      legacy.slots[_outbox] = 'imported';
      legacy.beforeCleanup = () =>
          legacy.slots[_outbox] = 'later-offline-write';
      await expectLater(migrate(), throwsA(isA<LegacyStorageConflict>()));
      expect(legacy.slots[_outbox], 'later-offline-write');
      final raw = (await database.getString(_outbox))!;
      expect(
        await AesGcmCacheCipher(_testKey).decrypt(_outbox, raw),
        'imported',
      );
      expect(await database.getString(_marker), 'true');
      expect(await database.getString(_conflict), 'true');
      expect(await migrate(background: true), isNull);
    },
  );

  for (final corruptReceipt in [false, true]) {
    test(
      '${corruptReceipt ? 'corrupt receipt' : 'new account slot'} fails closed without deleting either account',
      () async {
        legacy.slots[_outbox] = 'account-a-pending';
        legacy.failCleanup = true;
        await migrate();
        legacy.slots[_profile] = 'account-b-offline';
        if (corruptReceipt) await database.setString(_cleanup, 'corrupt');
        final original = Map.of(legacy.slots);
        legacy.failCleanup = false;
        await expectLater(migrate(), throwsA(isA<LegacyStorageConflict>()));
        expect(legacy.slots, original);
        expect(await database.getString(_profile), isNull);
        expect(await database.getString(_outbox), isNotNull);
      },
    );
  }

  test(
    'rollback data and cleanup evidence survive unreadable preferences and locked key',
    () async {
      legacy.slots[_outbox] = 'imported';
      legacy.failCleanup = true;
      await migrate();
      final receipt = await database.getString(_cleanup);
      legacy.failRead = true;
      await migrate();
      expect(await database.getString(_cleanup), receipt);
      legacy.failRead = false;
      legacy.slots[_outbox] = 'rollback-offline';
      keys.locked = true;
      final before = await database.readAll();
      for (var i = 0; i < 4; i++) {
        CacheKeyProvider.debugReset();
        expect(await migrate(), isNull);
      }
      expect((await database.readAll()).values, before.values);
      expect(legacy.slots[_outbox], 'rollback-offline');
      expect(keys.writes, 0);
      keys.locked = false;
      await expectLater(migrate(), throwsA(isA<LegacyStorageConflict>()));
      legacy.failRead = true;
      await expectLater(migrate(), throwsA(isA<LegacyStorageConflict>()));
    },
  );

  test(
    'production preference enumeration excludes auth and appearance settings',
    () async {
      SharedPreferences.setMockInitialValues({
        _outbox: 'pending',
        _receipt: 'receipt',
        'eatova.v1.training_session.account-b': 'checkpoint',
        'eatova.v1.theme_mode': 'dark',
        'supabase.auth.token': 'synthetic-session',
      });
      final source = PreferencesCacheSource();
      expect((await source.readSlots()).keys.toSet(), {
        _outbox,
        _receipt,
        'eatova.v1.training_session.account-b',
      });
      await source.removeSlots({_outbox: 'pending'});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('supabase.auth.token'), 'synthetic-session');
      expect(prefs.getString('eatova.v1.theme_mode'), 'dark');
    },
  );

  test(
    'production cleanup reloads and rejects a changed native value',
    () async {
      SharedPreferences.setMockInitialValues({_outbox: 'imported'});
      final source = PreferencesCacheSource();
      final expected = await source.readSlots();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_outbox, 'late-offline-write');
      await expectLater(
        source.removeSlots(expected),
        throwsA(isA<LegacyStorageConflict>()),
      );
      expect(prefs.getString(_outbox), 'late-offline-write');
      await prefs.remove(_outbox);
      await source.removeSlots(expected);
      expect(prefs.getString(_outbox), isNull);
    },
  );
}
