import 'training_limits.dart';
import 'training_log.dart';
import 'training_session.dart';

/// The player can leave an obsolete source without claiming a saved workout.
final class TrainingCompletionSourceRetired implements Exception {
  const TrainingCompletionSourceRetired();
}

/// The server has permanently deleted this session on another device.
final class TrainingCompletionDeleted implements Exception {
  const TrainingCompletionDeleted();
}

/// A plan-attached log waits while a workout session or its recovery exists.
final class TrainingLogBlockedBySession implements Exception {
  const TrainingLogBlockedBySession();
}

/// An immutable completed workout, independent of the source plan's lifetime.
///
/// Mirrors the server CHECK `is_valid_training_history`: no local-only keys,
/// no drafts and a lowercase session UUID (the row id's text form).
final class TrainingHistoryEntry {
  TrainingHistoryEntry({
    required this.snapshot,
    required DateTime finishedAt,
    String note = '',
  }) : finishedAt = finishedAt.toUtc(),
       note = TrainingJson.text(note, TrainingLimits.notesMaxLength) {
    if (snapshot.recoveryNote != null ||
        snapshot.pendingCompletionAt != null ||
        snapshot.phaseEndsAt != null ||
        snapshot.draftReps != null ||
        snapshot.draftWeightKg != null ||
        snapshot.sessionId != snapshot.sessionId.toLowerCase() ||
        snapshot.phase != TrainingSessionPhase.review ||
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

  TrainingSessionSnapshot recoverySnapshot() =>
      TrainingSessionSnapshot.fromJson({
        ...snapshot.toJson(),
        'pending_completion_at': finishedAt.toIso8601String(),
        'pending_completion_note': note,
      });

  factory TrainingHistoryEntry.fromRecovery(TrainingSessionSnapshot recovery) {
    final json = recovery.toJson()
      ..remove('pending_completion_at')
      ..remove('pending_completion_note');
    final finishedAt = recovery.pendingCompletionAt;
    if (finishedAt == null) {
      throw const FormatException('No pending completion');
    }
    return TrainingHistoryEntry(
      snapshot: TrainingSessionSnapshot.fromJson(json),
      finishedAt: finishedAt,
      note: recovery.pendingCompletionNote!,
    );
  }

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
      finishedAt: trainingTimestamp(row['finished_at'], allowOffset: true),
      note: TrainingJson.text(session['note'], TrainingLimits.notesMaxLength),
    );
    if (row['id'] != result.id) {
      throw const FormatException('Invalid history ID');
    }
    return result;
  }
}

/// Identity is plan-scoped; identical names and copied plans never collide.
///
/// The sets of the newest (by finish time) session of [planId] that performed
/// [exerciseId], ordered by set index; empty when there is none. One linear
/// pass without copying or sorting [history]: the Training tab asks once per
/// planned exercise and the player on every timer tick (10 Hz), with up to
/// `TrainingHistorySync.limit` entries. Among sessions finished at the same
/// instant the one listed first wins.
List<TrainingSetActual> lastTrainingPerformance(
  List<TrainingHistoryEntry> history,
  String planId,
  String exerciseId, {
  required bool isTimed,
}) {
  TrainingHistoryEntry? newest;
  var newestIndex = -1;
  for (final entry in history) {
    if (entry.snapshot.plan.id != planId) continue;
    if (newest != null && !entry.finishedAt.isAfter(newest.finishedAt)) {
      continue;
    }
    final index = entry.snapshot.workout.exercises.indexWhere(
      (e) => e.id == exerciseId && e.isTimed == isTimed,
    );
    if (index < 0 ||
        !entry.snapshot.actualSets.any(
          (a) => a.reference.exerciseIndex == index,
        )) {
      continue;
    }
    newest = entry;
    newestIndex = index;
  }
  return _performedSets(newest, newestIndex);
}

/// The cross-plan "Last time" fallback: the sets of the newest session outside
/// [excludePlanId] that performed an exercise of the same kind whose
/// [normalizeExerciseName] matches [exerciseName], ordered by set index; empty
/// when there is none. Within a session the first such exercise with actual
/// values wins; among equal finish times the one listed first wins.
List<TrainingSetActual> lastTrainingPerformanceByName(
  List<TrainingHistoryEntry> history, {
  required String excludePlanId,
  required String exerciseName,
  required bool isTimed,
}) {
  final name = normalizeExerciseName(exerciseName);
  TrainingHistoryEntry? newest;
  var newestIndex = -1;
  for (final entry in history) {
    if (entry.snapshot.plan.id == excludePlanId) continue;
    if (newest != null && !entry.finishedAt.isAfter(newest.finishedAt)) {
      continue;
    }
    final exercises = entry.snapshot.workout.exercises;
    for (var index = 0; index < exercises.length; index++) {
      if (exercises[index].isTimed == isTimed &&
          normalizeExerciseName(exercises[index].name) == name &&
          entry.snapshot.actualSets.any(
            (a) => a.reference.exerciseIndex == index,
          )) {
        newest = entry;
        newestIndex = index;
        break;
      }
    }
  }
  return _performedSets(newest, newestIndex);
}

List<TrainingSetActual> _performedSets(
  TrainingHistoryEntry? entry,
  int exerciseIndex,
) {
  if (entry == null) return const [];
  final sets =
      entry.snapshot.actualSets
          .where((a) => a.reference.exerciseIndex == exerciseIndex)
          .toList()
        ..sort((a, b) => a.reference.setIndex.compareTo(b.reference.setIndex));
  return List.unmodifiable(sets);
}
