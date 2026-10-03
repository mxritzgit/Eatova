import 'dart:convert';

import 'package:clock/clock.dart';
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
    'invalid plan': (j) => j['plan'] = <dynamic>[],
    'invalid ledger': (j) => j['completed_sets'] = <dynamic, dynamic>{},
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
    'oversized ledger': (j) => j['completed_sets'] = List.filled(201, <dynamic, dynamic>{}),
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

  // Rewritten deliberately (spec §4): rest now follows every completed set
  // except the workout's final set, so a rest between exercises is valid.
  test('rest between exercises is valid, the workout\'s final set has none, '
      'and rep snapshots cannot carry time', () {
    final json = valid()..['set_index'] = 1;
    json['completed_sets'] = [
      {'exercise_index': 0, 'set_index': 0},
      {'exercise_index': 0, 'set_index': 1},
    ];
    json['phase'] = 'rest';
    json['remaining_milliseconds'] = 10000;
    expect(TrainingSessionSnapshot.fromJson(json).toJson(), json);
    final last = valid()
      ..['workout_index'] = 1
      ..['completed_sets'] = [
        {'exercise_index': 0, 'set_index': 0},
      ]
      ..['phase'] = 'rest'
      ..['remaining_milliseconds'] = 10000;
    expect(() => TrainingSessionSnapshot.fromJson(last), throwsFormatException);
    json['exercise_index'] = 1;
    json['set_index'] = 0;
    json['phase'] = 'exercise';
    json['remaining_milliseconds'] = 1;
    expect(() => TrainingSessionSnapshot.fromJson(json), throwsFormatException);
  });

  group('phase_ends_at', () {
    const deadline = '2026-10-03T12:00:15.123456Z';

    Map<String, dynamic> rest() => valid()
      ..['completed_sets'] = [
        {'exercise_index': 0, 'set_index': 0},
      ]
      ..['phase'] = 'rest'
      ..['remaining_milliseconds'] = 15000
      ..['phase_ends_at'] = deadline;

    Map<String, dynamic> canonical(Map<String, dynamic> json) =>
        TrainingSessionSnapshot.fromJson(json).toJson();

    test('a rest deadline roundtrips byte-identically with microseconds', () {
      final json = jsonDecode(jsonEncode(canonical(rest()))) as Map;
      expect(json['phase_ends_at'], deadline);
      expect(
        jsonEncode(TrainingSessionSnapshot.fromJson(json).toJson()),
        jsonEncode(json),
      );
    });

    test('a running timed interval may carry its deadline', () {
      final json = valid()..['phase_ends_at'] = deadline;
      expect(canonical(json)['phase_ends_at'], deadline);
    });

    test('old checkpoints without the key decode unchanged', () {
      final json = valid();
      final decoded = TrainingSessionSnapshot.fromJson(json);
      expect(decoded.phaseEndsAt, isNull);
      expect(decoded.toJson().containsKey('phase_ends_at'), isFalse);
      expect(jsonEncode(decoded.toJson()), jsonEncode(json));
    });

    test('decoding never reads the clock', () {
      final json = canonical(rest());
      String decodeAt(DateTime now) => withClock(
        Clock.fixed(now),
        () => jsonEncode(TrainingSessionSnapshot.fromJson(json).toJson()),
      );
      expect(
        decodeAt(DateTime.utc(2026, 10, 3, 12)),
        decodeAt(DateTime.utc(2026, 10, 4, 18)),
      );
      final decoded = withClock(
        Clock.fixed(DateTime.utc(2026, 10, 9)),
        () => TrainingSessionSnapshot.fromJson(json),
      );
      expect(
        decoded.phaseEndsAt,
        DateTime.utc(2026, 10, 3, 12, 0, 15, 123, 456),
      );
      expect(decoded.remainingMilliseconds, 15000);
    });

    final misplaced = <String, Map<String, dynamic> Function()>{
      'a repetition exercise phase': () => valid()
        ..['exercise_index'] = 1
        ..['skipped_sets'] = [
          {'exercise_index': 0, 'set_index': 0},
          {'exercise_index': 0, 'set_index': 1},
        ]
        ..['remaining_milliseconds'] = 0
        ..['phase_ends_at'] = deadline,
      'review': () => {..._review().toJson(), 'phase_ends_at': deadline},
      'a pending completion': () => {
        ..._review().toJson(),
        'pending_completion_at': '2026-10-03T12:30:00.000Z',
        'pending_completion_note': '',
        'phase_ends_at': deadline,
      },
      'a null value': () => rest()..['phase_ends_at'] = null,
      'an offset timestamp': () =>
          rest()..['phase_ends_at'] = '2026-10-03T14:00:15.123456+02:00',
      'a number': () => rest()..['phase_ends_at'] = 1759492815123,
    };
    for (final entry in misplaced.entries) {
      test('is rejected in ${entry.key}', () {
        expect(
          () => TrainingSessionSnapshot.fromJson(entry.value()),
          throwsFormatException,
        );
      });
    }

    test('the constructor enforces the same rule', () {
      final review = _review();
      expect(
        () => TrainingSessionSnapshot(
          plan: review.plan,
          sessionId: review.sessionId,
          startedAt: review.startedAt,
          workoutIndex: review.workoutIndex,
          exerciseIndex: review.exerciseIndex,
          setIndex: review.setIndex,
          phase: review.phase,
          remainingMilliseconds: 0,
          completedSets: review.completedSets,
          skippedSets: review.skippedSets,
          phaseEndsAt: DateTime.utc(2026, 10, 3, 12),
        ),
        throwsFormatException,
      );
      final restAt = DateTime.utc(2026, 10, 3, 12, 0, 15).toLocal();
      final snapshot = TrainingSessionSnapshot.fromJson(rest());
      final stored = TrainingSessionSnapshot(
        plan: snapshot.plan,
        sessionId: snapshot.sessionId,
        startedAt: snapshot.startedAt,
        workoutIndex: 0,
        exerciseIndex: 0,
        setIndex: 0,
        phase: TrainingSessionPhase.rest,
        remainingMilliseconds: 15000,
        completedSets: snapshot.completedSets,
        phaseEndsAt: restAt,
      );
      expect(stored.phaseEndsAt!.isUtc, isTrue);
      expect(stored.toJson()['phase_ends_at'], '2026-10-03T12:00:15.000Z');
    });
  });
}

/// A review snapshot started at 12:00 UTC (all sets skipped).
TrainingSessionSnapshot _review() =>
    withClock(Clock.fixed(DateTime.utc(2026, 10, 3, 12)), () {
      final controller = TrainingSessionController(
        plan: timerPlan(),
        workoutIndex: 1,
        autoTick: false,
      );
      final snapshot = controller.completion().snapshot;
      controller.dispose();
      return snapshot;
    });
