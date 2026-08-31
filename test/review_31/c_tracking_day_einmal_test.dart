import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/meals_sync.dart' show mealResultToJson;
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_outbox.dart';

import '../outbox/outbox_test_helpers.dart';

// C-01 (Review 2026-08-31) — moving a meal ONTO today booked the streak day
// TWICE.
//
// `_applyLoggedMealDetails` carried two booking paths at once: an
// `onDelivered: _recordTrackingDay` on the live PATCH, and the trackingDay op
// queued right behind the upsert. On a live move both fired — the callback in
// the PATCH's `then`, and the replay that `_onSyncSuccess` starts for the
// queued twin in the same microtask. Two concurrent `record_tracking_day`
// calls, two `lifetimeStats` adoptions.
//
// The existing P1-05 tests only pinned the ORDER (upsert before booking), and
// the order was right in BOTH bookings — which is why the double call sat
// there unnoticed. These tests COUNT instead.
//
// The second group pins what the double booking cost beyond the extra request:
// the live callback's answer filters the outbox (`_clearQueuedTrackingDay`)
// while the replay is walking it, and the op behind the day falls out of the
// pass.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Pinned clock (K-02): every test here logs onto YESTERDAY and moves onto
  /// today, which across midnight would silently become a move onto tomorrow.
  final jetzt = DateTime(2026, 5, 14, 12, 30);
  Future<void> anTag(Future<void> Function() koerper) =>
      withClock(Clock.fixed(jetzt), koerper);

  /// How many `record_tracking_day` calls reached the server since [ab].
  int buchungen(FakeServer server, [int ab = 0]) => server.requests
      .skip(ab)
      .where((r) => r.url.path.contains('/rpc/record_tracking_day'))
      .length;

  /// Logged for yesterday, today still empty — the finding's starting state.
  Future<({String id, DateTime heute})> nachtragVonGestern(
      HomeStore store) async {
    final heute = DateUtils.dateOnly(clock.now());
    final id = store.addResultToDailyTotal(mealResult('Nachtrag'),
        foodDate: heute.subtract(const Duration(days: 1)));
    await settle();
    // Book the live log's stats bundle right away: its 600 ms debounce would
    // otherwise be a second, purely time-dependent trigger for
    // `_onSyncSuccess` — and thus for a replay — inside the window under test.
    store.flushPendingWrites();
    await settle();
    return (id: id, heute: heute);
  }

  group('C-01 — Verschieben AUF heute bucht den Tag GENAU EINMAL', () {
    test(
        'live: eine einzige record_tracking_day-Anfrage, und die geht erst '
        'nach dem PATCH raus', () => anTag(() async {
          final s = setup();
          s.server.enforceTrackingDaySourceProof = true;
          await boot(s.store);
          final vor = await nachtragVonGestern(s.store);
          expect(s.server.trackedDay, isNull, reason: 'Vorbedingung: heute leer');
          final abHier = s.server.requests.length;

          s.store.updateLoggedMealDetails(vor.id, day: clock.now());
          await settle();

          expect(buchungen(s.server, abHier), 1,
              reason: 'zwei Buchungspfade nebeneinander (Live-Callback UND '
                  'eingereihter Zwilling) setzen pro Verschieben ZWEI '
                  'nebenlaeufige RPCs ab — der Server macht daraus zwar einen '
                  'No-Op, aber es sind zwei Antworten, die je eine '
                  'lifetimeStats-Zeile adoptieren, und die schnellere kuerzt '
                  'die Outbox mitten im Replay');

          // The order promise of P1-05 keeps standing: the booking needs the
          // logged_meals row of the day, or the server answers P0001.
          final danach = s.server.requests.skip(abHier).toList();
          final patch = danach.indexWhere((r) =>
              r.method == 'PATCH' && r.url.path.contains('/logged_meals'));
          final rpc = danach.indexWhere(
              (r) => r.url.path.contains('/rpc/record_tracking_day'));
          expect(patch, isNonNegative);
          expect(patch, lessThan(rpc),
              reason: 'die Buchung vor dem Upsert trifft auf eine Zeile, die '
                  'es fuer heute noch gar nicht gibt');
          expect(s.server.trackingDayRejections, isEmpty);
          expect(s.server.trackedDay, localDayKey(vor.heute));
          expect(s.store.pendingOutbox, isEmpty,
              reason: 'live zugestellt heisst: nichts bleibt liegen');
          expect(s.store.lifetimeStats.lastTrackedDate, isNotNull,
              reason: 'die Streak steht, egal welcher Pfad sie gebucht hat');
        }));

    test(
        'offline: der eingereihte Zwilling ist der Buchungspfad — synchron '
        'hinter dem Upsert, und beim Replay genau eine Anfrage',
        () => anTag(() async {
              final s = setup();
              s.server.enforceTrackingDaySourceProof = true;
              await boot(s.store);
              final vor = await nachtragVonGestern(s.store);
              expect(s.store.pendingOutbox, isEmpty, reason: 'Vorbedingung');

              s.server.offline = true;
              s.store.updateLoggedMealDetails(vor.id, day: clock.now());

              // No settle: not a single microtask has run yet. A day that only
              // comes into being through an ANSWER never exists in the hanging
              // and in the killed case.
              expect(
                  s.store.pendingOutbox.map((o) => o.kind).toList(),
                  <SyncOpKind>[SyncOpKind.mealUpsert, SyncOpKind.trackingDay],
                  reason: 'der Zwilling darf NICHT verschwinden — ohne ihn '
                      'traegt kein Pfad den Tag nach, weil SyncOp.mealUpsert '
                      'kein track_day-Flag kennt');
              await settle();
              expect((await s.cache.readOutbox())!.map((o) => o.kind),
                  contains(SyncOpKind.trackingDay),
                  reason: 'und kill-sicher, nicht nur im Speicher');

              s.server.offline = false;
              final abHier = s.server.requests.length;
              s.store.flushPendingWrites();
              await settle();

              expect(buchungen(s.server, abHier), 1);
              expect(s.server.trackingDayRejections, isEmpty);
              expect(s.server.trackedDay, localDayKey(vor.heute));
              expect(s.store.pendingOutbox, isEmpty);
            }));

    test(
        'haengender PATCH: keine Buchung auf die noch leere Zeile, der Tag '
        'liegt kill-sicher in der Queue', () => anTag(() async {
          final s = setup();
          s.server.enforceTrackingDaySourceProof = true;
          await boot(s.store);
          final vor = await nachtragVonGestern(s.store);
          final abHier = s.server.requests.length;

          s.server.holdMealWrites();
          s.store.updateLoggedMealDetails(vor.id, day: clock.now());
          await settle();

          expect(buchungen(s.server, abHier), 0,
              reason: 'PostgREST kennt keinen Timeout: solange der PATCH '
                  'haengt, steht die Zeile fuer heute noch auf gestern — jede '
                  'Buchung waere ein verbrannter Zustellversuch (P0001)');
          expect((await s.cache.readOutbox())!.map((o) => o.kind),
              contains(SyncOpKind.trackingDay));

          // Cleanup: the answer arrives after all, and then exactly once.
          s.server.releaseMealWrites();
          await settle();
          expect(buchungen(s.server, abHier), 1);
          expect(s.server.trackedDay, localDayKey(vor.heute));
        }));
  });

  group('C-01 — was die Doppelbuchung dem Replay kostete', () {
    test(
        'die Op HINTER der Tages-Op faellt nicht aus dem Durchlauf, wenn die '
        'Outbox waehrend des Replays kuerzer wird', () => anTag(() async {
          final server = _ZwillingServer();
          // Yesterday's meal comes from the SERVER load, not from a log: a
          // live insert would open a stats bundle whose 600 ms flush could
          // start a second replay and deliver the victim after all.
          final gestern = DateUtils.dateOnly(clock.now())
              .subtract(const Duration(days: 1));
          const id = 'm-verschoben';
          server.mealRows[id] = <String, dynamic>{
            'id': id,
            'logged_at':
                DateTime(gestern.year, gestern.month, gestern.day, 12, 30)
                    .toUtc()
                    .toIso8601String(),
            'forced_slot': null,
            'local_day': localDayKey(gestern),
            'payload': mealResultToJson(mealResult('Nachtrag')),
          };

          final client = SupabaseClient(
            'https://example.supabase.co',
            'test-anon-key',
            httpClient: server.client(),
            authOptions: const AuthClientOptions(autoRefreshToken: false),
          );
          addTearDown(client.dispose);
          final snacks = SnackCapture();
          final store = HomeStore(
            sync: EatovaSync.forUser(client, 'user-c01'),
            health: const NoopHealthService(),
            notificationService: const NoopNotificationService(),
            initialUserName: 'Test',
            emitSnack: snacks.call,
            debugCache: LocalCache(InMemoryKeyValueStore(), 'user-c01'),
          );
          addTearDown(store.dispose);
          server.store = store;

          store.start();
          await store.profileReady;
          await pumpEventQueue(times: 60);
          expect(store.loggedMeals.map((m) => m.id), contains(id),
              reason: 'Vorbedingung: die Zeile von gestern ist geladen');

          // The move starts the live PATCH; the delete right behind it lands
          // BEHIND the day op, because meal:$id is busy (no live write) and a
          // delete never coalesces.
          store.updateLoggedMealDetails(id, day: clock.now());
          store.removeLoggedMeal(id);
          expect(
              store.pendingOutbox.map((o) => o.kind).toList(),
              <SyncOpKind>[
                SyncOpKind.mealUpsert,
                SyncOpKind.trackingDay,
                SyncOpKind.mealDelete,
              ],
              reason: 'Vorbedingung: das Opfer steht HINTER der Tages-Op');

          await pumpEventQueue(times: 500);

          expect(server.trackingCalls, 1,
              reason: 'Vorbedingung dieses Tests ist die Buchung selbst: eine '
                  'zweite Antwort ist es, die die Outbox mitten im Replay '
                  'filtert');
          expect(server.deletedMealIds, contains(id),
              reason: 'faellt die Tages-Op waehrend ihres eigenen await aus '
                  'der Queue, findet die Schleife sie per identical nicht '
                  'mehr, zaehlt den Index trotzdem hoch — und ueberspringt '
                  'damit genau die Op, die auf ihren Platz nachgerueckt ist; '
                  'die liegt dann bis zum 30-Sekunden-Timer');
          expect(store.pendingOutbox, isEmpty,
              reason: 'ein Durchlauf, der nichts ueberspringt, laesst nichts '
                  'liegen');
        }));
  });
}

/// Fake PostgREST for the interleaving of the finding.
///
/// The point is the WINDOW: the live booking's answer may only arrive while
/// the replay is inside ITS booking, because only then does the queue shrink
/// under the running loop. Both waits are bounded — once the double booking is
/// gone there is no second call, and the test must not hang on its own
/// reproduction aid.
class _ZwillingServer {
  /// Calls to record_tracking_day. Exactly 1 is the fix's signature.
  int trackingCalls = 0;

  /// Set from the test, read inside the handler: the replay's call waits for
  /// the day to have really left the queue.
  HomeStore? store;

  final Map<String, Map<String, dynamic>> mealRows =
      <String, Map<String, dynamic>>{};
  final List<String> deletedMealIds = <String>[];

  http.Client client() => MockClient(_handle);

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    http.Response ok(Object body) => http.Response(jsonEncode(body), 200,
        headers: const {'Content-Type': 'application/json'}, request: req);

    if (path.contains('/rpc/record_tracking_day')) {
      trackingCalls++;
      if (trackingCalls == 1) {
        // Hold the first answer until a second call is on the wire.
        for (var i = 0; i < 80 && trackingCalls < 2; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        return ok(_statsZeile());
      }
      // The replay's call: stay in flight until the first answer has really
      // removed the day, or the stale cursor never happens.
      for (var i = 0; i < 400; i++) {
        final queue = store?.pendingOutbox ?? const <SyncOp>[];
        if (!queue.any((o) => o.kind == SyncOpKind.trackingDay)) break;
        await Future<void>.delayed(Duration.zero);
      }
      return ok(_statsZeile());
    }
    if (path.contains('/rpc/increment_lifetime_stats')) return ok(_statsZeile());
    if (path.contains('/logged_meals')) {
      if (req.method == 'POST') {
        for (final row in FakeServer.rowsOf(req.body)) {
          mealRows[row['id'] as String] = row;
        }
        return http.Response('', 201, request: req);
      }
      if (req.method == 'PATCH') {
        final id = _idParam(req);
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final vorhanden = mealRows[id];
        if (vorhanden != null) mealRows[id!] = {...vorhanden, ...body};
        return ok(const <dynamic>[]);
      }
      if (req.method == 'DELETE') {
        final id = _idParam(req);
        if (id != null) {
          deletedMealIds.add(id);
          mealRows.remove(id);
        }
        return ok(const <dynamic>[]);
      }
      return ok(mealRows.values
          .map((r) => <String, dynamic>{
                'id': r['id'],
                'logged_at': r['logged_at'],
                'forced_slot': r['forced_slot'],
                'local_day': r['local_day'],
                'payload': r['payload'],
              })
          .toList());
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
        'last_workout_date': '2026-05-14',
        'session_start': '2026-08-01T00:00:00Z',
      };

  static String? _idParam(http.Request req) {
    final raw = req.url.queryParameters['id'];
    if (raw == null) return null;
    return raw.startsWith('eq.') ? raw.substring(3) : raw;
  }
}
