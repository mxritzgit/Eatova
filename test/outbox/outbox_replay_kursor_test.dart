import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/services/uuid.dart' show deriveStatsRequestId;

import 'outbox_test_helpers.dart';

// B2 (perf audit 2026-09-01) — the replay pass keeps a CURSOR into the queue
// instead of restarting its candidate search at the front for every op.
//
// The old walk was O(n^2): every round re-read the queue from index 0 and
// skipped everything already marked. At the 500-op cap that is ~125k wasted set
// lookups, and worst exactly when the queue is full — offline every op STAYS,
// so the marked prefix only ever grows.
//
// The cursor is a shortcut, never an authority. These tests pin the two hazards
// a naive index cursor walks into, plus the termination case:
//  (a) an op removed from the queue DURING the pass shifts everything behind it
//      one slot left; a cursor that does not notice skips exactly the op that
//      moved up. This is finding K1 of review 2026-08-31 one level deeper: not
//      the op the pass HOLDS falls out here, but one in front of it.
//  (b) an op APPENDED during the pass — above all the statsIncrement follow-up
//      the success path creates — must still be reached in the SAME pass, even
//      with a stack of already-marked ops between cursor and queue end.
//  (c) a pass mixing all three skip reasons (live write in flight, day op ahead
//      of its own proof, blocked entity) has to end and still reach the witness
//      at the very back.

/// The day the meals and the day op of test (a) hang on.
const String _tag = '2026-05-14';

/// Fixed point in time (K-02): these tests hang on a date that would otherwise
/// wander with the calendar.
final DateTime _jetzt = DateTime(2026, 5, 14, 12, 30);

/// Ids deliberately NOT in UUID shape: `_statsFollowUpFor` derives no request id
/// from them, so no counter follow-up changes the queue mid-pass. Test (a)
/// measures positions, not counters.
LoggedMeal _mahlzeit(String id) => LoggedMeal(
      id: id,
      result: mealResult(id),
      loggedAt: DateTime(2026, 5, 14, 12),
      localDay: _tag,
    );

/// Fake PostgREST for (a): it removes an op from IN FRONT of the cursor while
/// the pass is busy with a later one.
class _EntfernServer {
  /// record_tracking_day calls. The first is the day op's own replay and FAILS,
  /// so the op stays in the queue in front of the cursor; the second comes from
  /// the mealInsert replay, succeeds, and its answer is what removes it.
  int tagesAufrufe = 0;

  /// Set by the test, read in the handler.
  HomeStore? store;

  /// Holds the second answer back until the pass has walked PAST the day op —
  /// released by the first delete.
  final Completer<void> _zweiteAntwortFrei = Completer<void>();

  /// Precondition: the day op really left the queue inside the pass. Without it
  /// the test proves nothing.
  bool tagesOpFielImDurchlaufRaus = false;

  final List<String> geschriebeneMahlzeiten = <String>[];
  final List<String> geloeschteMahlzeiten = <String>[];

  http.Client client() => MockClient(_handle);

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    http.Response ok(Object body) => http.Response(jsonEncode(body), 200,
        headers: const {'Content-Type': 'application/json'}, request: req);

    if (path.contains('/rpc/record_tracking_day')) {
      tagesAufrufe++;
      if (tagesAufrufe == 1) {
        // The day op's own replay: a 500 is retryCounted, so the op stays —
        // marked, but still occupying slot 0 in front of the cursor.
        return http.Response(jsonEncode(const {'message': 'kaputt'}), 500,
            headers: const {'Content-Type': 'application/json'}, request: req);
      }
      // The unawaited call from the mealInsert replay. Its answer triggers
      // `_clearQueuedTrackingDay`, and it may only fall once the pass is two
      // ops further on.
      await _zweiteAntwortFrei.future
          .timeout(const Duration(seconds: 5), onTimeout: () {});
      return ok(_statsZeile());
    }
    if (path.contains('/rpc/increment_lifetime_stats')) return ok(_statsZeile());
    if (path.contains('/logged_meals')) {
      if (req.method == 'POST') {
        for (final row in FakeServer.rowsOf(req.body)) {
          final id = row['id'] as String?;
          if (id != null) geschriebeneMahlzeiten.add(id);
        }
        return http.Response('', 201, request: req);
      }
      if (req.method == 'DELETE') {
        final id = _idParam(req);
        if (id != null) geloeschteMahlzeiten.add(id);
        if (id == 'm-1') {
          // The window: the pass holds the FIRST delete, so the day op sits
          // behind the cursor's back. Release the held answer and wait until it
          // has really shortened the queue.
          if (!_zweiteAntwortFrei.isCompleted) _zweiteAntwortFrei.complete();
          for (var i = 0; i < 400; i++) {
            final queue = store?.pendingOutbox ?? const <SyncOp>[];
            if (!queue.any((o) => o.kind == SyncOpKind.trackingDay)) {
              tagesOpFielImDurchlaufRaus = true;
              break;
            }
            await Future<void>.delayed(Duration.zero);
          }
        }
        return ok(const <dynamic>[]);
      }
      return ok(const <dynamic>[]);
    }
    if (req.method == 'GET') return ok(const <dynamic>[]);
    return http.Response('', 201, request: req);
  }

  Map<String, dynamic> _statsZeile() => <String, dynamic>{
        'workouts_completed': 0,
        'meals_logged': 0,
        'water_total_ml': 0,
        'steps_recorded': 0,
        'weight_logs': 0,
        'current_streak': 1,
        'longest_streak': 1,
        'last_workout_date': _tag,
        'session_start': '2026-08-01T00:00:00Z',
      };

  static String? _idParam(http.Request req) {
    final raw = req.url.queryParameters['id'];
    if (raw == null) return null;
    return raw.startsWith('eq.') ? raw.substring(3) : raw;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> anTag(Future<void> Function() koerper) =>
      withClock(Clock.fixed(_jetzt), koerper);

  test(
      'B2 (a): faellt eine Op VOR dem Kursor waehrend des Durchlaufs weg, wird '
      'die nachgerueckte Op nicht uebersprungen',
      () => anTag(() async {
            final kv = InMemoryKeyValueStore();
            // The order is the whole test:
            //   0 trackingDay — fails, so it STAYS in front of the cursor.
            //   1 mealInsert m-a — carries track_day and fires the unawaited
            //     record_tracking_day whose answer removes op 0 later.
            //   2 mealDelete m-1 — the pass holds this one when op 0 falls out;
            //     everything behind it moves one slot left.
            //   3 mealDelete m-2 — lands exactly where a stale cursor points
            //     PAST, so it is the op that used to be lost.
            await kv.setString(
              'eatova.v1.outbox.user-b2',
              jsonEncode(<String, dynamic>{
                'items': <Map<String, dynamic>>[
                  SyncOp.trackingDay(_tag).toJson(),
                  SyncOp.mealInsert(_mahlzeit('m-a'), trackDay: true).toJson(),
                  SyncOp.mealDelete('m-1').toJson(),
                  SyncOp.mealDelete('m-2').toJson(),
                ],
              }),
            );

            final server = _EntfernServer();
            final client = SupabaseClient(
              'https://example.supabase.co',
              'test-anon-key',
              httpClient: server.client(),
              authOptions: const AuthClientOptions(autoRefreshToken: false),
            );
            addTearDown(client.dispose);
            final snacks = SnackCapture();
            final store = HomeStore(
              sync: EatovaSync.forUser(client, 'user-b2'),
              health: const NoopHealthService(),
              notificationService: const NoopNotificationService(),
              initialUserName: 'Test',
              emitSnack: snacks.call,
              debugCache: LocalCache(kv, 'user-b2'),
            );
            addTearDown(store.dispose);
            server.store = store;

            store.start();
            await store.profileReady;
            await pumpUntil(() => server.geloeschteMahlzeiten.length >= 2);
            await settle();

            expect(server.tagesAufrufe, 2,
                reason: 'Vorbedingung: der Replay der Tages-Op UND der '
                    'unawaitete Aufruf aus dem mealInsert muessen beide '
                    'gelaufen sein, sonst gibt es das Fenster nicht');
            expect(server.tagesOpFielImDurchlaufRaus, isTrue,
                reason: 'Vorbedingung: die Tages-Op muss die Queue WAEHREND '
                    'des Durchlaufs verlassen haben — sonst verschiebt sich '
                    'nichts und der Test prueft nichts');
            expect(server.geschriebeneMahlzeiten, contains('m-a'),
                reason: 'Vorbedingung: der Durchlauf kam bis zur Mahlzeit');

            // The core: after the removal the queue is one shorter, so m-2 sits
            // where the cursor already stood. A cursor that does not notice
            // ends the loop right here and leaves m-2 to the 30-second timer.
            expect(server.geloeschteMahlzeiten,
                containsAll(<String>['m-1', 'm-2']),
                reason: 'die nachgerueckte Op darf nicht aus dem Durchlauf '
                    'fallen — ein Kursor ist eine Abkuerzung, keine Autoritaet');
            expect(store.pendingOutbox, isEmpty,
                reason: 'ein Durchlauf, der nichts ueberspringt, laesst nichts '
                    'liegen');
          }));

  test(
      'B2 (b): eine waehrend des Durchlaufs ANGEHAENGTE Op wird noch im selben '
      'Durchlauf erreicht — auch hinter lauter schon markierten Ops',
      () => anTag(() async {
            // A UUID: only then does `_statsFollowUpFor` derive a request id and
            // append the statsIncrement to the END of the queue.
            const uuid = '11111111-2222-4333-8444-555555555555';
            final kv = InMemoryKeyValueStore();
            // Two rejected recipe ops in front: both stay in the queue and are
            // marked, so the cursor has to walk FORWARD over them to reach the
            // appended follow-up instead of ending the pass.
            await seedRawOutbox(kv, <Map<String, dynamic>>[
              SyncOp.recipeUpsert(userRecipe('sperre-a')).toJson(),
              SyncOp.recipeUpsert(userRecipe('sperre-b')).toJson(),
              SyncOp.mealInsert(
                LoggedMeal(
                  id: uuid,
                  result: mealResult('Nachzuegler'),
                  loggedAt: DateTime(2026, 5, 14, 12),
                  localDay: _tag,
                ),
                trackDay: false,
              ).toJson(),
            ]);

            final s = setup(kv: kv);
            // Profile in the cache: otherwise the store sits in onboarding,
            // which is a second, unrelated reason for writes.
            await s.cache.writeProfile(testProfile());
            s.server.rejectRecipeWrites = true;
            await boot(s.store);
            await pumpUntil(() => s.server.mealsCounted > 0);

            expect(
                s.server.statsRequestIds, contains(deriveStatsRequestId(uuid)),
                reason: 'der Folgeeintrag entsteht erst WAEHREND des '
                    'Durchlaufs und wird hinten angehaengt — vor ihm stehen '
                    'zwei markierte Ops, ueber die der Kursor laufen muss');
            expect(s.server.mealsCounted, 1);

            final liegengeblieben = s.store.pendingOutbox;
            expect(liegengeblieben.map((o) => o.kind).toList(),
                <SyncOpKind>[SyncOpKind.recipeUpsert, SyncOpKind.recipeUpsert],
                reason: 'nur die beiden abgelehnten Rezept-Ops bleiben — weder '
                    'die Mahlzeit noch ihr Zaehler');
            expect(liegengeblieben.map((o) => o.attempts).toList(), <int>[1, 1],
                reason: 'genau EIN gezaehlter Versuch pro Durchlauf und Op');
          }));

  test(
      'B2 (c): ein Durchlauf aus im Flug / vor dem Nachweis / blockiert endet '
      'und stellt den Zeugen ganz hinten trotzdem zu',
      () => anTag(() async {
            final s = setup();
            await boot(s.store);

            // Logged for YESTERDAY, so moving it to today puts a day op behind
            // the upsert (P1-05).
            final heute = DateUtils.dateOnly(clock.now());
            final id = s.store.addResultToDailyTotal(mealResult('Nachtrag'),
                foodDate: heute.subtract(const Duration(days: 1)));
            await settle();
            // Book the live log's stats bundle right away: its 600 ms debounce
            // would otherwise be a second, purely time-based trigger for a
            // replay inside the measuring window.
            s.store.flushPendingWrites();
            await settle();

            // 1) IN FLIGHT: the PATCH hangs, so `meal:<id>` stays in
            //    `_inFlightOps` — and the day op behind it is the P1-05c skip
            //    (a day must not overtake the meal row that proves it).
            s.server.holdMealWrites();
            s.store.updateLoggedMealDetails(id, day: clock.now());
            await settle();

            // 2) BLOCKED: the recipe write is rejected with a 500, and the
            //    delete of the same entity behind it is the blocked skip.
            // 3) And a witness at the very BACK of the queue that the same pass
            //    has to reach.
            s.server.offline = true;
            await s.store.createUserRecipe(userRecipe('sperre'));
            await s.store.deleteUserRecipe('sperre');
            s.store.logWeight(81);
            await settle();
            s.server.offline = false;
            s.server.rejectRecipeWrites = true;

            expect(
                s.store.pendingOutbox.map((o) => o.kind).toList(),
                <SyncOpKind>[
                  SyncOpKind.mealUpsert,
                  SyncOpKind.trackingDay,
                  SyncOpKind.recipeUpsert,
                  SyncOpKind.recipeDelete,
                  SyncOpKind.weightInsert,
                ],
                reason: 'Vorbedingung: alle drei Ueberspring-Gruende stehen '
                    'VOR dem Zeugen');

            // A foreign live write that goes through: its `_onSyncSuccess`
            // starts the pass while the PATCH still hangs.
            s.store.toggleFavorite(mealResult('Lieblingsbowl'));
            await pumpUntil(() => s.server.weightRows.isNotEmpty);
            await settle();

            expect(s.server.weightRows, isNotEmpty,
                reason: 'der Durchlauf muss ueber alle drei Ueberspringer '
                    'hinweg bis zum Zeugen laufen und dort ENDEN');
            expect(
                s.store.pendingOutbox.map((o) => o.kind).toList(),
                <SyncOpKind>[
                  SyncOpKind.mealUpsert,
                  SyncOpKind.trackingDay,
                  SyncOpKind.recipeUpsert,
                  SyncOpKind.recipeDelete,
                ],
                reason: 'uebersprungen heisst liegengeblieben — aber weder '
                    'doppelt gespielt noch verloren');
            expect(
                s.store.pendingOutbox
                    .where((o) => o.kind != SyncOpKind.recipeUpsert)
                    .map((o) => o.attempts)
                    .toList(),
                <int>[0, 0, 0],
                reason: 'ein Versuch darf nur die Op kosten, die wirklich beim '
                    'Server war');
            expect(s.server.trackedDay, isNull,
                reason: 'die Tages-Op stand vor ihrem eigenen Quellnachweis');

            // The other direction: skipped is not left lying around.
            s.server.rejectRecipeWrites = false;
            s.server.releaseMealWrites();
            await pumpUntil(() => s.store.pendingOutbox.isEmpty);

            expect(s.store.pendingOutbox, isEmpty,
                reason: 'sonst haengt alles bis zum naechsten '
                    'Lebenszyklus-Ereignis');
            expect(s.server.trackedDay, isNotNull);
          }));
}
