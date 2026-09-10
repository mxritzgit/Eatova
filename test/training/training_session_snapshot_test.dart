import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/services/training_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'training_timer_fixtures.dart';

void main() {
  Map<String, dynamic> valid() {
    final controller = TrainingSessionController(
      plan: timerPlan(),
      autoTick: false,
    );
    final json = controller.snapshot().toJson();
    controller.dispose();
    return json;
  }

  test('strict wire roundtrip accepts lossless numeric integers', () {
    final json = valid()..['schema_version'] = 2.0;
    json['remaining_milliseconds'] = 30000.0;
    expect(TrainingSessionSnapshot.fromJson(json).toJson(), json);
  });

  final invalid = <String, void Function(Map<String, dynamic>)>{
    'running status': (j) => j['status'] = 'running',
    'unknown schema': (j) => j['schema_version'] = 3,
    'unknown field': (j) => j['owner'] = 'someone',
    'missing field': (j) => j.remove('skipped_sets'),
    'fraction': (j) => j['remaining_milliseconds'] = .5,
    'numeric string': (j) => j['set_index'] = '0',
    'nonfinite': (j) => j['remaining_milliseconds'] = double.infinity,
    'negative time': (j) => j['remaining_milliseconds'] = -1,
    'over prescription': (j) => j['remaining_milliseconds'] = 30001,
    'invalid workout': (j) => j['workout_index'] = 2,
    'invalid exercise': (j) => j['exercise_index'] = 2,
    'invalid set': (j) => j['set_index'] = 2,
    'unknown phase': (j) => j['phase'] = 'warmup',
    'invalid plan': (j) => j['plan'] = [],
    'invalid ledger': (j) => j['completed_sets'] = {},
    'invalid ledger entry': (j) => j['completed_sets'] = [false],
    'unknown ledger key': (j) => j['completed_sets'] = [
      {'exercise_index': 0, 'set_index': 0, 'calories': 99},
    ],
    'future completion': (j) => j['completed_sets'] = [
      {'exercise_index': 1, 'set_index': 1},
    ],
    'current exercise completion': (j) => j['completed_sets'] = [
      {'exercise_index': 0, 'set_index': 0},
    ],
    'incomplete rest': (j) {
      j['phase'] = 'rest';
      j['remaining_milliseconds'] = 15000;
    },
    'fabricated review': (j) {
      j['phase'] = 'review';
      j['remaining_milliseconds'] = 0;
    },
    'progress gap': (j) => j['set_index'] = 1,
    'oversized ledger': (j) => j['completed_sets'] = List.filled(201, {}),
  };
  for (final entry in invalid.entries) {
    test('rejects ${entry.key} with sanitized FormatException', () {
      final json = valid();
      entry.value(json);
      expect(
        () => TrainingSessionSnapshot.fromJson(json),
        throwsFormatException,
      );
    });
  }

  test('duplicate and completed/skipped overlap are rejected', () {
    final entry = {'exercise_index': 0, 'set_index': 0};
    final json = valid()..['set_index'] = 1;
    json['completed_sets'] = [entry, entry];
    expect(() => TrainingSessionSnapshot.fromJson(json), throwsFormatException);
    json['completed_sets'] = [entry];
    json['skipped_sets'] = [entry];
    expect(() => TrainingSessionSnapshot.fromJson(json), throwsFormatException);
  });

  test('final set cannot have rest, and rep snapshots cannot carry time', () {
    final json = valid()..['set_index'] = 1;
    json['completed_sets'] = [
      {'exercise_index': 0, 'set_index': 0},
      {'exercise_index': 0, 'set_index': 1},
    ];
    json['phase'] = 'rest';
    json['remaining_milliseconds'] = 10000;
    expect(() => TrainingSessionSnapshot.fromJson(json), throwsFormatException);
    json['exercise_index'] = 1;
    json['set_index'] = 0;
    json['phase'] = 'exercise';
    json['remaining_milliseconds'] = 1;
    expect(() => TrainingSessionSnapshot.fromJson(json), throwsFormatException);
  });
}
