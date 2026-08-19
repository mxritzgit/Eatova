import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:shared_preferences/shared_preferences.dart';

import '../models/favorite_meal.dart';
import '../models/fitness_recipe.dart';
import '../models/lifetime_stats.dart';
import '../models/logged_meal.dart';
import '../models/user_profile.dart';
import '../models/weight_log.dart';
import 'crash_reporter.dart';
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

  /// Luecke A: selbst angelegte Rezepte. Sie waren die EINZIGE Nutzer-Sammlung
  /// mit nur EINEM Sicherungsnetz — der Outbox. Faellt die aus (zugestellt,
  /// gekappt, oder nie entstanden, weil der Live-Write ohne Timeout haengt),
  /// war das Rezept spurlos weg, und ein Kaltstart ohne Netz zeigte gar keine
  /// Eigen-Rezepte mehr. Jetzt derselbe Write-Through wie Tagebuch/Favoriten.
  /// Ebenfalls PII (Zutaten/Mengen des Nutzers) -> wird in [clear] geraeumt.
  String get _userRecipesKey => 'eatova.v1.user_recipes.$_userId';

  /// Tages-Aktivitaet: Schritte + daraus geschaetzte "Verbrannt"-kcal pro
  /// lokalem Kalendertag (Key im Blob: YYYY-MM-DD, s. local_day.dart).
  /// Anders als der Legacy-daily-Slot des frueheren Heute-Tabs traegt er nur
  /// diese zwei Zahlen — aber auch das sind Gesundheitsdaten, also PII ->
  /// wird in [clear] geraeumt. Bewusst NUR lokal (keine Supabase-Tabelle):
  /// Schritte kommen aus dem Health-Store des Geraets, ein Server-Sync wuerde
  /// Gesundheitsdaten hochladen, die dort nie gebraucht werden.
  String get _dailyActivityKey => 'eatova.v1.daily_activity.$_userId';

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

  // Wire-Format (userProfileToJson/-FromJson) liegt seit Luecke D in
  // sync_outbox.dart: das Profil hat jetzt ZWEI Persistenzwege — diesen
  // Cache-Slot und die Outbox-Op. Zwei Kopien desselben Mappings waeren die
  // Falle, gegen die der Vollstaendigkeits-Test in local_cache_test
  // geschrieben ist. Schluesselnamen und Defensiv-Verhalten sind unveraendert.
  Future<void> writeProfile(UserProfile profile) =>
      _writeJson(_profileKey, userProfileToJson(profile));

  Future<UserProfile?> readProfile() async {
    final json = await _readJson(_profileKey);
    if (json == null) return null;
    try {
      final profile = userProfileFromJson(json);
      if (profile == null) {
        dev.log(
            'LocalCache.readProfile: Blob unvollstaendig (Zahlenfeld fehlt/'
            'unlesbar) — verworfen, Server-Load liefert die Wahrheit',
            name: 'local_cache');
      }
      return profile;
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

  /// Eigen-Rezepte (Luecke A). Wire-Format ist bewusst die SERVERZEILE
  /// ([FitnessRecipe.toRow]/[FitnessRecipe.fromRow]): ein aus dem Cache
  /// gelesenes Rezept ist damit Zeichen fuer Zeichen dasselbe wie ein frisch
  /// geladenes — inklusive `userCreated: true` und dem festen Profi-Hinweis,
  /// die `fromRow` setzt (die Tabelle fuehrt beide Spalten nicht).
  Future<void> writeUserRecipes(List<FitnessRecipe> recipes) =>
      _writeJson(_userRecipesKey, _userRecipesToJson(recipes));

  static Map<String, dynamic> _userRecipesToJson(List<FitnessRecipe> recipes) =>
      <String, dynamic>{
        'items': recipes.map((r) => r.toRow()).toList(),
      };

  Future<List<FitnessRecipe>?> readUserRecipes() async {
    final items = await _readItems(_userRecipesKey);
    if (items == null) return null;
    try {
      return items.map(FitnessRecipe.fromRow).toList();
    } catch (e) {
      // Wie bei Tagebuch/Favoriten: der Slot faellt ALS GANZES aus (null),
      // der Server-Load bzw. der naechste Write fixt ihn. Ein Rezept ohne
      // slug wirft in fromRow — der slug ist der Konflikt-Schluessel des
      // Upserts und darf nie erfunden werden (Sentinel-Rest S4).
      dev.log('LocalCache.readUserRecipes parse failed', error: e,
          name: 'local_cache');
      return null;
    }
  }

  /// Tages-Aktivitaet (s. [_dailyActivityKey]). Wire-Format:
  /// `{'days': {'2026-08-11': {'steps': 8123, 'kcal': 312}}}`.
  Future<void> writeDailyActivity(
    Map<String, ({int steps, int kcal})> days,
  ) =>
      _writeJson(_dailyActivityKey, <String, dynamic>{
        'days': <String, dynamic>{
          for (final e in days.entries)
            e.key: <String, dynamic>{
              'steps': e.value.steps,
              'kcal': e.value.kcal,
            },
        },
      });

  /// Liest die Tages-Aktivitaet. Fehlt/korrupt -> null; einzelne unlesbare
  /// Tage werden uebersprungen statt den ganzen Slot zu verwerfen (Muster
  /// wie [readOutbox] — die uebrigen Tage sollen den einen kaputten nicht
  /// mitreissen).
  Future<Map<String, ({int steps, int kcal})>?> readDailyActivity() async {
    final json = await _readJson(_dailyActivityKey);
    final days = json?['days'];
    if (days is! Map) return null;
    final result = <String, ({int steps, int kcal})>{};
    for (final entry in days.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      result['${entry.key}'] = (
        steps: _int(value['steps'], 0),
        kcal: _int(value['kcal'], 0),
      );
    }
    return result;
  }

  Future<void> writeWeightLog(WeightLog log) =>
      _writeJson(_weightLogKey, _weightLogToJson(log));

  static Map<String, dynamic> _weightLogToJson(WeightLog log) =>
      <String, dynamic>{
        'items': log.entries
            .map((e) => <String, dynamic>{
                  't': e.timestamp.toIso8601String(),
                  'kg': e.weightKg,
                })
            .toList(),
      };

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
  //
  // Diese beiden Slots laufen NICHT ueber [_writeJson], sondern ueber
  // [_writeDurable]. Begruendung dort: sie sind kein Beschleunigungs-Cache,
  // sondern die Kill-Sicherung selbst.

  /// Schreibt die Outbox. `true` = der Blob liegt auf der Platte, `false` =
  /// er liegt NICHT dort und die Ops ueberleben keinen App-Kill.
  ///
  /// Der Rueckgabewert ist der Ausgang, den [_writeJson] nicht hat (siehe
  /// [_writeDurable]) — auswerten muss ihn niemand, die bestehenden Aufrufer
  /// duerfen ihn weiter ignorieren.
  Future<bool> writeOutbox(List<SyncOp> ops) =>
      _writeDurable(_outboxKey, 'outbox', <String, dynamic>{
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

  /// Wie [readOutbox], meldet einen LESEFEHLER aber, statt ihn zu schlucken.
  ///
  /// Die Boot-Hydration ist der einzige Leser, fuer den „Slot ist leer" und
  /// „Slot war nicht lesbar" zwei verschiedene Dinge sind: nur im zweiten Fall
  /// darf der naechste Enqueue den persistierten Blob NICHT ueberschreiben —
  /// bis zu [kOutboxMaxOps] nie zugestellte Writes haengen daran (der Schutz
  /// selbst sitzt in `_persistOutbox`, home_store_sync.dart). Ueber [_readJson]
  /// ist diese Unterscheidung nicht zu haben: der faengt jeden Fehler selbst ab
  /// und liefert `null`, was ueberall sonst „nichts Brauchbares da" heisst.
  ///
  /// Alle uebrigen Leser bleiben bewusst auf [readOutbox]. Fuer die ist ein
  /// kaputter Slot genau das, wonach er aussieht (kein Cache) — sie haetten von
  /// einem Wurf nichts als einen zusaetzlichen Fehlerpfad.
  Future<List<SyncOp>?> readOutboxOrThrow() async {
    final ops = await readOutbox();
    if (ops != null) return ops;
    await _assertSlotEmpty(_outboxKey, 'outbox');
    return null;
  }

  /// Schreibt die pendenden Lifetime-Deltas samt ihrer Anfrage-Id.
  ///
  /// [requestId] ist der Idempotenz-Schluessel des Buendels
  /// (`increment_lifetime_stats(p_request_id)`, Migration
  /// 20260814120000_audit_rls_guard.sql). Er MUSS zusammen mit den Zahlen
  /// liegen und nicht daneben: der Retry nach einem Abbruch ist nur dann
  /// wirksam, wenn er DIESELBE Id sendet — eine frisch erzeugte waere fuer den
  /// Server ein neuer Vorgang und zaehlte ein zweites Mal.
  ///
  /// `null` wird bewusst als FEHLENDER Schluessel geschrieben, nicht als
  /// `'request_id': null`: so ist die Wire-Form eines leeren Buendels exakt die
  /// alte, und ein Downgrade auf einen aelteren Build liest den Slot weiter.
  ///
  /// Rueckgabe wie bei [writeOutbox]: `false` heisst, die Deltas liegen nur im
  /// Speicher — ein Kill danach kostet die Lebenszeit-Zaehler dieser Mahlzeiten.
  Future<bool> writePendingStatsDeltas({
    required int meals,
    required int weightLogs,
    String? requestId,
  }) =>
      _writeDurable(_pendingStatsKey, 'pending_stats', <String, dynamic>{
        'meals': meals,
        'weight_logs': weightLogs,
        if (requestId != null) 'request_id': requestId,
      });

  /// Liest die pendenden Deltas. [requestId] ist `null`, wenn der Slot von
  /// einem aelteren Build stammt (Bestandsdaten kennen den Schluessel nicht) —
  /// der Aufrufer vergibt ihn dann nach.
  Future<({int meals, int weightLogs, String? requestId})?>
      readPendingStatsDeltas() async {
    final json = await _readJson(_pendingStatsKey);
    if (json == null) return null;
    final rid = json['request_id'];
    return (
      meals: _int(json['meals'], 0),
      weightLogs: _int(json['weight_logs'], 0),
      requestId: rid is String && rid.isNotEmpty ? rid : null,
    );
  }

  /// Wie [readPendingStatsDeltas], meldet einen Lesefehler aber (Begruendung
  /// s. [readOutboxOrThrow] — die Deltas sind die zweite Haelfte desselben
  /// kill-sicheren Sync-Zustands). Derselbe Mangel: der naechste Flush schreibt
  /// den Slot komplett neu, und ein verschluckter Lesefehler laesst ihn dabei
  /// bei 0 anfangen — die Lebenszeit-Zaehler des Nutzers blieben um die
  /// liegengebliebenen Mahlzeiten zu niedrig.
  Future<({int meals, int weightLogs, String? requestId})?>
      readPendingStatsDeltasOrThrow() async {
    final deltas = await readPendingStatsDeltas();
    if (deltas != null) return deltas;
    await _assertSlotEmpty(_pendingStatsKey, 'pending_stats');
    return null;
  }

  /// Raeumt die User-Slots.
  ///
  /// [preserveOutbox] `true` laesst GENAU [_outboxKey] und [_pendingStatsKey]
  /// stehen und loescht alles andere (A2): beim Sign-out duerfen ungesyncte
  /// Mahlzeiten nicht vernichtet werden — sie spielen beim naechsten Login
  /// desselben Users nach. Die beiden Slots sind seit `7f895f9` verschluesselt
  /// und per User-ID namensraumgetrennt, die urspruengliche PII-Begruendung
  /// (Audit M-1) traegt fuer sie also nicht mehr.
  ///
  /// Default `false` = Verhalten wie bisher (Konto-Loeschung raeumt restlos).
  Future<void> clear({bool preserveOutbox = false}) async {
    // Ausstehende entprellte Writes verwerfen, BEVOR geraeumt wird — sonst
    // schriebe ein noch laufender Debounce-Timer die gerade geloeschte PII
    // gleich wieder zurueck (G9b).
    _discardPendingWrites();

    await _store.remove(_profileKey);
    await _store.remove(_legacyDailyKey);
    await _store.remove(_statsKey);
    await _store.remove(_notificationsKey);
    await _store.remove(_loggedMealsKey);
    await _store.remove(_favoritesKey);
    await _store.remove(_weightLogKey);
    // Eigen-Rezepte sind Nutzerinhalt (Zutaten, Mengen) und fallen damit unter
    // dieselbe M-1-Begruendung wie das Tagebuch — auch bei [preserveOutbox].
    await _store.remove(_userRecipesKey);
    // Schritte/Burned-kcal sind Gesundheitsdaten — gleiche M-1-Begruendung.
    await _store.remove(_dailyActivityKey);
    if (preserveOutbox) return;
    await _store.remove(_outboxKey);
    await _store.remove(_pendingStatsKey);
  }

  // ---- Entprellte Blob-Writes (G9b) ---------------------------------------
  // Tagebuch, Favoriten, Gewichts-Log und Eigen-Rezepte sind Spiegel des
  // Server-Stands und werden bei JEDER Mutation komplett neu geschrieben —
  // jedes Mal der ganze Blob durch jsonEncode + AES-GCM + base64. Gemessen:
  // 91,5 ms bei 210 Mahlzeiten auf Desktop-JIT, mobiles AOT-ARM 2-4x
  // langsamer. Eine Fuenfer-Serie (hinzufuegen, korrigieren, loeschen, ...)
  // kostete das fuenfmal, weil jeder Aufruf sofort schrieb.
  //
  // Die entprellten Varianten fassen alle Aufrufe innerhalb von
  // [writeDebounce] zu EINEM Write pro Slot zusammen.
  //
  // BEWUSST NICHT entprellt sind die Outbox und die pendenden Stats-Deltas:
  // die SIND der Kill-Sicherungs-Mechanismus (DATA-7) und muessen sofort auf
  // der Platte liegen. Ein Verlust der vier Spiegel-Slots kostet dagegen nur
  // einen Netz-Load beim naechsten Kaltstart — die zugehoerigen Writes leben
  // ohnehin in der (sofort persistierten) Outbox. Profil und lifetime_stats
  // bleiben ebenfalls sofort: kleine Maps, vernachlaessigbare Krypto-Kosten.

  /// Fenster, in dem mehrere entprellte Writes zu einem zusammenfallen.
  /// Laeuft ab dem ERSTEN Aufruf (kein cancel+restart), damit eine lange
  /// Serie den Write nicht unbegrenzt vor sich herschiebt.
  static const Duration writeDebounce = Duration(milliseconds: 400);

  final Map<String, Map<String, dynamic>> _pendingWrites =
      <String, Map<String, dynamic>>{};
  Timer? _debounceTimer;

  /// True, solange mindestens ein entprellter Write aussteht.
  bool get hasPendingWrites => _pendingWrites.isNotEmpty;

  /// Entprellter Write-Through fuers Tagebuch. Ersetzt [writeLoggedMeals] auf
  /// dem heissen Mutations-Pfad.
  void writeLoggedMealsDebounced(List<LoggedMeal> meals) =>
      _scheduleWrite(_loggedMealsKey, <String, dynamic>{
        'items': meals.map(loggedMealToJson).toList(),
      });

  /// Entprellter Write-Through fuer die Favoriten.
  void writeFavoritesDebounced(List<FavoriteMeal> favorites) =>
      _scheduleWrite(_favoritesKey, <String, dynamic>{
        'items': favorites.map(favoriteMealToJson).toList(),
      });

  /// Entprellter Write-Through fuers Gewichts-Log.
  void writeWeightLogDebounced(WeightLog log) =>
      _scheduleWrite(_weightLogKey, _weightLogToJson(log));

  /// Entprellter Write-Through fuer die Eigen-Rezepte (Luecke A). Gleiche
  /// Begruendung wie oben: der Slot wird bei jeder Mutation komplett neu
  /// geschrieben, und ein Verlust kostet nur einen Netz-Load — der zugehoerige
  /// Write liegt in der (sofort persistierten) Outbox.
  void writeUserRecipesDebounced(List<FitnessRecipe> recipes) =>
      _scheduleWrite(_userRecipesKey, _userRecipesToJson(recipes));

  /// Schreibt alle ausstehenden entprellten Writes SOFORT weg.
  ///
  /// MUSS beim App-Pause/Hidden/Detach laufen (und vor jedem Logout, den
  /// [clear] selbst nicht abdeckt) — sonst verliert ein Kill innerhalb des
  /// [writeDebounce]-Fensters den letzten Spiegel-Stand.
  Future<void> flush() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _drainPendingWrites();
  }

  void _scheduleWrite(String key, Map<String, dynamic> value) {
    // Letzter Stand gewinnt: der Slot wird ohnehin immer als Ganzes
    // geschrieben, ein aelterer Blob desselben Slots ist wertlos.
    _pendingWrites[key] = value;
    _debounceTimer ??= Timer(writeDebounce, () {
      _debounceTimer = null;
      unawaited(_drainPendingWrites());
    });
  }

  Future<void> _drainPendingWrites() async {
    if (_pendingWrites.isEmpty) return;
    final batch = Map<String, Map<String, dynamic>>.of(_pendingWrites);
    _pendingWrites.clear();
    for (final entry in batch.entries) {
      await _writeJson(entry.key, entry.value);
    }
  }

  void _discardPendingWrites() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _pendingWrites.clear();
  }

  // ---- Low-level ----------------------------------------------------------

  Future<void> _writeJson(String key, Map<String, dynamic> value) async {
    // Ein sofortiger Write auf denselben Slot macht einen noch ausstehenden
    // entprellten Write ungueltig — sonst ueberschriebe der spaeter den
    // frischeren Stand.
    _pendingWrites.remove(key);
    try {
      await _store.setString(key, jsonEncode(value));
    } catch (e) {
      // Ein Cache-Write darf NIE den UI-Pfad killen — er ist reine Beschleunigung
      // fuer den naechsten Kaltstart. Bei Fehler still verwerfen.
      //
      // Das gilt AUSDRUECKLICH nur fuer die Spiegel-Slots (Profil, Stats,
      // Tagebuch, Favoriten, Gewicht, Eigen-Rezepte, Aktivitaet,
      // Erinnerungs-Flag): deren Inhalt steht auch auf dem Server, ein
      // verlorener Write kostet einen Netz-Load. Die Sync-Zustands-Slots
      // gehen deshalb ueber [_writeDurable] — was DORT verloren geht, kennt
      // niemand sonst.
      dev.log('LocalCache write failed ($key)', error: e, name: 'local_cache');
    }
  }

  /// Schreibweg fuer die Sync-Zustands-Slots (Outbox, pendende Stats-Deltas).
  ///
  /// Warum getrennt von [_writeJson]: die beiden Slots SIND die
  /// Kill-Sicherung (DATA-7), kein Beschleunigungs-Cache. Ihr Inhalt existiert
  /// nirgends sonst — der Server kennt die noch nicht zugestellte Mahlzeit
  /// nicht, und die Oberflaeche zeigt derweil „wird synchronisiert". Ein still
  /// verschluckter Fehlschlag (AES-Key nach Backup-Restore oder
  /// Keystore-Reset unlesbar, Plugin-Kanal-Fehler, `jsonEncode`-Fehler) ist
  /// hier also Datenverlust ohne jedes Signal — an den Nutzer wie an die
  /// Diagnose.
  ///
  /// Deshalb zwei Unterschiede zum generischen Pfad: der Fehlschlag geht
  /// (sanitisiert) an den [CrashReporter], und der Aufrufer bekommt ihn als
  /// `false` zurueck. Geworfen wird weiterhin NICHT — die Aufrufer laufen
  /// `unawaited` auf dem UI-Pfad, ein Wurf waere dort ein unbehandelter
  /// Future-Fehler.
  Future<bool> _writeDurable(
    String key,
    String slot,
    Map<String, dynamic> value,
  ) async {
    // Dieselbe Invariante wie in [_writeJson] — sie haengt am Slot, nicht am
    // Aufrufer. Fuer die beiden Sync-Slots laeuft sie heute leer (entprellt
    // wird hier bewusst nichts, s. Abschnitt „Entprellte Blob-Writes").
    _pendingWrites.remove(key);
    try {
      await _store.setString(key, jsonEncode(value));
      return true;
    } catch (e, s) {
      dev.log('LocalCache durable write failed ($slot)',
          error: e, stackTrace: s, name: 'local_cache');
      // NUR Slot-Kurzname und Fehlertyp gehen raus — nie der Key (er traegt
      // die User-ID) und nie der Wert (die Slots fuehren Gesundheitsdaten).
      // Dieselbe Einschraenkung wie bei [UnreadableCacheSlot]: schon eine
      // FormatException traegt ihre Quelle in der Message.
      unawaited(CrashReporter.capture(
        UnwritableCacheSlot(slot, e.runtimeType.toString()),
        s,
        context: 'cache_durable_write',
      ));
      return false;
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
    // Ein noch ausstehender entprellter Write ist der aktuellste Stand — ohne
    // diesen Durchgriff haette der Slot zwischen Schedule und Write ein
    // Read-after-Write-Loch (Boot-Hydration, Test, Diagnose).
    final pending = _pendingWrites[key];
    if (pending != null) return pending;
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

  /// Wirft [UnreadableCacheSlot], wenn [key] doch einen Rohwert traegt — oder
  /// wenn der Store ihn gar nicht erst herausgibt.
  ///
  /// Gegenprobe fuer die `OrThrow`-Leser: die haben ueber den toleranten Pfad
  /// `null` bekommen, und `null` deckt dort BEIDES ab — leerer Slot und
  /// verschluckter Lesefehler. Der Roh-Blick trennt die zwei.
  ///
  /// Bewusst DANACH und nicht davor: der gesunde Fall (Slot da und lesbar)
  /// kostet damit keinen zweiten Store-Zugriff, der unter
  /// [EncryptedKeyValueStore] ein zweites Entschluesseln des ganzen Blobs
  /// waere. Bezahlt wird nur der leere und der kaputte Slot.
  ///
  /// NICHT abgedeckt: ein nicht entschluesselbarer Slot. Den raeumt
  /// [EncryptedKeyValueStore] beim Lesen selbst weg und liefert `null` — hier
  /// kommt dann ein leerer Slot an. Das ist auch richtig so: es ist nichts
  /// mehr da, was ein Ueberschreiben noch verlieren koennte.
  Future<void> _assertSlotEmpty(String key, String slot) async {
    final String? raw;
    try {
      raw = await _store.getString(key);
    } catch (e) {
      // NUR der Fehlertyp geht raus. Der Aufrufer meldet den Wurf an den
      // CrashReporter, und z.B. eine FormatException traegt ihre Quelle in der
      // Message — das waere hier der entschluesselte Slot-Inhalt, also
      // Gesundheitsdaten (gleiche Regel wie bei [UndecryptableCacheSlot]).
      throw UnreadableCacheSlot(slot, e.runtimeType.toString());
    }
    if (raw != null && raw.isNotEmpty) {
      throw UnreadableCacheSlot(slot, 'Inhalt nicht deserialisierbar');
    }
  }

  // ---- (De)Serialisierung -------------------------------------------------
  // Bewusst hier statt auf den Modellen: die Modelle bleiben unveraendert
  // (keine fremden Aenderungen ausserhalb meiner File-Ownership), und der
  // Cache besitzt sein eigenes, versioniertes Wire-Format. Das Profil-Mapping
  // ist seit Luecke D die Ausnahme: es liegt in sync_outbox.dart, weil Cache
  // UND Outbox-Op dieselben Bytes brauchen (Begruendung dort).

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

  static String _dateOnly(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }
}

/// Ein Sync-Zustands-Slot war belegt, liess sich aber nicht lesen (Store-Fehler
/// oder strukturell kaputter Inhalt). Wird ausschliesslich von
/// [LocalCache.readOutboxOrThrow] und [LocalCache.readPendingStatsDeltasOrThrow]
/// geworfen.
///
/// Traegt NUR den Slot-Kurznamen und den Fehlertyp: nicht den Storage-Key (der
/// enthaelt die User-ID) und nie den Wert (die Slots fuehren Gesundheitsdaten).
/// Das Objekt geht aus dem Hydrations-Pfad in den Crash-Report — dieselbe
/// Einschraenkung wie bei [UndecryptableCacheSlot].
class UnreadableCacheSlot implements Exception {
  const UnreadableCacheSlot(this.slot, this.reason);

  /// Kurzname wie `outbox`, bewusst nicht der Storage-Key.
  final String slot;

  /// Fehlertyp bzw. Kurzbegruendung, nie ein Wert.
  final String reason;

  @override
  String toString() => 'UnreadableCacheSlot($slot): $reason';
}

/// Ein Sync-Zustands-Slot liess sich nicht SCHREIBEN — das Gegenstueck zu
/// [UnreadableCacheSlot] und der einzige Weg, von einem verlorenen Outbox-
/// bzw. Deltas-Write ueberhaupt zu erfahren (siehe [LocalCache._writeDurable]).
///
/// Dieselbe Einschraenkung wie dort: nur Slot-Kurzname und Fehlertyp, nie der
/// Storage-Key (User-ID) und nie der Wert (Gesundheitsdaten).
class UnwritableCacheSlot implements Exception {
  const UnwritableCacheSlot(this.slot, this.reason);

  /// Kurzname wie `outbox`, bewusst nicht der Storage-Key.
  final String slot;

  /// Fehlertyp, nie ein Wert.
  final String reason;

  @override
  String toString() => 'UnwritableCacheSlot($slot): $reason';
}
