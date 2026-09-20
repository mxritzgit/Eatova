// C7 (docs/REVIEW-2026-08-08.md): the in-app export used to be a partial
// in-memory snapshot of the session. DataExportService builds it from the
// server tables (RLS select_own) instead, the authoritative copy.
//
// The test drives the real SupabaseClient against a MockClient that applies
// PostgREST filtering and pagination — otherwise broken
// pagination would never show up here.

import 'dart:convert';

import '../support/recipe_read_fake.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/services/data_export.dart';

/// 5 diary rows, descending by logged_at.
final List<Map<String, dynamic>> _mealRows =
    List.generate(5, (i) {
      return <String, dynamic>{
        'id': '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
        'user_id': 'user-export',
        'logged_at': DateTime.utc(2026, 8, 1 + i, 12).toIso8601String(),
        'meal_name': 'Mahlzeit $i',
        'calories_kcal': 300 + i,
      };
    })..sort(
      (a, b) => (b['logged_at'] as String).compareTo(a['logged_at'] as String),
    );

class _FakePostgrest {
  final List<http.Request> requests = <http.Request>[];
  bool failChatMessages = false;
  int? serverPageLimit;
  bool ignoresCursor = false;
  String? invalidCursorId;
  List<Map<String, dynamic>> _lastPage = [];

  /// A faulty peer repeats a previously delivered row at the page boundary.
  bool wiederholtEineZeile = false;

  http.Client client() => MockClient(_handle);

  Future<http.Response> _handle(http.Request req) async {
    final recipe = emptyRecipeReadResponse(req);
    if (recipe != null) return recipe;
    requests.add(req);
    final path = req.url.path;

    http.Response ok(Object body) {
      final count = body is List ? body.length : 0;
      return http.Response(
        jsonEncode(body),
        200,
        headers: {
          'Content-Type': 'application/json',
          'content-range': '${count == 0 ? '*' : '0-${count - 1}'}/$count',
        },
        request: req,
      );
    }

    if (path.contains('/profiles')) {
      return ok([
        <String, dynamic>{
          'id': 'user-export',
          'display_name': 'Moritz',
          'weight_kg': 81,
          'diet_preference': 'vegetarian',
        },
      ]);
    }
    if (path.contains('/logged_meals')) {
      var selected = _mealRows.toList();
      final cursor = req.url.queryParameters['or'];
      if (cursor != null && !ignoresCursor) {
        final match = RegExp(
          r'^\(logged_at\.lt\.([^,]+),and\(logged_at\.eq\.([^,]+),id\.lt\.([a-f0-9-]+)\)\)$',
        ).firstMatch(cursor)!;
        final at = DateTime.parse(match.group(1)!);
        expect(DateTime.parse(match.group(2)!), at);
        final id = match.group(3)!;
        selected = selected.where((row) {
          final rowTime = DateTime.parse(row['logged_at'] as String);
          return rowTime.isBefore(at) ||
              (rowTime == at && (row['id'] as String).compareTo(id) < 0);
        }).toList();
      }
      // Apply PostgREST pagination: postgrest-dart sends offset/limit as query
      // parameters, falling back to a Range header "items=from-to".
      var from = 0;
      var to = selected.length - 1;
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
      if (serverPageLimit case final int cap) {
        to = to.clamp(from, from + cap - 1);
      }
      if (from >= selected.length) return ok(const <dynamic>[]);
      final slice = selected.sublist(from, (to + 1).clamp(0, selected.length));
      if (wiederholtEineZeile && _lastPage.isNotEmpty) {
        slice.insert(0, _lastPage.last);
      }
      _lastPage = slice.toList();
      if (invalidCursorId case final String id) {
        slice[slice.length - 1] = {...slice.last, 'id': id};
      }
      return ok(slice);
    }
    if (path.contains('/chat_messages')) {
      if (failChatMessages) {
        return http.Response(
          jsonEncode({'message': 'kaputt'}),
          500,
          headers: const {'Content-Type': 'application/json'},
          request: req,
        );
      }
      return ok([
        <String, dynamic>{
          'id': 'msg-1',
          'user_id': 'user-export',
          'role': 'user',
          'content': 'Wie viel Protein brauche ich?',
        },
      ]);
    }
    if (path.contains('/favorite_meals')) {
      return ok([
        <String, dynamic>{
          'favorite_key': 'name:bowl',
          'user_id': 'user-export',
          'payload': <String, dynamic>{'mealName': 'Bowl'},
        },
      ]);
    }
    if (path.endsWith('/ai_provider_user_usage')) {
      expect(req.url.queryParameters['user_id'], 'eq.user-export');
      return ok([
        {'user_id': 'user-export', 'usage_date': '2026-09-15', 'calls': 3},
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

    expect(
      (json['profiles'] as List).single,
      containsPair('diet_preference', 'vegetarian'),
      reason: 'Profil-Stammdaten inkl. Diaetpraeferenz (C7-Luecke)',
    );
    expect(
      json['logged_meals'],
      hasLength(_mealRows.length),
      reason: 'das VOLLSTAENDIGE Tagebuch, nicht das 35-Tage-Fenster',
    );
    expect(
      (json['chat_messages'] as List).single,
      containsPair('content', 'Wie viel Protein brauche ich?'),
    );
    expect(
      (json['favorite_meals'] as List).single,
      containsPair('favorite_key', 'name:bowl'),
    );
    expect(json['ai_provider_user_usage'], [
      {'user_id': 'user-export', 'usage_date': '2026-09-15', 'calls': 3},
    ]);
    for (final tabelle in DataExportService.alleExportTabellen) {
      expect(
        json.containsKey(tabelle),
        isTrue,
        reason: '$tabelle fehlt im Export',
      );
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
    // Each request seeks after the prior final tuple instead of counting
    // mutable offsets. The independent concurrency tests exercise deletion.
    for (var i = 0; i < seiten.length; i++) {
      expect(
        seiten[i].url.queryParameters['limit'],
        '2',
        reason: 'Seite $i fordert genau pageSize Zeilen an',
      );
      expect(seiten[i].url.queryParameters['offset'], isNull);
      expect(seiten[i].url.queryParameters['or'], i == 0 ? isNull : isNotNull);
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
    expect(
      ids.length,
      _mealRows.length,
      reason:
          'ohne den id-Filter stuenden Mahlzeiten doppelt in der '
          'Auskunft und der Empfaenger zaehlt falsch',
    );
    expect(ids.toSet(), _mealRows.map((r) => r['id']).toSet());
  });

  test(
    'ein kleineres Server-Seitenlimit schneidet das Tagebuch nicht ab',
    () async {
      final (service, server) = setup(pageSize: 3);
      server.serverPageLimit = 2;
      final text = await service.buildExportJson();
      final json = jsonDecode(text) as Map<String, dynamic>;

      expect(
        (json['logged_meals'] as List).map((row) => (row as Map)['id']),
        _mealRows.map((row) => row['id']),
      );
      expect(exportUmfangAus(text), ExportUmfang.vollstaendig);
      expect(
        server.requests
            .where((r) => r.url.path.endsWith('/logged_meals'))
            .length,
        4,
        reason:
            'Ein kleineres Serverlimit beendet die Pagination nicht vorzeitig.',
      );
    },
  );

  test('ein Server ohne Seitenfortschritt endet als unvollstaendig', () async {
    final (service, server) = setup();
    server.ignoresCursor = true;
    final text = await service.buildExportJson();
    final json = jsonDecode(text) as Map<String, dynamic>;

    expect(json['unvollstaendig'], contains('logged_meals'));
    expect(json, isNot(contains('logged_meals')));
    expect(exportUmfangAus(text), ExportUmfang.teilweise);
    expect(
      server.requests.where((r) => r.url.path.endsWith('/logged_meals')),
      hasLength(2),
      reason: 'Kein unbegrenztes Nachladen der gleichen privaten Daten.',
    );
  });

  test('ungueltige Cursorwerte gelangen nicht in weitere Filter', () async {
    final (service, server) = setup();
    server.invalidCursorId = 'bad),user_id.eq.other-owner';
    final text = await service.buildExportJson();
    final json = jsonDecode(text) as Map<String, dynamic>;

    expect(json['unvollstaendig'], contains('logged_meals'));
    expect(exportUmfangAus(text), ExportUmfang.teilweise);
    expect(
      server.requests.where((r) => r.url.path.endsWith('/logged_meals')),
      hasLength(1),
    );
  });

  test('eine nicht lesbare Tabelle macht den Export nicht kaputt — sie wird '
      'als unvollstaendig ausgewiesen', () async {
    final (service, server) = setup();
    server.failChatMessages = true;
    final json =
        jsonDecode(await service.buildExportJson()) as Map<String, dynamic>;

    expect(
      json['unvollstaendig'],
      contains('chat_messages'),
      reason: 'ein Fehler darf nicht still eine leere Sektion vortaeuschen',
    );
    expect(
      json['logged_meals'],
      hasLength(_mealRows.length),
      reason: 'die uebrigen Sektionen bleiben vollstaendig',
    );
  });
}
