import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/config/supabase_config.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/services/sync_dispatcher.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import 'fixlauf_a_helpers.dart';

// A silent socket must neither consume the retry budget nor block account
// cleanup. Confirmed writes survive with their immutable operation identity.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => RecipeImageStore.instance = StummerFotoStore());
  tearDown(RecipeImageStore.resetInstance);

  group('Zustellfenster', _slowWriteTests);

  test('Supabase.initialize bekommt ein PostgREST-Request-Timeout', () {
    expect(
      EatovaSupabaseConfig.postgrestOptions.requestTimeout,
      const Duration(seconds: 20),
    );
  });

  test('TimeoutException ist ein Netzfehler: retryFree, Offline-Text, kein '
      'Sentry', () {
    final e = TimeoutException('request', const Duration(seconds: 20));
    expect(isNetworkSyncError(e), isTrue);
    expect(classifyOutboxFailure(e, 0), OutboxVerdict.retryFree);
    expect(queuedDelivery(e), SyncDelivery.queuedOffline);
  });

  test('Logout am stummen Server bewahrt migrierte Stats samt Request-ID', () {
    fakeAsync((async) {
      final s = fixlaufSetup(disposeClient: false);
      const requestId = '11111111-2222-4333-8444-555555555555';
      s.cache!.writeProfile(completedProfile);
      s.cache!.writePendingStatsDeltas(
        meals: 1,
        weightLogs: 0,
        requestId: requestId,
      );
      async.flushMicrotasks();
      s.server.silent = true;
      s.store.start();
      async.flushMicrotasks();
      async.elapse(Duration.zero);
      async.flushMicrotasks();
      expect(s.store.profile.onboardingCompleted, isTrue);
      final pending = s.store.pendingOutbox.single;
      expect(pending.kind, SyncOpKind.statsIncrement);
      expect(pending.entityId, requestId);

      var completed = false;
      s.store.signOutCleanup().then((_) => completed = true);
      async.flushMicrotasks();
      async.elapse(kCacheSnapshotWaitBudget + const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(
        completed,
        isTrue,
        reason: 'Logout wartet auf lokale Commits, nicht auf das Netzwerk',
      );

      List<SyncOp>? persisted;
      s.cache!.readOutbox().then((value) => persisted = value);
      async.flushMicrotasks();
      expect(persisted!.single.operationId, pending.operationId);
      expect(persisted!.single.entityId, requestId);
      expect(persisted!.single.statsMeals, 1);
      expect(
        s.kv.snapshot.keys,
        isNot(contains('eatova.v1.profile.$kFixlaufUser')),
      );
    }, initialTime: DateTime(2026, 9, 20, 12));
  });

  test(
    'Logout wartet nicht auf einen haengenden Replay; seine Ops bleiben',
    () {
      fakeAsync((async) {
        final s = _bootOnline(async);
        s.server.offline = true;
        s.store.addResultToDailyTotal(mealResult('Unzustellbar'));
        async.flushMicrotasks();
        final ids = s.store.pendingOutbox.map((op) => op.operationId).toList();
        expect(ids, hasLength(2));
        s.server.offline = false;
        s.server.silentRpcs = true;
        var replayCompleted = false;
        s.store.syncPendingWrites().then((_) => replayCompleted = true);
        async.flushMicrotasks();
        expect(
          replayCompleted,
          isFalse,
          reason: 'Vorbedingung: der reale Dispatcher wartet auf einen RPC',
        );

        var logoutCompleted = false;
        s.store.signOutCleanup().then((_) => logoutCompleted = true);
        async.flushMicrotasks();
        async.elapse(kCacheSnapshotWaitBudget + const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(logoutCompleted, isTrue);
        expect(replayCompleted, isFalse);
        async.elapse(kSyncOperationTimeout);
        async.flushMicrotasks();
        expect(replayCompleted, isTrue);
        List<SyncOp>? persisted;
        s.cache!.readOutbox().then((value) => persisted = value);
        async.flushMicrotasks();
        expect(persisted!.map((op) => op.operationId), ids);
        expect(
          persisted!.every((op) => op.attempts == 0),
          isTrue,
          reason: 'ein Timeout verbraucht kein Retry-Budget',
        );
      }, initialTime: DateTime(2026, 9, 20, 12));
    },
  );

  test(
    'zwei bestaetigte Meals vor Logout behalten im Flug getrennte UUIDs',
    () {
      fakeAsync((async) {
        final s = _bootOnline(async);
        s.server.silentRpcs = true;
        var firstSaved = false;
        s.store
            .addResultToDailyTotal(mealResult('Eins'))
            .then((_) => firstSaved = true);
        async.flushMicrotasks();
        async.elapse(kSyncDeliveryWindow);
        async.flushMicrotasks();
        expect(firstSaved, isTrue);
        var secondSaved = false;
        s.store
            .addResultToDailyTotal(mealResult('Zwei'))
            .then((_) => secondSaved = true);
        async.flushMicrotasks();
        async.elapse(kSyncDeliveryWindow);
        async.flushMicrotasks();
        expect(secondSaved, isTrue);
        final meals = s.store.pendingOutbox
            .where((op) => op.kind == SyncOpKind.mealInsert)
            .toList();
        expect(meals, hasLength(2));
        expect(meals.map((op) => op.operationId).toSet(), hasLength(2));
        final flights = s.server
            .requestsTo('/rpc/apply_sync_operation')
            .map((request) => jsonDecode(request.body) as Map)
            .where((body) => body['p_kind'] == 'mealInsert')
            .toList();
        expect(flights, hasLength(1));
        expect(flights.single['p_operation_id'], meals.first.operationId);
        final ids = s.store.pendingOutbox.map((op) => op.operationId).toList();

        var completed = false;
        s.store.signOutCleanup().then((_) => completed = true);
        async.flushMicrotasks();
        async.elapse(kSyncOperationTimeout + const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(completed, isTrue);
        List<SyncOp>? persisted;
        s.cache!.readOutbox().then((value) => persisted = value);
        async.flushMicrotasks();
        expect(
          persisted!.map((op) => op.operationId),
          ids,
          reason: 'bestaetigte Deltas duerfen weder verschmelzen noch fehlen',
        );
        expect(
          persisted!.where((op) => op.kind == SyncOpKind.mealInsert),
          hasLength(2),
        );
        expect(s.server.mealsCounted, 0);
      }, initialTime: DateTime(2026, 9, 20, 12));
    },
  );
}

/// The queue hints of `_commitSyncIntents` among the captured snacks.
List<String> _queueHints(FixlaufSetup s) => s.snacks.messages
    .where(
      (m) =>
          m == deL10n.commonQueuedRetryGenericHint ||
          m == deL10n.commonQueuedOfflineHint,
    )
    .toList();

void _slowWriteTests() {
  test('ein langsamer, aber erfolgreicher Write meldet keinen Fehlschlag', () {
    fakeAsync((async) {
      final s = _bootOnline(async);
      s.server.holdWrites = true;
      var saved = false;
      s.store
          .toggleFavorite(mealResult('Langsam'))
          .then((_) => saved = true);
      async.flushMicrotasks();
      async.elapse(kSyncDeliveryWindow);
      async.flushMicrotasks();
      expect(saved, isTrue, reason: 'das Fenster beendet nur das Warten');
      expect(
        s.server.heldWrites,
        1,
        reason: 'Vorbedingung: der Write ist noch unterwegs',
      );
      // Before, the window's end read as a failure: "Änderung konnte nicht
      // gespeichert werden" for a write that had not failed.
      expect(_queueHints(s), isEmpty);

      s.server.holdWrites = false;
      s.server.releaseWrites();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(s.store.pendingOutbox, isEmpty);
      expect(_queueHints(s), isEmpty);
    }, initialTime: DateTime(2026, 9, 20, 12));
  });

  test('scheitert der Write erst nach dem Fenster, kommt der Hinweis dann', () {
    fakeAsync((async) {
      final s = _bootOnline(async);
      s.server.silentRpcs = true;
      s.store.toggleFavorite(mealResult('Stumm'));
      async.flushMicrotasks();
      async.elapse(kSyncDeliveryWindow);
      async.flushMicrotasks();
      expect(_queueHints(s), isEmpty);

      async.elapse(kSyncOperationTimeout);
      async.flushMicrotasks();
      expect(s.store.pendingOutbox, isNotEmpty);
      expect(_queueHints(s), [deL10n.commonQueuedOfflineHint]);
    }, initialTime: DateTime(2026, 9, 20, 12));
  });
}

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
