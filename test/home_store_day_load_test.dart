import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/meals_sync.dart'
    show MealsSync, mealResultToJson;
import 'package:eatova/src/services/notification_service.dart';

// On-Demand-Laden alter Tage (2026-08-06): der Boot laedt nur das 35-Tage-
// Fenster (MealsSync.loggedMealsWindowDays). Waehlt der Nutzer per Kalender
// einen aelteren Tag, laedt der Store GENAU diesen Tag nach und merged ihn
// duplikat-sicher (per id) in loggedMeals. Diese Tests treiben den ECHTEN
// HomeStore ueber einen zustandsbehafteten MockClient (Muster:
// home_store_outbox_test.dart), dessen logged_meals-GET die gte/lt-Filter wie
// PostgREST anwendet, und sichern:
//   1. Tages-Query + Merge + Session-Cache (kein doppelter GET, keine Dups).
//   2. Lade-Zustand fuer die UI (isLoadingFoodDay) waehrend des Nachladens.
//   3. Fehlerpfad: klassifizierte Meldung (sync_error_messages), kein
//      haengender Spinner, erneuter Tap laedt erneut.
//   4. Outbox-Sicherheit: pendende Inserts bleiben sichtbar, ein pendender
//      Delete belebt eine frisch geladene Server-Zeile NICHT wieder.
//   5. Cache-Write-Through blaeht nicht auf: Alt-Tage bleiben In-Memory.
//   6. Naechste Session (Fenster-Refresh): keine Geister-Duplikate — der
//      Alt-Tag ist wieder draussen und laedt bei Auswahl frisch.

/// Zustandsbehafteter Fake-PostgREST mit gte/lt-Filterung auf logged_at.
class _FakeServer {
  bool offline = false;

  /// Haelt logged_meals-GETs offen, bis der Completer abgeschlossen wird
  /// (Lade-Zustands-Szenario).
  Completer<void>? holdMealReads;

  final List<http.Request> requests = <http.Request>[];
  final Map<String, Map<String, dynamic>> mealRows =
      <String, Map<String, dynamic>>{};
  int mealsCounted = 0;
  int weightLogsCounted = 0;

  http.Client client() => MockClient(_handle);

  /// Alle logged_meals-GETs, die einen lt.-Filter tragen — also die
  /// On-Demand-Tages-Queries (der Boot-Fenster-Query sendet nur gte.).
  List<http.Request> get dayReads => requests
      .where((r) =>
          r.method == 'GET' &&
          r.url.path.contains('/logged_meals') &&
          (r.url.queryParametersAll['logged_at'] ?? const [])
              .any((f) => f.startsWith('lt.')))
      .toList();

  Future<http.Response> _handle(http.Request req) async {
    if (offline) {
      throw http.ClientException('offline', req.url);
    }
    requests.add(req);
    final path = req.url.path;

    http.Response ok(Object body) => http.Response(jsonEncode(body), 200,
        headers: const {'Content-Type': 'application/json'}, request: req);

    if (path.contains('/rpc/increment_lifetime_stats')) {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      mealsCounted += (body['p_meals'] as num?)?.toInt() ?? 0;
      weightLogsCounted += (body['p_weight_logs'] as num?)?.toInt() ?? 0;
      return ok(_statsRow());
    }
    if (path.contains('/rpc/record_tracking_day')) {
      return ok(_statsRow());
    }
    if (path.contains('/logged_meals')) {
      if (req.method == 'POST') {
        for (final row in _rowsOf(req.body)) {
          mealRows[row['id'] as String] = row;
        }
        return http.Response('', 201, request: req);
      }
      if (req.method == 'PATCH') {
        final id = _eqParam(req, 'id');
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final existing = mealRows[id];
        if (existing != null) mealRows[id!] = {...existing, ...body};
        return ok(const <dynamic>[]);
      }
      if (req.method == 'DELETE') {
        mealRows.remove(_eqParam(req, 'id'));
        return ok(const <dynamic>[]);
      }
      // GET: optionales Anhalten + gte/lt-Filter wie PostgREST anwenden.
      final hold = holdMealReads;
      if (hold != null) await hold.future;
      final filters = req.url.queryParametersAll['logged_at'] ?? const [];
      bool inRange(Map<String, dynamic> r) {
        final t = DateTime.parse(r['logged_at'] as String);
        for (final f in filters) {
          if (f.startsWith('gte.') &&
              t.isBefore(DateTime.parse(f.substring(4)))) {
            return false;
          }
          if (f.startsWith('lt.') &&
              !t.isBefore(DateTime.parse(f.substring(3)))) {
            return false;
          }
        }
        return true;
      }

      return ok(mealRows.values
          .where(inRange)
          .map((r) => <String, dynamic>{
                'id': r['id'],
                'logged_at': r['logged_at'],
                'forced_slot': r['forced_slot'],
                'local_day': r['local_day'],
                'payload': r['payload'],
              })
          .toList());
    }
    // Uebrige Reads leer, uebrige Writes Erfolg (siehe outbox-Test).
    if (req.method == 'GET') return ok(const <dynamic>[]);
    return http.Response('', 201, request: req);
  }

  Map<String, dynamic> _statsRow() => <String, dynamic>{
        'workouts_completed': 0,
        'meals_logged': mealsCounted,
        'water_total_ml': 0,
        'steps_recorded': 0,
        'weight_logs': weightLogsCounted,
        'current_streak': 1,
        'longest_streak': 1,
        'last_workout_date': null,
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

class _SnackCapture {
  final List<String> messages = <String>[];

  void call(
    String message, {
    IconData icon = Icons.info_outline,
    Color accent = Colors.white,
    Duration? duration,
    SnackBarAction? action,
  }) {
    messages.add(message);
  }
}

({
  HomeStore store,
  _FakeServer server,
  LocalCache cache,
  _SnackCapture snacks,
}) _setup({InMemoryKeyValueStore? kv, _FakeServer? server}) {
  final srv = server ?? _FakeServer();
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: srv.client(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  final cache = LocalCache(kv ?? InMemoryKeyValueStore(), 'user-dayload');
  final snacks = _SnackCapture();
  final store = HomeStore(
    sync: EatovaSync.forUser(client, 'user-dayload'),
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: 'Test',
    emitSnack: snacks.call,
    debugCache: cache,
  );
  addTearDown(store.dispose);
  return (store: store, server: srv, cache: cache, snacks: snacks);
}

MealAnalysisResult _result(String name, {int kcal = 300}) =>
    MealAnalysisResult(
      mealName: name,
      caloriesKcal: kcal,
      estimatedGrams: 350,
      kcalPer100G: kcal * 100 / 350,
      protein: '30 g',
      carbs: '40 g',
      fat: '10 g',
      confidence: 'Hoch',
      portionNotes: 'Test.',
      sourceLabel: 'Foto-KI',
    );

Map<String, dynamic> _serverMealRow(
  String id,
  DateTime loggedAt, {
  int kcal = 250,
  String name = 'Server-Gericht',
}) =>
    <String, dynamic>{
      'id': id,
      'logged_at': loggedAt.toUtc().toIso8601String(),
      'forced_slot': null,
      'local_day': null,
      'payload': mealResultToJson(_result(name, kcal: kcal)),
    };

/// Alt-Tag klar ausserhalb des 35-Tage-Fensters.
DateTime get _oldDay => DateUtils.dateOnly(DateTime.now())
    .subtract(const Duration(days: MealsSync.loggedMealsWindowDays + 5));

Future<void> _settle() => pumpEventQueue(times: 60);

Future<void> _boot(HomeStore store) async {
  store.start();
  await store.profileReady;
  await _settle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'Alt-Tag waehlen laedt den Tag nach (gte/lt auf dem Wire), merged ihn '
      'und cached ihn fuer die Session (kein zweiter GET, keine Duplikate)',
      () async {
    final s = _setup();
    final oldDay = _oldDay;
    s.server.mealRows['old-1'] =
        _serverMealRow('old-1', oldDay.add(const Duration(hours: 12)),
            kcal: 400, name: 'Alte Bowl');
    s.server.mealRows['win-1'] = _serverMealRow(
        'win-1', DateTime.now().subtract(const Duration(days: 1)));
    await _boot(s.store);

    // Boot-Fenster enthaelt nur die junge Zeile.
    expect(s.store.loggedMeals.map((m) => m.id), ['win-1']);

    s.store.setFoodDate(oldDay);
    await _settle();

    expect(s.store.mealsForFoodDate(oldDay).map((m) => m.id), ['old-1']);
    expect(s.store.consumedKcalForFoodDate(oldDay), 400);
    expect(
      s.store.loggedMeals.map((m) => m.id).toSet().length,
      s.store.loggedMeals.length,
      reason: 'Merge ist duplikat-sicher per id',
    );

    // Genau EIN Tages-GET mit halboffenem Fenster auf logged_at.
    expect(s.server.dayReads, hasLength(1));
    final bounds =
        s.server.dayReads.single.url.queryParametersAll['logged_at']!;
    final gte = DateTime.parse(
        bounds.singleWhere((f) => f.startsWith('gte.')).substring(4));
    final lt = DateTime.parse(
        bounds.singleWhere((f) => f.startsWith('lt.')).substring(3));
    expect(gte, DateTime(oldDay.year, oldDay.month, oldDay.day).toUtc());
    expect(lt, DateTime(oldDay.year, oldDay.month, oldDay.day + 1).toUtc());

    // Erneuter Besuch desselben Tags: Session-Cache, kein weiterer GET.
    s.store.setFoodDate(DateTime.now());
    s.store.setFoodDate(oldDay);
    await _settle();
    expect(s.server.dayReads, hasLength(1));
    expect(s.store.mealsForFoodDate(oldDay), hasLength(1));
  });

  test('isLoadingFoodDay ist waehrend des Nachladens true (Spinner-Zustand)',
      () async {
    final s = _setup();
    final oldDay = _oldDay;
    s.server.mealRows['old-1'] =
        _serverMealRow('old-1', oldDay.add(const Duration(hours: 9)));
    await _boot(s.store);

    s.server.holdMealReads = Completer<void>();
    s.store.setFoodDate(oldDay);
    await pumpEventQueue();

    expect(s.store.isLoadingFoodDay(oldDay), isTrue);
    expect(s.store.mealsForFoodDate(oldDay), isEmpty);

    s.server.holdMealReads!.complete();
    s.server.holdMealReads = null;
    await _settle();

    expect(s.store.isLoadingFoodDay(oldDay), isFalse);
    expect(s.store.mealsForFoodDate(oldDay), hasLength(1));
  });

  test(
      'Fehler beim Nachladen: klassifizierte Offline-Meldung, kein haengender '
      'Spinner — erneuter Tap laedt erneut', () async {
    final s = _setup();
    final oldDay = _oldDay;
    s.server.mealRows['old-1'] =
        _serverMealRow('old-1', oldDay.add(const Duration(hours: 9)));
    await _boot(s.store);

    s.server.offline = true;
    s.store.setFoodDate(oldDay);
    await _settle();

    expect(s.store.isLoadingFoodDay(oldDay), isFalse);
    expect(s.store.mealsForFoodDate(oldDay), isEmpty);
    expect(
      s.snacks.messages.last,
      'Offline — das hat gerade nicht geklappt. Bitte versuch es mit Internetverbindung erneut.',
    );
    // Kein Schema-/Exception-Leak in die UI.
    for (final m in s.snacks.messages) {
      expect(m, isNot(contains('ClientException')));
      expect(m, isNot(contains('logged_meals')));
    }

    // Netz zurueck: derselbe Tag laedt beim naechsten Tap erneut (der
    // Fehlschlag hat ihn NICHT als geladen markiert).
    s.server.offline = false;
    s.store.setFoodDate(oldDay);
    await _settle();
    expect(s.store.mealsForFoodDate(oldDay).map((m) => m.id), ['old-1']);
  });

  test(
      'Outbox-sicher: pendender Insert bleibt sichtbar, pendender Delete '
      'belebt die frisch geladene Server-Zeile NICHT wieder', () async {
    final s = _setup();
    final oldDay = _oldDay;
    s.server.mealRows['old-srv'] =
        _serverMealRow('old-srv', oldDay.add(const Duration(hours: 12)));
    await _boot(s.store);

    // Offline: Nachtrag auf den Alt-Tag + Loeschung der (nie gebooteten)
    // Server-Zeile — beides landet als Op in der Outbox.
    s.server.offline = true;
    final localId = s.store
        .addResultToDailyTotal(_result('Nachtrag', kcal: 200), foodDate: oldDay);
    s.store.removeLoggedMeal('old-srv');
    await _settle();

    // Wieder online: der Tages-Load merged den Server-Stand — die pendenden
    // Ops werden danach erneut ueberlagert.
    s.server.offline = false;
    s.store.setFoodDate(oldDay);
    await _settle();

    final ids = s.store.mealsForFoodDate(oldDay).map((m) => m.id).toList();
    expect(ids, contains(localId), reason: 'pendender Insert bleibt sichtbar');
    expect(ids, isNot(contains('old-srv')),
        reason: 'pendender Delete wird nicht wiederbelebt');
    expect(
      s.store.loggedMeals.map((m) => m.id).toSet().length,
      s.store.loggedMeals.length,
    );
  });

  test(
      'Cache-Write-Through blaeht nicht auf: nachgeladene Alt-Tage bleiben '
      'In-Memory, das Boot-Fenster bleibt gecacht', () async {
    final s = _setup();
    final oldDay = _oldDay;
    s.server.mealRows['old-1'] =
        _serverMealRow('old-1', oldDay.add(const Duration(hours: 12)));
    await _boot(s.store);

    s.store.setFoodDate(oldDay);
    await _settle();
    expect(s.store.mealsForFoodDate(oldDay), hasLength(1));

    // Write-Through ausloesen: heutigen Log hinzufuegen.
    s.store.setFoodDate(DateTime.now());
    final todayId = s.store.addResultToDailyTotal(_result('Heute-Bowl'));
    await _settle();

    final cached = await s.cache.readLoggedMeals();
    expect(cached, isNotNull);
    expect(cached!.map((m) => m.id), contains(todayId));
    expect(cached.map((m) => m.id), isNot(contains('old-1')),
        reason: 'Alt-Tage wandern bewusst NICHT in den durablen Cache');
    // In-Memory bleibt der Alt-Tag natuerlich da.
    expect(s.store.mealsForFoodDate(oldDay), hasLength(1));
  });

  test(
      'Naechste Session (Fenster-Refresh): keine Geister-Duplikate — der '
      'Alt-Tag ist draussen und laedt bei Auswahl exakt einmal frisch',
      () async {
    final kv = InMemoryKeyValueStore();
    final oldDay = _oldDay;

    // Session 1: Alt-Tag besuchen (gemerged, in-memory).
    final a = _setup(kv: kv);
    a.server.mealRows['old-1'] =
        _serverMealRow('old-1', oldDay.add(const Duration(hours: 12)));
    await _boot(a.store);
    a.store.setFoodDate(oldDay);
    await _settle();
    expect(a.store.mealsForFoodDate(oldDay), hasLength(1));

    // Session 2 auf demselben Cache + Server: der Boot ersetzt das Fenster,
    // der Alt-Tag kommt weder aus dem Cache noch als Geist mit.
    final b = _setup(kv: kv, server: a.server);
    await _boot(b.store);
    expect(b.store.loggedMeals.where((m) => m.id == 'old-1'), isEmpty);

    // Auswahl laedt frisch — exakt EINE Kopie, keine Duplikate.
    b.store.setFoodDate(oldDay);
    await _settle();
    expect(b.store.mealsForFoodDate(oldDay).map((m) => m.id), ['old-1']);
    expect(b.store.loggedMeals.where((m) => m.id == 'old-1'), hasLength(1));
  });

  // B5 (2026-08-08): _isOutsideBootWindow rechnete die Fenstergrenze mit
  // `dateOnly(now).difference(dateOnly(day)).inDays` — Absolutzeit. Ueber die
  // Fruehjahrsumstellung (Europe/Berlin, Sonntag 29.03.2026, 23 Stunden) fehlt
  // in jedem Zeitraum, der sie enthaelt, eine Stunde: der Randtag des
  // 35-Tage-Fensters zaehlt nur als 34 und gilt faelschlich als „im Fenster"
  // geladen. Er wurde deshalb NIE nachgeladen und blieb dauerhaft leer, obwohl
  // der Boot-Query (Zeitstempel-Cutoff) ihn hoechstens partiell mitbringt.
  //
  // Nachgerechnet auf dieser Maschine (Europe/Berlin):
  //   DateTime(2026,4,20).difference(DateTime(2026,3,16)).inDays == 34
  group('B5 — Fenstergrenze ueber die Fruehjahrsumstellung', () {
    test(
        'der Randtag (35 Kalendertage zurueck) wird nachgeladen, auch wenn '
        'die Umstellung dazwischen liegt', () async {
      final s = _setup();
      await _boot(s.store);
      expect(s.server.dayReads, isEmpty);

      await withClock(Clock.fixed(DateTime(2026, 4, 20, 10)), () async {
        s.store.setFoodDate(DateTime(2026, 3, 16));
        await _settle();
      });

      expect(s.server.dayReads, hasLength(1),
          reason: 'der Randtag muss on-demand nachgeladen werden');
      final bounds =
          s.server.dayReads.single.url.queryParametersAll['logged_at']!;
      final gte = DateTime.parse(
          bounds.singleWhere((f) => f.startsWith('gte.')).substring(4));
      final lt = DateTime.parse(
          bounds.singleWhere((f) => f.startsWith('lt.')).substring(3));
      expect(gte, DateTime(2026, 3, 16).toUtc());
      expect(lt, DateTime(2026, 3, 17).toUtc());
    });

    test('ein Tag INNERHALB des Fensters loest weiterhin keinen Load aus',
        () async {
      final s = _setup();
      await _boot(s.store);

      await withClock(Clock.fixed(DateTime(2026, 4, 20, 10)), () async {
        // 34 Kalendertage zurueck — der Boot-Query deckt ihn ab.
        s.store.setFoodDate(DateTime(2026, 3, 17));
        await _settle();
      });

      expect(s.server.dayReads, isEmpty);
    });
  });
}
