import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/sync_dispatcher.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import 'outbox_test_helpers.dart';

// Moving yesterday's meal ONTO today books the streak day. record_tracking_day
// needs a logged_meals row with local_day = p_day (the source proof of
// migration 20260811120000), else EX_DAY_NOT_LOGGED / P0001, so the day may
// only reach the server once the meal upsert wrote that row. The move commits
// the upsert and its ONE `trackingDay` op (with the upsert as predecessor) in
// the same local transaction, before any HTTP.
// [FakeServer.enforceTrackingDaySourceProof] mirrors the proof — without it
// the fake would define the failure away.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Pinned: these tests log onto yesterday and move onto today, which across
  /// midnight would silently become a move onto TOMORROW (K-02).
  final now = DateTime(2026, 5, 14, 12, 30);
  Future<void> onDay(Future<void> Function() body) =>
      withClock(Clock.fixed(now), body);

  /// Logged for yesterday, today still empty — the finding's starting state.
  Future<({String id, DateTime heute})> nachtragVonGestern(
    HomeStore store,
  ) async {
    final heute = DateUtils.dateOnly(clock.now());
    final id = await store.addResultToDailyTotal(
      mealResult('Nachtrag'),
      foodDate: heute.subtract(const Duration(days: 1)),
    );
    await settle();
    return (id: id, heute: heute);
  }

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

  // The only test here that fails when the day loses its predecessor link:
  // without the timeout the sequential replay alone keeps the order.
  test('ein abgelaufener Source-Write blockiert nur seinen abhaengigen Tag', () {
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

  // P1-05b: the kill between edit and RPC answer. The source upsert is
  // through, the booking is on the wire, and the app dies. Neither `then` nor
  // `catchError` runs, so only the op persisted BEFORE sending saves the day.
  test(
    'Kill zwischen Bearbeitung und RPC-Antwort: der Tag ueberlebt im '
    'eingereihten Zwilling und wird beim naechsten Start gebucht',
    () => onDay(() async {
      final kv = InMemoryKeyValueStore();
      final server = FakeServer()..enforceTrackingDaySourceProof = true;

      final a = setup(kv: kv, geteilterServer: server, disposeStore: false);
      await boot(a.store);
      final vor = await nachtragVonGestern(a.store);

      server.hangTrackingDay = true;
      await a.store.updateLoggedMealDetails(vor.id, day: clock.now());
      await settle();
      a.store.flushPendingWrites();
      await settle();

      expect(
        server.mealRows[vor.id]!['local_day'],
        localDayKey(vor.heute),
        reason: 'Vorbedingung: der Source-Upsert ist durch',
      );
      expect(
        server.trackedDay,
        isNull,
        reason: 'Vorbedingung: die Antwort der Buchung steht aus',
      );
      expect(
        (await a.cache.readOutbox())!.map((o) => o.kind),
        contains(SyncOpKind.trackingDay),
        reason:
            'nur was VOR dem Absenden persistiert wurde, kann '
            'einen Kill in diesem Fenster ueberleben',
      );

      // Restart on the same device against the same server. The request the
      // dead session already sent stays hanging; only new ones get answers.
      a.store.dispose();
      server.hangTrackingDay = false;
      final b = setup(kv: kv, geteilterServer: server);
      await boot(b.store);

      expect(
        server.trackedDay,
        localDayKey(vor.heute),
        reason:
            'sonst sieht der Server eine Luecke und die Streak '
            'reisst beim naechsten Log',
      );
      expect(
        b.store.pendingOutbox.where((o) => o.kind == SyncOpKind.trackingDay),
        isEmpty,
        reason: 'zugestellt heisst: die Op ist wieder raus',
      );
    }),
  );

  test(
    'Streak bleibt sichtbar, solange der Tag nur in der Queue liegt',
    () => onDay(() async {
      final s = setup();
      await boot(s.store);
      final vor = await nachtragVonGestern(s.store);

      s.server.offline = true;
      await s.store.updateLoggedMealDetails(vor.id, day: clock.now());
      await settle();

      expect(
        s.store.lifetimeStats.lastTrackedDate,
        vor.heute,
        reason:
            'die optimistische Buchung darf nicht verschwinden, '
            'nur weil die Zustellung wartet',
      );
    }),
  );
}
