import 'dart:convert';

import '../models/training_plan.dart';
import '../models/training_session.dart';

// Workouts have no independent IDs. Preserve an unchanged workout across
// reordering, but invalidate changed/removed sources. Duplicate removal is
// ambiguous, so a reduced count conservatively retires the checkpoint.
bool trainingSessionMatchesPlan(
  TrainingSessionSnapshot snapshot,
  TrainingPlan? plan,
) {
  if (plan == null ||
      plan.id != snapshot.plan.id ||
      plan.incarnation != snapshot.plan.incarnation) {
    return false;
  }
  final source = jsonEncode(snapshot.workout.toJson());
  int matches(TrainingPlan value) => value.workouts
      .where((workout) => jsonEncode(workout.toJson()) == source)
      .length;
  final identities = jsonEncode(
    snapshot.workout.exercises.map((e) => e.id).toList(),
  );
  return matches(plan) >= matches(snapshot.plan) &&
      plan.workouts.any(
        (workout) =>
            jsonEncode(workout.toJson()) == source &&
            jsonEncode(workout.exercises.map((e) => e.id).toList()) ==
                identities,
      );
}
