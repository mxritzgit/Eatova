// A commit that lands while a replay pass is finishing joins that pass. The
// pass may already have read the queue for the last time, so the new op
// needs one more pass instead of waiting for the retry timer (30 s or more)
// and showing a "will sync later" hint although nothing failed.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/local_cache.dart';

import 'outbox_test_helpers.dart';

const _outboxKey = 'eatova.v1.outbox.user-outbox';

/// Holds the return of the first empty-queue commit once armed: the replay
/// pass's final queue read, after which it finds no candidate and ends.
class _HoldFinalRead implements AtomicKeyValueStore {
  _HoldFinalRead(this.inner);
  final InMemoryKeyValueStore inner;
  Completer<void>? hold;
  bool held = false;

  @override
  Future<KeyValueSnapshot> readSnapshot(Iterable<String> keys) =>
      inner.readSnapshot(keys);

  @override
  Future<KeyValueCommit> writeBatch(
    Map<String, String?> changes, {
    Map<String, int> expectedVersions = const {},
  }) async {
    final commit = await inner.writeBatch(
      changes,
      expectedVersions: expectedVersions,
    );
    final gate = hold;
    final queue = inner.snapshot[_outboxKey];
    if (gate != null &&
        changes.isEmpty &&
        queue != null &&
        ((jsonDecode(queue) as Map)['items'] as List).isEmpty) {
      hold = null;
      held = true;
      await gate.future;
    }
    return commit;
  }

  @override
  Future<String?> getString(String key) => inner.getString(key);

  @override
  Future<void> setString(String key, String value) async {
    await writeBatch({key: value});
  }

  @override
  Future<void> remove(String key) async {
    await writeBatch({key: null});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a commit during the end of a replay pass is delivered at once',
      () async {
    final store = _HoldFinalRead(InMemoryKeyValueStore());
    final s = setup(injizierterCache: LocalCache(store, 'user-outbox'));
    await bootUntilIdle(s.store);

    final gate = store.hold = Completer<void>();
    final first = s.store.addResultToDailyTotal(mealResult('Erstes'));
    await pumpUntil(() => store.held);
    expect(store.held, isTrue, reason: 'precondition: the pass ended its read');
    expect(s.server.operations('mealInsert'), hasLength(1));

    final second = s.store.addResultToDailyTotal(mealResult('Zweites'));
    await pumpUntil(() => s.store.pendingOutbox.length == 2);
    expect(s.store.pendingOutbox, hasLength(2),
        reason: 'precondition: committed while the pass still runs');
    gate.complete();
    await first;
    await second;
    await settle();

    expect(s.server.operations('mealInsert'), hasLength(2));
    expect(s.store.pendingOutbox, isEmpty);
    expect(s.snacks.messages, isEmpty, reason: 'nothing failed');
  });
}
