import 'dart:developer' as dev;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/user_profile.dart';

/// Maps a raw public.profiles.sex string to [BiologicalSex]; null/unknown
/// falls back to [BiologicalSex.neutral]. Pure, so it needs no client.
BiologicalSex parseProfileSex(String? raw) {
  if (raw == null) return BiologicalSex.neutral;
  return BiologicalSex.values.firstWhere(
    (v) => v.name == raw,
    orElse: () => BiologicalSex.neutral,
  );
}

/// Maps a raw public.profiles.activity_level string to [ActivityLevel];
/// null/unknown falls back to [ActivityLevel.sedentary].
ActivityLevel parseProfileActivity(String? raw) {
  if (raw == null) return ActivityLevel.sedentary;
  return ActivityLevel.values.firstWhere(
    (v) => v.name == raw,
    orElse: () => ActivityLevel.sedentary,
  );
}

/// Maps a raw public.profiles.weight_goal string to [WeightGoal]; null/unknown
/// falls back to [WeightGoal.maintain]. Legacy pace values map onto the
/// kg/week rates — a wrong branch here is a silent ±550/±1100 kcal/day bug.
WeightGoal parseProfileGoal(String? raw) {
  if (raw == null) return WeightGoal.maintain;
  switch (raw) {
    case 'loseFast':
      return WeightGoal.lose05kg;
    case 'loseSteady':
      return WeightGoal.lose025kg;
    case 'gainFast':
      return WeightGoal.gain05kg;
    case 'gainSteady':
      return WeightGoal.gain025kg;
  }
  return WeightGoal.values.firstWhere(
    (v) => v.name == raw,
    orElse: () => WeightGoal.maintain,
  );
}

/// Maps a raw public.profiles.diet_preference string to [DietPreference];
/// null/unknown falls back to [DietPreference.none] so a broken field does not
/// silently restrict recommendations.
DietPreference parseDietPreference(String? raw) {
  if (raw == null) return DietPreference.none;
  return DietPreference.values.firstWhere(
    (v) => v.name == raw,
    orElse: () => DietPreference.none,
  );
}

/// Reads and writes UserProfile against public.profiles on Supabase.
/// Save uses UPSERT(.select().single()) so schema/auth/RLS errors surface as a
/// PostgrestException instead of a silent no-op. One instance per auth user id.
class ProfileSync {
  ProfileSync(this._client, this._userId);

  final SupabaseClient _client;
  final String _userId;

  static const _columns =
      'weight_kg, height_cm, age_years, sex, '
      'activity_level, target_weight_kg, '
      'daily_steps_goal, daily_kcal_goal, daily_water_goal_ml, '
      'daily_sleep_goal_minutes, '
      'protein_goal_g, carbs_goal_g, fat_goal_g, weight_goal, '
      'diet_preference, '
      'onboarding_completed';

  Future<UserProfile?> load() async {
    try {
      final row = await _client
          .from('profiles')
          .select(_columns)
          .eq('id', _userId)
          .maybeSingle();
      if (row == null) {
        dev.log('ProfileSync.load: no row for current user',
            name: 'profile_sync');
        return null;
      }
      // Sentinel finding 3: unreadable numeric fields used to get invented
      // defaults that boot treated as real hydration, so the next save() wrote
      // the fiction to the server. The columns are NOT NULL, so throwing is
      // right — no hydration, clobber protection stays closed. Enum fields
      // stay lenient (A7): they invent a category, not a measurement.
      int leseZahl(String spalte) {
        final wert = _toInt(row[spalte]);
        if (wert == null) {
          throw FormatException(
              'profiles.$spalte unlesbar (${row[spalte]?.runtimeType})');
        }
        return wert;
      }

      return UserProfile(
        weightKg: leseZahl('weight_kg'),
        heightCm: leseZahl('height_cm'),
        ageYears: leseZahl('age_years'),
        sex: _parseSex(row['sex']?.toString()),
        activityLevel: _parseActivity(row['activity_level']?.toString()),
        targetWeightKg: leseZahl('target_weight_kg'),
        dailyStepsGoal: leseZahl('daily_steps_goal'),
        dailyKcalGoal: leseZahl('daily_kcal_goal'),
        dailyWaterGoalMl: leseZahl('daily_water_goal_ml'),
        dailySleepGoalMinutes: leseZahl('daily_sleep_goal_minutes'),
        proteinGoalG: leseZahl('protein_goal_g'),
        carbsGoalG: leseZahl('carbs_goal_g'),
        fatGoalG: leseZahl('fat_goal_g'),
        weightGoal: _parseGoal(row['weight_goal']?.toString()),
        diet: _parseDiet(row['diet_preference']?.toString()),
        onboardingCompleted: row['onboarding_completed'] == true,
      );
    } catch (e, stack) {
      dev.log('ProfileSync.load failed', error: e, stackTrace: stack, name: 'profile_sync');
      rethrow;
    }
  }

  Future<void> save(UserProfile profile) async {
    final payload = <String, dynamic>{
      'id': _userId,
      'weight_kg': profile.weightKg,
      'height_cm': profile.heightCm,
      'age_years': profile.ageYears,
      'sex': profile.sex.name,
      'activity_level': profile.activityLevel.name,
      'target_weight_kg': profile.targetWeightKg,
      'daily_steps_goal': profile.dailyStepsGoal,
      'daily_kcal_goal': profile.dailyKcalGoal,
      'daily_water_goal_ml': profile.dailyWaterGoalMl,
      'daily_sleep_goal_minutes': profile.dailySleepGoalMinutes,
      'protein_goal_g': profile.proteinGoalG,
      'carbs_goal_g': profile.carbsGoalG,
      'fat_goal_g': profile.fatGoalG,
      'weight_goal': profile.weightGoal.name,
      'diet_preference': profile.diet.name,
      'onboarding_completed': profile.onboardingCompleted,
    };
    try {
      // UPSERT, not UPDATE: the profile row may not exist yet.
      // .select().single() forces a response, so an RLS block or 0 rows throws.
      await _client.from('profiles').upsert(payload).select().single();
    } catch (e, stack) {
      dev.log('ProfileSync.save failed', error: e, stackTrace: stack, name: 'profile_sync');
      rethrow;
    }
  }

  // Delegate to the pure top-level parsers above.
  static BiologicalSex _parseSex(String? raw) => parseProfileSex(raw);

  static ActivityLevel _parseActivity(String? raw) => parseProfileActivity(raw);

  static WeightGoal _parseGoal(String? raw) => parseProfileGoal(raw);

  static DietPreference _parseDiet(String? raw) => parseDietPreference(raw);

  static int? _toInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
