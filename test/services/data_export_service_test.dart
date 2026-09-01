// C7 (docs/REVIEW-2026-08-08.md): the in-app export used to be a partial
// in-memory snapshot of the session. DataExportService builds it from the
// server tables (RLS select_own) instead, the authoritative copy.
//
// The test drives the real SupabaseClient against a MockClient that applies
// PostgREST pagination (offset/limit or Range header) — otherwise broken
// pagination would never show up here.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/services/data_export.dart';

/// 5 diary rows, descending by logged_at.
final List<Map<String, dynamic>> _mealRows = List.generate(5, (i) {
  return <String, dynamic>{
    'id': 'meal-$i',
    'user_id': 'user-export',
    'logged_at': DateTime.utc(2026, 8, 1 + i, 12).toIso8601String(),
    'meal_name': 'Mahlzeit $i',
    'calories_kcal': 300 + i,
  };
})
  ..sort((a, b) =>
      (b['logged_at'] as String).compareTo(a['logged_at'] as String));

class _FakePostgrest {
  final List<http.Request> requests = <http.Request>[];
  bool failChatMessages = false;

  /// Simulates what an offset scan really does when a row is inserted while
  /// the export runs: the window slides and the following page repeats a row
  /// that was already delivered. Only with this does the id set in
  /// `_alleLoggedMeals` have anything to do.
  bool wiederholtEineZeile = false;

  http.Client client() => MockClient(_handle);

  Future<http.Response> _handle(http.Request req) async {
    requests.add(req);
    final path = req.url.path;

    http.Response ok(Object body) => http.Response(jsonEncode(body), 200,
        headers: const {'Content-Type': 'application/json'}, request: req);

    if (path.contains('/profiles')) {
      return ok([
        <String, dynamic>{
          'id': 'user-export',
          'display_name': 'Moritz',
          'weight_kg': 81,
          'diet_preference': 'vegetarian',
        }
      ]);
    }
    if (path.contains('/logged_meals')) {
      // Apply PostgREST pagination: postgrest-dart sends offset/limit as query
      // parameters, falling back to a Range header "items=from-to".
      var from = 0;
      var to = _mealRows.length - 1;
      final offset = int.tryParse(req.url.queryParameters['offset'] ?? '');
      final limit = int.tryParse(req.url.queryParameters['limit'] ?? '');
      if (offset != null) from = offset;
      if (limit != null) to = from + limit - 1;
      final range = req.headers['Range'] ?? req.headers['range'];
      if (range != null) {
        final m = RegExp(r'(\d+)-(\d+)').firstMatch(range);
        if (m != null) {
          from = int.parse(m.group(1)!);
          to = int.parse(m.group(2)!);
        }
      }
      if (wiederholtEineZeile && from > 0) from -= 1;
      if (from >= _mealRows.length) return ok(const <dynamic>[]);
      final slice = _mealRows.sublist(
          from, (to + 1).clamp(0, _mealRows.length));
      return ok(slice);
    }
    if (path.contains('/chat_messages')) {
      if (failChatMessages) {
        return http.Response(jsonEncode({'message': 'kaputt'}), 500,
            headers: const {'Content-Type': 'application/json'},
            request: req);
      }
      return ok([
        <String, dynamic>{
          'id': 'msg-1',
          'user_id': 'user-export',
          'role': 'user',
          'content': 'Wie viel Protein brauche ich?',
        }
      ]);
    }
    if (path.contains('/favorite_meals')) {
      return ok([
        <String, dynamic>{
          'favorite_key': 'name:bowl',
          'user_id': 'user-export',
          'payload': <String, dynamic>{'mealName': 'Bowl'},
        }
      ]);
    }
    // Remaining tables: empty, but successful.
    return ok(const <dynamic>[]);
  }
}

void main() {
  (DataExportService, _FakePostgrest) setup({int pageSize = 2}) {
    final server = _FakePostgrest();
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: server.client(),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    return (
      DataExportService(client, 'user-export', pageSize: pageSize),
      server,
    );
  }

  test('der Export enthaelt alle Nutzertabellen — auch Tagebuch, Favoriten '
      'und Coach-Verlauf, die dem alten Snapshot fehlten', () async {
    final (service, _) = setup();
    final json =
        jsonDecode(await service.buildExportJson()) as Map<String, dynamic>;

    expect((json['profiles'] as List).single, containsPair('diet_preference', 'vegetarian'),
        reason: 'Profil-Stammdaten inkl. Diaetpraeferenz (C7-Luecke)');
    expect(json['logged_meals'], hasLength(_mealRows.length),
        reason: 'das VOLLSTAENDIGE Tagebuch, nicht das 35-Tage-Fenster');
    expect((json['chat_messages'] as List).single,
        containsPair('content', 'Wie viel Protein brauche ich?'));
    expect((json['favorite_meals'] as List).single,
        containsPair('favorite_key', 'name:bowl'));
    for (final tabelle in DataExportService.alleExportTabellen) {
      expect(json.containsKey(tabelle), isTrue,
          reason: '$tabelle fehlt im Export');
    }
    expect(json['exportedAt'], isNotNull);
  });

  test('Pagination: mehr Zeilen als eine Seite kommen vollstaendig und ohne '
      'Duplikate an', () async {
    final (service, server) = setup(pageSize: 2);
    final json =
        jsonDecode(await service.buildExportJson()) as Map<String, dynamic>;

    final ids = (json['logged_meals'] as List)
        .map((r) => (r as Map)['id'])
        .toList();
    expect(ids.toSet(), _mealRows.map((r) => r['id']).toSet());
    expect(ids.length, ids.toSet().length, reason: 'keine Duplikate');
    // Proof that pagination really happened (5 rows / page size 2).
    final seiten = server.requests
        .where((r) => r.url.path.contains('/logged_meals'))
        .toList();
    expect(seiten.length, greaterThanOrEqualTo(3));
    // The requested windows themselves, not just the merged result: a window
    // one row too wide overlaps and only the id set hides it, so both guards
    // would mask each other's loss.
    for (var i = 0; i < seiten.length; i++) {
      expect(seiten[i].url.queryParameters['limit'], '2',
          reason: 'Seite $i fordert genau pageSize Zeilen an');
      expect(seiten[i].url.queryParameters['offset'], '${i * 2}',
          reason: 'die Fenster stossen lueckenlos aneinander');
    }
  });

  test('wiederholt der Server eine Zeile am Seitenrand, steht sie trotzdem '
      'nur einmal im Export', () async {
    final (service, server) = setup(pageSize: 2);
    server.wiederholtEineZeile = true;
    final json =
        jsonDecode(await service.buildExportJson()) as Map<String, dynamic>;

    final ids = (json['logged_meals'] as List)
        .map((r) => (r as Map)['id'])
        .toList();
    expect(ids.length, _mealRows.length,
        reason: 'ohne den id-Filter stuenden Mahlzeiten doppelt in der '
            'Auskunft und der Empfaenger zaehlt falsch');
    expect(ids.toSet(), _mealRows.map((r) => r['id']).toSet());
  });

  test('eine nicht lesbare Tabelle macht den Export nicht kaputt — sie wird '
      'als unvollstaendig ausgewiesen', () async {
    final (service, server) = setup();
    server.failChatMessages = true;
    final json =
        jsonDecode(await service.buildExportJson()) as Map<String, dynamic>;

    expect(json['unvollstaendig'], contains('chat_messages'),
        reason: 'ein Fehler darf nicht still eine leere Sektion vortaeuschen');
    expect(json['logged_meals'], hasLength(_mealRows.length),
        reason: 'die uebrigen Sektionen bleiben vollstaendig');
  });
}
