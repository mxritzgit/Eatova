import 'dart:async';

import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/atomic_store_faults.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'release waits beyond the UI settle budget for an accepted write',
    () async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      final storage = AtomicStoreFaults(InMemoryKeyValueStore())
        ..beforeWrite = (_) async {
          if (!entered.isCompleted) entered.complete();
          await gate.future;
        };
      final cache = LocalCache(storage, 'release-test');
      final write = cache.writeOutbox([SyncOp.trainingPlanDelete('plan')]);
      await entered.future;
      var finished = false;
      final release = cache.releaseStorage().then((_) => finished = true);
      final repeated = cache.releaseStorage();
      try {
        await Future<void>.delayed(
          LocalCache.settleBudget + const Duration(milliseconds: 100),
        );
        expect(
          finished,
          isFalse,
          reason: 'A UI timeout cannot close a worker with accepted IO pending',
        );
      } finally {
        gate.complete();
        await write;
        await release;
        await repeated;
      }
      expect(cache.isClosed, isTrue);
    },
  );
}
