import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/planned_meal.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/services/sync_dispatcher.dart';

import '../support/fixlauf_a_helpers.dart';

// Receipt ticks are local-first: the store commits them to the outbox and
// publishes them at once; delivery runs behind and never gates the next tick.
final _week = DateTime(2026, 9, 14, 12);
ShoppingCheck _check(String digit, {bool checked = true}) =>
    ShoppingCheck(id: '2026-09-14:${digit * 64}', checked: checked);

FixlaufSetup _bootOnline(FakeAsync async) {
  final s = fixlaufSetup(disposeClient: false);
  s.server.profileRow = serverProfileRow(completedProfile);
  s.store.start();
  async.flushMicrotasks();
  async.elapse(Duration.zero);
  async.flushMicrotasks();
  expect(s.store.profile.onboardingCompleted, isTrue);
  return s;
}

/// Shopping-check values the server received, per line, in request order.
Map<String, List<bool>> _sentChecks(FixlaufServer server) {
  final sent = <String, List<bool>>{};
  for (final request in server.requestsTo('/rpc/apply_sync_operation')) {
    final body = jsonDecode(request.body) as Map;
    if (body['p_kind'] != 'shoppingCheck') continue;
    (sent[body['p_entity_id'] as String] ??= []).add(
      (body['p_payload'] as Map)['checked'] as bool,
    );
  }
  return sent;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => RecipeImageStore.instance = StummerFotoStore());
  tearDown(RecipeImageStore.resetInstance);

  test('a tick shows at once while the previous tick hangs on the wire', () {
    fakeAsync((async) {
      final s = _bootOnline(async);
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

  test('repeated toggles of an unsent line send one op, a reversal none', () {
    fakeAsync((async) {
      final s = _bootOnline(async);
      s.server.silentRpcs = true;
      // The first tick is on the wire and hangs; later ticks queue behind it.
      final onWire = _check('a');
      s.store.setShoppingChecked(onWire);
      async.elapse(const Duration(milliseconds: 100));

      final toggled = _check('b'), reverted = _check('c');
      for (final checked in [true, false, true]) {
        s.store.setShoppingChecked(_check('b', checked: checked));
        async.elapse(const Duration(milliseconds: 100));
      }
      for (final checked in [true, false]) {
        s.store.setShoppingChecked(_check('c', checked: checked));
        async.elapse(const Duration(milliseconds: 100));
      }

      expect(
        s.store.pendingOutbox.map(
          (op) => (op.entityId, op.shoppingCheckValue!.checked),
        ),
        [(onWire.id, true), (toggled.id, true)],
      );
      expect(s.store.shoppingChecks, {
        onWire.id: true,
        toggled.id: true,
        reverted.id: false,
      });

      // The connection recovers: the hanging request times out, the queue
      // drains and the server sees each line's final value once.
      s.server.silentRpcs = false;
      async.elapse(kSyncOperationTimeout + const Duration(minutes: 2));
      async.flushMicrotasks();
      expect(s.store.pendingOutbox, isEmpty);
      expect(_sentChecks(s.server), {
        onWire.id: [true, true],
        toggled.id: [true],
      });
    }, initialTime: _week);
  });

  test('a tick already on the wire is never folded into a later one', () {
    fakeAsync((async) {
      final s = _bootOnline(async);
      s.server.silentRpcs = true;
      s.store.setShoppingChecked(_check('a'));
      async.elapse(const Duration(milliseconds: 100));
      s.store.setShoppingChecked(_check('a', checked: false));
      async.elapse(const Duration(milliseconds: 100));

      expect(
        s.store.pendingOutbox.map((op) => op.shoppingCheckValue!.checked),
        [true, false],
        reason: 'the server may already hold the first tick',
      );
      expect(s.store.pendingOutbox.first.deliveryStarted, isTrue);
      expect(s.store.shoppingChecks, {_check('a').id: false});

      async.elapse(kSyncOperationTimeout * 3);
      async.flushMicrotasks();
    }, initialTime: _week);
  });
}
