import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// Race in the outbox replay (audit 2026-08-14, finding A).
//
// The replay loop runs over INDICES with an `await` between reading the index
// and removing the op. Two paths shorten the queue inside that window without
// telling the loop: `_clearQueuedTrackingDay` (fired unawaited by `_performOp`
// for every replayed meal) and `_dequeueDeliveredOp` of a parallel live write.
//
// `removeAt(i)` then dropped a FOREIGN op: the skipped op was gone silently
// while the delivered one stayed and counted twice on the next replay — or the
// index missed entirely and the RangeError tore down `signOutCleanup` before
// `_clearCache`.
//
// The existing outbox suite is strictly sequential and cannot produce this, so
// this test interleaves the responses deliberately: the streak RPC of one meal
// is only released while the insert of the NEXT meal is still running.

/// The day the streak op and the meals hang on; also the trackingDay op's
/// `entityId`.
const String _tag = '2026-08-14';

/// Fake PostgREST producing exactly the interleaving under test.
class _RennenServer {
  /// How often record_tracking_day was called. The FIRST call fails so the
  /// streak op stays blocked BEFORE the loop index; the second comes from the
  /// mealInsert replay and delivers the day after all.
  int trackingCalls = 0;

  /// Holds back the second record_tracking_day response until the replay has
  /// moved on to the next op.
  final Completer<void> tagAntwortFrei = Completer<void>();

  /// [beimGateWrite] runs during this meal's logged_meals write — the window
  /// in which the queue shrinks underneath the loop index.
  String? gateMealId;
  Future<void> Function()? beimGateWrite;

  final List<String> insertedMealIds = <String>[];
  final List<String> deletedMealIds = <String>[];
  int mealsCounted = 0;

  http.Client client() => MockClient(_handle);

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    http.Response ok(Object body) => http.Response(jsonEncode(body), 200,
        headers: const {'Content-Type': 'application/json'}, request: req);
    http.Response fail() => http.Response(
        jsonEncode(const {'message': 'kaputt'}), 500,
        headers: const {'Content-Type': 'application/json'}, request: req);

    if (path.contains('/rpc/record_tracking_day')) {
      trackingCalls++;
      if (trackingCalls == 1) return fail();
      // Released only once the replay is one op further. The timeout is an
      // emergency brake so the test fails on its expectations, not by hanging.
      await tagAntwortFrei.future
          .timeout(const Duration(seconds: 5), onTimeout: () {});
      return ok(_statsRow());
    }
    if (path.contains('/rpc/increment_lifetime_stats')) {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      mealsCounted += (body['p_meals'] as num?)?.toInt() ?? 0;
      return ok(_statsRow());
    }
    if (path.contains('/logged_meals')) {
      if (req.method == 'POST') {
        String? geschrieben;
        for (final row in _rowsOf(req.body)) {
          geschrieben = row['id'] as String?;
          if (geschrieben != null) insertedMealIds.add(geschrieben);
        }
        if (geschrieben != null && geschrieben == gateMealId) {
          await beimGateWrite!();
        }
        return http.Response('', 201, request: req);
      }
      if (req.method == 'DELETE') {
        final id = _eqParam(req, 'id');
        if (id != null) deletedMealIds.add(id);
        return ok(const <dynamic>[]);
      }
      return ok(const <dynamic>[]);
    }
    // Remaining reads answer empty so the boot stays green; remaining writes
    // are acknowledged.
    if (req.method == 'GET') return ok(const <dynamic>[]);
    return http.Response('', 201, request: req);
  }

  Map<String, dynamic> _statsRow() => <String, dynamic>{
        'workouts_completed': 0,
        'meals_logged': mealsCounted,
        'water_total_ml': 0,
        'steps_recorded': 0,
        'weight_logs': 0,
        'current_streak': 1,
        'longest_streak': 1,
        'last_workout_date': _tag,
        'session_start': '2026-08-01T00:00:00Z',
      };

  static List<Map<String, dynamic>> _rowsOf(String body) {
    final decoded = jsonDecode(body);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    }
    if (decoded is Map) return [decoded.cast<String, dynamic>()];
    return const [];
  }

  static String? _eqParam(http.Request req, String key) {
    final raw = req.url.queryParameters[key];
    if (raw == null) return null;
    return raw.startsWith('eq.') ? raw.substring(3) : raw;
  }
}

void _snackSenke(
  String message, {
  IconData icon = Icons.info_outline,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

MealAnalysisResult _result(String name) => MealAnalysisResult(
      mealName: name,
      caloriesKcal: 300,
      estimatedGrams: 350,
      kcalPer100G: 300 * 100 / 350,
      protein: '30 g',
      carbs: '40 g',
      fat: '10 g',
      confidence: 'Hoch',
      portionNotes: 'Test.',
      sourceLabel: 'Foto-KI',
    );

/// The ids are deliberately NOT UUIDs: this test measures the replay loop's
/// position logic, not the counters. A non-UUID id yields no stats request id
/// (`_statsFollowUpFor`), so no follow-up entry changes the queue mid-run.
/// Switching to UUIDs means updating the queue expectations too.
LoggedMeal _meal(String id) => LoggedMeal(
      id: id,
      result: _result(id),
      loggedAt: DateTime(2026, 8, 14, 12),
      localDay: _tag,
    );

Future<void> _seedRawOutbox(
  InMemoryKeyValueStore kv,
  List<Map<String, dynamic>> items,
) =>
    kv.setString('eatova.v1.outbox.user-rennen',
        jsonEncode(<String, dynamic>{'items': items}));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'Replay-Wettlauf: wird die Queue waehrend eines await gekuerzt, faellt '
      'die ZUGESTELLTE Op heraus — nicht die dahinterliegende', () async {
    final kv = InMemoryKeyValueStore();
    // The order is the whole point:
    //   0 trackingDay — fails first and stays as a blocked entity.
    //   1 mealInsert m-a — carries track_day, triggering the second
    //     record_tracking_day whose response later removes op 0.
    //   2 mealInsert m-b — op 0 disappears during ITS write.
    //   3 mealDelete m-opfer — then sits where the stale index points.
    await _seedRawOutbox(kv, <Map<String, dynamic>>[
      SyncOp.trackingDay(_tag).toJson(),
      SyncOp.mealInsert(_meal('m-a'), trackDay: true).toJson(),
      SyncOp.mealInsert(_meal('m-b'), trackDay: false).toJson(),
      SyncOp.mealDelete('m-opfer').toJson(),
    ]);

    final server = _RennenServer();
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: server.client(),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    final store = HomeStore(
      sync: EatovaSync.forUser(client, 'user-rennen'),
      health: const NoopHealthService(),
      notificationService: const NoopNotificationService(),
      initialUserName: 'Test',
      emitSnack: _snackSenke,
      debugCache: LocalCache(kv, 'user-rennen'),
    );
    addTearDown(store.dispose);

    // Proof that the interleaving really happened; without it the test could
    // go vacuously green if the store order ever shifts.
    var queueWurdeGekuerzt = false;
    server.gateMealId = 'm-b';
    server.beimGateWrite = () async {
      // The hook can run twice (without the fix the op stays and is
      // replayed), but the release happens only once.
      if (!server.tagAntwortFrei.isCompleted) server.tagAntwortFrei.complete();
      // Wait until the streak day has really left the queue: only then are
      // the positions shifted and the replay's index stale.
      for (var i = 0; i < 400; i++) {
        if (!store.pendingOutbox.any((o) => o.kind == SyncOpKind.trackingDay)) {
          queueWurdeGekuerzt = true;
          break;
        }
        await Future<void>.delayed(Duration.zero);
      }
    };

    store.start();
    await store.profileReady;
    await pumpEventQueue(times: 200);

    expect(queueWurdeGekuerzt, isTrue,
        reason: 'Vorbedingung: die Queue muss WAEHREND des Replays kuerzer '
            'geworden sein, sonst prueft der Test nichts');

    // Both meals arrived, so the replay itself ran.
    expect(server.insertedMealIds, containsAll(<String>['m-a', 'm-b']));

    // The core: the deletion sat behind the just-delivered op, and
    // `removeAt(i)` used to drop it as if delivered.
    expect(server.deletedMealIds, contains('m-opfer'),
        reason: 'die fremde Op darf nicht still als "zugestellt" aus der '
            'Queue fallen');

    // The other direction: the actually delivered op must not stay, or the
    // next replay would book +1 meal a second time.
    expect(
      store.pendingOutbox
          .where((o) => o.kind == SyncOpKind.mealInsert && o.entityId == 'm-b'),
      isEmpty,
      reason: 'entfernt werden muss die zugestellte Op, nicht die naechste',
    );
    expect(store.pendingOutbox, isEmpty);
  });
}
