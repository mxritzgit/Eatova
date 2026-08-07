import 'dart:convert';
import 'dart:developer' as dev;

import 'package:shared_preferences/shared_preferences.dart';

import '../models/favorite_meal.dart';
import '../models/lifetime_stats.dart';
import '../models/logged_meal.dart';
import '../models/user_profile.dart';
import '../models/weight_log.dart';
import 'secure_cache_store.dart';
import 'sync_outbox.dart';

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

  /// Baut den Production-Cache auf SharedPreferences, verschluesselt mit dem
  /// OS-Keystore-DEK (SEC-1, siehe secure_cache_store.dart). Gibt bei
  /// Plugin-Fehler (z.B. fehlender Channel im Test ohne Mock) ODER wenn der
  /// DEK weder gelesen noch angelegt werden kann null zurueck, damit der
  /// Aufrufer einfach ohne Cache weiterlaeuft statt zu crashen. KEIN
  /// Klartext-Fallback — lieber kein Cache als ein unverschluesselter.
  ///
  /// Der Dekorator wird bewusst NUR hier eingezogen: der oeffentliche
  /// Konstruktor nimmt weiter einen nackten [KeyValueStore], damit die
  /// bestehenden Tests ihn unveraendert mit [InMemoryKeyValueStore] und rohen
  /// Klartext-Werten treiben koennen.
  static Future<LocalCache?> create(String userId) async {
    try {
      final base = await SharedPreferencesStore.create();
      final store = await EncryptedKeyValueStore.create(base);
      if (store == null) return null;
      final cache = LocalCache(store, userId);
      await cache.dropLegacySlots();
      return cache;
    } catch (e, s) {
      dev.log('LocalCache.create failed', error: e, stackTrace: s,
          name: 'local_cache');
      return null;
    }
  }

  /// Loescht Slots, die es nur noch in Alt-Installationen gibt.
  ///
  /// Aktuell [_legacyDailyKey] (`eatova.v1.daily.<uid>`): wird nie gelesen und
  /// nie geschrieben, bisher nur in [clear] geraeumt. Eine Installation von
  /// VOR der Entfernung des Heute-Tabs traegt dort weiterhin einen
  /// daily_logs-Snapshot INKLUSIVE der Mood-Freitextnotiz — und der
  /// Verschluesselungs-Dekorator wuerde ihn NIE anfassen, weil er nur beim
  /// Schreiben verschluesselt und beim Lesen migriert. Der Slot muss also
  /// ersatzlos weg statt verschluesselt zu werden.
  ///
  /// Oeffentlich, damit das ueber den einfachen Konstruktor testbar ist.
  Future<void> dropLegacySlots() => _store.remove(_legacyDailyKey);

  // Versions-Prefix erlaubt spaetere Schema-Migrationen ohne Crash auf alten
  // Eintraegen (unbekannte Keys werden einfach ignoriert).
  String get _profileKey => 'eatova.v1.profile.$_userId';

  /// Legacy-Slot des frueheren Heute-Tabs (daily_logs-Snapshot inkl. Mood-
  /// Notiz). Wird nicht mehr geschrieben/gelesen, aber in [clear] weiterhin
  /// geraeumt, damit Alt-Installationen beim Logout keine PII behalten (M-1).
  String get _legacyDailyKey => 'eatova.v1.daily.$_userId';
  String get _statsKey => 'eatova.v1.stats.$_userId';
  String get _notificationsKey => 'eatova.v1.notifications_enabled.$_userId';

  // DATA-7 Offline-Persistenz: Tagebuch, Favoriten und Gewichts-Log werden
  // gespiegelt, damit ein Kaltstart ohne Netz nicht mit leerem Tagebuch
  // startet. Dazu die Write-Outbox (noch nicht synchronisierte Operationen)
  // und die pendenden Lifetime-Stats-Deltas — beides muss einen App-Kill
  // ueberleben. ALLE Slots sind PII und werden in [clear] geraeumt.
  String get _loggedMealsKey => 'eatova.v1.logged_meals.$_userId';
  String get _favoritesKey => 'eatova.v1.favorites.$_userId';
  String get _weightLogKey => 'eatova.v1.weight_log.$_userId';
  String get _outboxKey => 'eatova.v1.outbox.$_userId';
  String get _pendingStatsKey => 'eatova.v1.pending_stats.$_userId';

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

  // ---- Tagebuch / Favoriten / Gewicht (DATA-7) ----------------------------
  // Listen werden als {'items': [...]} verpackt, damit der defensive
  // Map-basierte Wire-Pfad (_readJson/_writeJson) unveraendert traegt.

  Future<void> writeLoggedMeals(List<LoggedMeal> meals) =>
      _writeJson(_loggedMealsKey, <String, dynamic>{
        'items': meals.map(loggedMealToJson).toList(),
      });

  Future<List<LoggedMeal>?> readLoggedMeals() async {
    final items = await _readItems(_loggedMealsKey);
    if (items == null) return null;
    try {
      return items.map(loggedMealFromJson).toList();
    } catch (e) {
      dev.log('LocalCache.readLoggedMeals parse failed', error: e,
          name: 'local_cache');
      return null;
    }
  }

  Future<void> writeFavorites(List<FavoriteMeal> favorites) =>
      _writeJson(_favoritesKey, <String, dynamic>{
        'items': favorites.map(favoriteMealToJson).toList(),
      });

  Future<List<FavoriteMeal>?> readFavorites() async {
    final items = await _readItems(_favoritesKey);
    if (items == null) return null;
    try {
      return items.map(favoriteMealFromJson).toList();
    } catch (e) {
      dev.log('LocalCache.readFavorites parse failed', error: e,
          name: 'local_cache');
      return null;
    }
  }

  Future<void> writeWeightLog(WeightLog log) =>
      _writeJson(_weightLogKey, <String, dynamic>{
        'items': log.entries
            .map((e) => <String, dynamic>{
                  't': e.timestamp.toIso8601String(),
                  'kg': e.weightKg,
                })
            .toList(),
      });

  Future<WeightLog?> readWeightLog() async {
    final items = await _readItems(_weightLogKey);
    if (items == null) return null;
    try {
      final entries = items
          .map((j) => WeightLogEntry(
                timestamp: DateTime.parse(j['t'] as String),
                weightKg: (j['kg'] as num).toDouble(),
              ))
          .toList();
      return WeightLog(entries: entries);
    } catch (e) {
      dev.log('LocalCache.readWeightLog parse failed', error: e,
          name: 'local_cache');
      return null;
    }
  }

  // ---- Write-Outbox + pendende Stats-Deltas (DATA-7) ----------------------

  Future<void> writeOutbox(List<SyncOp> ops) =>
      _writeJson(_outboxKey, <String, dynamic>{
        'items': ops.map((o) => o.toJson()).toList(),
      });

  /// Liest die persistierte Outbox. Einzelne korrupte/unbekannte Ops werden
  /// uebersprungen (SyncOp.tryFromJson) statt die ganze Queue zu verwerfen —
  /// die uebrigen Writes des Users sollen den einen kaputten nicht mitreissen.
  Future<List<SyncOp>?> readOutbox() async {
    final items = await _readItems(_outboxKey);
    if (items == null) return null;
    final ops = <SyncOp>[];
    for (final item in items) {
      final op = SyncOp.tryFromJson(item);
      if (op != null) ops.add(op);
    }
    return ops;
  }

  Future<void> writePendingStatsDeltas({
    required int meals,
    required int weightLogs,
  }) =>
      _writeJson(_pendingStatsKey, <String, dynamic>{
        'meals': meals,
        'weight_logs': weightLogs,
      });

  Future<({int meals, int weightLogs})?> readPendingStatsDeltas() async {
    final json = await _readJson(_pendingStatsKey);
    if (json == null) return null;
    return (
      meals: _int(json['meals'], 0),
      weightLogs: _int(json['weight_logs'], 0),
    );
  }

  Future<void> clear() async {
    await _store.remove(_profileKey);
    await _store.remove(_legacyDailyKey);
    await _store.remove(_statsKey);
    await _store.remove(_notificationsKey);
    await _store.remove(_loggedMealsKey);
    await _store.remove(_favoritesKey);
    await _store.remove(_weightLogKey);
    await _store.remove(_outboxKey);
    await _store.remove(_pendingStatsKey);
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

  /// Liest eine als {'items': [...]} verpackte Listen-Slot-Zeile und liefert
  /// die Map-Eintraege. Fehlt der Slot oder ist er strukturell kaputt -> null
  /// (Aufrufer behandelt das wie "kein Cache").
  Future<List<Map<String, dynamic>>?> _readItems(String key) async {
    final json = await _readJson(key);
    final items = json?['items'];
    if (items is! List) return null;
    return items
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
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
