import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
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
import 'package:eatova/src/services/uuid.dart';

import '../outbox/outbox_test_helpers.dart';

// K1 (Review 2026-08-31) — der Replay-Durchlauf uebersprang eine Operation,
// wenn die Queue waehrend eines `await` kuerzer wurde.
//
// Die Schleife lief ueber Indizes. Fiel die GERADE bearbeitete Op waehrend
// ihres eigenen `await` aus der Liste (`indexWhere(identical) == -1`), zaehlte
// der Zweig trotzdem `i++` — und uebersprang damit genau die Op, die auf Platz
// `i` nachgerueckt war. Die lag dann bis zum 30-Sekunden-Timer.
//
// Ausloeser ist `_clearQueuedTrackingDay`: `_performOp` feuert fuer jede
// replayte Mahlzeit mit `track_day` ein unawaitetes `_recordTrackingDay`, und
// dessen Antwort filtert die Outbox — moeglicherweise mitten im `await` der
// Tages-Op, die derselbe Durchlauf gerade abarbeitet.
//
// Das Gegenstueck („Op VOR dem Cursor faellt weg") steht in
// test/outbox_replay_race_test.dart. Hier faellt die Op WEG, die der Cursor
// selbst in der Hand hat.

/// Der Tag, an dem Mahlzeiten und Tages-Op haengen; zugleich die `entityId`
/// der trackingDay-Op.
const String _tag = '2026-05-14';

/// Fester Zeitpunkt (K-02): der Test haengt an einem Datum, das sonst mit dem
/// Kalender wandert.
final DateTime _jetzt = DateTime(2026, 5, 14, 12, 30);

/// Ids ohne UUID-Form: `_statsFollowUpFor` leitet daraus keine Request-Id ab,
/// also veraendert kein Zaehler-Folgeeintrag die Queue mitten im Durchlauf.
/// Dieser Test misst die Positionslogik, nicht die Zaehler.
LoggedMeal _mahlzeit(String id) => LoggedMeal(
      id: id,
      result: mealResult(id),
      loggedAt: DateTime(2026, 5, 14, 12),
      localDay: _tag,
    );

/// Fake-PostgREST, das genau die Verschraenkung des Befunds erzeugt.
class _KursorServer {
  /// Aufrufe von record_tracking_day. Erwartet werden GENAU zwei: der
  /// unawaitete aus dem mealInsert-Replay und der der Tages-Op.
  int tagesAufrufe = 0;

  /// Vom Test gesetzt, im Handler gelesen.
  HomeStore? store;

  /// Haelt die Antwort des ERSTEN Aufrufs zurueck, bis der zweite auf dem Draht
  /// ist — sonst kuerzt sie die Queue, bevor die Tages-Op ueberhaupt laeuft.
  final Completer<void> _ersteAntwortFrei = Completer<void>();

  /// Vorbedingung des Tests: die Tages-Op hat die Queue waehrend ihres EIGENEN
  /// await verlassen. Ohne das prueft der Test nichts.
  bool tagesOpFielImEigenenAwaitRaus = false;

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
        // Der unawaitete Aufruf aus dem mealInsert-Replay. Seine Antwort ist
        // es, die `_clearQueuedTrackingDay` ausloest — sie darf erst fallen,
        // wenn die Tages-Op selbst im await haengt.
        await _ersteAntwortFrei.future
            .timeout(const Duration(seconds: 5), onTimeout: () {});
        return ok(_statsZeile());
      }
      // Der Aufruf der Tages-Op: Antwort des ersten freigeben und warten, bis
      // die eigene Op wirklich aus der Queue gefallen ist.
      if (!_ersteAntwortFrei.isCompleted) _ersteAntwortFrei.complete();
      for (var i = 0; i < 400; i++) {
        final queue = store?.pendingOutbox ?? const <SyncOp>[];
        if (!queue.any((o) => o.kind == SyncOpKind.trackingDay)) {
          tagesOpFielImEigenenAwaitRaus = true;
          break;
        }
        await Future<void>.delayed(Duration.zero);
      }
      return ok(_statsZeile());
    }
    if (path.contains('/rpc/increment_lifetime_stats')) return ok(_statsZeile());
    if (path.contains('/logged_meals')) {
      if (req.method == 'POST') {
        String? geschrieben;
        for (final row in FakeServer.rowsOf(req.body)) {
          geschrieben = row['id'] as String?;
          if (geschrieben != null) geschriebeneMahlzeiten.add(geschrieben);
        }
        // Der Abstandshalter: erst wenn der unawaitete Tages-Aufruf wirklich
        // beim Server liegt, darf der Durchlauf zur Tages-Op weitergehen.
        // Sonst haengt die Reihenfolge der beiden RPCs am Zufall.
        if (geschrieben == 'm-b') {
          for (var i = 0; i < 200 && tagesAufrufe < 1; i++) {
            await Future<void>.delayed(Duration.zero);
          }
        }
        return http.Response('', 201, request: req);
      }
      if (req.method == 'DELETE') {
        final id = _idParam(req);
        if (id != null) geloeschteMahlzeiten.add(id);
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
      'K1: faellt die bearbeitete Op waehrend ihres eigenen await aus der '
      'Queue, wird die nachgerueckte Op im SELBEN Durchlauf zugestellt',
      () => anTag(() async {
            final kv = InMemoryKeyValueStore();
            // Die Reihenfolge ist der ganze Test:
            //   0 mealInsert m-a — traegt track_day, feuert also das
            //     unawaitete `_recordTrackingDay`, dessen Antwort spaeter die
            //     Tages-Op aus der Queue filtert.
            //   1 mealInsert m-b — Abstandshalter, damit dieser RPC sicher vor
            //     der Tages-Op auf dem Draht liegt.
            //   2 trackingDay — faellt waehrend ihres EIGENEN await weg.
            //   3 mealDelete m-opfer — rueckt auf ihren Platz nach.
            await kv.setString(
              'eatova.v1.outbox.user-k1',
              jsonEncode(<String, dynamic>{
                'items': <Map<String, dynamic>>[
                  SyncOp.mealInsert(_mahlzeit('m-a'), trackDay: true).toJson(),
                  SyncOp.mealInsert(_mahlzeit('m-b'), trackDay: false).toJson(),
                  SyncOp.trackingDay(_tag).toJson(),
                  SyncOp.mealDelete('m-opfer').toJson(),
                ],
              }),
            );

            final server = _KursorServer();
            final client = SupabaseClient(
              'https://example.supabase.co',
              'test-anon-key',
              httpClient: server.client(),
              authOptions: const AuthClientOptions(autoRefreshToken: false),
            );
            addTearDown(client.dispose);
            final snacks = SnackCapture();
            final store = HomeStore(
              sync: EatovaSync.forUser(client, 'user-k1'),
              health: const NoopHealthService(),
              notificationService: const NoopNotificationService(),
              initialUserName: 'Test',
              emitSnack: snacks.call,
              debugCache: LocalCache(kv, 'user-k1'),
            );
            addTearDown(store.dispose);
            server.store = store;

            store.start();
            await store.profileReady;
            await pumpEventQueue(times: 800);

            expect(server.tagesAufrufe, 2,
                reason: 'Vorbedingung: der unawaitete Aufruf aus dem '
                    'mealInsert-Replay UND der der Tages-Op muessen beide '
                    'gelaufen sein, sonst gibt es das Fenster gar nicht');
            expect(server.tagesOpFielImEigenenAwaitRaus, isTrue,
                reason: 'Vorbedingung: die Tages-Op muss die Queue WAEHREND '
                    'ihres eigenen await verlassen haben — sonst prueft der '
                    'Test nichts');
            expect(server.geschriebeneMahlzeiten,
                containsAll(<String>['m-a', 'm-b']),
                reason: 'Vorbedingung: der Durchlauf lief bis zur Tages-Op');

            // Der Kern: die nachgerueckte Op darf nicht uebersprungen werden.
            expect(server.geloeschteMahlzeiten, contains('m-opfer'),
                reason: 'findet die Schleife ihre eigene Op per identical '
                    'nicht mehr und zaehlt den Index trotzdem hoch, faellt '
                    'genau die nachgerueckte Op aus dem Durchlauf und liegt '
                    'bis zum 30-Sekunden-Timer');
            expect(store.pendingOutbox, isEmpty,
                reason: 'ein Durchlauf, der nichts ueberspringt, laesst nichts '
                    'liegen');
          }));

  test(
      'K1-Regression: ein waehrend des Durchlaufs ANGEHAENGTER '
      'Zaehler-Folgeeintrag wird im selben Durchlauf noch erreicht',
      () => anTag(() async {
            // Eine UUID: nur dann leitet `_statsFollowUpFor` eine Request-Id ab
            // und haengt den statsIncrement HINTEN an die Queue. Ein Snapshot
            // zu Beginn des Durchlaufs wuerde ihn genau hier verlieren.
            const uuid = '11111111-2222-4333-8444-555555555555';
            final kv = InMemoryKeyValueStore();
            await seedRawOutbox(kv, <Map<String, dynamic>>[
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
            // Profil im Cache: sonst steht der Store im Onboarding, und das
            // ist ein zweiter, sachfremder Grund fuer Schreibvorgaenge.
            await s.cache.writeProfile(testProfile());
            await boot(s.store);

            expect(s.server.statsRequestIds,
                contains(deriveStatsRequestId(uuid)),
                reason: 'der Folgeeintrag entsteht erst WAEHREND des '
                    'Durchlaufs und wird hinten angehaengt — er darf nicht '
                    'bis zum naechsten Pass liegenbleiben');
            expect(s.server.mealsCounted, 1);
            expect(s.store.pendingOutbox, isEmpty,
                reason: 'weder die Mahlzeit noch ihr Zaehler duerfen '
                    'zurueckbleiben');
          }));

  test(
      'K1-Regression: der retryCounted-Pfad spielt eine Op nicht zweimal im '
      'selben Durchlauf', () => anTag(() async {
        final kv = InMemoryKeyValueStore();
        await seedRawOutbox(kv, <Map<String, dynamic>>[
          SyncOp.mealInsert(_mahlzeit('m-500'), trackDay: false).toJson(),
          SyncOp.mealDelete('m-weg').toJson(),
        ]);

        final s = setup(kv: kv);
        await s.cache.writeProfile(testProfile());
        // 500 auf den Mahlzeiten-Write (nur POST): retryCounted, also ERSETZT
        // der Durchlauf die Op durch `op.incrementAttempt()` — eine neue
        // Instanz, die derselbe Pass nicht erneut anfassen darf.
        s.server.rejectMealWrites = true;
        await boot(s.store);

        final versuche = s.server.requests
            .where((r) =>
                r.method == 'POST' && r.url.path.contains('/logged_meals'))
            .length;
        expect(versuche, 1,
            reason: 'die nachgezaehlte Kopie ist eine neue Instanz — wird sie '
                'im selben Durchlauf nochmal gewaehlt, verbrennt ein Pass '
                'mehrere der acht Zustellversuche auf einen Schlag');
        expect(
            s.server.requests
                .where((r) =>
                    r.method == 'DELETE' &&
                    r.url.path.contains('/logged_meals'))
                .length,
            1,
            reason: 'und der Durchlauf muss trotz der blockierten Entitaet '
                'weiterlaufen');

        final liegengeblieben = s.store.pendingOutbox
            .where((o) => o.kind == SyncOpKind.mealInsert)
            .toList();
        expect(liegengeblieben, hasLength(1));
        expect(liegengeblieben.single.attempts, 1,
            reason: 'genau EIN gezaehlter Versuch pro Durchlauf');
      }));
}
