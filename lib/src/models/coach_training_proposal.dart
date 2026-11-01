import 'training_limits.dart';
import 'training_plan.dart';

/// A Coach draft. Converting it to a saved plan requires the caller's action.
final class CoachTrainingProposal {
  CoachTrainingProposal({
    required String title,
    String description = '',
    String goal = '',
    required List<TrainingWorkout> workouts,
    int? sessionsPerWeek,
  }) : sessionsPerWeek = sessionsPerWeek == null
           ? null
           : TrainingJson.integer(
               sessionsPerWeek,
               1,
               TrainingLimits.sessionsPerWeekMax,
             ),
       title = TrainingJson.text(
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

  /// Planned sessions per week ("2 of 4"); null means no target. Workouts
  /// rotate, so this is not `workouts.length`.
  final int? sessionsPerWeek;

  /// Malformed provider output or history never becomes an adoptable draft.
  static CoachTrainingProposal? fromJson(Map<dynamic, dynamic> json) {
    try {
      TrainingJson.requireKeys(json, {
        'schema_version',
        'title',
        'description',
        'goal',
        'workouts',
        if (json.containsKey('sessions_per_week')) 'sessions_per_week',
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
        // A present key must hold a number; JSON null is rejected.
        sessionsPerWeek: json.containsKey('sessions_per_week')
            ? TrainingJson.integer(
                json['sessions_per_week'],
                1,
                TrainingLimits.sessionsPerWeekMax,
              )
            : null,
      );
    } on FormatException {
      return null;
    }
  }

  /// Without a target the key is absent, so builds that predate it still
  /// read the plan.
  Map<String, dynamic> toJson() => {
    'schema_version': TrainingLimits.schemaVersion,
    'title': title,
    'description': description,
    'goal': goal,
    'workouts': workouts.map((workout) => workout.toJson()).toList(),
    if (sessionsPerWeek != null) 'sessions_per_week': sessionsPerWeek,
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
    sessionsPerWeek: sessionsPerWeek,
  );

  /// The same plan with [value] as its weekly target (null clears it).
  CoachTrainingProposal withSessionsPerWeek(int? value) =>
      CoachTrainingProposal(
        title: title,
        description: description,
        goal: goal,
        workouts: workouts,
        sessionsPerWeek: value,
      );
}
