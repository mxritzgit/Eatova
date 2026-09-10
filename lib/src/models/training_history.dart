import 'training_limits.dart';
import 'training_session.dart';

/// The player can leave an obsolete source without claiming a saved workout.
final class TrainingCompletionSourceRetired implements Exception {
  const TrainingCompletionSourceRetired();
}

/// An immutable completed workout, independent of the source plan's lifetime.
final class TrainingHistoryEntry {
  TrainingHistoryEntry({
    required this.snapshot,
    required DateTime finishedAt,
    String note = '',
  }) : finishedAt = finishedAt.toUtc(),
       note = TrainingJson.text(note, TrainingLimits.notesMaxLength) {
    if (snapshot.phase != TrainingSessionPhase.review ||
        this.finishedAt.isBefore(snapshot.startedAt) ||
        snapshot.actualSets.length != snapshot.completedSets.length) {
      throw const FormatException('Incomplete training history');
    }
    for (final actual in snapshot.actualSets) {
      final exercise =
          snapshot.workout.exercises[actual.reference.exerciseIndex];
      if ((!exercise.isTimed && actual.reps == null) ||
          (exercise.isTimed && actual.reps != null) ||
          actual.completedAt.isAfter(this.finishedAt)) {
        throw const FormatException('Invalid completed training values');
      }
    }
  }

  final TrainingSessionSnapshot snapshot;
  final DateTime finishedAt;
  final String note;
  String get id => snapshot.sessionId;

  Map<String, dynamic> toRow() => {
    'id': id,
    'finished_at': finishedAt.toIso8601String(),
    'session': {'snapshot': snapshot.toJson(), 'note': note},
  };

  factory TrainingHistoryEntry.fromRow(Map<dynamic, dynamic> row) {
    final session = row['session'];
    if (session is! Map || session['snapshot'] is! Map) {
      throw const FormatException('Invalid training history');
    }
    TrainingJson.requireKeys(session, const {'snapshot', 'note'});
    final result = TrainingHistoryEntry(
      snapshot: TrainingSessionSnapshot.fromJson(session['snapshot'] as Map),
      finishedAt: trainingTimestamp(row['finished_at']),
      note: TrainingJson.text(session['note'], TrainingLimits.notesMaxLength),
    );
    if (row['id'] != result.id) {
      throw const FormatException('Invalid history ID');
    }
    return result;
  }
}

/// Identity is plan-scoped; identical names and copied plans never collide.
List<TrainingSetActual> lastTrainingPerformance(
  List<TrainingHistoryEntry> history,
  String planId,
  String exerciseId, {
  required bool isTimed,
}) {
  final sorted = [...history]
    ..sort((a, b) => b.finishedAt.compareTo(a.finishedAt));
  for (final entry in sorted) {
    if (entry.snapshot.plan.id != planId) continue;
    final exercises = entry.snapshot.workout.exercises;
    final index = exercises.indexWhere(
      (e) => e.id == exerciseId && e.isTimed == isTimed,
    );
    if (index < 0) continue;
    final sets =
        entry.snapshot.actualSets
            .where((a) => a.reference.exerciseIndex == index)
            .toList()
          ..sort(
            (a, b) => a.reference.setIndex.compareTo(b.reference.setIndex),
          );
    if (sets.isNotEmpty) return List.unmodifiable(sets);
  }
  return const [];
}
