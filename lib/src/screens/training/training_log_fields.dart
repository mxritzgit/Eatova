part of 'training_log_editor.dart';

/// The text of a numeric field and what it means.
class _NumberField {
  _NumberField(
    this.min,
    this.max, {
    required this.digits,
    this.decimal = false,
    String text = '',
  }) : controller = TextEditingController(text: text);

  final int min;
  final int max;
  final int digits;
  final bool decimal;
  final TextEditingController controller;

  NumberInput get _input => NumberInput.parse(controller.text);

  bool get isEmpty => _input is EmptyNumberInput;

  /// The number within [min]..[max]; null while empty or invalid.
  num? get value {
    final input = _input;
    final number = decimal ? input.value : input.wholeValue;
    return number == null || number < min || number > max ? null : number;
  }

  bool get invalid => !isEmpty && value == null;

  String? error(AppLocalizations l10n) => invalid
      ? numberInputHint(_input, l10n, wholeNumber: !decimal) ??
            l10n.trainingPageRange(min, max)
      : null;

  void dispose() => controller.dispose();
}

class _FreeSet {
  _FreeSet({String reps = '', String weight = ''})
    : reps = _NumberField(0, TrainingLogLimits.repsMax, digits: 4, text: reps),
      weight = _weightField(weight);

  final _NumberField reps;
  final _NumberField weight;

  void dispose() {
    reps.dispose();
    weight.dispose();
  }
}

_NumberField _weightField(String text) => _NumberField(
  0,
  TrainingLogLimits.weightKgMax.toInt(),
  digits: 6,
  decimal: true,
  text: text,
);

class _FreeExercise {
  _FreeExercise({
    String name = '',
    this.timed = false,
    int? durationSeconds,
    List<_FreeSet>? sets,
  }) : name = TextEditingController(text: name),
       minutes = _NumberField(
         0,
         TrainingLogLimits.timedSecondsMax ~/ 60,
         digits: 3,
         text: durationSeconds == null || durationSeconds < 60
             ? ''
             : '${durationSeconds ~/ 60}',
       ),
       seconds = _NumberField(
         0,
         TrainingLogLimits.timedSecondsMax,
         digits: 5,
         text: durationSeconds == null || durationSeconds % 60 == 0
             ? ''
             : '${durationSeconds % 60}',
       ),
       sets = sets ?? [_FreeSet()];

  final TextEditingController name;
  bool timed;
  final _NumberField minutes;
  final _NumberField seconds;
  final List<_FreeSet> sets;

  /// Seconds per set; null while nothing (or something invalid) is entered.
  int? get durationSeconds {
    if (minutes.invalid || seconds.invalid) return null;
    if (minutes.isEmpty && seconds.isEmpty) return null;
    return (minutes.value ?? 0).toInt() * 60 + (seconds.value ?? 0).toInt();
  }

  bool get hasInvalidInput =>
      (timed && (minutes.invalid || seconds.invalid)) ||
      sets.any((set) => (!timed && set.reps.invalid) || set.weight.invalid);

  /// No value typed yet, so a picked name may prefill "Last time".
  bool get blank =>
      minutes.isEmpty &&
      seconds.isEmpty &&
      sets.every((set) => set.reps.isEmpty && set.weight.isEmpty);

  LoggedExercise toLogged() => LoggedExercise(
    name: name.text,
    timed: timed,
    durationSeconds: timed ? durationSeconds : null,
    sets: [
      for (final set in sets)
        LoggedSet(
          reps: timed ? null : set.reps.value?.toInt(),
          weightKg: set.weight.value?.toDouble(),
        ),
    ],
  );

  void dispose() {
    name.dispose();
    minutes.dispose();
    seconds.dispose();
    for (final set in sets) {
      set.dispose();
    }
  }
}

class _PlannedSet {
  _PlannedSet({required String reps, required String weight})
    : reps = _NumberField(0, TrainingLogLimits.repsMax, digits: 4, text: reps),
      weight = _weightField(weight);

  bool done = true;

  /// Typed by hand: an earlier set's weight no longer carries into it.
  bool weightEdited = false;
  final _NumberField reps;
  final _NumberField weight;

  void dispose() {
    reps.dispose();
    weight.dispose();
  }
}

/// An exercise name from the history, newest spelling first.
final class _KnownExercise {
  const _KnownExercise({
    required this.name,
    required this.key,
    required this.timed,
    this.durationSeconds,
  });

  final String name;
  final String key;
  final bool timed;
  final int? durationSeconds;
}

List<_KnownExercise> _knownExercises(List<TrainingHistoryEntry> history) {
  final newest = [...history]
    ..sort((a, b) => b.finishedAt.compareTo(a.finishedAt));
  final seen = <String>{};
  return [
    for (final entry in newest)
      for (final exercise in entry.snapshot.workout.exercises)
        if (normalizeExerciseName(exercise.name) case final key
            when key.isNotEmpty && seen.add(key))
          _KnownExercise(
            name: exercise.name.trim(),
            key: key,
            timed: exercise.isTimed,
            durationSeconds: exercise.durationSeconds,
          ),
  ];
}

/// A set's done/skipped switch: lime with a check when done.
class _DoneToggle extends StatelessWidget {
  const _DoneToggle({
    super.key,
    required this.done,
    required this.label,
    required this.onTap,
  });

  final bool done;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      container: true,
      checked: done,
      enabled: onTap != null,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: done ? t.lime : t.field,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox.square(
            dimension: 48,
            child: Icon(
              Icons.check_rounded,
              size: 22,
              color: done ? t.onLime : t.inkFaint,
            ),
          ),
        ),
      ),
    );
  }
}
