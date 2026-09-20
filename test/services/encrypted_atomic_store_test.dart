import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
import 'package:eatova/src/services/sqlite_key_value_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

class _ControlledCipher implements CacheCipher {
  _ControlledCipher(this.inner);
  final CacheCipher inner;
  String? failKey;
  final started = Completer<void>();
  Completer<void>? hold;

  @override
  Future<String> encrypt(String key, String plaintext) async {
    if (hold case final gate?) {
      hold = null;
      started.complete();
      await gate.future;
    }
    if (key == failKey) throw StateError('synthetic cipher failure');
    return inner.encrypt(key, plaintext);
  }

  @override
  Future<String> decrypt(String key, String armored) =>
      inner.decrypt(key, armored);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SqliteKeyValueStore database;
  late _ControlledCipher cipher;
  late EncryptedKeyValueStore storage;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('eatova_atomic_cipher_');
    database = await SqliteKeyValueStore.open('${directory.path}/cache.sqlite');
    cipher = _ControlledCipher(
      AesGcmCacheCipher(Uint8List.fromList(List.generate(32, (i) => i))),
    );
    storage = EncryptedKeyValueStore(
      database,
      cipher,
      acceptLegacyPlaintext: false,
    );
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'failed second encryption cannot publish half an entity/outbox batch',
    () async {
      await storage.writeBatch({'entity': 'old', 'outbox': 'old-op'});
      final before = await database.readAll();
      cipher.failKey = 'outbox';
      await expectLater(
        storage.writeBatch({'entity': 'new', 'outbox': 'new-op'}),
        throwsStateError,
      );
      final after = await database.readAll();
      expect(after.values, before.values);
      expect(after.versions, before.versions);
      cipher.failKey = null;
      await storage.writeBatch({'entity': 'new', 'outbox': 'new-op'});
      expect((await storage.readSnapshot(['entity', 'outbox'])).values, {
        'entity': 'new',
        'outbox': 'new-op',
      });
    },
  );

  test(
    'authoritative snapshot preserves corrupt bytes and fails closed',
    () async {
      await storage.setString('entity', 'old');
      const corrupt = '${cacheCipherMagic}broken';
      await database.setString('outbox', corrupt);
      final before = await database.readAll();
      await expectLater(
        storage.readSnapshot(['entity', 'outbox']),
        throwsA(anything),
      );
      expect((await database.readAll()).values, before.values);
      expect((await database.readAll()).versions, before.versions);
      expect(await database.getString('outbox'), corrupt);
    },
  );

  test(
    'a delayed mirror encryption cannot overtake a newer atomic commit',
    () async {
      final gate = cipher.hold = Completer<void>();
      final old = storage.setString('entity', 'old');
      await cipher.started.future;
      final newer = storage.writeBatch({'entity': 'new', 'outbox': 'new-op'});
      final read = storage.readSnapshot(['entity', 'outbox']);
      gate.complete();
      await old;
      await newer;
      expect((await read).values, {'entity': 'new', 'outbox': 'new-op'});
    },
  );

  test(
    'independent encrypted connections reject an obsolete snapshot',
    () async {
      final secondDatabase = await SqliteKeyValueStore.open(
        '${directory.path}/cache.sqlite',
      );
      try {
        final second = EncryptedKeyValueStore(secondDatabase, cipher);
        final snapshot = await storage.readSnapshot([
          'entity',
          'outbox',
          'session',
        ]);
        await second.writeBatch({'session': 'new-account-generation'});
        await expectLater(
          storage.writeBatch({
            'entity': 'late',
            'outbox': 'late-op',
          }, expectedVersions: snapshot.versions),
          throwsA(isA<KeyValueConflict>()),
        );
        expect((await storage.readSnapshot(['entity', 'outbox'])).values, {
          'entity': null,
          'outbox': null,
        });
      } finally {
        await secondDatabase.close();
      }
    },
  );

  for (final preserve in [false, true]) {
    test(
      'account purge is atomic and scoped (preserve sync: $preserve)',
      () async {
        const profile = 'eatova.v1.profile.A';
        const outbox = 'eatova.v1.outbox.A';
        const receipt = 'eatova.v1.training_history_deletions.A';
        const other = 'eatova.v1.profile.B';
        await storage.writeBatch({
          profile: 'A profile',
          outbox: 'A op',
          receipt: 'A receipt',
          other: 'B profile',
        });
        final before = await database.readAll();
        final connection = sqlite3.open('${directory.path}/cache.sqlite');
        connection.execute(
          'CREATE TRIGGER fail_purge BEFORE INSERT ON cache_slots '
          "WHEN NEW.key = 'eatova.v1.stats.A' BEGIN SELECT RAISE(ABORT, 'fault'); END",
        );
        connection.close();
        await expectLater(
          LocalCache(storage, 'A').clear(preserveOutbox: preserve),
          throwsA(isA<UnwritableCacheSlot>()),
        );
        expect((await database.readAll()).values, before.values);
        final retryConnection = sqlite3.open('${directory.path}/cache.sqlite');
        retryConnection.execute('DROP TRIGGER fail_purge');
        retryConnection.close();
        await LocalCache(storage, 'A').clear(preserveOutbox: preserve);
        final result = (await storage.readSnapshot([
          profile,
          outbox,
          receipt,
          other,
        ])).values;
        expect(result[profile], isNull);
        expect(result[outbox], preserve ? 'A op' : isNull);
        expect(result[receipt], preserve ? 'A receipt' : isNull);
        expect(result[other], 'B profile');
      },
    );
  }
}
