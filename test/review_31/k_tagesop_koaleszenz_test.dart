import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import '../outbox/outbox_test_helpers.dart';

// A meal now books its counter and tracking day in ONE transaction. There is
// no redundant day-only queue entry to coalesce; confirmed meal intents retain
// distinct identities even when the same day repeatedly fails to synchronize.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 5, 14, 12, 30);
  Future<void> onDay(Future<void> Function() body) =>
      withClock(Clock.fixed(now), body);

  test(
    'acht Logs behalten acht Meal-UUIDs ohne redundante Tages-Ops',
    () => onDay(() async {
      final s = setup();
      await boot(s.store);
      s.server.rejectTrackingDay = true;
      for (var i = 1; i <= 8; i++) {
        await s.store.addResultToDailyTotal(mealResult('Bowl $i'));
      }
      final meals = s.store.pendingOutbox
          .where((op) => op.kind == SyncOpKind.mealInsert)
          .toList();
      expect(meals, hasLength(8));
      expect(meals.every((op) => op.trackDay), isTrue);
      expect(meals.map((op) => op.operationId).toSet(), hasLength(8));
      expect(
        s.store.pendingOutbox,
        hasLength(8),
        reason: 'keine separaten Tages-Ops und keine verlorenen Meal-Intents',
      );
      expect(
        (await s.cache.readOutbox())!.map((op) => op.operationId),
        meals.map((op) => op.operationId),
      );
      expect(s.server.operations('trackingDay'), isEmpty);
      expect(
        s.server.mealsCounted,
        0,
        reason: 'eine abgewiesene atomare Tagesbuchung zaehlt kein Meal',
      );
    }),
  );

  test(
    'Nachlieferung bucht jedes Meal einmal und denselben Tag atomar',
    () => onDay(() async {
      final s = setup();
      await boot(s.store);
      s.server.rejectTrackingDay = true;
      for (var i = 1; i <= 3; i++) {
        await s.store.addResultToDailyTotal(mealResult('Bowl $i'));
      }
      final pending = s.store.pendingOutbox;
      expect(pending, hasLength(3));
      final before = s.server.operations('mealInsert').length;
      s.server.rejectTrackingDay = false;
      await s.store.syncPendingWrites(retryBlocked: true);
      expect(s.server.operations('mealInsert').length - before, 3);
      expect(s.server.operations('trackingDay'), isEmpty);
      expect(s.server.trackedDay, localDayKey(now));
      expect(s.server.mealsCounted, 3);
      expect(s.server.mealRows, hasLength(3));
      expect(s.store.pendingOutbox, isEmpty);
      await s.store.syncPendingWrites();
      expect(
        s.server.mealsCounted,
        3,
        reason: 'ein zweiter Pass darf keinen bereits bestaetigten Log zaehlen',
      );
    }),
  );
}
