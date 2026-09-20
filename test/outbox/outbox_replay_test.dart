import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import 'outbox_test_helpers.dart';

// The replay itself: coalescing, idempotent delivery, one blocked entity not
// holding up the others, and gap B — the op is on disk BEFORE the live write,
// so a kill in that window costs nothing and the replay does not double up.

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

  test('Gewicht: unklarer Timeout + Retry schreiben dieselbe Client-UUID '
      '-> Upsert, KEIN Duplikat', () async {
    final s = setup();
    await boot(s.store);

    s.server.ambiguousWrites = true;
    await s.store.logWeight(80.5);
    await settle();

    expect(s.store.weightLog.latest?.weightKg, 80.5);
    final op = s.store.pendingOutbox.singleWhere(
      (o) => o.kind == SyncOpKind.weightInsert,
    );
    expect(
      s.server.weightRows,
      hasLength(1),
      reason: 'der erste Versuch hat die Zeile bereits geschrieben',
    );

    s.server.ambiguousWrites = false;
    s.store.flushPendingWrites();
    await settle();

    expect(s.store.pendingOutbox, isEmpty);
    expect(s.server.weightRows, hasLength(1));
    expect(s.server.weightRows.keys.single, op.entityId);
    final posts = s.server.operations('weightInsert');
    expect(posts, hasLength(2));
    final payloads = posts.map((post) => jsonDecode(post.body) as Map).toList();
    expect(payloads.map((p) => p['p_operation_id']).toSet(), {op.operationId});
    for (final payload in payloads) {
      expect(payload['p_entity_id'], op.entityId);
      expect(payload['p_payload']['row']['id'], op.entityId);
    }
  });

  test('Blockierte Entitaet (Meal-Write faellt weiter aus) haelt andere '
      'Entitaeten nicht auf', () async {
    final s = setup();
    await boot(s.store);
    s.server.offline = true;

    final mealId = await s.store.addResultToDailyTotal(mealResult('Bowl'));
    await s.store.logWeight(80.5);
    await settle();
    expect(s.store.pendingOutbox.length, greaterThanOrEqualTo(2));

    s.server.offline = false;
    s.server.rejectMealWrites = true;
    s.store.flushPendingWrites();
    await settle();

    // Weight is through, the meal op stays, and nothing rolled back.
    expect(s.server.weightRows, hasLength(1));
    expect(s.store.pendingOutbox.map((o) => o.kind), [SyncOpKind.mealInsert]);
    expect(s.store.loggedMeals.map((m) => m.id), contains(mealId));

    s.server.rejectMealWrites = false;
    s.store.flushPendingWrites();
    await settle();
    expect(s.store.pendingOutbox, isEmpty);
    expect(s.server.mealRows.keys, contains(mealId));
  });

  test('Bearbeiten (Slot+Tag) offline: Aenderung landet als mealUpsert in der '
      'Outbox, der Replay schreibt logged_at/local_day/forced_slot — und '
      'zaehlt KEINE neue Mahlzeit', () async {
    final s = setup();
    await boot(s.store);

    final id = await s.store.addResultToDailyTotal(mealResult('Bowl'));
    await settle();
    expect(s.server.mealRows.keys, contains(id));

    s.server.offline = true;
    final yesterday = DateUtils.dateOnly(
      DateTime.now(),
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
  });

  test('Bearbeiten online: der PATCH traegt logged_at + local_day — die '
      'Tag-Verschiebung erreicht den Server auch ohne Outbox', () async {
    final s = setup();
    await boot(s.store);
    final id = await s.store.addResultToDailyTotal(mealResult('Bowl'));
    await settle();

    final yesterday = DateUtils.dateOnly(
      DateTime.now(),
    ).subtract(const Duration(days: 1));
    await s.store.updateLoggedMealDetails(id, day: yesterday);
    await settle();

    expect(s.store.pendingOutbox, isEmpty);
    expect(s.server.operations('mealUpsert'), hasLength(1));
    final row = s.server.mealRows[id]!;
    expect(row['local_day'], localDayKey(yesterday));
    final loggedAt = DateTime.parse(row['logged_at'] as String).toLocal();
    expect(DateUtils.isSameDay(loggedAt, yesterday), isTrue);
  });

  // --- Gap B: the outbox op exists BEFORE the network write -----------------
  //
  // `_syncOrQueue` used to enqueue only in `catchError`, so a hanging request
  // produced no op at all. Now the op is persisted before delivery.

  test(
    'Luecke B: die Op liegt schon in der PERSISTIERTEN Queue, bevor der '
    'Server geantwortet hat — und ist nach der Zustellung wieder raus',
    () async {
      final s = setup();
      await boot(s.store);

      s.server.holdRecipeWrites();
      final saving = s.store.createUserRecipe(userRecipe('user_sofort'));
      await pumpUntil(() => s.server.operations('recipeUpsert').isNotEmpty);
      // The server is held after the local transaction committed.
      expect(
        s.store.pendingOutbox.map((o) => o.entityKey),
        contains('recipe:user_sofort'),
        reason: 'zwischen Tap und Antwort existierte das Rezept nur im RAM',
      );
      expect(
        (await s.cache.readOutbox())!.map((o) => o.entityKey),
        contains('recipe:user_sofort'),
        reason: 'ein App-Kill in diesem Fenster darf das Rezept nicht kosten',
      );

      s.server.releaseRecipeWrites();
      await saving;

      expect(s.server.recipeRows.keys, contains('user_sofort'));
      expect(
        s.store.pendingOutbox,
        isEmpty,
        reason: 'zugestellt heisst: die Op ist wieder raus',
      );
      expect((await s.cache.readOutbox())!, isEmpty);
      // The success path must not produce a queue hint.
      expect(s.snacks.offlineHints, isEmpty);
      expect(
        s.snacks.messages.where((m) => m.contains('erneut versucht')),
        isEmpty,
      );
    },
  );

  test('Luecke B: ein haengender Live-Write blockiert die Outbox nicht — Ops '
      'anderer Entitaeten laufen weiter', () async {
    final s = setup();
    await boot(s.store);
    s.server.hangRecipeWrites = true;
    await s.store.createUserRecipe(userRecipe('user_haenger'));
    await settle();

    // A second change must get through despite the hanging recipe request.
    s.server.offline = true;
    final id = await s.store.addResultToDailyTotal(mealResult('Bowl'));
    await settle();
    s.server.offline = false;
    await s.store.syncPendingWrites();

    expect(
      s.server.mealRows.keys,
      contains(id),
      reason:
          'der Replay darf nicht am haengenden Rezept-Request stehen '
          'bleiben — sonst kostet EIN Request die ganze Queue',
    );
    expect(
      s.store.pendingOutbox.map((o) => o.entityKey),
      contains('recipe:user_haenger'),
      reason:
          'die haengende Op bleibt liegen und wird beim naechsten Start '
          'nachgeholt',
    );
  });

  test('P1-02: ein Pass mit UEBERSPRUNGENER Op raeumt den Wecker nicht weg — '
      'sonst liegt die Op ohne Zusteller in der Queue', () async {
    final s = setup();
    await boot(s.store);

    // Erst ein echter Fehlschlag: er armiert den Backoff-Wecker.
    s.server.offline = true;
    final id = await s.store.addResultToDailyTotal(mealResult('Wecker-Bowl'));
    await settle();
    expect(
      s.store.debugOutboxRetryTimerIsActive,
      isTrue,
      reason:
          'Vorbedingung: der fehlgeschlagene Write hat einen Wecker '
          'gestellt',
    );

    // Jetzt ein haengender Live-Write: seine Op liegt in der Queue (Luecke B)
    // und wird im Replay UEBERSPRUNGEN, ohne in `blocked` zu landen.
    s.server.offline = false;
    s.server.hangRecipeWrites = true;
    await s.store.createUserRecipe(userRecipe('user_uebersprungen'));
    await settle();

    // Der Pass stellt die Mahlzeit zu, ueberspringt das Rezept — und beendete
    // sich frueher mit blocked.isEmpty, also mit abgeraeumtem Wecker.
    s.store.flushPendingWrites();
    await settle();

    expect(
      s.server.mealRows.keys,
      contains(id),
      reason: 'Vorbedingung: der Pass ist wirklich gelaufen',
    );
    expect(
      s.store.pendingOutbox.map((o) => o.entityKey),
      contains('recipe:user_uebersprungen'),
      reason:
          'Vorbedingung: die uebersprungene Op liegt weiter unzugestellt '
          'in der Queue',
    );
    expect(
      s.store.debugOutboxRetryTimerIsActive,
      isTrue,
      reason:
          'uebersprungen ist nicht zugestellt: ohne Wecker fasst die Op '
          'bis zum naechsten Lifecycle-Ereignis niemand mehr an',
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

  test('Luecke B: die kurz eingereihte mealInsert-Op wird nicht zusaetzlich '
      'nachgespielt — ein POST, eine gezaehlte Mahlzeit', () async {
    final s = setup();
    await boot(s.store);
    await s.store.addResultToDailyTotal(mealResult('Bowl'));
    await settle();
    s.store.flushPendingWrites();
    await settle();

    expect(s.store.pendingOutbox, isEmpty);
    expect(s.server.operations('mealInsert'), hasLength(1));
    expect(
      s.server.mealsCounted,
      1,
      reason: 'sonst zaehlten Live-Write UND Replay dieselbe Mahlzeit',
    );
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
