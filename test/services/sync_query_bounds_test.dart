import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/services/meals_sync.dart';
import 'package:eatova/src/services/tracking_sync.dart';
import 'package:eatova/src/services/user_recipes_sync.dart';

// PERF/DATA: the four boot reads were unbounded — after a year of tracking
// every cold start pulls thousands of JSONB rows, and a db-max-rows setting
// truncates SILENTLY in PostgREST. These tests pin the bounds ON THE WIRE:
// order desc plus an explicit limit everywhere, a date window on logged_meals,
// and an ASCENDING result for weight_log (latest == entries.last).

/// SupabaseClient over a MockClient that records every request and answers
/// GETs with the given rows.
({SupabaseClient client, List<http.Request> requests}) _recordingClient(
  Object rows,
) {
  final requests = <http.Request>[];
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: MockClient((req) async {
      requests.add(req);
      return http.Response(jsonEncode(rows), 200,
          headers: const {'Content-Type': 'application/json'}, request: req);
    }),
    // No GoTrue auto-refresh ticker in tests.
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  return (client: client, requests: requests);
}

/// The bounds every boot read shares: the user filter, `order desc` and an
/// explicit limit. One place, so a new loader inherits the same check.
void _erwarteGedeckelt(
  http.Request req, {
  required String pfad,
  required String orderSpalte,
  required int limit,
}) {
  expect(req.url.path, endsWith(pfad));
  final params = req.url.queryParameters;
  expect(params['user_id'], 'eq.user-1');
  expect(params['order'], startsWith('$orderSpalte.desc'));
  expect(params['limit'], '$limit');
}

/// The reads whose ONLY difference is table, sort column and limit.
final _gedeckelteReads =
    <(String, String, String, int, Future<void> Function(SupabaseClient))>[
  (
    'MealsSync.loadFavorites',
    '/favorite_meals',
    'added_at',
    MealsSync.favoritesLimit,
    (c) => MealsSync(c, 'user-1').loadFavorites()
  ),
  (
    'TrackingSync.loadWeightLog',
    '/weight_log',
    'recorded_at',
    TrackingSync.weightLogLimit,
    (c) => TrackingSync(c, 'user-1').loadWeightLog()
  ),
  (
    'UserRecipesSync.load',
    '/user_recipes',
    'created_at',
    UserRecipesSync.userRecipesLimit,
    (c) => UserRecipesSync(c, 'user-1').load()
  ),
];

void main() {
  group('MealsSync.loadLoggedMeals', () {
    test('sendet Datumsfenster, order desc und explizites Limit', () async {
      final c = _recordingClient(const <dynamic>[]);
      await MealsSync(c.client, 'user-1').loadLoggedMeals();

      final req = c.requests.single;
      _erwarteGedeckelt(req,
          pfad: '/logged_meals',
          orderSpalte: 'logged_at',
          limit: MealsSync.loggedMealsMaxRows);

      final gte = req.url.queryParameters['logged_at'];
      expect(gte, isNotNull, reason: 'Datumsfilter fehlt auf dem Wire');
      expect(gte, startsWith('gte.'));
      final cutoff = DateTime.parse(gte!.substring('gte.'.length));
      final age = DateTime.now().toUtc().difference(cutoff);
      expect(
        age.inDays,
        inInclusiveRange(
          MealsSync.loggedMealsWindowDays - 1,
          MealsSync.loggedMealsWindowDays,
        ),
        reason:
            'Cutoff muss ~${MealsSync.loggedMealsWindowDays} Tage zurueckliegen',
      );
    });

    test('behaelt die Server-Reihenfolge (neueste zuerst) bei', () async {
      // A payload without caloriesKcal counts as corrupt and its row is
      // skipped, so the fixtures carry that required field.
      final c = _recordingClient([
        {
          'id': 'neu',
          'logged_at': '2026-08-05T12:00:00Z',
          'forced_slot': null,
          'local_day': null,
          'payload': <String, dynamic>{'caloriesKcal': 100},
        },
        {
          'id': 'alt',
          'logged_at': '2026-07-20T12:00:00Z',
          'forced_slot': null,
          'local_day': null,
          'payload': <String, dynamic>{'caloriesKcal': 200},
        },
      ]);
      final meals = await MealsSync(c.client, 'user-1').loadLoggedMeals();

      expect(meals.map((m) => m.id).toList(), ['neu', 'alt']);
    });
  });

  group('MealsSync.loadLoggedMealsForDay', () {
    test(
        'sendet halboffenes Tagesfenster (gte/lt auf logged_at), order desc '
        'und kleines Limit', () async {
      final c = _recordingClient(const <dynamic>[]);
      await MealsSync(c.client, 'user-1')
          .loadLoggedMealsForDay(DateTime(2026, 3, 14, 15, 30));

      final req = c.requests.single;
      _erwarteGedeckelt(req,
          pfad: '/logged_meals',
          orderSpalte: 'logged_at',
          limit: MealsSync.loggedMealsDayMaxRows);

      // gte and lt share the query key logged_at -> queryParametersAll.
      final bounds = req.url.queryParametersAll['logged_at'] ?? const [];
      final gte = bounds
          .singleWhere((f) => f.startsWith('gte.'))
          .substring('gte.'.length);
      final lt = bounds
          .singleWhere((f) => f.startsWith('lt.'))
          .substring('lt.'.length);
      // Local midnight of the day and the next, translated to UTC; the time
      // of the passed DateTime does not matter.
      expect(DateTime.parse(gte), DateTime(2026, 3, 14).toUtc());
      expect(DateTime.parse(lt), DateTime(2026, 3, 15).toUtc());
    });
  });

  for (final (name, pfad, spalte, limit, lade) in _gedeckelteReads) {
    test('$name: user_id, order desc und explizites Limit auf dem Wire',
        () async {
      final c = _recordingClient(const <dynamic>[]);
      await lade(c.client);

      _erwarteGedeckelt(c.requests.single,
          pfad: pfad, orderSpalte: spalte, limit: limit);
    });
  }

  test('TrackingSync.loadWeightLog: Ergebnis aufsteigend (WeightLog-Kontrakt)',
      () async {
    // Server answers desc (newest first), exactly as the query asked.
    final c = _recordingClient([
      {'recorded_at': '2026-08-05T07:00:00Z', 'weight_kg': 81.0},
      {'recorded_at': '2026-08-01T07:00:00Z', 'weight_kg': 82.5},
      {'recorded_at': '2026-07-20T07:00:00Z', 'weight_kg': 84.0},
    ]);
    final log = await TrackingSync(c.client, 'user-1').loadWeightLog();

    // Flipped back to ascending on the client: latest == entries.last, and the
    // history chart draws old on the left, new on the right.
    expect(log.entries.map((e) => e.weightKg).toList(), [84.0, 82.5, 81.0]);
    expect(log.latest?.weightKg, 81.0);
    final timestamps = log.entries.map((e) => e.timestamp).toList();
    expect(timestamps, orderedEquals([...timestamps]..sort()));
  });
}
