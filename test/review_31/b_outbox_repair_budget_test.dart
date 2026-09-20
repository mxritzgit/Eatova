import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import '../outbox/outbox_test_helpers.dart';
import '../support/failing_snapshot_store.dart';

// A read failure rejects the entire save regardless of elapsed time or attempts.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid = 'user-outbox';
  for (final slot in ['outbox', 'pending_stats']) {
    for (final elapsed in [Duration.zero, const Duration(days: 365)]) {
      test(
        '$slot survives repeated failures across $elapsed and replays after restart',
        () async {
          final start = DateTime(2026, 9, 20, 12);
          var now = start;
          await withClock(Clock(() => now), () async {
            final storage = FailingSnapshotStore();
            final cache = LocalCache(storage, uid);
            final key = 'eatova.v1.$slot.$uid';
            final old = SyncOp.mealInsert(
              LoggedMeal(
                id: '11111111-1111-4111-8111-111111111111',
                result: mealResult('Old bowl'),
                loggedAt: start,
              ),
              trackDay: false,
            );
            if (slot == 'outbox') {
              await cache.writeOutbox([old]);
            } else {
              await cache.writePendingStatsDeltas(
                meals: 3,
                weightLogs: 0,
                requestId: 'legacy-request',
              );
            }
            final original = storage.snapshot[key];
            storage.blockedKeys.add(key);
            final server = FakeServer()..offline = true;
            final first = setup(
              injizierterCache: cache,
              geteilterServer: server,
              disposeStore: false,
            );
            var disposed = false;
            addTearDown(() {
              if (!disposed) first.store.dispose();
            });
            await boot(first.store);
            for (var i = 0; i < 12; i++) {
              now = now.add(elapsed);
              await expectLater(
                first.store.addResultToDailyTotal(mealResult('Rejected $i')),
                throwsA(isA<StateError>()),
              );
              expect(storage.snapshot[key], original);
              expect(first.store.loggedMeals, isEmpty);
              expect(first.store.favorites, isEmpty);
            }
            expect(server.requests, isEmpty);
            first.store.dispose();
            disposed = true;
            storage.blockedKeys.clear();
            server.offline = false;
            final second = setup(kv: storage, geteilterServer: server);
            await boot(second.store);
            await second.store.syncPendingWrites();
            expect(second.store.pendingOutbox, isEmpty);
            expect(server.mealsCounted, slot == 'outbox' ? 1 : 3);
            if (slot == 'outbox') {
              expect(server.mealRows.keys, [
                '11111111-1111-4111-8111-111111111111',
              ]);
              expect(
                server.syncOperations.receipts.keys,
                contains(old.operationId),
              );
            } else {
              expect(server.statsRequestIds, contains('legacy-request'));
            }
            await second.store.syncPendingWrites();
            expect(server.mealsCounted, slot == 'outbox' ? 1 : 3);
          });
        },
      );
    }
  }
}
