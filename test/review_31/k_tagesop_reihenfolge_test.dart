import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/sync_dispatcher.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import '../outbox/outbox_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('K2: abgelaufener Source-Write blockiert nur seinen abhaengigen Tag', () {
    final now = DateTime(2026, 5, 14, 12, 30);
    fakeAsync((async) {
      final s = setup(disposeClient: false);
      s.server.enforceTrackingDaySourceProof = true;
      s.store.start();
      async.flushMicrotasks();
      async.elapse(Duration.zero);
      async.flushMicrotasks();
      String? id;
      s.store
          .addResultToDailyTotal(
            mealResult('Gestern'),
            foodDate: now.subtract(const Duration(days: 1)),
          )
          .then((value) => id = value);
      async.flushMicrotasks();
      expect(id, isNotNull);
      expect(s.server.trackedDay, isNull);
      s.server.holdMealWrites();
      s.store.updateLoggedMealDetails(id!, day: now);
      async.flushMicrotasks();
      s.store.createUserRecipe(userRecipe('user_beweis'));
      async.flushMicrotasks();
      expect(s.store.pendingOutbox.map((o) => o.kind), [
        SyncOpKind.mealUpsert,
        SyncOpKind.trackingDay,
        SyncOpKind.recipeUpsert,
      ]);
      // The shared dispatcher frees unrelated entities after its real deadline.
      // A tracking operation cannot pass a still-unconfirmed source operation.
      async.elapse(kSyncOperationTimeout + const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(s.server.recipeRows.keys, contains('user_beweis'));
      expect(s.server.operations('trackingDay'), isEmpty);
      expect(s.server.trackingDayRejections, isEmpty);
      final day = s.store.pendingOutbox.singleWhere(
        (op) => op.kind == SyncOpKind.trackingDay,
      );
      expect(day.attempts, 0);
      s.server.releaseMealWrites();
      async.flushMicrotasks();
      s.store.syncPendingWrites();
      async.flushMicrotasks();
      expect(s.server.operations('trackingDay'), hasLength(1));
      expect(s.server.trackingDayRejections, isEmpty);
      expect(s.server.trackedDay, localDayKey(now));
      expect(s.store.pendingOutbox, isEmpty);
    }, initialTime: now);
  });
}
