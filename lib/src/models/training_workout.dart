import 'training_exercise.dart';
import 'training_limits.dart';

export 'training_exercise.dart';

/// An immutable workout; list order determines the execution order.
final class TrainingWorkout {
  TrainingWorkout({
    required String title,
    String description = '',
    required List<TrainingExercise> exercises,
  }) : title = TrainingJson.text(
         title,
         TrainingLimits.titleMaxLength,
         required: true,
       ),
       description = TrainingJson.text(
         description,
         TrainingLimits.workoutDescriptionMaxLength,
       ),
       exercises = List.unmodifiable(exercises) {
    if (exercises.isEmpty || exercises.length > TrainingLimits.exercisesMax) {
      throw const FormatException('Invalid training exercise count');
    }
  }

  final String title;
  final String description;
  final List<TrainingExercise> exercises;

  int get estimatedDurationSeconds => exercises.fold(
    0,
    (seconds, exercise) => seconds + exercise.estimatedDurationSeconds,
  );

  int get totalSets =>
      exercises.fold(0, (sets, exercise) => sets + exercise.sets);

  factory TrainingWorkout.fromJson(Map<dynamic, dynamic> json) {
    TrainingJson.requireKeys(json, const {'title', 'description', 'exercises'});
    final rawExercises = json['exercises'];
    if (rawExercises is! List ||
        rawExercises.isEmpty ||
        rawExercises.length > TrainingLimits.exercisesMax) {
      throw const FormatException('Invalid training exercise count');
    }
    return TrainingWorkout(
      title: TrainingJson.text(
        json['title'],
        TrainingLimits.titleMaxLength,
        required: true,
      ),
      description: TrainingJson.text(
        json['description'],
        TrainingLimits.workoutDescriptionMaxLength,
      ),
      exercises: rawExercises
          .map((raw) {
            if (raw is! Map) {
              throw const FormatException('Invalid training exercise');
            }
            return TrainingExercise.fromJson(raw);
          })
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    'description': description,
    'exercises': exercises.map((exercise) => exercise.toJson()).toList(),
  };

  TrainingWorkout copyWith({
    String? title,
    String? description,
    List<TrainingExercise>? exercises,
  }) => TrainingWorkout(
    title: title ?? this.title,
    description: description ?? this.description,
    exercises: exercises ?? this.exercises,
  );
}
