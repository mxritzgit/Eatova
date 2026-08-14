// C7 (docs/REVIEW-2026-08-08.md): der In-App-Export war ein In-Memory-
// Teil-Snapshot der aktuellen Session — kein Tagebuch, keine Favoriten,
// keine Rezepte, kein Coach-Verlauf, keine Profil-Stammdaten. Der
// DataExportService baut die Auskunft stattdessen direkt aus den
// Server-Tabellen (RLS select_own), also aus der autoritativen Kopie.
//
// Der Test faehrt den echten SupabaseClient gegen einen MockClient, der
// PostgREST-Pagination (offset/limit bzw. Range-Header) anwendet — sonst
// wuerde eine kaputte Pagination hier nie auffallen.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/services/data_export.dart';

/// 5 Tagebuch-Zeilen, absteigend nach logged_at.
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
      // PostgREST-Pagination anwenden: postgrest-dart schickt offset/limit
      // als Query-Parameter (Fallback: Range-Header "items=from-to").
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
    // Uebrige Tabellen: leer, aber erfolgreich.
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
    // Beleg, dass wirklich paginiert wurde (5 Zeilen / Seitengroesse 2).
    expect(
        server.requests
            .where((r) => r.url.path.contains('/logged_meals'))
            .length,
        greaterThanOrEqualTo(3));
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
