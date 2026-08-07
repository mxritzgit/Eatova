import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/favorite_meal.dart';
import '../models/fitness_recipe.dart';
import '../models/lifetime_stats.dart';
import '../models/logged_meal.dart';
import '../models/macro_progress.dart';
import '../models/meal_analysis_result.dart';
import '../models/user_profile.dart';
import '../models/weight_log.dart';
import '../services/crash_reporter.dart';
import '../services/eatova_sync.dart';
import '../services/health_service.dart';
import '../services/local_cache.dart';
import '../services/local_day.dart';
import '../services/meal_totals.dart' as totals;
import '../services/meals_sync.dart' show MealsSync;
import '../services/notification_service.dart';
import '../services/streak_reminder_planner.dart';
import '../services/sync_error_messages.dart';
import '../services/sync_outbox.dart';
import '../services/uuid.dart';
import '../theme/app_colors.dart';
import '../widgets/common/app_snack.dart';

part 'home_store_meals.dart';
part 'home_store_profile.dart';
part 'home_store_sync.dart';
part 'home_store_tracking.dart';

/// Vom [HomeStore] ausgesendete, context-FREIE Snackbar-Anforderung. Der Store
/// haelt bewusst nie einen BuildContext (ARCH-4 Store-Seam) — er signalisiert
/// nur „zeige diese Meldung", die `_EatovaHomePageState` uebersetzt das in ein
/// echtes [showAppSnack]. So bleibt die gesamte Sync-/Outbox-Logik testbar und
/// vom Widget-Baum entkoppelt.
typedef SnackEmitter = void Function(
  String message, {
  IconData icon,
  Color accent,
  Duration? duration,
  SnackBarAction? action,
});

/// Gemeinsamer Kern der [HomeStore]-Parts: Konstruktor-Dependencies, der von
/// mehreren Parts geteilte State sowie die kleinen puren Helfer/Sichten
/// darauf. Die Part-Mixins haengen per `on`-Klausel hieran (bzw. aneinander),
/// dadurch bleiben alle privaten Member library-privat — nichts musste fuer
/// die Aufteilung public werden. Part-EIGENER State (Outbox, Health-Snapshot,
/// Notification-/Onboarding-Flags, Archive-Day-Sets) lebt im jeweiligen Part.
abstract class _HomeStoreBase extends ChangeNotifier {
  _HomeStoreBase({
    required this.sync,
    required this.health,
    required this.notificationService,
    required this.initialUserName,
    required SnackEmitter emitSnack,
    this.debugCache,
  }) : _emitSnack = emitSnack;

  final EatovaSync? sync;
  final HealthService health;
  final NotificationService notificationService;
  final String initialUserName;
  final LocalCache? debugCache;
  final SnackEmitter _emitSnack;

  bool _disposed = false;

  // --- State (vormals Felder von _EatovaHomePageState) --------------------
  // Tab-Indizes nach dem Entfernen von Heute/Training/Trends:
  // 0 = Food, 1 = Rezepte, 2 = Coach.
  int selectedTab = 0;
  int dailyConsumedKcal = 0;
  int dailySteps = 0;
  DateTime selectedFoodDate = DateUtils.dateOnly(DateTime.now());
  UserProfile profile = const UserProfile();
  MacroProgress macroProgress = MacroProgress.empty;
  List<FavoriteMeal> favorites = <FavoriteMeal>[];
  List<LoggedMeal> loggedMeals = <LoggedMeal>[];
  List<FitnessRecipe> _userRecipes = const <FitnessRecipe>[];
  WeightLog weightLog = const WeightLog();
  LifetimeStats lifetimeStats = LifetimeStats();
  String userName = 'Moritz';

  LocalCache? _cache;
  bool _hydratedFromRealSource = false;

  // --- Read-only Sichten fuer die UI-Schale --------------------------------
  List<FitnessRecipe> get userRecipes => _userRecipes;

  String get profileInitial {
    final parts = userName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return 'S';
    return parts.first.substring(0, 1).toUpperCase();
  }

  /// Kompakter Tages-/Profil-Snapshot für den AI-Coach, damit er konkret statt
  /// generisch beraten kann (z.B. „dir fehlen heute 38 g Protein").
  String get coachContext {
    final p = profile;
    final remKcal = p.dailyKcalGoal - dailyConsumedKcal;
    final remProt = (p.proteinGoalG - macroProgress.proteinG).round();
    final remCarbs = (p.carbsGoalG - macroProgress.carbsG).round();
    final remFat = (p.fatGoalG - macroProgress.fatG).round();
    final lines = [
      'Körpergewicht: ${p.weightKg} kg (Ziel ${p.targetWeightKg} kg).',
      'Heute gegessen: $dailyConsumedKcal von ${p.dailyKcalGoal} kcal '
          '(noch $remKcal kcal übrig).',
      'Makros heute noch offen: Protein $remProt g, Kohlenhydrate $remCarbs g, '
          'Fett $remFat g.',
    ];
    // Konkrete Lebensmittel-Namen zuletzt anhängen, damit der Coach auf „was
    // habe ich heute gegessen?" antworten kann. Bewusst als LETZTE Zeile: der
    // 600-Zeichen-Cap der Edge Function kappt so nur die Essensliste, nie die
    // kcal-/Makro-Kernwerte davor.
    final foods = _todaysFoodSummary();
    if (foods != null) lines.add(foods);
    return lines.join(' ');
  }

  /// Kompakte Auflistung der heute geloggten Mahlzeiten (Slot: Name (kcal)),
  /// oder null wenn nichts geloggt ist. Gekappt auf [maxFoods] Einträge und
  /// die Namen auf 40 Zeichen, damit der Kontext den 600-Zeichen-Rahmen der
  /// Edge Function nicht sprengt; bei mehr Einträgen signalisiert „…" die
  /// gekürzte Liste.
  String? _todaysFoodSummary() {
    const maxFoods = 10;
    final meals = mealsForFoodDate(DateTime.now());
    if (meals.isEmpty) return null;
    final shown = meals.take(maxFoods).map((m) {
      final raw = m.result.mealName.trim();
      final name = raw.isEmpty
          ? 'Mahlzeit'
          : (raw.length > 40 ? '${raw.substring(0, 39)}…' : raw);
      return '${m.slot.label}: $name (${m.result.caloriesKcal} kcal)';
    }).join(', ');
    final suffix = meals.length > maxFoods ? ' …' : '';
    return 'Heute gegessene Lebensmittel — $shown$suffix.';
  }

  bool get selectedFoodDateIsToday =>
      _isSameFoodDate(selectedFoodDate, DateTime.now());

  // Reine Aggregation lebt in services/meal_totals.dart (unit-getestet) — hier
  // nur dünne Wrapper, die den aktuellen loggedMeals-Stand binden.
  List<LoggedMeal> mealsForFoodDate(DateTime date) =>
      totals.mealsForFoodDate(loggedMeals, date);

  int consumedKcalForFoodDate(DateTime date) =>
      totals.consumedKcalForFoodDate(loggedMeals, date);

  MacroProgress macroProgressForFoodDate(DateTime date) =>
      totals.macroProgressForFoodDate(loggedMeals, date);

  // --- interne Helfer -------------------------------------------------------
  /// Fuehrt [fn] aus und benachrichtigt danach die Listener (ersetzt das alte
  /// `setState`). Nach dispose ein No-Op auf der Notify-Seite.
  void _mutate(VoidCallback fn) {
    fn();
    if (!_disposed) notifyListeners();
  }

  bool _isSameFoodDate(DateTime a, DateTime b) => DateUtils.isSameDay(a, b);

  DateTime _timestampForFoodDate(DateTime date) {
    final now = DateTime.now();
    final day = DateUtils.dateOnly(date);
    return DateTime(day.year, day.month, day.day, now.hour, now.minute);
  }
}

/// ARCH-4: Single source of truth fuer den Home-State. Frueher lebten diese ~40
/// Felder + ~50 Mutationen als God-Object direkt im `_EatovaHomePageState`, wo
/// jede Mutation ueber `setState` den GANZEN Home-Baum neu baute (Wurzel der
/// PERF-2-Rebuild-Schulden). Jetzt ist der State ein [ChangeNotifier]: die UI
/// haengt sich per `ListenableBuilder`/Slice-Selector dran und rebuildet gezielt.
///
/// Der Store kennt KEINEN BuildContext. Navigation + modale Sheets bleiben in der
/// State-Schale; nutzerseitige Meldungen laufen ueber den injizierten
/// [SnackEmitter]. Verhalten ist 1:1 zum vorherigen God-Object — die 283 Tests
/// gelten als Charakterisierung.
///
/// Der Store ist bewusst EINE Klasse (dutzende Tests + Widgets haengen an der
/// API), die Datei war aber auf ~1600 Zeilen angewachsen. Deshalb ist die
/// Klasse rein mechanisch in `part`-Dateien/Mixins aufgeteilt — gleiche
/// Library, identisches Verhalten, private Member bleiben privat:
///  * `home_store.dart`          — Klassenkern: Konstruktor, Boot/Hydration,
///    gemeinsamer State + Sichten ([_HomeStoreBase]), Tab/Datum, dispose
///  * `home_store_sync.dart`     — Outbox (DATA-7) mit Replay/Backoff,
///    Stats-Deltas, Cache-Write-Through, Fehler-/Snack-Pfade, Konto-Cleanup
///  * `home_store_meals.dart`    — Mahlzeiten loggen/editieren/loeschen,
///    Favoriten/Recents, Eigen-Rezepte, Archive-Day-Loading
///  * `home_store_profile.dart`  — Profil/Settings, Onboarding, Erinnerungen
///  * `home_store_tracking.dart` — Gewicht, Health-Import, Streak
class HomeStore extends _HomeStoreBase
    with
        _HomeStoreSyncPart,
        _HomeStoreTrackingPart,
        _HomeStoreProfilePart,
        _HomeStoreMealsPart {
  HomeStore({
    required super.sync,
    required super.health,
    required super.notificationService,
    required super.initialUserName,
    required super.emitSnack,
    super.debugCache,
  }) {
    userName = initialUserName;
  }

  final Completer<void> _profileReadyCompleter = Completer<void>();

  Future<void> get profileReady => _profileReadyCompleter.future;

  // --- Boot / Hydration -----------------------------------------------------

  /// Startet den Boot. Ohne Sync (Test/Preview) ist sofort „ready"; mit Sync
  /// zuerst aus dem durablen Cache hydratisieren, dann der Netz-Boot.
  void start() {
    if (sync == null) {
      if (!_profileReadyCompleter.isCompleted) _profileReadyCompleter.complete();
      return;
    }
    unawaited(_hydrateThenBoot());
  }

  Future<void> _hydrateThenBoot() async {
    final s = sync;
    if (s == null) return;
    if (debugCache != null) {
      _cache = debugCache;
    } else {
      final userId = s.client.auth.currentUser?.id;
      if (userId != null && userId.isNotEmpty) {
        _cache = await LocalCache.create(userId);
      }
    }
    if (_cache != null) {
      await _hydrateFromCache();
    }
    // Outbox VOR dem Server-Load nachspielen (best effort): so enthaelt der
    // folgende Refresh die nachgeholten Writes bereits. Offline scheitert der
    // Replay einfach — die Ops bleiben liegen und werden beim Boot-Merge
    // (_applyPendingOpsToState) ueber die Server-Daten gelegt.
    await _replayOutbox();
    await _bootFromSupabase();
    // Beim letzten Lauf haengengebliebene (persistierte) Stats-Deltas jetzt
    // nachreichen — der Boot-Load hat lifetimeStats gerade frisch gesetzt,
    // increment_lifetime_stats addiert serverseitig-atomar obendrauf.
    if (_pendingMealsDelta != 0 || _pendingWeightLogsDelta != 0) {
      unawaited(_flushStatsDelta());
    }
    await _initNotificationsFromCache();
  }

  Future<void> _hydrateFromCache() async {
    final cache = _cache;
    if (cache == null) return;
    final today = DateTime.now();
    UserProfile? cachedProfile;
    LifetimeStats? cachedStats;
    List<LoggedMeal>? cachedMeals;
    List<FavoriteMeal>? cachedFavorites;
    WeightLog? cachedWeightLog;
    List<SyncOp>? cachedOutbox;
    ({int meals, int weightLogs})? cachedDeltas;
    try {
      cachedProfile = await cache.readProfile();
      cachedStats = await cache.readLifetimeStats();
      cachedMeals = await cache.readLoggedMeals();
      cachedFavorites = await cache.readFavorites();
      cachedWeightLog = await cache.readWeightLog();
      cachedOutbox = await cache.readOutbox();
      cachedDeltas = await cache.readPendingStatsDeltas();
    } catch (e, st) {
      dev.log('LocalCache hydrate failed',
          error: e, stackTrace: st, name: 'local_cache');
      unawaited(CrashReporter.capture(e, st, context: 'cache-hydrate'));
    }
    if (_disposed) return;
    // Outbox + Stats-Deltas IMMER uebernehmen — das ist der kill-sichere Teil
    // des Sync-Zustands, unabhaengig davon, ob sonst etwas gecacht war.
    if (cachedOutbox != null) _outbox = cachedOutbox;
    if (cachedDeltas != null) {
      _pendingMealsDelta += cachedDeltas.meals;
      _pendingWeightLogsDelta += cachedDeltas.weightLogs;
    }
    if (cachedProfile == null &&
        cachedStats == null &&
        cachedMeals == null &&
        cachedFavorites == null &&
        cachedWeightLog == null &&
        _outbox.isEmpty) {
      return;
    }
    _mutate(() {
      if (cachedProfile != null) {
        profile = cachedProfile;
        _hydratedFromRealSource = true;
      }
      if (cachedStats != null) {
        lifetimeStats = cachedStats;
      }
      if (cachedMeals != null) loggedMeals = cachedMeals;
      if (cachedFavorites != null) favorites = cachedFavorites;
      if (cachedWeightLog != null) weightLog = cachedWeightLog;
      _applyPendingOpsToState();
      dailyConsumedKcal = consumedKcalForFoodDate(today);
      macroProgress = macroProgressForFoodDate(today);
    });
  }

  Future<void> _bootFromSupabase() async {
    final s = sync!;
    final today = DateTime.now();
    final results = await Future.wait<Object?>([
      _safeLoad('boot-profile', () => s.profile.load()),
      _safeLoad('boot-meals', () => s.meals.loadLoggedMeals()),
      _safeLoad('boot-favorites', () => s.meals.loadFavorites()),
      _safeLoad('boot-weight-log', () => s.tracking.loadWeightLog()),
      _safeLoad('boot-lifetime-stats', () => s.lifetimeStats.load()),
      _safeLoad('boot-user-recipes', () => s.userRecipes.load()),
    ]);
    if (_disposed) return;
    _mutate(() {
      final loadedProfile = results[0] as UserProfile?;
      if (loadedProfile != null) {
        profile = loadedProfile;
        _hydratedFromRealSource = true;
      }

      final loadedMeals = results[1] as List<LoggedMeal>?;
      if (loadedMeals != null) {
        loggedMeals = loadedMeals;
        // Der frische Fenster-Load ERSETZT die Liste komplett — zuvor
        // nachgeladene Alt-Tage sind damit wieder draussen und muessen bei
        // erneuter Auswahl neu geladen werden. Ohne dieses Reset wuerde der
        // Session-Cache den Tag als „geladen" fuehren und einen leeren Tag
        // anzeigen; Geister-Duplikate entstehen umgekehrt nie, weil die
        // Merge-Quelle immer der Server-Stand des Tages ist (Dedup per id).
        _loadedArchiveDays.clear();
      }

      final loadedFavorites = results[2] as List<FavoriteMeal>?;
      if (loadedFavorites != null) favorites = loadedFavorites;

      final loadedWeightLog = results[3] as WeightLog?;
      if (loadedWeightLog != null) weightLog = loadedWeightLog;

      final loadedStats = results[4] as LifetimeStats?;
      if (loadedStats != null) {
        lifetimeStats = loadedStats;
      }

      final loadedRecipes = results[5] as List<FitnessRecipe>?;
      if (loadedRecipes != null) _userRecipes = loadedRecipes;

      // Cache-then-network-Merge: Server-Daten gewinnen fuer synchronisierte
      // Eintraege, aber noch nicht synchronisierte Outbox-Writes bleiben
      // sichtbar (sonst wuerde der frische Server-Load z.B. eine offline
      // geloggte Mahlzeit wieder aus dem Tagebuch werfen).
      _applyPendingOpsToState();

      dailyConsumedKcal = consumedKcalForFoodDate(today);
      macroProgress = macroProgressForFoodDate(today);
    });
    // Haengt die Auswahl gerade auf einem Alt-Tag (Boot lief waehrend eines
    // Kalender-Besuchs), den Tag direkt wieder nachladen statt ihn nach dem
    // Fenster-Replace leer anzuzeigen.
    if (_isOutsideBootWindow(selectedFoodDate)) {
      unawaited(_ensureArchiveDayLoaded(selectedFoodDate));
    }
    unawaited(_writeCacheSnapshot());
    if (!_profileReadyCompleter.isCompleted) {
      _profileReadyCompleter.complete();
    }
  }

  Future<T?> _safeLoad<T>(
      String operation, Future<T?> Function() loader) async {
    try {
      return await loader();
    } catch (e, st) {
      dev.log('Eatova load failed ($operation)',
          error: e, stackTrace: st, name: 'eatova_sync');
      unawaited(CrashReporter.capture(e, st, context: operation));
      return null;
    }
  }

  // --- Tab / Datum ----------------------------------------------------------

  void setTab(int index) => _mutate(() => selectedTab = index);

  void setFoodDate(DateTime date) {
    final day = DateUtils.dateOnly(date);
    _mutate(() => selectedFoodDate = day);
    // Kalender-Auswahl ausserhalb des Boot-Fensters: den Tag on-demand
    // nachladen statt einen faelschlich leeren Tag zu zeigen.
    if (_isOutsideBootWindow(day)) {
      unawaited(_ensureArchiveDayLoaded(day));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _statsSaveDebounce?.cancel();
    _outboxRetryTimer?.cancel();
    sync?.dispose();
    super.dispose();
  }
}
