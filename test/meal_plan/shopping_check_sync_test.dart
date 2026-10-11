import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/services/sync_dispatcher.dart';

import '../fixlauf_a_helpers.dart';

// Receipt ticks are local-first: the store commits them to the outbox and
// publishes them at once; delivery runs behind and never gates the next tick.
final _week = DateTime(2026, 9, 14, 12);
ShoppingCheck _check(String digit, {bool checked = true}) =>
    ShoppingCheck(id: '2026-09-14:${digit * 64}', checked: checked);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => RecipeImageStore.instance = StummerFotoStore());
  tearDown(RecipeImageStore.resetInstance);

  test('a tick shows at once while the previous tick hangs on the wire', () {
    fakeAsync((async) {
      final s = fixlaufSetup(disposeClient: false);
      s.server.profileRow = serverProfileRow(completedProfile);
      s.store.start();
      async.flushMicrotasks();
      async.elapse(Duration.zero);
      async.flushMicrotasks();
      expect(s.store.profile.onboardingCompleted, isTrue);
      // Weak signal: every sync request stays open until its timeout.
      s.server.silentRpcs = true;

      final first = _check('a'), second = _check('b');
      var firstDone = false, secondDone = false;
      s.store.setShoppingChecked(first).then((_) => firstDone = true);
      s.store.setShoppingChecked(second).then((_) => secondDone = true);
      async.elapse(const Duration(milliseconds: 300));

      expect(s.store.shoppingChecks, {
        first.id: true,
        second.id: true,
      }, reason: 'the second tick must not wait for the first delivery');
      expect(firstDone && secondDone, isTrue, reason: 'rows unlock at once');
      expect(s.store.pendingOutbox.map((op) => op.entityId), [
        first.id,
        second.id,
      ], reason: 'both ticks are durable before any server answer');

      // Let the hanging requests run into their timeout before teardown.
      async.elapse(kSyncOperationTimeout * 3);
      async.flushMicrotasks();
    }, initialTime: _week);
  });
}
