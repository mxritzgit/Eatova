import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/app/auth_gate.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_execution_guard.dart';
import 'package:eatova/src/services/sync_outbox.dart';

class _PausedPurgeStore extends InMemoryKeyValueStore {
  final purgeStarted = Completer<void>();
  final allowPurge = Completer<void>();

  @override
  Future<KeyValueCommit> writeBatch(
    Map<String, String?> changes, {
    Map<String, int> expectedVersions = const {},
  }) async {
    if (changes.containsKey('eatova.v1.profile.A') &&
        changes['eatova.v1.profile.A'] == null) {
      purgeStarted.complete();
      await allowPurge.future;
    }
    return super.writeBatch(changes, expectedVersions: expectedVersions);
  }
}

void main() {
  test(
    'unfreiwilliges Sessionende entzieht Claim und behaelt Outbox',
    () async {
      final db = InMemoryKeyValueStore();
      final guard = SyncExecutionGuard(db);
      await guard.activate('A', 'old');
      final claim = (await guard.tryClaim('A'))!;
      final cache = LocalCache(db, 'A');
      await cache.writeProfile(const UserProfile(weightKg: 80));
      await cache.commitSyncOperations([SyncOp.mealDelete('meal')]);
      await purgePersonalCache(cache, expectedSessionId: 'old');
      expect(await claim.isCurrent(), isFalse);
      expect(await guard.tryClaim('A'), isNull);
      expect(await cache.readProfile(), isNull);
      expect(await cache.readOutbox(), hasLength(1));
    },
  );

  test('verspaeteter Purge bewahrt neues Login derselben UID', () async {
    final db = InMemoryKeyValueStore();
    final guard = SyncExecutionGuard(db);
    await guard.activate('A', 'new');
    final claim = (await guard.tryClaim('A'))!;
    final cache = LocalCache(db, 'A');
    await cache.writeProfile(const UserProfile(weightKg: 81));
    await purgePersonalCache(cache, expectedSessionId: 'old');
    expect(await claim.isCurrent(), isTrue);
    expect((await cache.readProfile())?.weightKg, 81);
    expect(cache.isClosed, isFalse);
    cache.close();
  });

  test('Login waehrend Purge-CAS bewahrt neue Daten und Generation', () async {
    final db = _PausedPurgeStore();
    final guard = SyncExecutionGuard(db);
    await guard.activate('A', 'old');
    final oldCache = LocalCache(db, 'A');
    await oldCache.writeProfile(const UserProfile(weightKg: 80));
    final purge = purgePersonalCache(oldCache, expectedSessionId: 'old');
    await db.purgeStarted.future;
    await guard.activate('A', 'new');
    final newCache = LocalCache(db, 'A');
    await newCache.writeProfile(const UserProfile(weightKg: 82));
    final claim = (await guard.tryClaim('A'))!;
    db.allowPurge.complete();
    await purge;
    expect((await newCache.readProfile())?.weightKg, 82);
    expect(await claim.isCurrent(), isTrue);
    newCache.close();
  });

  test(
    'reaktivierter User wird nicht einmal vor Cache-Open geschlossen',
    () async {
      final cache = LocalCache(InMemoryKeyValueStore(), 'A');
      await purgePersonalCacheFor(
        'A',
        expectedSessionId: 'old',
        isInactive: () => false,
      );
      expect(cache.isClosed, isFalse);
      cache.close();
    },
  );
}
