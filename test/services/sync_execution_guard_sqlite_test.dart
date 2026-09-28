import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/services/key_value_store.dart';
import 'package:eatova/src/services/sqlite_key_value_store.dart';
import 'package:eatova/src/services/sync_execution_guard.dart';

import '../support/atomic_store_faults.dart';

void main() {
  late Directory directory;
  late SqliteKeyValueStore firstDb;
  late SqliteKeyValueStore secondDb;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('eatova-sync-claim-');
    final path = '${directory.path}/claims.sqlite';
    firstDb = await SqliteKeyValueStore.open(path);
    secondDb = await SqliteKeyValueStore.open(path);
  });
  tearDown(() async {
    await firstDb.close();
    await secondDb.close();
    await directory.delete(recursive: true);
  });

  test(
    'echte SQLite-Verbindungen koordinieren Claim und Logout-Ack-Fence',
    () async {
      await withClock(Clock.fixed(DateTime.utc(2026, 9, 20)), () async {
        await SyncExecutionGuard(firstDb).activate('A', 'session-A');
        final firstStore = AtomicStoreFaults(firstDb);
        final secondStore = AtomicStoreFaults(secondDb);
        final first = SyncExecutionGuard(firstStore);
        final second = SyncExecutionGuard(secondStore);

        // Both engines read the unclaimed state before either writes, then
        // the first commits. The second's write therefore reaches SQLite
        // with stale versions: the cross-connection CAS loser, every time.
        final firstRead = Completer<void>();
        final secondRead = Completer<void>();
        final firstCommitted = Completer<void>();
        var secondWrites = 0;
        firstStore.beforeWrite = (_) async {
          firstRead.complete();
          await secondRead.future;
        };
        secondStore.beforeWrite = (_) async {
          secondWrites++;
          secondRead.complete();
          await firstRead.future;
          await firstCommitted.future;
        };
        final losing = second.tryClaim('A');
        final winner = await first.tryClaim('A');
        firstStore.beforeWrite = null;
        firstCommitted.complete();
        expect(winner, isNotNull);
        expect(await losing, isNull);
        expect(secondWrites, 1, reason: 'the loser must attempt its CAS');
        final claimKey = syncClaimKey('A');
        expect(
          (await secondDb.readSnapshot([claimKey])).versions[claimKey],
          1,
          reason: 'the rejected claim must not have been applied',
        );

        // Once the claim is committed, a later engine sees the live lease
        // and backs off without writing at all.
        secondStore.beforeWrite = (_) async {
          secondWrites++;
        };
        expect(await second.tryClaim('A'), isNull);
        expect(secondWrites, 1);

        await second.invalidate('A');
        expect(await winner!.isCurrent(), isFalse);
        await expectLater(
          firstDb.writeBatch({
            'ack': 'would-delete-outbox',
          }, expectedVersions: winner.guards),
          throwsA(isA<KeyValueConflict>()),
        );
        expect(await secondDb.getString('ack'), isNull);
        await winner.release();
      });
    },
  );
}
