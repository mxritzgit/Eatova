import 'training_limits.dart';

/// One exercise uses either repetitions or a timed work interval per set.
final class TrainingExercise {
  TrainingExercise({
    required String name,
    required int sets,
    int? reps,
    int? durationSeconds,
    required int restSeconds,
    String notes = '',
  }) : name = TrainingJson.text(
         name,
         TrainingLimits.titleMaxLength,
         required: true,
       ),
       sets = TrainingJson.integer(sets, 1, TrainingLimits.setsMax),
       reps = reps == null
           ? null
           : TrainingJson.integer(reps, 1, TrainingLimits.repsMax),
       durationSeconds = durationSeconds == null
           ? null
           : TrainingJson.integer(
               durationSeconds,
               TrainingLimits.durationSecondsMin,
               TrainingLimits.durationSecondsMax,
             ),
       restSeconds = TrainingJson.integer(
         restSeconds,
         0,
         TrainingLimits.restSecondsMax,
       ),
       notes = TrainingJson.text(notes, TrainingLimits.notesMaxLength) {
    if ((reps == null) == (durationSeconds == null)) {
      throw const FormatException('Exercise needs repetitions or a duration');
    }
  }

  final String name;
  final int sets;
  final int? reps;
  final int? durationSeconds;
  final int restSeconds;
  final String notes;

  bool get isTimed => durationSeconds != null;

  int get estimatedDurationSeconds =>
      sets *
          (durationSeconds ?? reps! * TrainingLimits.estimatedSecondsPerRep) +
      (sets - 1) * restSeconds;

  factory TrainingExercise.fromJson(Map<dynamic, dynamic> json) {
    TrainingJson.requireKeys(json, const {
      'name',
      'sets',
      'reps',
      'duration_seconds',
      'rest_seconds',
      'notes',
    });
    return TrainingExercise(
      name: TrainingJson.text(
        json['name'],
        TrainingLimits.titleMaxLength,
        required: true,
      ),
      sets: TrainingJson.integer(json['sets'], 1, TrainingLimits.setsMax),
      reps: json['reps'] == null
          ? null
          : TrainingJson.integer(json['reps'], 1, TrainingLimits.repsMax),
      durationSeconds: json['duration_seconds'] == null
          ? null
          : TrainingJson.integer(
              json['duration_seconds'],
              TrainingLimits.durationSecondsMin,
              TrainingLimits.durationSecondsMax,
            ),
      restSeconds: TrainingJson.integer(
        json['rest_seconds'],
        0,
        TrainingLimits.restSecondsMax,
      ),
      notes: TrainingJson.text(json['notes'], TrainingLimits.notesMaxLength),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'sets': sets,
    'reps': reps,
    'duration_seconds': durationSeconds,
    'rest_seconds': restSeconds,
    'notes': notes,
  };

  /// Passing null explicitly clears the repetitions or the duration.
  TrainingExercise copyWith({
    String? name,
    int? sets,
    Object? reps = _unchanged,
    Object? durationSeconds = _unchanged,
    int? restSeconds,
    String? notes,
  }) => TrainingExercise(
    name: name ?? this.name,
    sets: sets ?? this.sets,
    reps: _nullableInt(reps, this.reps),
    durationSeconds: _nullableInt(durationSeconds, this.durationSeconds),
    restSeconds: restSeconds ?? this.restSeconds,
    notes: notes ?? this.notes,
  );

  static const Object _unchanged = Object();

  static int? _nullableInt(Object? value, int? existing) {
    if (identical(value, _unchanged)) return existing;
    if (value == null || value is int) return value as int?;
    throw const FormatException('Invalid training number');
  }
}
