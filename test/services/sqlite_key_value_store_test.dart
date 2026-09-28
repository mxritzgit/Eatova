import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:eatova/src/services/key_value_store.dart';
import 'package:eatova/src/services/sqlite_key_value_store.dart';

/// Diagnostics may name SQLite's fixed result code, never the message, the
/// SQL, the bound values or the database path.
Matcher _sanitizedFor(String path) => allOf([
  isNot(contains('test fault')),
  isNot(contains('cache_slots')),
  isNot(contains('INSERT')),
  isNot(contains('ROLLBACK')),
  isNot(contains('new-op')),
  isNot(contains('meal-')),
  isNot(contains(path)),
  isNot(contains('eatova_sqlite_')),
]);

void main() {
  group('DurableStorageException SQLite codes', () {
    test('maps every primary result code to its fixed SQLite name', () {
      const names = {
        1: 'error',
        2: 'internal',
        3: 'perm',
        4: 'abort',
        5: 'busy',
        6: 'locked',
        7: 'nomem',
        8: 'readonly',
        9: 'interrupt',
        10: 'ioerr',
        11: 'corrupt',
        12: 'notfound',
        13: 'full',
        14: 'cantopen',
        15: 'protocol',
        16: 'empty',
        17: 'schema',
        18: 'toobig',
        19: 'constraint',
        20: 'mismatch',
        21: 'misuse',
        22: 'nolfs',
        23: 'auth',
        24: 'format',
        25: 'range',
        26: 'notadb',
        27: 'notice',
        28: 'warning',
      };
      for (final entry in names.entries) {
        expect(
          DurableStorageException('x', sqliteResultCode: entry.key).sqliteCode,
          entry.value,
          reason: 'primary code ${entry.key}',
        );
      }
    });

    test('extended codes keep their primary category', () {
      const extended = {
        261: 'busy', // SQLITE_BUSY_RECOVERY
        517: 'busy', // SQLITE_BUSY_SNAPSHOT
        262: 'locked', // SQLITE_LOCKED_SHAREDCACHE
        1034: 'ioerr', // SQLITE_IOERR_FSYNC
        4618: 'ioerr', // SQLITE_IOERR_SHMOPEN
        3850: 'ioerr', // SQLITE_IOERR_LOCK
        270: 'cantopen', // SQLITE_CANTOPEN_NOTEMPDIR
        1811: 'constraint', // SQLITE_CONSTRAINT_TRIGGER
      };
      for (final entry in extended.entries) {
        final error = DurableStorageException(
          'database operation failed',
          sqliteResultCode: entry.key,
        );
        expect(error.sqliteCode, entry.value, reason: 'code ${entry.key}');
        expect(
          error.toString(),
          'DurableStorageException: database operation failed '
          '(sqlite ${entry.value}, code ${entry.key})',
        );
      }
    });

    test('unknown or absent codes stay generic', () {
      expect(
        const DurableStorageException('x', sqliteResultCode: 99).sqliteCode,
        'unknown',
      );
      const plain = DurableStorageException('database is closed');
      expect(plain.sqliteCode, isNull);
      expect(plain.toString(), 'DurableStorageException: database is closed');
    });
  });

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
        throwsA(
          isA<DurableStorageException>()
              .having((e) => e.reason, 'reason', 'database operation failed')
              .having((e) => e.sqliteCode, 'sqliteCode', 'constraint')
              // SQLITE_CONSTRAINT_TRIGGER
              .having((e) => e.sqliteResultCode, 'sqliteResultCode', 1811)
              .having((e) => '$e', 'toString', _sanitizedFor(path)),
        ),
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

  test(
    'a failure swallowed inside initialization still blocks its commit',
    () async {
      final store = await open();
      await store.writeBatch({'entity': 'old'});
      await expectLater(
        store.initializeExclusively(() async {
          try {
            await store.writeBatch(
              {'entity': 'stale'},
              expectedVersions: {'entity': 0},
            );
          } on KeyValueConflict {
            // A migration step that ignores its own failed write.
          }
          await store.writeBatch({'migrated': 'true'});
        }),
        throwsA(isA<DurableStorageException>()),
      );
      await store.close();
      final reopened = await open();
      expect((await reopened.readSnapshot(['entity', 'migrated'])).values, {
        'entity': 'old',
        'migrated': null,
      });
      await reopened.initializeExclusively(() async {
        await reopened.writeBatch({'migrated': 'true'});
      });
      expect(await reopened.getString('migrated'), 'true');
    },
  );

  test(
    'an unreadable file reports the SQLite category, not its path',
    () async {
      await File(path).writeAsBytes(List<int>.filled(4096, 0x41));
      await expectLater(
        open(),
        throwsA(
          isA<DurableStorageException>()
              .having((e) => e.reason, 'reason', 'database unavailable')
              .having((e) => e.sqliteCode, 'sqliteCode', 'notadb')
              .having((e) => e.sqliteResultCode, 'sqliteResultCode', 26)
              .having((e) => '$e', 'toString', _sanitizedFor(path)),
        ),
      );
    },
  );

  group('a transaction SQLite already rolled back', () {
    void installRollbackTrigger() {
      final connection = sqlite3.open(path);
      connection.execute(
        "CREATE TRIGGER fail_outbox BEFORE UPDATE ON cache_slots "
        "WHEN NEW.key = 'outbox' BEGIN SELECT RAISE(ROLLBACK, 'test fault'); "
        'END',
      );
      connection.close();
    }

    void dropRollbackTrigger() {
      final connection = sqlite3.open(path);
      connection.execute('DROP TRIGGER fail_outbox');
      connection.close();
    }

    test(
      'reports the original failure instead of the failed ROLLBACK',
      () async {
        final store = await open();
        await store.writeBatch({'entity': 'old', 'outbox': 'old-op'});
        installRollbackTrigger();
        await expectLater(
          store.writeBatch({'entity': 'new', 'outbox': 'new-op'}),
          throwsA(
            isA<DurableStorageException>()
                .having((e) => e.sqliteCode, 'sqliteCode', 'constraint')
                .having((e) => '$e', 'toString', _sanitizedFor(path)),
          ),
        );
        dropRollbackTrigger();
        expect((await store.writeBatch({'entity': 'next'})).versions, {
          'entity': 2,
        });
        expect((await store.readSnapshot(['entity', 'outbox'])).values, {
          'entity': 'next',
          'outbox': 'old-op',
        });
      },
    );

    test('does not leave the connection in a phantom initialization', () async {
      final store = await open();
      await store.writeBatch({'entity': 'old', 'outbox': 'old-op'});
      installRollbackTrigger();
      await expectLater(
        store.initializeExclusively(() async {
          await store.writeBatch({'entity': 'imported'});
          await store.writeBatch({'outbox': 'imported-op'});
        }),
        throwsA(
          isA<DurableStorageException>().having(
            (e) => e.sqliteCode,
            'sqliteCode',
            'constraint',
          ),
        ),
      );
      dropRollbackTrigger();
      expect((await store.readSnapshot(['entity', 'outbox'])).values, {
        'entity': 'old',
        'outbox': 'old-op',
      });
      // A stuck initialization flag would reject this and run later batches
      // without their own transaction.
      await store.initializeExclusively(() async {
        await store.writeBatch({'entity': 'imported', 'migrated': 'true'});
      });
      expect((await store.readSnapshot(['entity', 'migrated'])).values, {
        'entity': 'imported',
        'migrated': 'true',
      });
    });
  });
}
