import 'dart:convert';

import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/atomic_store_faults.dart';
import '../training/training_timer_fixtures.dart';

// Perf polish 2026-10-01: a workout checkpoint (every 5 s in the player)
// declares the plan library, heads, history and deletions read-only, so the
// atomic mutation no longer re-encodes the whole history just to diff it.
// "Read-only" must not weaken the checkpoint: those slots are still read for
// the completion check and still guarded by their versions.

const _historyKey = 'eatova.v1.training_history.A';
const _sessionKey = 'eatova.v1.training_session.A';

TrainingHistoryEntry _finished(String sessionId) {
  final start = DateTime.utc(2026, 9, 30, 7);
  return TrainingHistoryEntry(
    snapshot: TrainingSessionSnapshot(
      plan: timerPlan(),
      sessionId: sessionId,
      startedAt: start,
      actualSets: [
        TrainingSetActual(
          reference: const TrainingSetReference(exerciseIndex: 0, setIndex: 0),
          completedAt: start.add(const Duration(minutes: 1)),
          reps: 8,
        ),
      ],
      workoutIndex: 1,
      exerciseIndex: 0,
      setIndex: 0,
      phase: TrainingSessionPhase.review,
      remainingMilliseconds: 0,
      completedSets: const [
        TrainingSetReference(exerciseIndex: 0, setIndex: 0),
      ],
    ),
    finishedAt: start.add(const Duration(minutes: 20)),
  );
}

TrainingSessionSnapshot _checkpoint(String sessionId, int remaining) =>
    TrainingSessionSnapshot(
      plan: timerPlan(),
      sessionId: sessionId,
      startedAt: DateTime.utc(2026, 10, 1, 7),
      workoutIndex: 0,
      exerciseIndex: 0,
      setIndex: 0,
      phase: TrainingSessionPhase.exercise,
      remainingMilliseconds: remaining,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const running = '00000000-0000-4000-8000-000000000010';
  const done = '00000000-0000-4000-8000-000000000011';

  test('Checkpoint schreibt nur die Sitzung, die Historie bleibt unberuehrt '
      'und versioniert', () async {
    final memory = InMemoryKeyValueStore();
    final faults = AtomicStoreFaults(memory);
    final cache = LocalCache(faults, 'A');
    await cache.writeTrainingHistory([_finished(done)]);
    await cache.settle();
    final storedHistory = await memory.getString(_historyKey);
    expect(storedHistory, isNotNull);

    final written = <String>[];
    faults.beforeWrite = (changes) async => written.addAll(changes.keys);
    final first = _checkpoint(running, 20000);
    await cache.commitTrainingCheckpoint(first, expectedSnapshot: null);
    expect(written, contains(_sessionKey));
    expect(written, isNot(contains(_historyKey)));
    expect(await memory.getString(_historyKey), storedHistory);

    // Another writer (e.g. background sync) changes the history between the
    // checkpoint's read and its write: the version guard still rejects it.
    faults.beforeWrite = (changes) async {
      faults.beforeWrite = null;
      await memory.writeBatch({
        _historyKey: jsonEncode({'items': <Object>[]}),
      });
    };
    await expectLater(
      cache.commitTrainingCheckpoint(
        _checkpoint(running, 10000),
        expectedSnapshot: first,
      ),
      throwsA(isA<KeyValueConflict>()),
    );
    expect((await cache.readTrainingSession())!.toJson(), first.toJson());
  });

  test('Checkpoint liest die Historie weiterhin: eine dort abgeschlossene '
      'Einheit wird nicht wiederbelebt', () async {
    final cache = LocalCache(InMemoryKeyValueStore(), 'A');
    await cache.writeTrainingHistory([_finished(done)]);
    await cache.settle();
    await expectLater(
      cache.commitTrainingCheckpoint(
        _checkpoint(done, 20000),
        expectedSnapshot: null,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Training completion retired',
        ),
      ),
    );
    expect(await cache.readTrainingSession(), isNull);
  });
}
