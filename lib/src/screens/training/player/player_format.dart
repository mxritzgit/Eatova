import '../../../l10n/l10n.dart';
import '../../../models/training_plan.dart';
import '../../../models/training_session.dart';
import '../training_actual_fields.dart' show formatTrainingWeight;

/// Whole seconds as the player shows them: rounded up, never negative.
int ceilSeconds(Duration value) =>
    value.isNegative ? 0 : (value.inMilliseconds / 1000).ceil();

/// "01:30" for countdowns; hours appear only when needed ("1:02:03").
String formatClock(int seconds) {
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final rest = (seconds % 60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$rest';
  }
  return '${minutes.toString().padLeft(2, '0')}:$rest';
}

/// The plan line of an exercise: "3 × 8 reps · 90s rest".
String planSummary(TrainingExercise exercise, AppLocalizations l) {
  final work = exercise.isTimed
      ? l.trainingPageSetsTime(exercise.sets, exercise.durationSeconds!)
      : l.trainingPageSetsReps(exercise.sets, exercise.reps!);
  return exercise.restSeconds == 0
      ? work
      : '$work · ${l.trainingPageRestSeconds(exercise.restSeconds)}';
}

/// A done exercise collapsed to one line: "3/3 sets · 10/8/8 · 80–90 kg".
String doneSummary(
  TrainingExercise exercise,
  List<TrainingSetActual> sets,
  AppLocalizations l,
) {
  final parts = [l.trainingTimerSetsDone(sets.length, exercise.sets)];
  if (!exercise.isTimed && sets.isNotEmpty) {
    parts.add(sets.map((set) => set.reps?.toString() ?? '–').join('/'));
  }
  final weights = [
    for (final set in sets)
      if (set.weightKg != null) set.weightKg!,
  ];
  if (weights.isNotEmpty) {
    weights.sort();
    final low = formatTrainingWeight(weights.first, l);
    final high = formatTrainingWeight(weights.last, l);
    parts.add(l.trainingHistoryWeightValue(low == high ? low : '$low–$high'));
  }
  return parts.join(' · ');
}

/// The value a Last-time cell shows: "8 × 60 kg", "8", "60 kg" or a timed
/// interval's length.
String lastTimeValue(
  TrainingSetActual set,
  TrainingExercise exercise,
  AppLocalizations l,
) {
  final weight = set.weightKg == null
      ? null
      : l.trainingHistoryWeightValue(formatTrainingWeight(set.weightKg!, l));
  if (exercise.isTimed) {
    return weight ?? formatClock(exercise.durationSeconds ?? 0);
  }
  final reps = '${set.reps ?? '–'}';
  return weight == null ? reps : '$reps × $weight';
}
