import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import 'outbox_test_helpers.dart';

// Review 2026-08-29, Nachzuegler der Welle 1.
//
// P1-01b — the live success path used to clear the orphan mark
// (`_orphanedEntities.remove`). The mark is what routes the next write to an
// entity through the outbox (full upsert) instead of a live PATCH, because a
// PATCH hitting 0 rows answers 204: "success", and repairs nothing.
//
// The order that breaks it: `_enqueueOp` -> `_persistOutbox` ->
// `_repairOutboxHydration` starts SYNCHRONOUSLY (before `action()`), reads the
// blob back, merges, caps — and marks exactly the entity whose live PATCH is
// still in flight. That PATCH then reports success and deletes the fresh mark.
//
// P1-02b — the retry ladder was reset on every pass whose only reason for
// doing nothing was `_inFlightOps`. PostgREST carries no timeout, so a hanging
// request keeps its entity there forever: the alarm re-armed at 30 s, over and
// over, instead of climbing to the 4 min cap.

const String _uid = 'user-outbox';

/// Cache whose OUTBOX slot throws on the FIRST read: the cold start does not
/// see the blob, so `_outboxHydrationFailed` is set and the next
/// `_persistOutbox` starts the repair.
class _ErsterLesefehlerCache extends LocalCache {
  _ErsterLesefehlerCache(super.store, super.userId);

  int leseversuche = 0;

  @override
  Future<List<SyncOp>?> readOutbox() {
    leseversuche++;
    if (leseversuche == 1) {
      return Future<List<SyncOp>?>.error(StateError('Outbox-Slot unlesbar'));
    }
    return super.readOutbox();
  }
}

/// The meal the user is about to correct: visible locally (diary cache), never
/// delivered to the server.
LoggedMeal _waise() => LoggedMeal(
      id: 'm-waise',
      result: mealResult('Waisen-Bowl', kcal: 300),
      loggedAt: DateTime.now(),
      forcedSlot: MealSlot.lunch,
    );

/// A full queue of deletes. The cap sheds WRITE ops first, so with these 500 in
/// place the next write op is exactly what falls out — the constellation that
/// marks its entity as orphaned.
List<SyncOp> _vollerDeleteStapel() =>
    List<SyncOp>.generate(500, (i) => SyncOp.mealDelete('alt-$i'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P1-01b: die Waisen-Marke ueberlebt den Live-Erfolg', () {
    test(
        'der Repair markiert die Entitaet waehrend ihr Live-PATCH fliegt — '
        'die naechste Korrektur landet trotzdem auf dem Server', () async {
      final kv = InMemoryKeyValueStore();
      final seed = LocalCache(kv, _uid);
      await seed.writeOutbox(_vollerDeleteStapel());
      await seed.writeLoggedMeals(<LoggedMeal>[_waise()]);

      final cache = _ErsterLesefehlerCache(kv, _uid);
      final a = setup(injizierterCache: cache);
      // Offline cold start: the diary comes from the cache, the outbox slot is
      // unreadable, and the server load does not replace the meal list.
      a.server.offline = true;
      await boot(a.store);
      a.server.offline = false;

      expect(a.store.loggedMeals.map((m) => m.id), contains('m-waise'),
          reason: 'Vorbedingung: die Mahlzeit ist lokal sichtbar');
      expect(a.store.pendingOutbox, isEmpty,
          reason: 'Vorbedingung: die Hydration hat den Blob nicht gesehen');
      expect(cache.leseversuche, 1,
          reason: 'Vorbedingung: der Repair lief noch nicht');
      expect(a.server.mealRows, isEmpty,
          reason: 'Vorbedingung: die Zeile existiert serverseitig nicht');

      // The window: the live PATCH waits, the repair (started synchronously in
      // _enqueueOp -> _persistOutbox) runs to the end.
      a.server.holdMealWrites();
      a.store.updateLoggedMealResult('m-waise', mealResult('Korrektur 1'));
      await settle();

      expect(a.store.debugOrphanedEntities, contains('meal:m-waise'),
          reason: 'Vorbedingung: der Repair hat die Op der fliegenden Entitaet '
              'gekappt und sie damit als verwaist markiert');

      // The PATCH answers — on ZERO rows, which PostgREST reports as success.
      a.server.releaseMealWrites();
      await settle();
      await settle();

      expect(a.store.debugOrphanedEntities, contains('meal:m-waise'),
          reason: 'ein PATCH auf 0 Zeilen ist ein 204: dieser Erfolgspfad kann '
              '„Zeile geschrieben" nicht von „Zeile fehlt" unterscheiden und '
              'darf die eben gesetzte, noch gebrauchte Marke nicht loeschen');

      // The user corrects a second time. With the mark this goes through the
      // outbox, where the op is a full upsert on the client UUID.
      a.store.updateLoggedMealResult('m-waise', mealResult('Korrektur 2'));
      await settle();
      a.store.flushPendingWrites();
      await settle();
      await settle();

      expect(a.server.mealRows['m-waise'], isNotNull,
          reason: 'ohne die Marke ging auch die zweite Korrektur als PATCH '
              'raus, meldete 204 und die Mahlzeit war serverseitig endgueltig '
              'weg');
      expect(a.store.debugOrphanedEntities, isNot(contains('meal:m-waise')),
          reason: 'erst der Replay-Erfolg raeumt die Marke ab — dort ist der '
              'Erfolg echt');
    });

    test(
        'Gegenprobe: ohne Repair-Kappung bleibt der Live-Pfad offen — die '
        'Korrektur geht als PATCH raus und wird nicht eingereiht', () async {
      final a = setup();
      await boot(a.store);
      final id = a.store.addResultToDailyTotal(mealResult('Normal'));
      await settle();
      expect(a.server.mealRows[id], isNotNull, reason: 'Vorbedingung');

      a.store.updateLoggedMealResult(id, mealResult('Korrigiert', kcal: 400));
      await settle();

      expect(a.store.debugOrphanedEntities, isEmpty);
      expect(a.store.pendingOutbox, isEmpty,
          reason: 'eine gesunde Entitaet darf nicht in die Queue umgeleitet '
              'werden');
      expect(
          a.server.requests
              .where((r) =>
                  r.url.path.contains('/logged_meals') && r.method == 'PATCH')
              .length,
          1);
    });
  });

  group('P1-02b: die Retry-Leiter bei haengendem Request', () {
    test(
        'ein Pass, der nur wegen _inFlightOps nichts erledigt hat, setzt die '
        'Leiter nicht zurueck', () {
      fakeAsync((async) {
        // No client dispose: the teardown runs outside the fake zone and the
        // hanging request would never answer it.
        final a = setup(disposeClient: false);
        a.store.start();
        async.flushMicrotasks();
        async.elapse(Duration.zero);
        async.flushMicrotasks();

        // A request that NEVER answers: neither `then` nor `catchError` fires,
        // so the entity stays in _inFlightOps for good.
        a.server.hangRecipeWrites = true;
        a.store.createUserRecipe(userRecipe('user_haenger'));
        async.flushMicrotasks();
        expect(a.store.pendingOutbox.map((o) => o.entityKey),
            contains('recipe:user_haenger'),
            reason: 'Vorbedingung: die Op liegt vor dem Write in der Queue');

        // A lifecycle flush arms the alarm for the non-empty queue (P1-02).
        a.store.flushPendingWrites();
        async.flushMicrotasks();
        expect(a.store.debugOutboxRetryTimerIsActive, isTrue,
            reason: 'Vorbedingung: der Wecker steht');
        expect(a.store.debugOutboxRetryStage, 0, reason: 'Vorbedingung');

        // t = 30 s: the timer pass skips the in-flight op and does nothing.
        async.elapse(const Duration(seconds: 31));
        async.flushMicrotasks();
        expect(a.store.debugOutboxRetryStage, 1,
            reason: 'der Pass hat nichts zugestellt — er darf die Leiter nicht '
                'auf 0 setzen, sonst tickt der Wecker bei einem haengenden '
                'Request endlos alle 30 s');

        // t = 91 s: second stage (60 s).
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        expect(a.store.debugOutboxRetryStage, 2);

        // t = 211 s: third stage (120 s), then the 4 min cap.
        async.elapse(const Duration(seconds: 120));
        async.flushMicrotasks();
        expect(a.store.debugOutboxRetryStage, 3);
        async.elapse(const Duration(seconds: 241));
        async.flushMicrotasks();
        expect(a.store.debugOutboxRetryStage, 3,
            reason: 'die Leiter ist bei 4 min gedeckelt');
      });
    });

    test(
        'der gesunde Fall bleibt: hat der Pass ETWAS zugestellt, faengt die '
        'Leiter wieder bei 30 s an', () {
      fakeAsync((async) {
        final a = setup(disposeClient: false);
        a.store.start();
        async.flushMicrotasks();
        async.elapse(Duration.zero);
        async.flushMicrotasks();

        a.server.hangRecipeWrites = true;
        a.store.createUserRecipe(userRecipe('user_haenger'));
        async.flushMicrotasks();

        // Climb two stages on the hanging op alone.
        a.store.flushPendingWrites();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 31));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        expect(a.store.debugOutboxRetryStage, 2, reason: 'Vorbedingung');

        // A second, deliverable op: it fails while offline and goes through on
        // the next pass — that pass DID something.
        a.server.offline = true;
        a.store.addResultToDailyTotal(mealResult('Zweite'));
        async.flushMicrotasks();
        a.server.offline = false;
        async.elapse(const Duration(seconds: 121));
        async.flushMicrotasks();

        expect(a.store.debugOutboxRetryStage, 0,
            reason: 'ein Pass mit echter Zustellung ist Fortschritt — die '
                'Bestrafung des Leerlaufs darf ihn nicht mittreffen');
      });
    });
  });
}
