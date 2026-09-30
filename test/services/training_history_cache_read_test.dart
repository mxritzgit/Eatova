import 'dart:convert';

import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:flutter_test/flutter_test.dart';

// Perf polish 2026-10-01: a large cached training history is decoded and
// validated in a background isolate at hydration. Both paths (inline below
// LocalCache.historyIsolateMinChars, isolate above) must answer exactly as
// before: the entries, or null for anything broken.

const _historyKey = 'eatova.v1.training_history.A';

final _plan = TrainingPlan(
  id: 'big',
  proposal: CoachTrainingProposal(
    title: 'Big plan',
    workouts: [
      for (var w = 0; w < 3; w++)
        TrainingWorkout(
          title: 'Workout $w',
          exercises: [
            for (var e = 0; e < 6; e++)
              TrainingExercise(
                id: 'w$w-e$e',
                name: 'Exercise $w/$e',
                sets: 4,
                reps: 8,
                restSeconds: 90,
              ),
          ],
        ),
    ],
  ),
);

TrainingHistoryEntry _entry(int i) {
  final start = DateTime.utc(2026, 1, 1).add(Duration(days: i));
  final workout = _plan.workouts[i % 3];
  final references = [
    for (var e = 0; e < workout.exercises.length; e++)
      for (var s = 0; s < 4; s++)
        TrainingSetReference(exerciseIndex: e, setIndex: s),
  ];
  return TrainingHistoryEntry(
    snapshot: TrainingSessionSnapshot(
      plan: _plan,
      sessionId: '00000000-0000-4000-8000-${'$i'.padLeft(12, '0')}',
      startedAt: start,
      actualSets: [
        for (final reference in references)
          TrainingSetActual(
            reference: reference,
            completedAt: start,
            weightKg: 40.0 + i % 30,
            reps: 8,
          ),
      ],
      workoutIndex: i % 3,
      exerciseIndex: workout.exercises.length - 1,
      setIndex: 3,
      phase: TrainingSessionPhase.review,
      remainingMilliseconds: 0,
      completedSets: references,
    ),
    finishedAt: start.add(const Duration(minutes: 45)),
  );
}

String _rows(List<TrainingHistoryEntry>? entries) =>
    jsonEncode([for (final entry in entries ?? const []) entry.toRow()]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final count in [3, 80]) {
    test('Historie mit $count Einheiten liest unveraendert', () async {
      final memory = InMemoryKeyValueStore();
      final cache = LocalCache(memory, 'A');
      final entries = [for (var i = 0; i < count; i++) _entry(i)];
      await cache.writeTrainingHistory(entries);
      await cache.flush();
      final raw = (await memory.getString(_historyKey))!;
      // The two sizes cover both paths.
      expect(
        raw.length >= LocalCache.historyIsolateMinChars,
        count == 80,
        reason: '${raw.length} chars',
      );
      final read = await cache.readTrainingHistory();
      expect(read, hasLength(count));
      expect(_rows(read), _rows(entries));
      expect(() => (read! as List).add(entries.first), throwsUnsupportedError);
    });
  }

  test('Grosse, kaputte Historie ergibt weiterhin null', () async {
    final memory = InMemoryKeyValueStore();
    final cache = LocalCache(memory, 'A');
    final rows = [for (var i = 0; i < 80; i++) _entry(i).toRow()];

    Future<List<TrainingHistoryEntry>?> readWith(Object json) async {
      await memory.setString(_historyKey, jsonEncode(json));
      final raw = (await memory.getString(_historyKey))!;
      expect(
        raw.length,
        greaterThanOrEqualTo(LocalCache.historyIsolateMinChars),
      );
      return cache.readTrainingHistory();
    }

    // One invalid row, a duplicate id, a non-list and broken JSON.
    expect(
      await readWith({
        'items': [
          ...rows,
          {'id': 'x', 'session': 'kaputt'},
        ],
      }),
      isNull,
    );
    expect(
      await readWith({
        'items': [...rows, rows.first],
      }),
      isNull,
    );
    expect(await readWith({'items': 'x' * 300000}), isNull);
    await memory.setString(_historyKey, '${jsonEncode({'items': rows})}}}');
    expect(await cache.readTrainingHistory(), isNull);
  });
}
