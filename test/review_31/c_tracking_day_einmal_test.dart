import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import '../outbox/outbox_test_helpers.dart';

// C-01: moving yesterday's meal to today commits the source before its single
// tracking operation. Shrinking the acknowledged queue must not skip its tail.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 5, 14, 12, 30);
  Future<void> onDay(Future<void> Function() body) =>
      withClock(Clock.fixed(now), body);

  test(
    'live: Source-Upsert vor genau einer Tracking-Buchung',
    () => onDay(() async {
      final s = setup();
      s.server.enforceTrackingDaySourceProof = true;
      await boot(s.store);
      final id = await s.store.addResultToDailyTotal(
        mealResult('Gestern'),
        foodDate: now.subtract(const Duration(days: 1)),
      );
      expect(s.server.trackedDay, isNull);
      final before = s.server.requests.length;
      await s.store.updateLoggedMealDetails(id, day: now);
      await s.store.syncPendingWrites();
      final kinds = s.server.requests
          .skip(before)
          .where((r) => r.url.path.endsWith('/rpc/apply_sync_operation'))
          .map((r) => (jsonDecode(r.body) as Map)['p_kind'])
          .toList();
      expect(kinds, ['mealUpsert', 'trackingDay']);
      expect(s.server.trackingDayRejections, isEmpty);
      expect(s.server.trackedDay, localDayKey(now));
      expect(s.store.pendingOutbox, isEmpty);
      expect(s.store.lifetimeStats.lastTrackedDate, isNotNull);
    }),
  );

  test(
    'offline: Source und Tag werden gemeinsam dauerhaft vor HTTP gespeichert',
    () => onDay(() async {
      final s = setup();
      s.server.enforceTrackingDaySourceProof = true;
      await boot(s.store);
      final id = await s.store.addResultToDailyTotal(
        mealResult('Gestern'),
        foodDate: now.subtract(const Duration(days: 1)),
      );
      s.server.offline = true;
      await s.store.updateLoggedMealDetails(id, day: now);
      final queue = await s.cache.readSyncOperations();
      expect(queue.map((o) => o.kind), [
        SyncOpKind.mealUpsert,
        SyncOpKind.trackingDay,
      ]);
      s.server.offline = false;
      final before = s.server.operations('trackingDay').length;
      await s.store.syncPendingWrites();
      expect(s.server.operations('trackingDay').length - before, 1);
      expect(s.server.trackingDayRejections, isEmpty);
      expect(s.server.trackedDay, localDayKey(now));
      expect(s.store.pendingOutbox, isEmpty);
    }),
  );

  test(
    'haengender Source-Write sendet keinen Tag vor seinem Commit',
    () => onDay(() async {
      final s = setup();
      s.server.enforceTrackingDaySourceProof = true;
      await boot(s.store);
      final id = await s.store.addResultToDailyTotal(
        mealResult('Gestern'),
        foodDate: now.subtract(const Duration(days: 1)),
      );
      s.server.holdMealWrites();
      final move = s.store.updateLoggedMealDetails(id, day: now);
      await settle();
      expect(s.server.operations('trackingDay'), isEmpty);
      expect((await s.cache.readSyncOperations()).map((o) => o.kind), [
        SyncOpKind.mealUpsert,
        SyncOpKind.trackingDay,
      ]);
      s.server.releaseMealWrites();
      await move;
      await s.store.syncPendingWrites();
      expect(s.server.operations('trackingDay'), hasLength(1));
      expect(s.server.trackingDayRejections, isEmpty);
    }),
  );

  test(
    'Ack kuerzt Queue ohne die nachfolgende Delete-Op zu ueberspringen',
    () => onDay(() async {
      final s = setup();
      s.server.enforceTrackingDaySourceProof = true;
      await boot(s.store);
      final id = await s.store.addResultToDailyTotal(
        mealResult('Gestern'),
        foodDate: now.subtract(const Duration(days: 1)),
      );
      s.server.holdMealWrites();
      final move = s.store.updateLoggedMealDetails(id, day: now);
      await settle();
      final remove = s.store.removeLoggedMeal(id);
      await settle();
      expect(s.store.pendingOutbox.map((o) => o.kind), [
        SyncOpKind.mealUpsert,
        SyncOpKind.trackingDay,
        SyncOpKind.mealDelete,
      ]);
      s.server.releaseMealWrites();
      await Future.wait([move, remove]);
      await s.store.syncPendingWrites();
      expect(s.server.operations('trackingDay'), hasLength(1));
      expect(s.server.operations('mealDelete'), hasLength(1));
      expect(s.server.trackingDayRejections, isEmpty);
      expect(s.server.mealRows, isNot(contains(id)));
      expect(s.store.pendingOutbox, isEmpty);
      expect(await s.cache.readSyncOperations(), isEmpty);
    }),
  );
}
