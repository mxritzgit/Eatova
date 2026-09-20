import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/services/key_value_store.dart';
import 'package:eatova/src/services/sqlite_key_value_store.dart';
import 'package:eatova/src/services/sync_execution_guard.dart';

void main() {
  test(
    'echte SQLite-Verbindungen koordinieren Claim und Logout-Ack-Fence',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'eatova-sync-claim-',
      );
      final path = '${directory.path}/claims.sqlite';
      final firstDb = await SqliteKeyValueStore.open(path);
      final secondDb = await SqliteKeyValueStore.open(path);
      try {
        await withClock(Clock.fixed(DateTime.utc(2026, 9, 20)), () async {
          final first = SyncExecutionGuard(firstDb);
          final second = SyncExecutionGuard(secondDb);
          await first.activate('A', 'session-A');
          final claims = await Future.wait([
            first.tryClaim('A'),
            second.tryClaim('A'),
          ]);
          expect(claims.whereType<SyncExecutionClaim>(), hasLength(1));
          final winner = claims.whereType<SyncExecutionClaim>().single;
          await second.invalidate('A');
          expect(await winner.isCurrent(), isFalse);
          await expectLater(
            firstDb.writeBatch({
              'ack': 'would-delete-outbox',
            }, expectedVersions: winner.guards),
            throwsA(isA<KeyValueConflict>()),
          );
          expect(await secondDb.getString('ack'), isNull);
          await winner.release();
        });
      } finally {
        await firstDb.close();
        await secondDb.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
