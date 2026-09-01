import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/config/supabase_config.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

import 'fixlauf_a_helpers.dart';

// Review 2026-08-27, F1-05: no PostgREST request carried a timeout, so a
// silent socket held `_inFlightOps` for the process lifetime (follow-up
// updates queued silently) and `signOutCleanup` hung on its delivery attempt.
//
// Pinned: the client-wide request timeout, that a TimeoutException is already
// classified as a free network retry, and that the logout's delivery attempt
// is bounded.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Supabase.initialize bekommt ein PostgREST-Request-Timeout', () {
    expect(EatovaSupabaseConfig.postgrestOptions.requestTimeout,
        const Duration(seconds: 20));
  });

  test('TimeoutException ist ein Netzfehler: retryFree, Offline-Text, kein '
      'Sentry', () {
    final e = TimeoutException('request', const Duration(seconds: 20));
    expect(isNetworkSyncError(e), isTrue);
    expect(classifyOutboxFailure(e, 0), OutboxVerdict.retryFree);
    expect(queuedDelivery(e), SyncDelivery.queuedOffline);
  });

  test('signOutCleanup haengt nicht an einem stummen Server: der '
      'Zustellversuch ist zeitlich begrenzt, der Sync-Slot ueberlebt', () {
    RecipeImageStore.instance = StummerFotoStore();
    addTearDown(RecipeImageStore.resetInstance);
    fakeAsync((async) {
      final s = fixlaufSetup(disposeClient: false);
      // Cached profile opens the gate; a pending delta forces a delivery
      // attempt at logout.
      s.cache!.writeProfile(completedProfile);
      s.cache!.writePendingStatsDeltas(
          meals: 1, weightLogs: 0, requestId: 'rid-1');
      async.flushMicrotasks();
      s.server.silent = true;
      s.store.start();
      async.flushMicrotasks();
      async.elapse(Duration.zero);
      async.flushMicrotasks();
      expect(s.store.profile.onboardingCompleted, isTrue,
          reason: 'Vorbedingung: Gate ueber den Cache offen');

      var fertig = false;
      s.store.signOutCleanup().then((_) => fertig = true);
      async.flushMicrotasks();
      expect(fertig, isFalse, reason: 'der Zustellversuch laeuft');

      async.elapse(kSignOutDeliveryBudget + const Duration(seconds: 1));
      async.flushMicrotasks();

      expect(fertig, isTrue,
          reason: 'ohne Zeitgrenze bliebe der Logout am stummen Socket '
              'haengen');
      // The flight persisted its start state (0); the deadline must put the
      // bundle back WITH its id, or the next login counts nothing / twice.
      ({int meals, int weightLogs, String? requestId})? slot;
      s.cache!.readPendingStatsDeltas().then((v) => slot = v);
      async.flushMicrotasks();
      expect(slot?.meals, 1,
          reason: 'was nicht zugestellt wurde, ueberlebt den Logout (A2)');
      expect(slot?.requestId, 'rid-1',
          reason: 'dieselbe Id: ein doch gelandeter Call ist beim naechsten '
              'Login ein serverseitiger Repeat');
      expect(s.kv.snapshot.keys,
          isNot(contains('eatova.v1.profile.$kFixlaufUser')));
    });
  });

  // The test above only reaches the STATS leg: its outbox is empty, so
  // `_replayOutbox()` returns before it touches the socket and its own
  // `.timeout(kSignOutDeliveryBudget)` is never exercised. Dropping that
  // deckel went unnoticed by the whole suite — hence this case, which puts an
  // undeliverable op in front of the logout.
  test('auch der Replay-Zweig des Logouts ist gedeckelt: eine unzustellbare '
      'Op haelt den Logout nicht fest', () {
    RecipeImageStore.instance = StummerFotoStore();
    addTearDown(RecipeImageStore.resetInstance);
    fakeAsync((async) {
      final s = fixlaufSetup(disposeClient: false);
      s.server.profileRow = serverProfileRow(completedProfile);
      s.store.start();
      async.flushMicrotasks();
      async.elapse(Duration.zero);
      async.flushMicrotasks();
      expect(s.store.profile.onboardingCompleted, isTrue,
          reason: 'Vorbedingung');

      // Offline write -> the op stays queued. Only THEN does the socket go
      // silent, so the boot replay is already through and the logout's first
      // await is the one that hangs.
      s.server.offline = true;
      s.store.addResultToDailyTotal(mealResult('Unzustellbar'));
      async.flushMicrotasks();
      expect(s.store.pendingOutbox, isNotEmpty,
          reason: 'Vorbedingung: der Replay hat etwas zu tun');
      s.server.offline = false;
      s.server.silent = true;

      var fertig = false;
      s.store.signOutCleanup().then((_) => fertig = true);
      async.flushMicrotasks();
      expect(fertig, isFalse, reason: 'der Replay haengt am stummen Socket');

      // One budget for the replay leg, one for the stats leg behind it.
      async.elapse(kSignOutDeliveryBudget * 2 + const Duration(seconds: 2));
      async.flushMicrotasks();

      expect(fertig, isTrue,
          reason: 'ohne Deckel auf dem Replay-Zweig bliebe der Logout am '
              'stummen Socket haengen');
      expect(s.store.pendingOutbox, isNotEmpty,
          reason: 'was nicht zugestellt wurde, bleibt in der Queue');
    });
  });

  test('Delta waehrend des Flugs gebucht: nach der Deadline traegt der Slot '
      'BEIDE Deltas unter der Id des Flugs', () {
    RecipeImageStore.instance = StummerFotoStore();
    addTearDown(RecipeImageStore.resetInstance);
    fakeAsync((async) {
      final s = fixlaufSetup(disposeClient: false);
      s.server.profileRow = serverProfileRow(completedProfile);
      s.store.start();
      async.flushMicrotasks();
      async.elapse(Duration.zero);
      async.flushMicrotasks();
      expect(s.store.profile.onboardingCompleted, isTrue, reason: 'Vorbedingung');

      // Delivered meal -> pending delta (bundle A); the RPCs now hang.
      s.server.silentRpcs = true;
      s.store.addResultToDailyTotal(mealResult('Eins'));
      async.flushMicrotasks();

      // Logout starts the flush of bundle A itself (debounce not fired yet).
      var fertig = false;
      s.store.signOutCleanup().then((_) => fertig = true);
      async.flushMicrotasks();
      final flug = s.server
          .requestsTo('/rpc/increment_lifetime_stats', method: 'POST')
          .map((r) => (jsonDecode(r.body) as Map)['p_request_id'] as String?)
          .toList();
      expect(flug, hasLength(1), reason: 'Vorbedingung: Bundle A ist im Flug');

      // A second meal lands DURING the flight -> a new bundle opens.
      s.store.addResultToDailyTotal(mealResult('Zwei'));
      async.flushMicrotasks();

      async.elapse(kSignOutDeliveryBudget + const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(fertig, isTrue);

      ({int meals, int weightLogs, String? requestId})? slot;
      s.cache!.readPendingStatsDeltas().then((v) => slot = v);
      async.flushMicrotasks();
      expect(slot?.meals, 2, reason: 'beide Deltas bleiben erhalten');
      expect(slot?.requestId, flug.single,
          reason: 'das waehrend des Flugs geoeffnete Buendel ERBT die '
              'Flug-Id — nur die kann serverseitig schon verbucht sein; unter '
              'neuer Id wuerde ein gelandeter Call erneut addiert');
    });
  });
}
