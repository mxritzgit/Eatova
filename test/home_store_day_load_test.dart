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
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/meals_sync.dart'
    show MealsSync, mealResultToJson;
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

import 'support/postgrest_filters.dart';
import 'support/sync_operation_fake.dart';

// On-demand loading of old days: the boot loads only the 35-day window, and
// picking an older day loads exactly that day and merges it by id. Driven
// against the REAL HomeStore over a stateful MockClient that applies the
// canonical-day and legacy timestamp filters like PostgREST.

/// Stateful fake PostgREST applying owner, day, timestamp, sort and row limits.
class _FakeServer {
  bool offline = false;

  /// Holds logged_meals GETs open until completed, for the loading-state test.
  Completer<void>? holdMealReads;

  final List<http.Request> requests = <http.Request>[];
  final Map<String, Map<String, dynamic>> mealRows =
      <String, Map<String, dynamic>>{};
  int mealsCounted = 0;
  int weightLogsCounted = 0;
  final _counted = <String>{};
  late final operations = SyncOperationFake(
    meals: mealRows, weights: {}, favorites: {}, recipes: {},
    readProfile: () => null, writeProfile: (_) {}, readStats: _statsRow,
    incrementStats: (id, meals, weights) {
      if (_counted.add(id)) {
        mealsCounted += meals;
        weightLogsCounted += weights;
      }
    }, recordDay: (_) {},
  );

  http.Client client() => MockClient(_handle);

  /// Archive requests include a canonical-day group; old timestamp-only
  /// requests remain recognizable for negative controls.
  List<http.Request> get dayReads => requests
      .where((r) =>
          r.method == 'GET' &&
          r.url.path.contains('/logged_meals') &&
          (r.url.queryParameters.containsKey('or') ||
              (r.url.queryParametersAll['logged_at'] ?? const [])
                  .any((f) => f.startsWith('lt.'))))
      .toList();

  Future<http.Response> _handle(http.Request req) async {
    if (offline) {
      throw http.ClientException('offline', req.url);
    }
    requests.add(req);
    final path = req.url.path;

    http.Response ok(Object body) => http.Response(jsonEncode(body), 200,
        headers: const {'content-type': 'application/json; charset=utf-8'}, request: req);

    if (path.endsWith('/rpc/apply_sync_operation')) {
      final receipt = operations.apply(
          (jsonDecode(req.body) as Map).cast<String, dynamic>());
      // The real RPC derives ownership from auth.uid(), not its payload.
      for (final row in mealRows.values) {
        row.putIfAbsent('user_id', () => 'user-dayload');
      }
      return ok(receipt);
    }

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
      final hold = holdMealReads;
      if (hold != null) await hold.future;
      var rows = mealRows.values
          .where((row) => matchesPostgrestFilters(row, req.url))
          .toList();
      final order = req.url.queryParameters['order'];
      if (order != null && order.startsWith('id.asc')) {
        rows.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
      } else if (order != null && order.startsWith('logged_at.desc')) {
        rows.sort((a, b) => DateTime.parse(b['logged_at'] as String)
            .compareTo(DateTime.parse(a['logged_at'] as String)));
      } else {
        throw StateError('Diary request lost its server ordering');
      }
      final limit = int.parse(req.url.queryParameters['limit']!);
      if (rows.length > limit) rows = rows.sublist(0, limit);
      return ok(rows.map((r) => <String, dynamic>{
                'id': r['id'],
                'logged_at': r['logged_at'],
                'forced_slot': r['forced_slot'],
                'local_day': r['local_day'],
                'payload': r['payload'],
              }).toList());
    }
    // Remaining reads empty, remaining writes succeed (see outbox test).
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
    SnackTone tone = SnackTone.positive,
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
  String? localDay,
  String userId = 'user-dayload',
}) =>
    <String, dynamic>{
      'id': id,
      'user_id': userId,
      'logged_at': loggedAt.toUtc().toIso8601String(),
      'forced_slot': null,
      'local_day': localDay,
      'payload': mealResultToJson(_result(name, kcal: kcal)),
    };

/// An old day clearly outside the 35-day window.
DateTime get _oldDay => DateUtils.dateOnly(DateTime.now())
    .subtract(const Duration(days: MealsSync.loggedMealsWindowDays + 5));

Future<void> _settle() => pumpEventQueue(times: 60);

Future<void> _boot(HomeStore store) async {
  store.start();
  await store.profileReady;
  await _settle();
}

void _expectDayFilter(http.Request request, DateTime day) {
  final start = DateTime(day.year, day.month, day.day).toUtc();
  final end = DateTime(day.year, day.month, day.day + 1).toUtc();
  expect(request.url.queryParameters['or'],
      '(local_day.eq.${localDayKey(day)},and(local_day.is.null,'
      'logged_at.gte.${start.toIso8601String()},'
      'logged_at.lt.${end.toIso8601String()}))');
  expect(request.url.queryParameters.containsKey('logged_at'), isFalse);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a boot row cap does not leave an in-window day permanently empty',
      () async {
    await withClock(Clock.fixed(DateTime(2026, 9, 25, 12)), () async {
      final s = _setup();
      final now = DateTime(2026, 9, 25, 12);
      for (var day = 0; day < 20; day++) {
        for (var row = 0; row < 50; row++) {
          final index = day * 50 + row;
          final id =
              '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
          s.server.mealRows[id] = _serverMealRow(
            id,
            now.subtract(Duration(days: day)).add(Duration(seconds: row)),
            localDay: localDayKey(now.subtract(Duration(days: day))),
          );
        }
      }
      final missingDay = DateTime(2026, 9, 1);
      const missingId = '00000000-0000-4000-8000-999999999999';
      s.server.mealRows[missingId] = _serverMealRow(
        missingId,
        missingDay.add(const Duration(hours: 12)),
        kcal: 415,
        localDay: localDayKey(missingDay),
      );

      await _boot(s.store);
      expect(s.store.loggedMeals, hasLength(MealsSync.loggedMealsMaxRows));
      expect(s.store.mealsForFoodDate(missingDay), isEmpty);

      s.store.setFoodDate(missingDay);
      await _settle();

      expect(s.store.mealsForFoodDate(missingDay).map((m) => m.id), [missingId]);
      expect(s.store.consumedKcalForFoodDate(missingDay), 415);
      expect(
        s.server.dayReads.any((r) =>
            r.url.queryParameters['or']?.contains(localDayKey(missingDay)) ??
            false),
        isTrue,
      );
    });
  });

  test(
      'Alt-Tag waehlen laedt den kanonischen Tag nach, merged ihn '
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

    // The boot window holds only the recent row.
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

    expect(s.server.dayReads, hasLength(1));
    _expectDayFilter(s.server.dayReads.single, oldDay);

    // Revisiting the same day hits the session cache, no further GET.
    s.store.setFoodDate(DateTime.now());
    s.store.setFoodDate(oldDay);
    await _settle();
    expect(s.server.dayReads, hasLength(1));
    expect(s.store.mealsForFoodDate(oldDay), hasLength(1));

    // ... aber ein Fenster-Refresh IN DERSELBEN Sitzung (retryBoot) ersetzt
    // loggedMeals, also muss der Sitzungs-Cache den Tag wieder vergessen.
    // Ohne den Reset gilt er weiter als „geladen" und steht ab jetzt dauerhaft
    // leer da — der zweite Store der letzten Faelle kann das nicht zeigen, er
    // startet ohnehin mit leerem Set.
    await s.store.retryBoot();
    await _settle();
    expect(s.server.dayReads, hasLength(2),
        reason: 'der Fenster-Refresh hat den Alt-Tag aus loggedMeals geworfen, '
            'die weiterhin ausgewaehlte Auswahl muss ihn neu holen');
    expect(s.store.mealsForFoodDate(oldDay).map((m) => m.id), ['old-1'],
        reason: 'sonst zeigt der offene Alt-Tag nach jedem Boot-Retry leer');
  });

  test('archive loads canonical meals after timezone travel', () async {
    await withClock(Clock.fixed(DateTime(2026, 9, 19, 12)), () async {
      final s = _setup();
      final day = DateTime(2026, 7, 14);
      final next = DateTime(2026, 7, 15);
      s.server.mealRows.addAll({
        'earlier': _serverMealRow('earlier', day.subtract(const Duration(hours: 1)),
            localDay: '2026-07-14', kcal: 110),
        'later': _serverMealRow('later', next.add(const Duration(hours: 1)),
            localDay: '2026-07-14', kcal: 220),
        'wrong-day': _serverMealRow('wrong-day', DateTime(2026, 7, 14, 12),
            localDay: '2026-07-15', kcal: 900),
        'foreign': _serverMealRow('foreign', day,
            localDay: '2026-07-14', userId: 'other-user'),
      });
      await _boot(s.store);
      expect(s.store.loggedMeals, isEmpty);
      s.store.setFoodDate(day);
      await _settle();
      expect(s.store.mealsForFoodDate(day).map((meal) => meal.id),
          ['later', 'earlier']);
      expect(s.store.loggedMeals.map((meal) => meal.id), ['later', 'earlier']);
      expect(s.store.consumedKcalForFoodDate(day), 330);
      expect(s.server.dayReads, hasLength(1));
    });
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
    // No schema or exception leak into the UI.
    for (final m in s.snacks.messages) {
      expect(m, isNot(contains('ClientException')));
      expect(m, isNot(contains('logged_meals')));
    }

    // The failure did NOT mark the day as loaded, so the next tap reloads.
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

    // Offline: a late entry plus a delete of the never-booted server row.
    s.server.offline = true;
    final localId = await s.store
        .addResultToDailyTotal(_result('Nachtrag', kcal: 200), foodDate: oldDay);
    await s.store.removeLoggedMeal('old-srv');
    await _settle();

    // The day load merges the server state, then the pending ops go on top.
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

    // Trigger a write-through by logging something for today.
    s.store.setFoodDate(DateTime.now());
    final todayId = await s.store.addResultToDailyTotal(_result('Heute-Bowl'));
    await _settle();

    final cached = await s.cache.readLoggedMeals();
    expect(cached, isNotNull);
    expect(cached!.map((m) => m.id), contains(todayId));
    expect(cached.map((m) => m.id), isNot(contains('old-1')),
        reason: 'Alt-Tage wandern bewusst NICHT in den durablen Cache');
    expect(s.store.mealsForFoodDate(oldDay), hasLength(1));
  });

  test(
      'Naechste Session (Fenster-Refresh): keine Geister-Duplikate — der '
      'Alt-Tag ist draussen und laedt bei Auswahl exakt einmal frisch',
      () async {
    final kv = InMemoryKeyValueStore();
    final oldDay = _oldDay;

    // Session 1: visit the old day (merged, in memory).
    final a = _setup(kv: kv);
    a.server.mealRows['old-1'] =
        _serverMealRow('old-1', oldDay.add(const Duration(hours: 12)));
    await _boot(a.store);
    a.store.setFoodDate(oldDay);
    await _settle();
    expect(a.store.mealsForFoodDate(oldDay), hasLength(1));

    // Session 2, same cache and server: the boot replaces the window and the
    // old day returns neither from cache nor as a ghost.
    final b = _setup(kv: kv, server: a.server);
    await _boot(b.store);
    expect(b.store.loggedMeals.where((m) => m.id == 'old-1'), isEmpty);

    // Selecting it loads fresh: exactly ONE copy, no duplicates.
    b.store.setFoodDate(oldDay);
    await _settle();
    expect(b.store.mealsForFoodDate(oldDay).map((m) => m.id), ['old-1']);
    expect(b.store.loggedMeals.where((m) => m.id == 'old-1'), hasLength(1));
  });

  // B5 (2026-08-08): _isOutsideBootWindow measured the window in absolute time
  // via `difference(...).inDays`. A span containing the spring DST switch is an
  // hour short, so the 35-day edge day counted as 34, was wrongly treated as
  // loaded and stayed empty forever.
  //   DateTime(2026,4,20).difference(DateTime(2026,3,16)).inDays == 34
  //
  // P1-06: boot query, window predicate and cache filter used to measure
  // against two different clocks — `_isOutsideBootWindow` on `clock.now()`, the
  // query on `DateTime.now()`. Under `withClock` they diverged, so no test
  // could prove the invariant "a day the store treats as INSIDE the window was
  // really loaded". The whole group therefore boots INSIDE the fixed clock.
  group('B5 — Fenstergrenze ueber die Fruehjahrsumstellung', () {
    final umstellung = Clock.fixed(DateTime(2026, 4, 20, 10));

    /// Dieselbe Umstellung, aber frueh am Tag — und darauf kommt es an.
    ///
    /// `.difference(...).inDays` verliert die DST-Stunde nur, wenn die Uhrzeit
    /// KLEINER ist als sie. Um 10:00 meldete die alte Wanduhr-Rechnung
    /// 35 Tage 9 Stunden, also weiterhin „ausserhalb" — der Randtag wurde
    /// nachgeladen und der Fall war gruen, ohne den Fehler zu beruehren
    /// (Mutationslauf T4, 2026-09-01). Um 00:30 sind es 34 Tage 23:30, und
    /// genau da faellt der Randtag faelschlich ins Fenster.
    ///
    /// Wie in `test/services/day_math_test.dart`: die Aussage greift nur in
    /// einer Zone mit Sommerzeit; unter UTC hat der Tag 24 Stunden.
    final umstellungFrueh = Clock.fixed(DateTime(2026, 4, 20, 0, 30));

    test(
        'der Randtag (35 Kalendertage zurueck) wird nachgeladen, auch wenn '
        'die Umstellung dazwischen liegt', () async {
      final s = _setup();

      await withClock(umstellungFrueh, () async {
        await _boot(s.store);
        expect(s.server.dayReads, isEmpty);

        s.store.setFoodDate(DateTime(2026, 3, 16));
        await _settle();
      });

      expect(s.server.dayReads, hasLength(1),
          reason: 'der Randtag muss on-demand nachgeladen werden');
      _expectDayFilter(s.server.dayReads.single, DateTime(2026, 3, 16));
    });

    test('ein Tag INNERHALB des Fensters loest weiterhin keinen Load aus',
        () async {
      final s = _setup();

      await withClock(umstellung, () async {
        await _boot(s.store);
        // 34 calendar days back, and the boot ran on the SAME clock — so this
        // day really is covered by the boot query, as the next test proves.
        s.store.setFoodDate(DateTime(2026, 3, 17));
        await _settle();
      });

      expect(s.server.dayReads, isEmpty);
    });

    // The invariant itself, not just the predicate: the day the store declares
    // INSIDE the window must carry the rows the boot query actually brought
    // back. Rows on both sides of the edge, so a window silently shifted in
    // either direction is visible.
    //
    // 'ausserhalb' sits at 00:30 on the boundary day, i.e. BEFORE the cutoff
    // timestamp (now - 35 days, around 10:00 local): the boundary day is only
    // partially covered, which is exactly why the predicate counts it as
    // outside and reloads it in full. The gap between 00:30 and 10:00 is far
    // wider than any zone/DST offset, so the setup holds in every zone.
    //
    // 'randtag-drin' liegt am SELBEN Randtag, aber um 12:00 — also NACH dem
    // Cutoff und damit schon im Boot-Fenster. Genau diese Zeile bekommt das
    // Nachladen ein zweites Mal, und nur an ihr zeigt sich, ob
    // `_mergeArchiveMeals` wirklich per id dedupliziert: ohne den Filter stuende
    // sie doppelt im Tagebuch und der Tag zaehlte ihre Kalorien zweimal
    // (Mutationslauf T4, 2026-09-01 — vorher deckte kein Fall diese
    // Ueberlappung ab).
    test(
        'was der Store als „im Fenster" fuehrt, hat der Boot-Load auch '
        'wirklich geholt — und der Randtag kommt trotz Ueberlappung einfach',
        () async {
      final s = _setup();
      s.server.mealRows['im-fenster'] = _serverMealRow(
          'im-fenster', DateTime(2026, 3, 17, 12),
          kcal: 410, name: 'Randnah');
      s.server.mealRows['randtag-drin'] = _serverMealRow(
          'randtag-drin', DateTime(2026, 3, 16, 12),
          kcal: 120, name: 'Randtag mittags');
      s.server.mealRows['ausserhalb'] = _serverMealRow(
          'ausserhalb', DateTime(2026, 3, 16, 0, 30),
          kcal: 380, name: 'Randtag');

      await withClock(umstellung, () async {
        await _boot(s.store);

        // The boot load brought back exactly the rows inside the window.
        expect(s.store.loggedMeals.map((m) => m.id),
            <String>['im-fenster', 'randtag-drin'],
            reason: 'die Boot-Query muss dieselbe Uhr benutzen wie das '
                'Fenster-Praedikat — sonst behauptet der Store „geladen" '
                'ueber einen Tag, den der Server nie geschickt hat');

        // P1-06b: the write-through filter is the THIRD place this window is
        // computed (_cacheableLoggedMeals). On `DateTime.now()` it drifted
        // against the two above, so a row loaded and led as „im Fenster" fell
        // out of the durable cache — and the next offline cold start showed
        // the day empty although nobody ever left the window.
        //
        // The local commit must retain the complete hydrated window even when
        // the profile endpoint has no row for this account.
        s.store.setFoodDate(DateTime(2026, 4, 20));
        final heuteId = await s.store.addResultToDailyTotal(_result('Fenster-Bowl'));
        await _settle();
        s.store.flushPendingWrites();
        await _settle();
        expect((await s.cache.readLoggedMeals())?.map((m) => m.id),
            containsAll(<String>['im-fenster', heuteId]),
            reason: 'was im Fenster liegt, gehoert auch in den durablen '
                'Cache — sonst ist der Offline-Bestand nach dem naechsten '
                'Kaltstart lueckenhaft');

        // And the store treats the day as inside the window: no reload …
        s.store.setFoodDate(DateTime(2026, 3, 17));
        await _settle();
        expect(s.server.dayReads, isEmpty,
            reason: 'ein Tag im Fenster wird nicht nachgeladen');
        // … and it is still not empty.
        expect(s.store.mealsForFoodDate(DateTime(2026, 3, 17)).map((m) => m.id),
            <String>['im-fenster'],
            reason: 'genau das ist die Invariante: im Fenster gefuehrt UND '
                'geladen — sonst bleibt der Tag dauerhaft leer');
        expect(s.store.consumedKcalForFoodDate(DateTime(2026, 3, 17)), 410);

        // Counter-check: the day outside arrives only on demand.
        s.store.setFoodDate(DateTime(2026, 3, 16));
        await _settle();
        expect(s.server.dayReads, hasLength(1));
        // Der Randtag wird VOLLSTAENDIG neu geholt, also auch die Zeile, die
        // das Boot-Fenster schon hatte. Sie darf danach genau einmal dastehen.
        expect(s.store.mealsForFoodDate(DateTime(2026, 3, 16)).map((m) => m.id),
            <String>['randtag-drin', 'ausserhalb']);
        expect(s.store.loggedMeals.where((m) => m.id == 'randtag-drin'),
            hasLength(1),
            reason: 'die ueberlappende Zeile kam zweimal an — der Merge muss '
                'sie per id verwerfen');
        expect(s.store.consumedKcalForFoodDate(DateTime(2026, 3, 16)), 500,
            reason: '120 + 380; eine Dublette machte daraus 620');
      });
    });
  });
}
