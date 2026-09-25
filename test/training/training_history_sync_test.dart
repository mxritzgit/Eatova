import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/services/training_history_sync.dart';
import 'package:eatova/src/services/training_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'training_timer_fixtures.dart';

void main() {
  test(
    'deleting a fetched row during pagination cannot hide an older session',
    () async {
      final finished = DateTime.utc(2026, 9, 25, 12, 0, 0, 123, 456);
      final template = withClock(Clock.fixed(finished), () {
        final controller = TrainingSessionController(
          plan: timerPlan(),
          workoutIndex: 1,
          autoTick: false,
        );
        controller.start();
        controller.completeCurrentSet();
        final row = controller
            .completion(finishedAt: finished.add(const Duration(minutes: 1)))
            .toRow();
        controller.dispose();
        return row;
      });
      final rows = List.generate(501, (index) {
        final id =
            '00000000-0000-4000-8000-${(501 - index).toString().padLeft(12, '0')}';
        final row = jsonDecode(jsonEncode(template)) as Map<String, dynamic>;
        row['id'] = id;
        row['finished_at'] = finished
            .add(Duration(minutes: 501 - (index == 500 ? 499 : index)))
            .toIso8601String();
        (row['session'] as Map)['snapshot']['session_id'] = id;
        return row;
      });
      var requests = 0;
      final client = SupabaseClient(
        'https://example.invalid',
        'fixture',
        httpClient: MockClient((request) async {
          requests++;
          expect(request.method, 'GET');
          expect(request.url.queryParameters['user_id'], 'eq.A');
          expect(
            request.url.queryParameters['order'],
            'finished_at.desc.nullslast,id.desc.nullslast',
          );
          final offset = int.parse(
            request.url.queryParameters['offset'] ?? '0',
          );
          final limit = int.parse(request.url.queryParameters['limit']!);
          expect(limit, 500);
          var candidates = rows;
          final cursor = request.url.queryParameters['or'];
          if (cursor != null) {
            expect(offset, 0);
            final match = RegExp(
              r'^\(finished_at\.lt\.([^,]+),and\(finished_at\.eq\.([^,]+),id\.lt\.([^\)]+)\)\)$',
            ).firstMatch(cursor);
            expect(
              match,
              isNotNull,
              reason: 'history must use a stable cursor',
            );
            final at = DateTime.parse(match!.group(1)!);
            expect(DateTime.parse(match.group(2)!), at);
            expect(at.microsecond, 456);
            final id = match.group(3)!;
            candidates = rows.where((row) {
              final time = DateTime.parse(row['finished_at'] as String);
              return time.isBefore(at) ||
                  (time == at && (row['id'] as String).compareTo(id) < 0);
            }).toList();
          }
          final page = candidates.skip(offset).take(limit).toList();
          if (requests == 1) rows.removeAt(0);
          return http.Response(
            jsonEncode(page),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);

      final history = await TrainingHistorySync(client, 'A').load();
      expect(requests, 2);
      expect(history, hasLength(501));
      expect(history.map((entry) => entry.id).toSet(), hasLength(501));
      expect(history.last.id, rows.last['id']);
    },
  );
}
