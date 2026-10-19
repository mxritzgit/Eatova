// TrendService pages its six-month window (2026-10-18). PostgREST caps every
// answer at db-max-rows, 1000 live, so the former single limit(2500) came
// back with at most 1000 rows and dropped whole days without a sign. The
// fake below caps like the live server; the window must still be complete.
// Since 2026-10-19 only an empty page ends the read, so a server whose cap
// is lowered below the page size cannot truncate the window either.

import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:eatova/src/services/trend_service.dart';

final DateTime _now = DateTime(2026, 10, 18, 12);

/// One row per entry, [count] of them spread over 150 days, ids ascending.
List<Map<String, Object>> _rows(int count) => [
  for (var i = 0; i < count; i++)
    {
      'id': 'id-${i.toString().padLeft(5, '0')}',
      'local_day':
          '2026-${(i % 150 < 18 ? 10 : 5).toString().padLeft(2, '0')}-'
          '${((i % 150) % 28 + 1).toString().padLeft(2, '0')}',
      'logged_at': '2026-06-01T08:00:00Z',
      'calories_kcal': 100,
      'protein_g': 5,
      'carbs_g': 10,
      'fat_g': 3,
    },
];

/// Serves [rows] like PostgREST: filters `id=gt.`, sorts by id, and never
/// answers with more than [maxRows], whatever the request's limit says.
({SupabaseClient client, List<Uri> requests}) _server(
  List<Map<String, Object>> rows, {
  int maxRows = 1000,
  List<Map<String, Object>> Function(int page)? override,
}) {
  final requests = <Uri>[];
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: MockClient((req) async {
      requests.add(req.url);
      final page = requests.length - 1;
      var body = override?.call(page);
      if (body == null) {
        final after = req.url.queryParameters['id']?.replaceFirst('gt.', '');
        final limit = int.parse(req.url.queryParameters['limit'] ?? '100000');
        body = [
          for (final row in rows)
            if (after == null || (row['id'] as String).compareTo(after) > 0)
              row,
        ].take(limit < maxRows ? limit : maxRows).toList();
      }
      return http.Response(
        jsonEncode(body),
        200,
        headers: const {'Content-Type': 'application/json'},
        request: req,
      );
    }),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  return (client: client, requests: requests);
}

Future<List<TrendDayTotals>> _load(SupabaseClient client) {
  final cache = TrendTotalsCache();
  addTearDown(cache.dispose);
  return withClock(
    Clock.fixed(_now),
    () => TrendService(client, 'u1', cache: cache).loadDailyTotals(),
  );
}

int _kcal(List<TrendDayTotals> totals) =>
    totals.fold(0, (sum, day) => sum + day.kcal);

void main() {
  test('Fenster und Seiten: sechs Monate, Seiten so gross wie db-max-rows', () {
    expect(TrendService.trendWindowDays, 182);
    expect(TrendService.trendPageRows, 1000);
    expect(
      TrendService.trendMaxRows,
      TrendService.trendPageRows * TrendService.trendMaxPages,
    );
    expect(
      TrendService.trendMaxRows / TrendService.trendWindowDays,
      greaterThanOrEqualTo(50),
    );
  });

  test('2.500 Zeilen kommen ueber drei Seiten vollstaendig an', () async {
    final server = _server(_rows(2500));
    final totals = await _load(server.client);

    expect(_kcal(totals), 2500 * 100);
    // Three pages with rows, then the empty page that ends the read.
    expect(server.requests, hasLength(4));
    final first = server.requests.first.queryParameters;
    expect(first['limit'], '1000');
    expect(first['order'], startsWith('id.asc'));
    expect(first['logged_at'], startsWith('gte.'));
    expect(first['user_id'], 'eq.u1');
    expect(first.containsKey('id'), isFalse);
    expect(server.requests[1].queryParameters['id'], 'gt.id-00999');
    expect(server.requests[2].queryParameters['id'], 'gt.id-01999');
    expect(server.requests[3].queryParameters['id'], 'gt.id-02499');
  });

  test('eine kurze Seite endet erst mit einer leeren Seite', () async {
    final server = _server(_rows(40));
    final totals = await _load(server.client);
    expect(_kcal(totals), 40 * 100);
    expect(server.requests, hasLength(2));
    expect(server.requests[1].queryParameters['id'], 'gt.id-00039');
  });

  // A lowered db-max-rows answers short pages while rows remain; stopping
  // at the first short page brought the silent truncation back.
  test('ein Server mit max_rows 500 liefert trotzdem alle Zeilen', () async {
    final server = _server(_rows(2500), maxRows: 500);
    final totals = await _load(server.client);
    expect(_kcal(totals), 2500 * 100);
    expect(server.requests, hasLength(6));
    expect(server.requests[1].queryParameters['id'], 'gt.id-00499');
  });

  test('genau eine volle Seite fragt einmal leer nach', () async {
    final server = _server(_rows(1000));
    final totals = await _load(server.client);
    expect(_kcal(totals), 1000 * 100);
    expect(server.requests, hasLength(2));
  });

  test(
    'eine nicht aufsteigende Cursor-Folge bricht ab statt zu wiederholen',
    () async {
      final page = _rows(1000);
      final server = _server(
        const [],
        // The server keeps answering the same full page.
        override: (_) => page,
      );
      await expectLater(_load(server.client), throwsStateError);
      expect(server.requests, hasLength(2));
    },
  );

  test(
    'ueber der Seitengrenze scheitert das Laden statt Teilsummen zu zeigen',
    () async {
      final server = _server(_rows(TrendService.trendMaxRows + 1));
      await expectLater(_load(server.client), throwsStateError);
      expect(server.requests, hasLength(TrendService.trendMaxPages + 1));
    },
  );

  test('genau an der Seitengrenze endet das Laden mit der leeren Seite', () async {
    final server = _server(_rows(TrendService.trendMaxRows));
    final totals = await _load(server.client);
    expect(_kcal(totals), TrendService.trendMaxRows * 100);
    expect(server.requests, hasLength(TrendService.trendMaxPages + 1));
  });
}
