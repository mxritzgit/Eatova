import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/model_limits.dart';

// W1-06: DB check-constraint bounds as client constants.
//
// `digitsOnly` is a TYPE guard, not a RANGE guard: "75,5" in the weight field
// becomes 755 kg -> PostgreSQL 23514 -> outbox drop.
//
// This suite checks three things:
//   1) Every bound at min-1/min/max/max+1.
//   2) The truncator never splits a UTF-16 surrogate pair.
//   3) The constants match the check constraints the SQL migrations leave
//      behind, read from the migration files themselves.

/// Checks an integer bound at all four edges; [clamp] only where one exists
/// (typed body data and goals are rejected, never clamped).
void _pruefeIntGrenze(
  String feld, {
  required int min,
  required int max,
  int Function(num)? clamp,
  required bool Function(num) istGueltig,
}) {
  test('$feld: min-1 / min / max / max+1', () {
    expect(
      istGueltig(min - 1),
      isFalse,
      reason: '$feld: ${min - 1} liegt unter der DB-Untergrenze $min',
    );
    expect(istGueltig(min), isTrue, reason: '$feld: $min ist der gueltige Rand');
    expect(istGueltig(max), isTrue, reason: '$feld: $max ist der gueltige Rand');
    expect(
      istGueltig(max + 1),
      isFalse,
      reason: '$feld: ${max + 1} liegt ueber der DB-Obergrenze $max',
    );

    if (clamp == null) return;
    expect(clamp(min - 1), min, reason: '$feld: unterhalb wird auf $min geklemmt');
    expect(clamp(min), min);
    expect(clamp(max), max);
    expect(clamp(max + 1), max, reason: '$feld: oberhalb wird auf $max geklemmt');
  });
}

/// Checks a floating-point bound at all four edges.
void _pruefeDoubleGrenze(
  String feld, {
  required double min,
  required double max,
  required double Function(num) clamp,
  required bool Function(num) istGueltig,
}) {
  test('$feld: min-1 / min / max / max+1', () {
    expect(istGueltig(min - 1), isFalse);
    expect(istGueltig(min), isTrue);
    expect(istGueltig(max), isTrue);
    expect(istGueltig(max + 1), isFalse);

    expect(clamp(min - 1), min);
    expect(clamp(min), min);
    expect(clamp(max), max);
    expect(clamp(max + 1), max);
  });
}

/// Finds unpaired surrogates — the proof that truncation did not split an
/// emoji. `substring` on a non-BMP character produces exactly that.
bool _hatKaputteSurrogate(String text) {
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      // High surrogate: needs a low surrogate right after it.
      if (i + 1 >= text.length) return true;
      final naechste = text.codeUnitAt(i + 1);
      if (naechste < 0xDC00 || naechste > 0xDFFF) return true;
      i++;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      // Low surrogate without a preceding high surrogate.
      return true;
    }
  }
  return false;
}

/// The migrations in apply order, `--` comments stripped: a header rationale
/// names columns and numbers and would otherwise match like a check body.
List<String> _migrationsInOrder() {
  final files = Directory('supabase/migrations')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.sql'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final file in files)
      file
          .readAsStringSync()
          .split('\n')
          .map((line) {
            final i = line.indexOf('--');
            return i < 0 ? line : line.substring(0, i);
          })
          .join('\n'),
  ];
}

/// The `check (...)` body of the last migration that adds [constraint].
String _checkBody(String constraint) {
  String? body;
  final kopf = RegExp('add constraint\\s+$constraint\\s+check\\s*\\(');
  for (final sql in _migrationsInOrder()) {
    for (final match in kopf.allMatches(sql)) {
      var tiefe = 1;
      var i = match.end;
      for (; i < sql.length && tiefe > 0; i++) {
        if (sql[i] == '(') tiefe++;
        if (sql[i] == ')') tiefe--;
      }
      body = sql.substring(match.end, i - 1);
    }
  }
  expect(body, isNotNull, reason: 'keine Migration legt $constraint an');
  return body!;
}

/// `<expr> between <min> and <max>` inside [body].
(int, int) _between(String body, String expr) {
  final match = RegExp(
    '${RegExp.escape(expr)}\\s+between\\s+(\\d+)\\s+and\\s+(\\d+)',
  ).firstMatch(body);
  expect(match, isNotNull, reason: '$expr between … fehlt');
  return (int.parse(match!.group(1)!), int.parse(match.group(2)!));
}

/// `<expr> <= <max>` inside [body].
int _atMost(String body, String expr) {
  final match =
      RegExp('${RegExp.escape(expr)}\\s*<=\\s*(\\d+)').firstMatch(body);
  expect(match, isNotNull, reason: '$expr <= … fehlt');
  return int.parse(match!.group(1)!);
}

void main() {
  group('profiles — Biometrie (profiles_biometrics_range_check)', () {
    _pruefeIntGrenze(
      'weight_kg',
      min: ProfileLimits.weightKgMin,
      max: ProfileLimits.weightKgMax,
      istGueltig: isValidProfileWeightKg,
    );
    _pruefeIntGrenze(
      'height_cm',
      min: ProfileLimits.heightCmMin,
      max: ProfileLimits.heightCmMax,
      istGueltig: isValidProfileHeightCm,
    );
    _pruefeIntGrenze(
      'age_years',
      min: ProfileLimits.ageYearsMin,
      max: ProfileLimits.ageYearsMax,
      istGueltig: isValidProfileAgeYears,
    );
    _pruefeIntGrenze(
      'target_weight_kg',
      min: ProfileLimits.targetWeightKgMin,
      max: ProfileLimits.targetWeightKgMax,
      clamp: clampProfileTargetWeightKg,
      istGueltig: isValidProfileTargetWeightKg,
    );
  });

  group('profiles — Tagesziele (profiles_goals_range_check)', () {
    _pruefeIntGrenze(
      'daily_steps_goal',
      min: ProfileLimits.dailyStepsGoalMin,
      max: ProfileLimits.dailyStepsGoalMax,
      istGueltig: isValidDailyStepsGoal,
    );
    _pruefeIntGrenze(
      'daily_kcal_goal',
      min: ProfileLimits.dailyKcalGoalMin,
      max: ProfileLimits.dailyKcalGoalMax,
      istGueltig: isValidDailyKcalGoal,
    );
    _pruefeIntGrenze(
      'protein_goal_g',
      min: ProfileLimits.proteinGoalGMin,
      max: ProfileLimits.proteinGoalGMax,
      clamp: clampProteinGoalG,
      istGueltig: isValidProteinGoalG,
    );
    _pruefeIntGrenze(
      'carbs_goal_g',
      min: ProfileLimits.carbsGoalGMin,
      max: ProfileLimits.carbsGoalGMax,
      clamp: clampCarbsGoalG,
      istGueltig: isValidCarbsGoalG,
    );
    _pruefeIntGrenze(
      'fat_goal_g',
      min: ProfileLimits.fatGoalGMin,
      max: ProfileLimits.fatGoalGMax,
      clamp: clampFatGoalG,
      istGueltig: isValidFatGoalG,
    );
  });

  group('logged_meals (logged_meals_safe_ranges_check)', () {
    _pruefeIntGrenze(
      'calories_kcal',
      min: LoggedMealLimits.caloriesKcalMin,
      max: LoggedMealLimits.caloriesKcalMax,
      clamp: clampMealCaloriesKcal,
      istGueltig: isValidMealCaloriesKcal,
    );
    _pruefeIntGrenze(
      'estimated_g',
      min: LoggedMealLimits.estimatedGMin,
      max: LoggedMealLimits.estimatedGMax,
      clamp: clampMealEstimatedG,
      istGueltig: isValidMealEstimatedG,
    );
    _pruefeDoubleGrenze(
      'protein_g / carbs_g / fat_g',
      min: LoggedMealLimits.macroGMin,
      max: LoggedMealLimits.macroGMax,
      clamp: clampMealMacroG,
      istGueltig: isValidMealMacroG,
    );
  });

  group('weight_log (weight_log_safe_range_check)', () {
    _pruefeDoubleGrenze(
      'weight_kg',
      min: WeightLogLimits.weightKgMin,
      max: WeightLogLimits.weightKgMax,
      clamp: clampWeightLogKg,
      istGueltig: isValidWeightLogKg,
    );

    test('numeric(5,2): auf zwei Nachkommastellen gerundet', () {
      // The column is numeric(5,2) and the server rounds anyway; rounding here
      // too keeps the local cache and the server row identical.
      expect(clampWeightLogKg(70.125), 70.13);
      expect(clampWeightLogKg(75.5), 75.5);
      expect(clampWeightLogKg(80.001), 80.0);
    });
  });

  group('Plausibilitaet (keine DB-Entsprechung)', () {
    test('kcal/100 g ueber 900 ist physikalisch unmoeglich (reines Fett)', () {
      // OFF sometimes puts kJ numbers in the kcal field (2180 instead of 521).
      expect(isPlausibleKcalPer100G(900), isTrue);
      expect(isPlausibleKcalPer100G(901), isFalse);
      expect(isPlausibleKcalPer100G(2180), isFalse);
      expect(isPlausibleKcalPer100G(-1), isFalse);
      expect(clampKcalPer100G(2180), PlausibilityLimits.kcalPer100GMax);
      expect(clampKcalPer100G(-1), PlausibilityLimits.kcalPer100GMin);
    });

    test('Portion: DB erlaubt 0 g, plausibel ist erst ab 1 g', () {
      // The DB bound (estimated_g >= 0) and the plausibility bound (>= 1 g)
      // deliberately differ.
      expect(LoggedMealLimits.estimatedGMin, 0);
      expect(PlausibilityLimits.portionGramsMin, 1);
      expect(isPlausiblePortionGrams(0), isFalse);
      expect(isPlausiblePortionGrams(1), isTrue);
      expect(isPlausiblePortionGrams(10000), isTrue);
      expect(isPlausiblePortionGrams(10001), isFalse);
      expect(clampPortionGrams(0), 1);
      expect(clampPortionGrams(99999), 10000);
    });
  });

  group('Nicht-endliche Werte', () {
    test('NaN ist ungueltig und clampt auf den Fallback', () {
      expect(isValidProfileWeightKg(double.nan), isFalse);
      expect(isValidWeightLogKg(double.nan), isFalse);
      expect(isValidMealCaloriesKcal(double.nan), isFalse);
      // Without a fallback: the lower bound.
      expect(
        clampProfileTargetWeightKg(double.nan),
        ProfileLimits.targetWeightKgMin,
      );
      // With a fallback: the caller picks the substitute.
      expect(clampProfileTargetWeightKg(double.nan, fallback: 78), 78);
      // An out-of-range fallback is itself clamped.
      expect(
        clampProfileTargetWeightKg(double.nan, fallback: 900),
        ProfileLimits.targetWeightKgMax,
      );
      // Same rule on the double side — that is where B1 came from: a NaN macro
      // silently becoming 0 g instead of the caller's "unknown" substitute.
      // Only the int clamp was pinned, so the double one could drop the
      // fallback unnoticed.
      expect(clampMealMacroG(double.nan), LoggedMealLimits.macroGMin);
      expect(clampMealMacroG(double.nan, fallback: 42), 42);
      expect(clampKcalPer100G(double.nan, fallback: 250), 250);
      expect(
        clampKcalPer100G(double.nan, fallback: 5000),
        PlausibilityLimits.kcalPer100GMax,
        reason: 'auch der Fallback bleibt in den Grenzen',
      );
    });

    test('Unendlich clampt auf die jeweilige Grenze statt zu werfen', () {
      expect(
        clampProfileTargetWeightKg(double.infinity),
        ProfileLimits.targetWeightKgMax,
      );
      expect(
        clampProfileTargetWeightKg(double.negativeInfinity),
        ProfileLimits.targetWeightKgMin,
      );
      expect(clampMealCaloriesKcal(double.infinity), LoggedMealLimits.caloriesKcalMax);
      expect(clampWeightLogKg(double.infinity), WeightLogLimits.weightKgMax);
      expect(isValidProfileWeightKg(double.infinity), isFalse);
    });

    test('sehr grosse endliche Doubles werfen keinen Ueberlauf', () {
      expect(clampMealCaloriesKcal(1e300), LoggedMealLimits.caloriesKcalMax);
      expect(clampMealCaloriesKcal(-1e300), LoggedMealLimits.caloriesKcalMin);
    });
  });

  group('Das Komma-Szenario aus dem Review', () {
    test('"75,5" -> digitsOnly -> 755 kg wird abgelehnt, nicht geklemmt', () {
      // Clamping 755 to 300 would silently falsify the input — the user meant
      // 75.5 kg, so the UI must reject it.
      expect(isValidProfileWeightKg(755), isFalse);
    });

    test('200000 kcal getippt: ungueltig, aber DB-sicher klemmbar', () {
      expect(isValidMealCaloriesKcal(200000), isFalse);
      expect(clampMealCaloriesKcal(200000), LoggedMealLimits.caloriesKcalMax);
    });
  });

  group('Text-Kuerzung — Postgres char_length zaehlt Code Points', () {
    test('charLength zaehlt Runen, nicht UTF-16-Einheiten', () {
      expect('🥗'.length, 2, reason: 'Dart zaehlt UTF-16-Einheiten');
      expect(charLength('🥗'), 1, reason: 'Postgres char_length zaehlt Code Points');
      expect(charLength('Salat 🥗'), 7);
    });

    test('kuerzeres Wort bleibt unveraendert', () {
      expect(truncateToChars('Haferflocken', 160), 'Haferflocken');
      expect(truncateToChars('', 160), '');
    });

    test('Emoji exakt an der Grenze bleibt vollstaendig erhalten', () {
      // 159 ASCII + 1 emoji = exactly 160 code points = the bound.
      final name = '${'a' * 159}🥗';
      expect(charLength(name), LoggedMealLimits.mealNameMaxChars);
      final gekuerzt = truncateToChars(name, LoggedMealLimits.mealNameMaxChars);
      expect(gekuerzt, name);
      expect(_hatKaputteSurrogate(gekuerzt), isFalse);
    });

    test('Emoji ueber der Grenze wird ganz entfernt, nie halbiert', () {
      // 160 ASCII + emoji = 161 code points, so the emoji drops entirely.
      final name = '${'a' * 160}🥗';
      final gekuerzt = truncateToChars(name, LoggedMealLimits.mealNameMaxChars);
      expect(gekuerzt, 'a' * 160);
      expect(_hatKaputteSurrogate(gekuerzt), isFalse);
    });

    test('Schnitt mitten im Surrogatpaar: substring waere kaputt, wir nicht', () {
      // 159 ASCII + emoji + rest: a naive substring(0, 160) cuts exactly
      // between the emoji's high and low surrogate.
      final name = '${'a' * 159}🥗${'b' * 10}';
      final naiv = name.substring(0, LoggedMealLimits.mealNameMaxChars);
      expect(
        _hatKaputteSurrogate(naiv),
        isTrue,
        reason: 'Kontrollgruppe: substring zerlegt das Emoji tatsaechlich',
      );

      final gekuerzt = truncateToChars(name, LoggedMealLimits.mealNameMaxChars);
      expect(_hatKaputteSurrogate(gekuerzt), isFalse);
      expect(gekuerzt, '${'a' * 159}🥗');
      expect(charLength(gekuerzt), LoggedMealLimits.mealNameMaxChars);
      expect(gekuerzt.runes.last, 0x1F957, reason: 'Das Emoji ist intakt');
    });

    test('maxChars 0 oder negativ liefert den leeren String', () {
      expect(truncateToChars('abc', 0), '');
      expect(truncateToChars('abc', -5), '');
    });
  });

  group('Text-Clamps an den Modellgrenzen', () {
    test('meal_name: leer verletzt char_length >= 1 -> Fallback', () {
      // char_length(meal_name) between 1 and 160: the empty string is a 23514
      // violation, not a harmless default.
      expect(clampMealName(''), isNotEmpty);
      expect(clampMealName('   '), isNotEmpty);
      expect(clampMealName('', fallback: 'Snack'), 'Snack');
      expect(clampMealName('  Linsensuppe  '), 'Linsensuppe');
      expect(charLength(clampMealName('x' * 500)), LoggedMealLimits.mealNameMaxChars);
      // The cut itself can land on a space; only the length was measured, so
      // the trailing trim was free to disappear.
      expect(clampMealName('${'x' * 159} Suppe'), 'x' * 159);
    });

    test('meal_name: isValidMealName trennt leer/zu lang von gueltig', () {
      expect(isValidMealName(''), isFalse);
      expect(isValidMealName('   '), isFalse);
      expect(isValidMealName('a'), isTrue);
      expect(isValidMealName('a' * 160), isTrue);
      expect(isValidMealName('a' * 161), isFalse);
      // 160 emoji are 320 UTF-16 units but only 160 code points.
      expect(isValidMealName('🥗' * 160), isTrue);
      expect(isValidMealName('🥗' * 161), isFalse);
    });

    test('brand: auf 120 gekuerzt, leer wird zu null', () {
      expect(clampBrand(null), isNull);
      expect(clampBrand('   '), isNull);
      expect(clampBrand(' Alpro '), 'Alpro');
      expect(charLength(clampBrand('b' * 400)!), LoggedMealLimits.brandMaxChars);
    });

    test('barcode / source_label', () {
      expect(charLength(clampBarcode('9' * 200)!), LoggedMealLimits.barcodeMaxChars);
      expect(
        charLength(clampSourceLabel('s' * 200)!),
        LoggedMealLimits.sourceLabelMaxChars,
      );
      expect(clampBarcode(null), isNull);
    });

    test('favorite_key: 1..180, gekuerzt an der Runengrenze', () {
      expect(charLength(clampFavoriteKey('name:${'x' * 400}')), 180);
      expect(clampFavoriteKey(''), isNotEmpty);
      expect(isValidFavoriteKey(''), isFalse);
      expect(isValidFavoriteKey('barcode:4008400202020'), isTrue);
      expect(isValidFavoriteKey('n' * 181), isFalse);
    });
  });

  group('Enum-Constraints', () {
    test('profiles: sex / activity_level / weight_goal / diet_preference', () {
      expect(ProfileLimits.sexValues, {'male', 'female', 'neutral'});
      expect(ProfileLimits.activityLevelValues, {
        'sedentary',
        'light',
        'moderate',
        'active',
        'athlete',
      });
      expect(ProfileLimits.weightGoalValues, {
        'lose1kg',
        'lose075kg',
        'lose05kg',
        'lose025kg',
        'maintain',
        'gain025kg',
        'gain05kg',
      });
      expect(ProfileLimits.dietPreferenceValues, {
        'none',
        'vegetarian',
        'vegan',
        'pescetarian',
      });
    });

    test('logged_meals.forced_slot', () {
      expect(LoggedMealLimits.forcedSlotValues, {
        'breakfast',
        'lunch',
        'dinner',
        'snack',
      });
    });
  });

  // -------------------------------------------------------------------------
  // Drift guard: the constants against the check constraints the migrations
  // leave behind. Each body is read from the LAST migration that adds the
  // constraint (file-name order is apply order), so a migration that moves a
  // bound turns this red and names what the client must follow.
  // -------------------------------------------------------------------------
  group('Drift-Waechter: Konstanten == Endzustand der SQL-Migrationen', () {
    test('profiles: Biometrie, Tagesziele, Texte, Wunschgewicht', () {
      final bio = _checkBody('profiles_biometrics_range_check');
      expect(_between(bio, 'weight_kg'),
          (ProfileLimits.weightKgMin, ProfileLimits.weightKgMax));
      expect(_between(bio, 'height_cm'),
          (ProfileLimits.heightCmMin, ProfileLimits.heightCmMax));
      expect(_between(bio, 'age_years'),
          (ProfileLimits.ageYearsMin, ProfileLimits.ageYearsMax));

      final goals = _checkBody('profiles_goals_range_check');
      expect(_between(goals, 'daily_steps_goal'),
          (ProfileLimits.dailyStepsGoalMin, ProfileLimits.dailyStepsGoalMax));
      expect(_between(goals, 'daily_kcal_goal'),
          (ProfileLimits.dailyKcalGoalMin, ProfileLimits.dailyKcalGoalMax));
      expect(_between(goals, 'daily_water_goal_ml'), (
        ProfileLimits.dailyWaterGoalMlMin,
        ProfileLimits.dailyWaterGoalMlMax,
      ));
      expect(_between(goals, 'daily_sleep_goal_minutes'), (
        ProfileLimits.dailySleepGoalMinutesMin,
        ProfileLimits.dailySleepGoalMinutesMax,
      ));
      expect(_between(goals, 'protein_goal_g'),
          (ProfileLimits.proteinGoalGMin, ProfileLimits.proteinGoalGMax));
      expect(_between(goals, 'carbs_goal_g'),
          (ProfileLimits.carbsGoalGMin, ProfileLimits.carbsGoalGMax));
      expect(_between(goals, 'fat_goal_g'),
          (ProfileLimits.fatGoalGMin, ProfileLimits.fatGoalGMax));

      expect(
        _atMost(
          _checkBody('profiles_display_name_length_check'),
          'char_length(display_name)',
        ),
        ProfileLimits.displayNameMaxChars,
      );
      expect(
        _atMost(
          _checkBody('profiles_avatar_url_length_check'),
          'char_length(avatar_url)',
        ),
        ProfileLimits.avatarUrlMaxChars,
      );
      expect(
        _between(
          _checkBody('profiles_target_weight_range_check'),
          'target_weight_kg',
        ),
        (ProfileLimits.targetWeightKgMin, ProfileLimits.targetWeightKgMax),
      );
    });

    test('logged_meals_safe_ranges_check', () {
      final body = _checkBody('logged_meals_safe_ranges_check');
      expect(_between(body, 'char_length(meal_name)'),
          (LoggedMealLimits.mealNameMinChars, LoggedMealLimits.mealNameMaxChars));
      expect(_between(body, 'calories_kcal'),
          (LoggedMealLimits.caloriesKcalMin, LoggedMealLimits.caloriesKcalMax));
      expect(_between(body, 'estimated_g'),
          (LoggedMealLimits.estimatedGMin, LoggedMealLimits.estimatedGMax));
      for (final macro in const ['protein_g', 'carbs_g', 'fat_g']) {
        expect(
          _between(body, macro),
          (LoggedMealLimits.macroGMin, LoggedMealLimits.macroGMax),
          reason: macro,
        );
      }
      expect(_atMost(body, 'char_length(barcode)'),
          LoggedMealLimits.barcodeMaxChars);
      expect(_atMost(body, 'char_length(brand)'),
          LoggedMealLimits.brandMaxChars);
      expect(_atMost(body, 'char_length(source_label)'),
          LoggedMealLimits.sourceLabelMaxChars);
      expect(_atMost(body, 'octet_length(payload::text)'),
          LoggedMealLimits.payloadMaxBytes);
    });

    test('favorite_meals_safe_ranges_check', () {
      final body = _checkBody('favorite_meals_safe_ranges_check');
      expect(_between(body, 'char_length(favorite_key)'), (
        FavoriteMealLimits.favoriteKeyMinChars,
        FavoriteMealLimits.favoriteKeyMaxChars,
      ));
      expect(_between(body, 'char_length(meal_name)'), (
        FavoriteMealLimits.mealNameMinChars,
        FavoriteMealLimits.mealNameMaxChars,
      ));
      expect(_between(body, 'calories_kcal'), (
        FavoriteMealLimits.caloriesKcalMin,
        FavoriteMealLimits.caloriesKcalMax,
      ));
      expect(_between(body, 'estimated_g'),
          (FavoriteMealLimits.estimatedGMin, FavoriteMealLimits.estimatedGMax));
      expect(_atMost(body, 'char_length(barcode)'),
          FavoriteMealLimits.barcodeMaxChars);
      expect(_atMost(body, 'char_length(brand)'),
          FavoriteMealLimits.brandMaxChars);
      expect(_atMost(body, 'char_length(source_label)'),
          FavoriteMealLimits.sourceLabelMaxChars);
      expect(_atMost(body, 'octet_length(payload::text)'),
          FavoriteMealLimits.payloadMaxBytes);
    });

    test('weight_log_safe_range_check und numeric(5,2)', () {
      final (min, max) = _between(
        _checkBody('weight_log_safe_range_check'),
        'weight_kg',
      );
      expect((min.toDouble(), max.toDouble()),
          (WeightLogLimits.weightKgMin, WeightLogLimits.weightKgMax));
      final column = RegExp(r'weight_kg\s+numeric\(\d+,\s*(\d+)\)')
          .firstMatch(_migrationsInOrder().join('\n'));
      expect(column, isNotNull, reason: 'weight_log.weight_kg numeric(p,s)');
      expect(int.parse(column!.group(1)!), WeightLogLimits.weightKgDecimals);
    });
  });
}
