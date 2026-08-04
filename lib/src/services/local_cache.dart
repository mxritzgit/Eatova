import 'dart:convert';
import 'dart:developer' as dev;

import 'package:shared_preferences/shared_preferences.dart';

import '../models/lifetime_stats.dart';
import '../models/user_profile.dart';

/// Minimaler async Key-Value-Store hinter [LocalCache]. Abstrahiert
/// SharedPreferences, damit der Cache OHNE Plugin-Channel unit-getestet werden
/// kann (siehe [InMemoryKeyValueStore]).
abstract class KeyValueStore {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

/// Plattform-Default: SharedPreferences. Wird in Production via
/// [LocalCache.create] gebaut. shared_preferences ist bereits transitiv ueber
/// supabase_flutter vorhanden (gotrue nutzt es fuer die Session).
class SharedPreferencesStore implements KeyValueStore {
  SharedPreferencesStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<SharedPreferencesStore> create() async {
    final prefs = await SharedPreferences.getInstance();
    return SharedPreferencesStore(prefs);
  }

  @override
  Future<String?> getString(String key) async => _prefs.getString(key);

  @override
  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);

  @override
  Future<void> remove(String key) => _prefs.remove(key);
}

/// In-Memory-Store fuer Tests (kein Plugin-Channel noetig).
class InMemoryKeyValueStore implements KeyValueStore {
  InMemoryKeyValueStore([Map<String, String>? initial])
      : _data = {...?initial};

  final Map<String, String> _data;

  Map<String, String> get snapshot => Map.unmodifiable(_data);

  @override
  Future<String?> getString(String key) async => _data[key];

  @override
  Future<void> setString(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _data.remove(key);
  }
}

/// Duenner Write-Through-Cache (JSON in SharedPreferences) fuer Profil und
/// lifetime_stats EINES Users (DATA-3).
///
/// Zweck: ein Kaltstart OHNE Netz darf nicht die nackten Ctor-Defaults
/// (78 kg / 178 cm) zeigen — und ein anschliessender Save darf die echte
/// Server-Zeile NICHT mit diesen Defaults ueberschreiben. Die HomePage
/// hydratisiert beim Start ZUERST aus diesem Cache (letzter bekannter Stand),
/// danach erst aus dem Netz; jede persistierte Mutation schreibt parallel hier
/// rein.
///
/// Pro User gekeyt (SharedPreferences ist global). Alle Reads/Writes sind
/// defensiv: ein korrupter/teilweiser Eintrag liefert null statt zu crashen —
/// der Netz-Boot bzw. der naechste Write fixt ihn.
class LocalCache {
  LocalCache(this._store, this._userId);

  final KeyValueStore _store;
  final String _userId;

  /// Baut den Production-Cache auf SharedPreferences. Gibt bei Plugin-Fehler
  /// (z.B. fehlender Channel im Test ohne Mock) null zurueck, damit der Aufrufer
  /// einfach ohne Cache weiterlaeuft statt zu crashen.
  static Future<LocalCache?> create(String userId) async {
    try {
      final store = await SharedPreferencesStore.create();
      return LocalCache(store, userId);
    } catch (e, s) {
      dev.log('LocalCache.create failed', error: e, stackTrace: s,
          name: 'local_cache');
      return null;
    }
  }

  // Versions-Prefix erlaubt spaetere Schema-Migrationen ohne Crash auf alten
  // Eintraegen (unbekannte Keys werden einfach ignoriert).
  String get _profileKey => 'eatova.v1.profile.$_userId';

  /// Legacy-Slot des frueheren Heute-Tabs (daily_logs-Snapshot inkl. Mood-
  /// Notiz). Wird nicht mehr geschrieben/gelesen, aber in [clear] weiterhin
  /// geraeumt, damit Alt-Installationen beim Logout keine PII behalten (M-1).
  String get _legacyDailyKey => 'eatova.v1.daily.$_userId';
  String get _statsKey => 'eatova.v1.stats.$_userId';
  String get _notificationsKey => 'eatova.v1.notifications_enabled.$_userId';

  // ---- Erinnerungen (PROD-1) ----------------------------------------------
  // Opt-in-Flag fuer die lokalen Retention-Nudges. Persistiert pro User, damit
  // ein Kaltstart die geplanten Nudges nur dann wieder aufsetzt, wenn der User
  // sie aktiviert hat. Wir reusen den vorhandenen JSON-Slot statt eines eigenen
  // bool-Channels, damit der Wire-Pfad einheitlich (und defensiv) bleibt.

  /// Schreibt das Erinnerungs-Opt-in-Flag. No-Op bei Plugin-Fehler (s. _writeJson).
  Future<void> writeNotificationsEnabled(bool enabled) =>
      _writeJson(_notificationsKey, <String, dynamic>{'enabled': enabled});

  /// Liest das Opt-in-Flag. Fehlt/korrupt -> null (Aufrufer waehlt seinen
  /// Default, in der App: OFF bis der User opt-in macht).
  Future<bool?> readNotificationsEnabled() async {
    final json = await _readJson(_notificationsKey);
    if (json == null) return null;
    final v = json['enabled'];
    return v is bool ? v : null;
  }

  // ---- Profil -------------------------------------------------------------

  Future<void> writeProfile(UserProfile profile) =>
      _writeJson(_profileKey, _profileToJson(profile));

  Future<UserProfile?> readProfile() async {
    final json = await _readJson(_profileKey);
    if (json == null) return null;
    try {
      return _profileFromJson(json);
    } catch (e) {
      dev.log('LocalCache.readProfile parse failed', error: e,
          name: 'local_cache');
      return null;
    }
  }

  // ---- lifetime_stats -----------------------------------------------------

  Future<void> writeLifetimeStats(LifetimeStats stats) =>
      _writeJson(_statsKey, _statsToJson(stats));

  Future<LifetimeStats?> readLifetimeStats() async {
    final json = await _readJson(_statsKey);
    if (json == null) return null;
    try {
      return LifetimeStats.fromRow(json);
    } catch (e) {
      dev.log('LocalCache.readLifetimeStats parse failed', error: e,
          name: 'local_cache');
      return null;
    }
  }

  Future<void> clear() async {
    await _store.remove(_profileKey);
    await _store.remove(_legacyDailyKey);
    await _store.remove(_statsKey);
    await _store.remove(_notificationsKey);
  }

  // ---- Low-level ----------------------------------------------------------

  Future<void> _writeJson(String key, Map<String, dynamic> value) async {
    try {
      await _store.setString(key, jsonEncode(value));
    } catch (e) {
      // Ein Cache-Write darf NIE den UI-Pfad killen — er ist reine Beschleunigung
      // fuer den naechsten Kaltstart. Bei Fehler still verwerfen.
      dev.log('LocalCache write failed ($key)', error: e, name: 'local_cache');
    }
  }

  Future<Map<String, dynamic>?> _readJson(String key) async {
    try {
      final raw = await _store.getString(key);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } catch (e) {
      dev.log('LocalCache read failed ($key)', error: e, name: 'local_cache');
      return null;
    }
  }

  // ---- (De)Serialisierung -------------------------------------------------
  // Bewusst hier statt auf den Modellen: die Modelle bleiben unveraendert
  // (keine fremden Aenderungen ausserhalb meiner File-Ownership), und der
  // Cache besitzt sein eigenes, versioniertes Wire-Format.

  static Map<String, dynamic> _profileToJson(UserProfile p) => <String, dynamic>{
        'weight_kg': p.weightKg,
        'height_cm': p.heightCm,
        'age_years': p.ageYears,
        'sex': p.sex.name,
        'activity_level': p.activityLevel.name,
        'target_weight_kg': p.targetWeightKg,
        'daily_steps_goal': p.dailyStepsGoal,
        'daily_kcal_goal': p.dailyKcalGoal,
        'daily_water_goal_ml': p.dailyWaterGoalMl,
        'daily_sleep_goal_minutes': p.dailySleepGoalMinutes,
        'protein_goal_g': p.proteinGoalG,
        'carbs_goal_g': p.carbsGoalG,
        'fat_goal_g': p.fatGoalG,
        'weight_goal': p.weightGoal.name,
        'onboarding_completed': p.onboardingCompleted,
      };

  static UserProfile _profileFromJson(Map<String, dynamic> j) => UserProfile(
        weightKg: _int(j['weight_kg'], 78),
        heightCm: _int(j['height_cm'], 178),
        ageYears: _int(j['age_years'], 30),
        sex: _enumByName(BiologicalSex.values, j['sex'], BiologicalSex.neutral),
        activityLevel: _enumByName(
            ActivityLevel.values, j['activity_level'], ActivityLevel.sedentary),
        targetWeightKg: _int(j['target_weight_kg'], 78),
        dailyStepsGoal: _int(j['daily_steps_goal'], 8000),
        dailyKcalGoal: _int(j['daily_kcal_goal'], 2200),
        dailyWaterGoalMl: _int(j['daily_water_goal_ml'], 2500),
        dailySleepGoalMinutes: _int(j['daily_sleep_goal_minutes'], 7 * 60 + 30),
        proteinGoalG: _int(j['protein_goal_g'], 130),
        carbsGoalG: _int(j['carbs_goal_g'], 240),
        fatGoalG: _int(j['fat_goal_g'], 70),
        weightGoal:
            _enumByName(WeightGoal.values, j['weight_goal'], WeightGoal.maintain),
        onboardingCompleted: j['onboarding_completed'] == true,
      );

  static Map<String, dynamic> _statsToJson(LifetimeStats s) => <String, dynamic>{
        'workouts_completed': s.workoutsCompleted,
        'meals_logged': s.mealsLogged,
        'water_total_ml': s.waterTotalMl,
        'steps_recorded': s.stepsRecorded,
        'weight_logs': s.weightLogs,
        'current_streak': s.currentStreak,
        'longest_streak': s.longestStreak,
        'last_workout_date':
            s.lastTrackedDate == null ? null : _dateOnly(s.lastTrackedDate!),
      };

  static int _int(Object? v, int fallback) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  static T _enumByName<T extends Enum>(List<T> values, Object? raw, T fallback) {
    if (raw is! String) return fallback;
    for (final v in values) {
      if (v.name == raw) return v;
    }
    return fallback;
  }

  static String _dateOnly(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }
}
