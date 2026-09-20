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
  int cleanups = 0;
  @override
  Future<Map<String, String>> readSlots() async {
    if (failRead) throw StateError('legacy unavailable');
    return Map.of(slots);
  }

  @override
  Future<Map<String, String>> readKeyMetadata() async => Map.of(metadata);
  @override
  Future<void> removeSlots(Iterable<String> keys) async {
    cleanups++;
    if (failCleanup) throw StateError('cleanup failed');
    for (final key in keys) {
      slots.remove(key);
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
      await source.removeSlots([_outbox]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('supabase.auth.token'), 'synthetic-session');
      expect(prefs.getString('eatova.v1.theme_mode'), 'dark');
    },
  );
}
