part of 'training_plan_editor.dart';

class _PlanText {
  _PlanText(String text, this.maximum, {this.required = false, this.min})
    : controller = TextEditingController(text: text);

  final TextEditingController controller;
  final int maximum;
  final bool required;
  final int? min;
  String? error;

  String? validate(AppLocalizations l10n) {
    final value = controller.text;
    if (min != null) {
      final number = int.tryParse(value);
      if (number == null || number < min! || number > maximum) {
        return l10n.trainingPageRange(min!, maximum);
      }
    } else {
      if (required && value.trim().isEmpty) return l10n.trainingPageRequired;
      if (value.runes.length > maximum) return l10n.trainingPageTooLong;
      if (value.runes.any((c) => c < 32 && c != 9 && c != 10 && c != 13)) {
        return l10n.trainingPageInvalidCharacters;
      }
    }
    return null;
  }

  int get number => int.parse(controller.text);
  void dispose() => controller.dispose();
}

class _WorkoutFields {
  _WorkoutFields(TrainingWorkout? value)
    : title = _PlanText(
        value?.title ?? '',
        TrainingLimits.titleMaxLength,
        required: true,
      ),
      description = _PlanText(
        value?.description ?? '',
        TrainingLimits.workoutDescriptionMaxLength,
      ),
      exercises =
          value?.exercises.map(_ExerciseFields.new).toList() ??
          [_ExerciseFields(null)];

  final _PlanText title;
  final _PlanText description;
  final List<_ExerciseFields> exercises;

  Iterable<_PlanText> get values sync* {
    yield* [title, description];
    for (final exercise in exercises) {
      yield* exercise.values;
    }
  }

  TrainingWorkout build() => TrainingWorkout(
    title: title.controller.text,
    description: description.controller.text,
    exercises: exercises.map((exercise) => exercise.build()).toList(),
  );

  void dispose() {
    title.dispose();
    description.dispose();
    for (final exercise in exercises) {
      exercise.dispose();
    }
  }
}

class _ExerciseFields {
  _ExerciseFields(TrainingExercise? value)
    : id = value?.id ?? uuidV4(),
      name = _PlanText(
        value?.name ?? '',
        TrainingLimits.titleMaxLength,
        required: true,
      ),
      notes = _PlanText(value?.notes ?? '', TrainingLimits.notesMaxLength),
      sets = _PlanText('${value?.sets ?? 3}', TrainingLimits.setsMax, min: 1),
      reps = _PlanText('${value?.reps ?? 10}', TrainingLimits.repsMax, min: 1),
      duration = _PlanText(
        '${value?.durationSeconds ?? 30}',
        TrainingLimits.durationSecondsMax,
        min: TrainingLimits.durationSecondsMin,
      ),
      rest = _PlanText(
        '${value?.restSeconds ?? 60}',
        TrainingLimits.restSecondsMax,
        min: 0,
      ),
      timed = value?.isTimed ?? false;

  final String id;
  final _PlanText name, notes, sets, reps, duration, rest;
  bool timed;

  Iterable<_PlanText> get values => [
    name,
    notes,
    sets,
    timed ? duration : reps,
    rest,
  ];

  TrainingExercise build() => TrainingExercise(
    id: id,
    name: name.controller.text,
    notes: notes.controller.text,
    sets: sets.number,
    reps: timed ? null : reps.number,
    durationSeconds: timed ? duration.number : null,
    restSeconds: rest.number,
  );

  void dispose() {
    for (final value in [name, notes, sets, reps, duration, rest]) {
      value.dispose();
    }
  }
}
