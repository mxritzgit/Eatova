import 'dart:convert';

import '../support/recipe_read_fake.dart';

import 'package:eatova/src/services/data_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

String mealId(int number) =>
    '00000000-0000-4000-8000-${number.toString().padLeft(12, '0')}';

void main() {
  for (final mutation in ['delete-read-row', 'insert-newest-row']) {
    test('export retains unread diary rows after $mutation', () async {
      final initial = List.generate(
        6,
        (i) => <String, dynamic>{
          'id': mealId(i),
          'user_id': 'owner-a',
          // Ties require the unique ID to participate in the cursor.
          'logged_at': DateTime.utc(2026, 9, 15 - i ~/ 2, 0, 0, 0, 0, 321)
              .toIso8601String().replaceFirst('Z', '+00:00'),
        },
      );
      final rows = initial.map(Map<String, dynamic>.of).toList();
      var pages = 0;
      final client = SupabaseClient(
        'https://export-test.invalid',
        'dummy-anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          final recipe = emptyRecipeReadResponse(request);
          if (recipe != null) return recipe;
          var result = <Map<String, dynamic>>[];
          if (request.url.path.endsWith('/logged_meals')) {
            expect(request.url.queryParameters['user_id'], 'eq.owner-a');
            pages++;
            if (pages == 2) {
              if (mutation == 'delete-read-row') {
                rows.removeWhere((row) => row['id'] == mealId(1));
              } else {
                rows.add({
                  'id': mealId(99),
                  'user_id': 'owner-a',
                  'logged_at': '2026-09-16T00:00:00.000Z',
                });
              }
            }
            var selected = rows.toList()
              ..sort((a, b) {
                final time = (b['logged_at'] as String).compareTo(
                  a['logged_at'] as String,
                );
                return time != 0
                    ? time
                    : (b['id'] as String).compareTo(a['id'] as String);
              });
            final filter = request.url.queryParameters['or'];
            if (filter != null) {
              final match = RegExp(
                r'^\(logged_at\.lt\.([^,]+),and\(logged_at\.eq\.([^,]+),id\.lt\.([a-f0-9-]+)\)\)$',
              ).firstMatch(filter);
              expect(match, isNotNull);
              final date = DateTime.parse(match!.group(1)!);
              expect(DateTime.parse(match.group(2)!), date);
              final id = match.group(3)!;
              selected = selected.where((row) {
                final rowDate = DateTime.parse(row['logged_at'] as String);
                return rowDate.isBefore(date) ||
                    (rowDate == date &&
                        (row['id'] as String).compareTo(id) < 0);
              }).toList();
            }
            final offset = int.parse(
              request.url.queryParameters['offset'] ?? '0',
            );
            final limit = int.parse(request.url.queryParameters['limit']!);
            result = selected.skip(offset).take(limit).toList();
          }
          return http.Response(
            jsonEncode(result),
            200,
            request: request,
            headers: {
              'content-type': 'application/json',
              'content-range': result.isEmpty
                  ? '*/0'
                  : '0-${result.length - 1}/*',
            },
          );
        }),
      );
      addTearDown(client.dispose);
      final export =
          jsonDecode(
                await DataExportService(
                  client,
                  'owner-a',
                  pageSize: 3,
                ).buildExportJson(),
              )
              as Map<String, dynamic>;
      final ids = (export['logged_meals'] as List)
          .map((row) => (row as Map)['id'])
          .toList();
      expect(ids.toSet(), initial.map((row) => row['id']).toSet());
      expect(ids, hasLength(initial.length));
      expect(pages, lessThanOrEqualTo(5));
    });
  }
}
