import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/coach_workout_log.dart';

// Spec C3: one fixture file is the server truth for the `/log` wire schema.
// The TS validator (workout_log_test.ts), the SQL CHECK
// (coach_workout_log_rls.sql) and this Dart parser read the same cases, so a
// payload the server stores can never be one the app rejects, and the reverse.

const String _fixture =
    'supabase/functions/coach-chat/fixtures/workout_log_cases.json';

Map<String, dynamic> _cases() =>
    jsonDecode(File(_fixture).readAsStringSync()) as Map<String, dynamic>;

/// A stored assistant row carrying [workoutLog], as the history select
/// returns it.
ChatMessage _row(Object? workoutLog) => ChatMessage.fromRow({
  'id': '0b6f2a4e-8c1d-4f7a-9e3b-5d2c1a0f9e8d',
  'role': 'assistant',
  'content': 'Workout erkannt.',
  'refusal': false,
  'created_at': '2026-10-03T08:00:00Z',
  'recipe': null,
  'training_plan': null,
  'workout_log': workoutLog,
});

void main() {
  final cases = _cases();
  final valid = cases['valid'] as List<dynamic>;
  final invalid = cases['invalid'] as List<dynamic>;

  test('the shared fixture carries both directions', () {
    expect(valid, isNotEmpty);
    expect(invalid, isNotEmpty);
  });

  for (var i = 0; i < valid.length; i++) {
    final value = valid[i] as Map<String, dynamic>;
    test(
      'valid case $i (${value['title']}) parses and writes back unchanged',
      () {
        final log = CoachWorkoutLog.fromJson(value);
        expect(log, isNotNull);
        expect(log!.toJson(), value);
        // A history row with it rebuilds the card.
        expect(_row(value).workoutLogProposal?.toJson(), value);
      },
    );
  }

  for (final entry in invalid) {
    final reason = (entry as Map<String, dynamic>)['reason'] as String;
    final value = entry['value'];
    test('invalid case "$reason" never becomes a proposal', () {
      if (value is Map) expect(CoachWorkoutLog.fromJson(value), isNull);
      // Every shape, maps or not, arrives through a history row.
      final message = _row(value);
      expect(message.workoutLogProposal, isNull);
      expect(message.content, 'Workout erkannt.');
    });
  }
}
