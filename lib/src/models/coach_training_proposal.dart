import 'training_limits.dart';
import 'training_plan.dart';

/// A Coach draft. Converting it to a saved plan requires the caller's action.
final class CoachTrainingProposal {
  CoachTrainingProposal({
    required String title,
    String description = '',
    String goal = '',
    required List<TrainingWorkout> workouts,
  }) : title = TrainingJson.text(
         title,
         TrainingLimits.titleMaxLength,
         required: true,
       ),
       description = TrainingJson.text(
         description,
         TrainingLimits.descriptionMaxLength,
       ),
       goal = TrainingJson.text(goal, TrainingLimits.goalMaxLength),
       workouts = List.unmodifiable(workouts) {
    if (workouts.isEmpty || workouts.length > TrainingLimits.workoutsMax) {
      throw const FormatException('Invalid training workout count');
    }
    final characters =
        title.runes.length +
        description.runes.length +
        goal.runes.length +
        workouts.fold<int>(
          0,
          (count, workout) =>
              count +
              workout.title.runes.length +
              workout.description.runes.length +
              workout.exercises.fold<int>(
                0,
                (count, exercise) =>
                    count +
                    exercise.name.runes.length +
                    exercise.notes.runes.length,
              ),
        );
    if (characters > TrainingLimits.combinedTextMaxLength) {
      throw const FormatException('Training text exceeds the combined limit');
    }
  }

  final String title;
  final String description;
  final String goal;
  final List<TrainingWorkout> workouts;

  int get estimatedDurationSeconds => workouts.fold(
    0,
    (seconds, workout) => seconds + workout.estimatedDurationSeconds,
  );

  /// Malformed provider output or history never becomes an adoptable draft.
  static CoachTrainingProposal? fromJson(Map<dynamic, dynamic> json) {
    try {
      TrainingJson.requireKeys(json, const {
        'schema_version',
        'title',
        'description',
        'goal',
        'workouts',
      });
      TrainingJson.integer(
        json['schema_version'],
        TrainingLimits.schemaVersion,
        TrainingLimits.schemaVersion,
      );
      final rawWorkouts = json['workouts'];
      if (rawWorkouts is! List ||
          rawWorkouts.isEmpty ||
          rawWorkouts.length > TrainingLimits.workoutsMax) {
        return null;
      }
      return CoachTrainingProposal(
        title: TrainingJson.text(
          json['title'],
          TrainingLimits.titleMaxLength,
          required: true,
        ),
        description: TrainingJson.text(
          json['description'],
          TrainingLimits.descriptionMaxLength,
        ),
        goal: TrainingJson.text(json['goal'], TrainingLimits.goalMaxLength),
        workouts: rawWorkouts
            .map((raw) {
              if (raw is! Map) {
                throw const FormatException('Invalid training workout');
              }
              return TrainingWorkout.fromJson(raw);
            })
            .toList(growable: false),
      );
    } on FormatException {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'schema_version': TrainingLimits.schemaVersion,
    'title': title,
    'description': description,
    'goal': goal,
    'workouts': workouts.map((workout) => workout.toJson()).toList(),
  };

  TrainingPlan toTrainingPlan({required String id}) =>
      TrainingPlan(id: id, proposal: this);

  CoachTrainingProposal copyWith({
    String? title,
    String? description,
    String? goal,
    List<TrainingWorkout>? workouts,
  }) => CoachTrainingProposal(
    title: title ?? this.title,
    description: description ?? this.description,
    goal: goal ?? this.goal,
    workouts: workouts ?? this.workouts,
  );
}
