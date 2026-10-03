import 'training_limits.dart';
import 'training_log.dart';

enum CoachWorkoutLogKind { reps, timed }

/// [reps] is null for timed work or when it was not said.
final class CoachWorkoutLogSet {
  const CoachWorkoutLogSet({this.reps, this.weightKg});

  final int? reps;
  final double? weightKg;

  Map<String, dynamic> toJson() => {'reps': reps, 'weight_kg': weightKg};
}

/// [durationSeconds] is per set, null for reps or when it was not said.
final class CoachWorkoutLogExercise {
  const CoachWorkoutLogExercise({
    required this.name,
    required this.kind,
    this.durationSeconds,
    required this.sets,
  });

  final String name;
  final CoachWorkoutLogKind kind;
  final int? durationSeconds;
  final List<CoachWorkoutLogSet> sets;

  Map<String, dynamic> toJson() => {
    'name': name,
    'kind': kind.name,
    'duration_seconds': durationSeconds,
    'sets': [for (final set in sets) set.toJson()],
  };
}

/// A Coach `/log` draft, wire and stored schema v1 (spec C3,
/// `chat_messages.workout_log`). Writes nothing: history is written only
/// after the user confirms the review sheet.
final class CoachWorkoutLog {
  const CoachWorkoutLog({
    required this.title,
    this.performedOn,
    this.durationMinutes,
    this.otherDaysOmitted = false,
    this.note = '',
    required this.exercises,
  });

  static const int schemaVersion = 1;

  final String title;

  /// 'YYYY-MM-DD', or null when the day was not said.
  final String? performedOn;
  final int? durationMinutes;
  final bool otherDaysOmitted;
  final String note;
  final List<CoachWorkoutLogExercise> exercises;

  /// Exact keys and bounds; null on any violation. The date check is format
  /// only (a real calendar day, no clock), so stored rows keep decoding. The
  /// C3 caps of 6000 code points and 32 KiB hold by the field limits alone
  /// (at most 3020 code points of text, about 21 KB of JSON).
  static CoachWorkoutLog? fromJson(Map<dynamic, dynamic> json) {
    try {
      return _parse(json);
    } on FormatException {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'title': title,
    'performed_on': performedOn,
    'duration_minutes': durationMinutes,
    'other_days_omitted': otherDaysOmitted,
    'note': note,
    'exercises': [for (final exercise in exercises) exercise.toJson()],
  };

  /// The editable form for the review sheet; unsaid values stay null.
  LoggedWorkoutDraft toDraft() {
    final day = performedOn == null ? null : DateTime.tryParse(performedOn!);
    return LoggedWorkoutDraft(
      title: title,
      performedOn: day == null ? null : DateTime(day.year, day.month, day.day),
      durationMinutes: durationMinutes,
      note: note,
      otherDaysOmitted: otherDaysOmitted,
      exercises: [
        for (final exercise in exercises)
          LoggedExercise(
            name: exercise.name,
            timed: exercise.kind == CoachWorkoutLogKind.timed,
            durationSeconds: exercise.durationSeconds,
            sets: [
              for (final set in exercise.sets)
                LoggedSet(reps: set.reps, weightKg: set.weightKg),
            ],
          ),
      ],
    );
  }

  static CoachWorkoutLog _parse(Map<dynamic, dynamic> json) {
    TrainingJson.requireKeys(json, const {
      'schema_version',
      'title',
      'performed_on',
      'duration_minutes',
      'other_days_omitted',
      'note',
      'exercises',
    });
    TrainingJson.integer(json['schema_version'], schemaVersion, schemaVersion);
    final omitted = json['other_days_omitted'];
    final rawExercises = json['exercises'];
    if (omitted is! bool ||
        rawExercises is! List ||
        rawExercises.isEmpty ||
        rawExercises.length > TrainingLimits.exercisesMax) {
      throw const FormatException('Invalid workout log');
    }
    return CoachWorkoutLog(
      title: TrainingJson.text(
        json['title'],
        TrainingLimits.titleMaxLength,
        required: true,
      ),
      performedOn: json['performed_on'] == null
          ? null
          : _day(json['performed_on']),
      durationMinutes: json['duration_minutes'] == null
          ? null
          : TrainingJson.integer(
              json['duration_minutes'],
              1,
              TrainingLogLimits.durationMinutesMax,
            ),
      otherDaysOmitted: omitted,
      note: TrainingJson.text(json['note'], TrainingLimits.notesMaxLength),
      exercises: List.unmodifiable(rawExercises.map(_exercise)),
    );
  }

  static CoachWorkoutLogExercise _exercise(Object? raw) {
    if (raw is! Map) throw const FormatException('Invalid workout log');
    TrainingJson.requireKeys(raw, const {
      'name',
      'kind',
      'duration_seconds',
      'sets',
    });
    final kind = switch (raw['kind']) {
      'reps' => CoachWorkoutLogKind.reps,
      'timed' => CoachWorkoutLogKind.timed,
      _ => throw const FormatException('Invalid workout log'),
    };
    final seconds = raw['duration_seconds'] == null
        ? null
        : TrainingJson.integer(
            raw['duration_seconds'],
            TrainingLimits.durationSecondsMin,
            TrainingLogLimits.timedSecondsMax,
          );
    final rawSets = raw['sets'];
    if ((kind == CoachWorkoutLogKind.reps && seconds != null) ||
        rawSets is! List ||
        rawSets.isEmpty ||
        rawSets.length > TrainingLimits.setsMax ||
        // A set over an hour is stored as ⌈d/3600⌉ parts (see training_log).
        (seconds != null &&
            rawSets.length *
                    ((seconds + TrainingLimits.durationSecondsMax - 1) ~/
                        TrainingLimits.durationSecondsMax) >
                TrainingLimits.setsMax)) {
      throw const FormatException('Invalid workout log');
    }
    return CoachWorkoutLogExercise(
      name: TrainingJson.text(
        raw['name'],
        TrainingLimits.titleMaxLength,
        required: true,
      ),
      kind: kind,
      durationSeconds: seconds,
      sets: List.unmodifiable(rawSets.map((set) => _set(set, kind))),
    );
  }

  static CoachWorkoutLogSet _set(Object? raw, CoachWorkoutLogKind kind) {
    if (raw is! Map) throw const FormatException('Invalid workout log');
    TrainingJson.requireKeys(raw, const {'reps', 'weight_kg'});
    final reps = raw['reps'] == null
        ? null
        : TrainingJson.integer(raw['reps'], 0, TrainingLogLimits.repsMax);
    final weight = raw['weight_kg'];
    if ((kind == CoachWorkoutLogKind.timed && reps != null) ||
        (weight != null &&
            (weight is! num ||
                !weight.isFinite ||
                weight < 0 ||
                weight > TrainingLogLimits.weightKgMax ||
                // At most two decimals; exact for every such double.
                (weight * 100).roundToDouble() / 100 != weight))) {
      throw const FormatException('Invalid workout log');
    }
    return CoachWorkoutLogSet(
      reps: reps,
      weightKg: (weight as num?)?.toDouble(),
    );
  }

  static final RegExp _dayPattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

  static String _day(Object? value) {
    final match = value is String ? _dayPattern.firstMatch(value) : null;
    if (match == null) throw const FormatException('Invalid workout day');
    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    final date = DateTime.utc(year, month, day);
    if (year < 1 || date.month != month || date.day != day) {
      throw const FormatException('Invalid workout day');
    }
    return value as String;
  }
}
