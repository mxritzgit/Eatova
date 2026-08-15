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

// Wettlauf im Outbox-Replay (Audit 2026-08-14, Befund A).
//
// Der Replay-Loop laeuft ueber INDIZES, und zwischen dem Lesen des Index und
// dem Entfernen der Op liegt ein `await`. Genau in diesem Fenster kuerzen zwei
// Pfade die Queue, ohne den Loop zu fragen:
//   * `_clearQueuedTrackingDay` — `_performOp` feuert fuer jede nachgeholte
//     Mahlzeit selbst und UNGEAWAITET einen record_tracking_day; kommt der
//     durch, faellt die gleichnamige Streak-Op aus der Queue. Die kann weiter
//     VORNE liegen als der Laufindex (der Replay hat sie in diesem Lauf schon
//     als „blockiert" uebersprungen), also verschieben sich alle Positionen
//     dahinter.
//   * `_dequeueDeliveredOp` eines parallel zugestellten Live-Writes.
//
// Der Erfolgszweig entfernte danach `removeAt(i)` — also eine FREMDE Op. Der
// Preis war doppelt: die uebersprungene Op ist endgueltig weg (kein Snack, kein
// Crash-Report, sie galt ja als zugestellt), und die tatsaechlich zugestellte
// bleibt liegen und zaehlt beim naechsten Replay ein zweites Mal. Trifft der
// Index daneben statt ins Leere, ist es ein RangeError — und der liegt
// ausserhalb des inneren try, reisst also `signOutCleanup` VOR `_clearCache`
// ab.
//
// Die bestehende Outbox-Suite ist streng sequenziell und kann den Fall nicht
// erzeugen: dort antwortet der Fake-Server sofort, und waehrend eines `await`
// passiert nie etwas anderes. Dieser Test verschraenkt die Antworten deshalb
// bewusst — die Antwort auf den Streak-RPC der einen Mahlzeit wird erst
// freigegeben, waehrend der Insert der NAECHSTEN Mahlzeit noch laeuft.

/// Der Tag, an dem Streak-Op und Mahlzeiten haengen — er ist zugleich die
/// `entityId` der trackingDay-Op.
const String _tag = '2026-08-14';

/// Fake-PostgREST, der genau die Verschraenkung herstellt, um die es geht.
class _RennenServer {
  /// Wie oft record_tracking_day gerufen wurde. Der ERSTE Aufruf (der Replay
  /// der liegengebliebenen Streak-Op) scheitert — nur dann bleibt sie als
  /// blockierte Op VOR dem Laufindex liegen. Der zweite kommt aus dem
  /// mealInsert-Replay und stellt den Tag doch noch zu.
  int trackingCalls = 0;

  /// Haelt die Antwort auf den zweiten record_tracking_day zurueck, bis der
  /// Replay bei der naechsten Op steht.
  final Completer<void> tagAntwortFrei = Completer<void>();

  /// Waehrend des logged_meals-Writes dieser Mahlzeit laeuft [beimGateWrite] —
  /// das ist das Fenster, in dem die Queue unter dem Laufindex kuerzer wird.
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
      // Die Zusage kommt erst, wenn der Replay eine Op weiter ist. Der Timeout
      // ist reine Notbremse: bleibt die Freigabe aus, soll der Test an seinen
      // Erwartungen scheitern statt zu haengen.
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
    // Uebrige Reads (profiles, lifetime_stats, favorite_meals, weight_log,
    // user_recipes) leer — der Boot bleibt gruen; uebrige Writes quittiert.
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

/// Die Ids sind bewusst KEINE UUIDs: dieser Test misst die Positionslogik des
/// Replay-Loops, nicht die Zaehler. Aus einer nicht-UUID-Id laesst sich keine
/// Stats-Request-Id ableiten (Fix 3, `_statsFollowUpFor`), es entsteht also
/// kein Folgeeintrag, der die Queue waehrend des Laufs zusaetzlich veraendern
/// wuerde. Wer sie auf UUID-Form hebt, prueft hier zusaetzlich die
/// Eintrags-Erzeugung — dann aber auch die Queue-Erwartungen mitziehen.
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
    // Reihenfolge ist der ganze Punkt:
    //   0 trackingDay — scheitert im ersten Anlauf und bleibt liegen, wird also
    //     im selben Lauf nicht mehr angefasst (blockierte Entitaet).
    //   1 mealInsert m-a — traegt track_day, stoesst also den zweiten
    //     record_tracking_day an, dessen Antwort spaeter genau diese Op 0
    //     entfernt.
    //   2 mealInsert m-b — waehrend SEINES Writes faellt Op 0 weg.
    //   3 mealDelete m-opfer — steht danach an der Stelle, auf die der
    //     veraltete Laufindex zeigt. Sie ist das Opfer.
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

    // Beleg, dass die Verschraenkung wirklich stattgefunden hat — ohne ihn
    // koennte der Test vakuum-gruen werden, sobald sich die Reihenfolge im
    // Store einmal verschiebt.
    var queueWurdeGekuerzt = false;
    server.gateMealId = 'm-b';
    server.beimGateWrite = () async {
      // Der Hook kann ein zweites Mal laufen (ohne den Fix bleibt die Op
      // liegen und wird nachgespielt) — die Freigabe gibt es aber nur einmal.
      if (!server.tagAntwortFrei.isCompleted) server.tagAntwortFrei.complete();
      // Warten, bis der Streak-Tag WIRKLICH aus der Queue gefallen ist: erst
      // dann sind die Positionen verschoben, und erst dann ist der Laufindex
      // des Replays veraltet.
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

    // Beide Mahlzeiten sind angekommen — der Replay als solcher lief.
    expect(server.insertedMealIds, containsAll(<String>['m-a', 'm-b']));

    // Der Kern: die Loeschung stand hinter der gerade zugestellten Op. Frueher
    // entfernte `removeAt(i)` genau sie — sie galt damit als zugestellt, ohne
    // je gesendet worden zu sein, und die Mahlzeit kam beim naechsten Kaltstart
    // vom Server zurueck.
    expect(server.deletedMealIds, contains('m-opfer'),
        reason: 'die fremde Op darf nicht still als "zugestellt" aus der '
            'Queue fallen');

    // Und die Gegenrichtung: die tatsaechlich zugestellte Op bleibt nicht
    // liegen (sie wuerde beim naechsten Replay ein zweites Mal +1 Mahlzeit
    // buchen).
    expect(
      store.pendingOutbox
          .where((o) => o.kind == SyncOpKind.mealInsert && o.entityId == 'm-b'),
      isEmpty,
      reason: 'entfernt werden muss die zugestellte Op, nicht die naechste',
    );
    expect(store.pendingOutbox, isEmpty);
  });
}
