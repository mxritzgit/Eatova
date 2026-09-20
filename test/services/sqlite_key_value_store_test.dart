import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:eatova/src/services/key_value_store.dart';
import 'package:eatova/src/services/sqlite_key_value_store.dart';

void main() {
  late Directory directory;
  late String path;
  final opened = <SqliteKeyValueStore>[];

  Future<SqliteKeyValueStore> open() async {
    final store = await SqliteKeyValueStore.open(path);
    opened.add(store);
    return store;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('eatova_sqlite_');
    path = '${directory.path}/cache.sqlite';
  });
  tearDown(() async {
    for (final store in opened) {
      await store.close();
    }
    opened.clear();
    await directory.delete(recursive: true);
  });

  test('committed entity and outbox survive a real close and reopen', () async {
    final store = await open();
    expect(await store.durabilitySettings(), {
      'wal': 1,
      'synchronous': 2,
      'fullfsync': 1,
    });
    final receipt = await store.writeBatch(
      {'entity': 'meal-1', 'outbox': 'operation-1'},
      expectedVersions: {'entity': 0, 'outbox': 0},
    );
    expect(receipt.versions, {'entity': 1, 'outbox': 1});
    await store.close();
    final reopened = await open();
    final snapshot = await reopened.readSnapshot(['entity', 'outbox']);
    expect(snapshot.values, {'entity': 'meal-1', 'outbox': 'operation-1'});
    expect(snapshot.versions, receipt.versions);
  });

  test(
    'SQL failure after the first update rolls the whole batch back',
    () async {
      final store = await open();
      await store.writeBatch({'entity': 'old', 'outbox': 'old-op'});
      final connection = sqlite3.open(path);
      connection.execute(
        "CREATE TRIGGER fail_outbox BEFORE UPDATE ON cache_slots "
        "WHEN NEW.key = 'outbox' BEGIN SELECT RAISE(ABORT, 'test fault'); END",
      );
      connection.close();
      await expectLater(
        store.writeBatch({'entity': 'new', 'outbox': 'new-op'}),
        throwsA(isA<DurableStorageException>()),
      );
      await store.close();
      final reopened = await open();
      final snapshot = await reopened.readSnapshot(['entity', 'outbox']);
      expect(snapshot.values, {'entity': 'old', 'outbox': 'old-op'});
      expect(snapshot.versions, {'entity': 1, 'outbox': 1});
    },
  );

  test(
    'independent connections cannot overwrite an acknowledged commit',
    () async {
      final first = await open();
      final second = await open();
      final original = await first.readSnapshot(['entity', 'outbox']);
      await second.writeBatch({'entity': 'other', 'outbox': 'other-op'});
      await expectLater(
        first.writeBatch({
          'entity': 'stale',
          'outbox': 'stale-op',
        }, expectedVersions: original.versions),
        throwsA(isA<KeyValueConflict>()),
      );
      expect((await first.readSnapshot(['entity', 'outbox'])).values, {
        'entity': 'other',
        'outbox': 'other-op',
      });
    },
  );

  test(
    'unchanged generation guards and deleted keys retain their versions',
    () async {
      final store = await open();
      final before = await store.readSnapshot(['session', 'entity']);
      await store.setString('session', 'generation-1');
      await store.remove('session');
      expect((await store.readSnapshot(['session'])).versions['session'], 2);
      await expectLater(
        store.writeBatch({
          'entity': 'late-account-write',
        }, expectedVersions: before.versions),
        throwsA(isA<KeyValueConflict>()),
      );
      expect(await store.getString('entity'), isNull);
    },
  );

  test(
    'failed initialization does not leave a partial migration marker',
    () async {
      final store = await open();
      await expectLater(
        store.initializeExclusively(() async {
          await store.writeBatch({'entity': 'imported'});
          throw StateError('simulated migration failure');
        }),
        throwsStateError,
      );
      expect((await store.readSnapshot(['entity', 'migrated'])).values, {
        'entity': null,
        'migrated': null,
      });
      await store.initializeExclusively(() async {
        await store.writeBatch({'entity': 'imported', 'migrated': 'true'});
      });
      await store.close();
      expect(
        (await (await open()).readSnapshot(['entity', 'migrated'])).values,
        {'entity': 'imported', 'migrated': 'true'},
      );
    },
  );
}
