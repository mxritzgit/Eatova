import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/services/meals_sync.dart';
import 'package:eatova/src/services/tracking_sync.dart';
import 'package:eatova/src/services/user_recipes_sync.dart';

// PERF/DATA: Die vier Boot-Reads (Tagebuch, Favoriten, Gewicht, Rezepte)
// waren unbounded — nach einem Jahr Tracking laed jeder Kaltstart Tausende
// JSONB-Zeilen, und ein gesetztes db-max-rows kappt bei PostgREST STILL
// (aeltere Eintraege verschwinden kommentarlos). Diese Tests fahren die
// echten Sync-Services gegen einen aufzeichnenden MockClient (Muster aus
// home_store_outbox_test.dart) und sichern die Bounds AUF DEM WIRE:
//   1. logged_meals: Datumsfenster (gte auf logged_at, ~35 Tage) + order
//      desc + explizites Limit; Ergebnis-Reihenfolge = Server-Reihenfolge.
//   2. favorite_meals: order desc + grosszuegiges Limit.
//   3. weight_log: order desc + Limit auf dem Wire, aber AUFSTEIGENDE
//      Reihenfolge im Ergebnis (WeightLog-Kontrakt: latest == entries.last).
//   4. user_recipes: order desc + grosszuegiges Limit.

/// SupabaseClient gegen einen MockClient, der jeden Request aufzeichnet und
/// fuer GETs die uebergebenen Zeilen liefert.
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
    // Kein GoTrue-Auto-Refresh-Ticker im Test (siehe home_store_outbox_test).
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  return (client: client, requests: requests);
}

void main() {
  group('MealsSync.loadLoggedMeals', () {
    test('sendet Datumsfenster, order desc und explizites Limit', () async {
      final c = _recordingClient(const <dynamic>[]);
      await MealsSync(c.client, 'user-1').loadLoggedMeals();

      final req = c.requests.single;
      expect(req.url.path, endsWith('/logged_meals'));
      final params = req.url.queryParameters;
      expect(params['user_id'], 'eq.user-1');
      expect(params['order'], startsWith('logged_at.desc'));
      expect(params['limit'], '${MealsSync.loggedMealsMaxRows}');

      final gte = params['logged_at'];
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
      // Seit Sentinel-Rest S1 ist ein Payload ohne caloriesKcal korrupt und
      // die Zeile wird uebersprungen — die Fixtures tragen deshalb das
      // Pflichtfeld (die erste Fassung nutzte leere Payloads).
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
      expect(req.url.path, endsWith('/logged_meals'));
      final params = req.url.queryParameters;
      expect(params['user_id'], 'eq.user-1');
      expect(params['order'], startsWith('logged_at.desc'));
      expect(params['limit'], '${MealsSync.loggedMealsDayMaxRows}');

      // gte + lt teilen sich den Query-Key logged_at -> queryParametersAll.
      final bounds = req.url.queryParametersAll['logged_at'] ?? const [];
      final gte = bounds
          .singleWhere((f) => f.startsWith('gte.'))
          .substring('gte.'.length);
      final lt = bounds
          .singleWhere((f) => f.startsWith('lt.'))
          .substring('lt.'.length);
      // Lokale Mitternacht des Tages bzw. des Folgetags, nach UTC uebersetzt —
      // die Uhrzeit des uebergebenen DateTime ist egal.
      expect(DateTime.parse(gte), DateTime(2026, 3, 14).toUtc());
      expect(DateTime.parse(lt), DateTime(2026, 3, 15).toUtc());
    });
  });

  test('MealsSync.loadFavorites: order desc + grosszuegiges Limit', () async {
    final c = _recordingClient(const <dynamic>[]);
    await MealsSync(c.client, 'user-1').loadFavorites();

    final req = c.requests.single;
    expect(req.url.path, endsWith('/favorite_meals'));
    final params = req.url.queryParameters;
    expect(params['user_id'], 'eq.user-1');
    expect(params['order'], startsWith('added_at.desc'));
    expect(params['limit'], '${MealsSync.favoritesLimit}');
  });

  test(
      'TrackingSync.loadWeightLog: bounded auf dem Wire (desc + Limit), '
      'Ergebnis aufsteigend (WeightLog-Kontrakt)', () async {
    // Server liefert desc (neueste zuerst) — genau wie die Query bestellt.
    final c = _recordingClient([
      {'recorded_at': '2026-08-05T07:00:00Z', 'weight_kg': 81.0},
      {'recorded_at': '2026-08-01T07:00:00Z', 'weight_kg': 82.5},
      {'recorded_at': '2026-07-20T07:00:00Z', 'weight_kg': 84.0},
    ]);
    final log = await TrackingSync(c.client, 'user-1').loadWeightLog();

    final req = c.requests.single;
    expect(req.url.path, endsWith('/weight_log'));
    final params = req.url.queryParameters;
    expect(params['user_id'], 'eq.user-1');
    expect(params['order'], startsWith('recorded_at.desc'));
    expect(params['limit'], '${TrackingSync.weightLogLimit}');

    // Client-seitig zurueck in die aufsteigende Reihenfolge: latest ==
    // entries.last, der Verlaufs-Chart zeichnet links (alt) -> rechts (neu).
    expect(log.entries.map((e) => e.weightKg).toList(), [84.0, 82.5, 81.0]);
    expect(log.latest?.weightKg, 81.0);
    final timestamps = log.entries.map((e) => e.timestamp).toList();
    expect(timestamps, orderedEquals([...timestamps]..sort()));
  });

  test('UserRecipesSync.load: order desc + grosszuegiges Limit', () async {
    final c = _recordingClient(const <dynamic>[]);
    await UserRecipesSync(c.client, 'user-1').load();

    final req = c.requests.single;
    expect(req.url.path, endsWith('/user_recipes'));
    final params = req.url.queryParameters;
    expect(params['user_id'], 'eq.user-1');
    expect(params['order'], startsWith('created_at.desc'));
    expect(params['limit'], '${UserRecipesSync.userRecipesLimit}');
  });
}
