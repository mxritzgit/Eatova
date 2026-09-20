import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_dispatcher.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import 'outbox/outbox_test_helpers.dart';
import 'support/sync_replay_interleaving_fake.dart';

// The durable queue may change while a response is outstanding. A receipt must
// remove its exact UUID, never whichever operation has inherited its index.
const _day = '2026-08-14';
LoggedMeal _meal(String id) => LoggedMeal(
  id: id,
  result: mealResult(id),
  loggedAt: DateTime(2026, 8, 14, 12),
  localDay: _day,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Replay-Wettlauf: frueherer Ack darf keine fremde Tail-Op entfernen',
    () async {
      await withClock(Clock.fixed(DateTime(2026, 8, 14, 12, 30)), () async {
        final kv = InMemoryKeyValueStore();
        final day = SyncOp.trackingDay(_day);
        final first = SyncOp.mealInsert(
          _meal('11111111-2222-4333-8444-555555555555'),
          trackDay: true,
        );
        final second = SyncOp.mealInsert(
          _meal('22222222-2222-4333-8444-555555555555'),
          trackDay: false,
        );
        final tail = SyncOp.mealDelete('33333333-2222-4333-8444-555555555555');
        await seedRawOutbox(kv, [
          day.toJson(),
          first.toJson(),
          second.toJson(),
          tail.toJson(),
        ]);
        final server = ReplayInterleavingServer()
          ..enforceTrackingDaySourceProof = true;
        final s = setup(kv: kv, geteilterServer: server);
        await s.cache.writeProfile(testProfile());
        final independentClient = SupabaseClient(
          'https://example.supabase.co',
          'test-anon-key',
          httpClient: server.client(),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        addTearDown(independentClient.dispose);
        final independentSync = EatovaSync.forUser(
          independentClient,
          'user-outbox',
        );
        var shortenedDuringAwait = false;
        server.beforeReceipt = (params, _) async {
          if (params['p_operation_id'] != second.operationId ||
              shortenedDuringAwait) {
            return;
          }
          final before = await s.cache.readSyncOperations();
          expect(before.map((op) => op.operationId), [
            day.operationId,
            second.operationId,
            tail.operationId,
          ]);
          // The first day attempt had no meal source. Once the first meal lands,
          // an independent, genuine receipt can acknowledge that earlier entry.
          // This deliberately exercises the cache boundary below worker leases.
          final deliveredDay = await dispatchSyncOp(independentSync, day);
          await s.cache.acknowledgeSyncOperation(day.operationId, deliveredDay);
          final after = await s.cache.readSyncOperations();
          expect(after.map((op) => op.operationId), [
            second.operationId,
            tail.operationId,
          ]);
          shortenedDuringAwait = true;
        };
        await bootUntilIdle(s.store);
        expect(
          shortenedDuringAwait,
          isTrue,
          reason: 'die Queue muss vor dem aktuellen Cursor im await schrumpfen',
        );
        expect(server.trackingDayRejections, [_day]);
        expect(server.operations('trackingDay'), hasLength(2));
        expect(
          server.mealRows.keys,
          containsAll([first.entityId, second.entityId]),
        );
        expect(
          server.operations('mealDelete'),
          hasLength(1),
          reason:
              'eine ungesendete fremde Op darf niemals als quittiert gelten',
        );
        expect(server.mealsCounted, 2);
        expect(s.store.pendingOutbox, isEmpty);
        expect(await s.cache.readOutbox(), isEmpty);
        await s.store.syncPendingWrites();
        expect(server.operations('mealInsert'), hasLength(2));
        expect(server.mealsCounted, 2);
      });
    },
  );
}
