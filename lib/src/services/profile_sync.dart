import 'dart:developer' as dev;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/user_profile.dart';

/// Mappt einen Roh-String aus public.profiles.sex auf [BiologicalSex].
/// Null/Unbekanntes faellt auf [BiologicalSex.neutral] zurueck.
/// Top-level + rein, damit das Mapping ohne Supabase-Client testbar ist.
BiologicalSex parseProfileSex(String? raw) {
  if (raw == null) return BiologicalSex.neutral;
  return BiologicalSex.values.firstWhere(
    (v) => v.name == raw,
    orElse: () => BiologicalSex.neutral,
  );
}

/// Mappt einen Roh-String aus public.profiles.activity_level auf
/// [ActivityLevel]. Null/Unbekanntes faellt auf [ActivityLevel.sedentary].
ActivityLevel parseProfileActivity(String? raw) {
  if (raw == null) return ActivityLevel.sedentary;
  return ActivityLevel.values.firstWhere(
    (v) => v.name == raw,
    orElse: () => ActivityLevel.sedentary,
  );
}

/// Mappt einen Roh-String aus public.profiles.weight_goal auf [WeightGoal].
/// Bestands-Werte aus dem alten Tempo-Schema werden auf die kg/Woche-Raten
/// gemappt, damit bereits onboardete User ihr Ziel nicht verlieren — falsche
/// Branches hier sind stille ±550/±1100 kcal/Tag-Zielbugs. Null/Unbekanntes
/// faellt auf [WeightGoal.maintain] zurueck.
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

/// Mappt einen Roh-String aus public.profiles.diet_preference auf
/// [DietPreference]. Null/Unbekanntes faellt auf [DietPreference.none] zurueck,
/// damit ein leeres/kaputtes Feld den User nicht ungewollt einschraenkt
/// (none empfiehlt alles). Top-level + rein, ohne Supabase-Client testbar.
DietPreference parseDietPreference(String? raw) {
  if (raw == null) return DietPreference.none;
  return DietPreference.values.firstWhere(
    (v) => v.name == raw,
    orElse: () => DietPreference.none,
  );
}

/// Liest und schreibt UserProfile gegen public.profiles auf Supabase.
/// Save nutzt UPSERT(.select().single()), damit der Aufrufer bei
/// Schema/Auth/RLS-Fehlern eine PostgrestException kriegt statt einer
/// stillen No-Op. Eine Instanz gehoert genau einem auth.users.id.
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
      // Sentinel-Fund 3 (Nachverifikation 2026-08-08): unlesbare Zahlenfelder
      // wurden hier mit erfundenen Werten aufgefuellt (78 kg, 178 cm, 2200
      // kcal, ...) und das Ergebnis galt dem Boot als echte Hydrationsquelle
      // (_hydratedFromRealSource) — der naechste save() schrieb die Fantasie
      // dauerhaft auf den Server. Die Spalten sind serverseitig NOT NULL;
      // unlesbar heisst Parse-Muell oder Schema-Drift, und dann ist Werfen
      // richtig: _safeLoad im Boot faengt es, es gibt keine Hydration, der
      // Clobber-Schutz bleibt geschlossen. Die Enum-Felder bleiben bewusst
      // nachsichtig (A7: Vorwaertskompatibilitaet mit kuenftigen Enum-Werten
      // — sie erfinden Einordnungen, keine Messwerte).
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
      // UPSERT statt UPDATE - faengt den Fall ab dass die Profile-Row
      // noch nicht existiert (z.B. bei Test-Accounts oder wenn der
      // Bootstrap-Trigger aus irgendeinem Grund nicht gegriffen hat).
      // .select().single() erzwingt eine Antwort - bei RLS-Block oder
      // 0-rows kommt eine PostgrestException statt stiller No-Op.
      await _client.from('profiles').upsert(payload).select().single();
    } catch (e, stack) {
      dev.log('ProfileSync.save failed', error: e, stackTrace: stack, name: 'profile_sync');
      rethrow;
    }
  }

  // Delegieren an die reinen Top-level-Parser (oben), damit das Verhalten
  // identisch bleibt und 1:1 ohne Supabase-Client getestet werden kann.
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
