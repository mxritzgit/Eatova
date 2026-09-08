/// Shared bounds for the versioned Coach plan and saved training payloads.
abstract final class TrainingLimits {
  static const int schemaVersion = 1;
  static const int titleMaxLength = 120;
  static const int descriptionMaxLength = 1000;
  static const int goalMaxLength = 200;
  static const int workoutDescriptionMaxLength = 500;
  static const int notesMaxLength = 500;
  static const int workoutsMax = 7;
  static const int exercisesMax = 20;
  static const int setsMax = 10;
  static const int repsMax = 100;
  static const int durationSecondsMin = 5;
  static const int durationSecondsMax = 3600;
  static const int restSecondsMax = 600;
  static const int idMaxLength = 100;
  static const int combinedTextMaxLength = 12000;

  /// Display estimate only: repetition sets advance on user confirmation.
  static const int estimatedSecondsPerRep = 3;
}

/// Boundary validation deliberately rejects rather than repairs plan data.
abstract final class TrainingJson {
  static void requireKeys(Map<dynamic, dynamic> json, Set<String> keys) {
    if (json.length != keys.length ||
        json.keys.any((key) => key is! String || !keys.contains(key))) {
      throw const FormatException('Invalid training fields');
    }
  }

  static String text(Object? value, int maximum, {bool required = false}) {
    if (value is! String ||
        value.runes.length > maximum ||
        (required && value.trim().isEmpty) ||
        !_validTextEncoding(value)) {
      throw const FormatException('Invalid training text');
    }
    return value;
  }

  static int integer(Object? value, int minimum, int maximum) {
    if (value is! num ||
        !value.isFinite ||
        value < minimum ||
        value > maximum ||
        value != value.truncateToDouble()) {
      throw const FormatException('Invalid training number');
    }
    return value.toInt();
  }

  static String id(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value.length > TrainingLimits.idMaxLength ||
        !_idPattern.hasMatch(value)) {
      throw const FormatException('Invalid training identifier');
    }
    return value;
  }

  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]+$');

  static bool _validTextEncoding(String value) {
    for (var index = 0; index < value.length; index++) {
      final unit = value.codeUnitAt(index);
      if (unit < 32 && unit != 9 && unit != 10 && unit != 13) return false;
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++index >= value.length) return false;
        final low = value.codeUnitAt(index);
        if (low < 0xdc00 || low > 0xdfff) return false;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        return false;
      }
    }
    return true;
  }
}
