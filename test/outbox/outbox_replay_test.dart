import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import '../support/pinned_clock.dart';
import 'outbox_test_helpers.dart';

// The replay itself: per-entity order, idempotent delivery, the retry timer,
// and gap B — the op is on disk BEFORE the live write, so a kill in that window
// costs nothing and the replay does not double up. A blocked entity not holding
// up the others: outbox_replay_kursor_test.dart.

/// Noon of a fixed day: "yesterday" is computed and checked on one date.
final DateTime _mittag = DateTime(2026, 8, 12, 12);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Replay nach Reconnect: gestarteter Insert+Update bleiben immutable FIFO '
    '(neuester Payload), Stats zaehlen genau 1 Mahlzeit',
    () async {
      final s = setup();
      await boot(s.store);
      s.server.offline = true;

      final id = await s.store.addResultToDailyTotal(mealResult('Bowl'));
      await settle();
      await s.store.updateLoggedMealResult(id, mealResult('Bowl', kcal: 500));
      await settle();

      // Once delivery started its identity/payload is immutable, even offline.
      final mealOps = s.store.pendingOutbox
          .where((o) => o.entityKey == 'meal:$id')
          .toList();
      expect(mealOps.map((op) => op.kind), [
        SyncOpKind.mealInsert,
        SyncOpKind.mealUpsert,
      ]);
      expect(mealOps.first.meal!.result.caloriesKcal, 300);
      expect(mealOps.last.meal!.result.caloriesKcal, 500);
      expect(mealOps.map((op) => op.operationId).toSet(), hasLength(2));

      s.server.offline = false;
      s.store.flushPendingWrites();
      await settle();

      expect(s.store.pendingOutbox, isEmpty);
      expect(await s.cache.readOutbox(), isEmpty);
      expect(s.server.mealRows, hasLength(1));
      final row = s.server.mealRows[id]!;
      expect(row['calories_kcal'], 500);
      expect((row['payload'] as Map)['caloriesKcal'], 500);

      final insert = s.server.operations('mealInsert').single;
      final update = s.server.operations('mealUpsert').single;
      expect(
        s.server.requests.indexOf(insert),
        lessThan(s.server.requests.indexOf(update)),
      );
      expect((jsonDecode(insert.body) as Map)['p_entity_id'], id);
      expect((jsonDecode(update.body) as Map)['p_entity_id'], id);

      s.store.flushPendingWrites(); // short-circuit the delta-queue debounce
      await settle();
      expect(s.server.mealsCounted, 1);
    },
  );

  test('Bearbeiten (Slot+Tag) offline: Aenderung landet als mealUpsert in der '
      'Outbox, der Replay schreibt logged_at/local_day/forced_slot — und '
      'zaehlt KEINE neue Mahlzeit', () => withClockAt(_mittag, () async {
    final s = setup();
    await boot(s.store);

    final id = await s.store.addResultToDailyTotal(mealResult('Bowl'));
    await settle();
    expect(s.server.mealRows.keys, contains(id));

    s.server.offline = true;
    final yesterday = DateUtils.dateOnly(
      clock.now(),
    ).subtract(const Duration(days: 1));
    await s.store.updateLoggedMealDetails(
      id,
      slot: MealSlot.snack,
      day: yesterday,
    );
    await settle();

    final local = s.store.loggedMeals.singleWhere((m) => m.id == id);
    expect(local.forcedSlot, MealSlot.snack);
    expect(local.localDay, localDayKey(yesterday));

    // ONE mealUpsert op with the full new state.
    final ops = s.store.pendingOutbox
        .where((o) => o.entityKey == 'meal:$id')
        .toList();
    expect(ops, hasLength(1));
    expect(ops.single.kind, SyncOpKind.mealUpsert);
    final queued = ops.single.meal!;
    expect(queued.forcedSlot, MealSlot.snack);
    expect(queued.localDay, localDayKey(yesterday));

    s.server.offline = false;
    s.store.flushPendingWrites();
    await settle();

    expect(s.store.pendingOutbox, isEmpty);
    final row = s.server.mealRows[id]!;
    expect(row['forced_slot'], 'snack');
    expect(row['local_day'], localDayKey(yesterday));
    final loggedAt = DateTime.parse(row['logged_at'] as String).toLocal();
    expect(DateUtils.isSameDay(loggedAt, yesterday), isTrue);

    // An edit is NOT a new log: the lifetime stats still count 1.
    s.store.flushPendingWrites();
    await settle();
    expect(s.server.mealsCounted, 1);
  }));

  // --- Gap B: the outbox op exists BEFORE the network write -----------------
  //
  // `_syncOrQueue` used to enqueue only in `catchError`, so a hanging request
  // produced no op at all. Now the op is persisted before delivery.

  // P1-02: a pass that delivered something used to end with the retry timer
  // cleared, although another op was still undelivered. The old version of
  // this test held that op in a hanging request, so the pass never ended
  // before the assertion and the test could not fail.
  test('P1-02: ein Pass mit Erfolg UND liegengebliebener Op laesst den Wecker '
      'gestellt — sonst liegt die Op ohne Zusteller in der Queue', () async {
    final s = setup();
    await boot(s.store);

    s.server.offline = true;
    final id = await s.store.addResultToDailyTotal(mealResult('Wecker-Bowl'));
    await s.store.createUserRecipe(userRecipe('user_abgelehnt'));
    await settle();

    // Back online, but recipe writes are rejected (500, retryable): the pass
    // delivers the meal and leaves the recipe behind.
    s.server.offline = false;
    s.server.rejectRecipeWrites = true;
    await s.store.syncPendingWrites();

    expect(
      s.server.mealRows.keys,
      contains(id),
      reason: 'Vorbedingung: der Pass hat etwas zugestellt',
    );
    expect(
      s.store.pendingOutbox.map((o) => o.entityKey),
      contains('recipe:user_abgelehnt'),
      reason: 'Vorbedingung: die abgelehnte Op liegt weiter in der Queue',
    );
    expect(
      s.store.debugOutboxRetryTimerIsActive,
      isTrue,
      reason:
          'ohne Wecker fasst die Op bis zum naechsten Lifecycle-Ereignis '
          'niemand mehr an',
    );
  });

  test('Luecke B: auch der Mahlzeiten-Insert reiht ZUERST ein — die Op liegt '
      'auf der Platte, bevor der Server geantwortet hat', () async {
    final kv = InMemoryKeyValueStore();
    final s = setup(kv: kv);
    await boot(s.store);

    s.server.holdMealWrites();
    final saving = s.store.addResultToDailyTotal(mealResult('Bowl'));
    await pumpUntil(() => s.server.operations('mealInsert').isNotEmpty);
    final id = s.store.loggedMeals.single.id;
    // The server cannot acknowledge before the persisted queue is inspected.
    expect(s.store.pendingOutbox.map((o) => o.entityKey), contains('meal:$id'));
    expect(
      kv.snapshot['eatova.v1.outbox.user-outbox'],
      contains('"entity_id":"$id"'),
    );

    s.server.releaseMealWrites();
    expect(await saving, id);
    expect(s.server.mealRows.keys, contains(id));
    expect(s.store.pendingOutbox, isEmpty);
  });

  test('Luecke B: eine zweite Aenderung waehrend des laufenden Live-Writes '
      'erzeugt keinen falschen Warteschlangen-Hinweis', () async {
    final s = setup();
    await boot(s.store);

    s.server.holdRecipeWrites();
    final first = s.store.createUserRecipe(
      userRecipe('user_doppelt', title: 'Erste Fassung'),
    );
    await pumpUntil(() => s.server.operations('recipeUpsert').isNotEmpty);
    final second = s.store.createUserRecipe(
      userRecipe('user_doppelt', title: 'Zweite Fassung'),
    );
    await pumpUntil(
      () =>
          s.store.pendingOutbox
              .where((op) => op.kind == SyncOpKind.recipeUpsert)
              .length ==
          2,
    );
    s.server.releaseRecipeWrites();
    await Future.wait([first, second]);

    expect(
      s.snacks.messages.where((m) => m.contains('erneut versucht')),
      isEmpty,
      reason: 'nichts ist fehlgeschlagen — der Hinweis waere gelogen',
    );
    expect(s.store.pendingOutbox, isEmpty);
    expect(
      s.server.recipeRows['user_doppelt']!['title'],
      'Zweite Fassung',
      reason: 'der juengere Stand gewinnt, die Reihenfolge bleibt',
    );
  });
}
