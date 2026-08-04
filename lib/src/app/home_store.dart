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
import '../services/fitpilot_sync.dart';
import '../services/health_service.dart';
import '../services/local_cache.dart';
import '../services/meal_totals.dart' as totals;
import '../services/notification_service.dart';
import '../services/streak_reminder_planner.dart';
import '../services/uuid.dart';
import '../theme/app_colors.dart';
import '../widgets/common/app_snack.dart';

/// Vom [HomeStore] ausgesendete, context-FREIE Snackbar-Anforderung. Der Store
/// haelt bewusst nie einen BuildContext (ARCH-4 Store-Seam) — er signalisiert
/// nur „zeige diese Meldung", die `_ShiftFitHomePageState` uebersetzt das in ein
/// echtes [showAppSnack]. So bleibt die gesamte Sync-/Rollback-Logik testbar und
/// vom Widget-Baum entkoppelt.
typedef SnackEmitter = void Function(
  String message, {
  IconData icon,
  Color accent,
  Duration? duration,
  SnackBarAction? action,
});

/// ARCH-4: Single source of truth fuer den Home-State. Frueher lebten diese ~40
/// Felder + ~50 Mutationen als God-Object direkt im `_ShiftFitHomePageState`, wo
/// jede Mutation ueber `setState` den GANZEN Home-Baum neu baute (Wurzel der
/// PERF-2-Rebuild-Schulden). Jetzt ist der State ein [ChangeNotifier]: die UI
/// haengt sich per `ListenableBuilder`/Slice-Selector dran und rebuildet gezielt.
///
/// Der Store kennt KEINEN BuildContext. Navigation + modale Sheets bleiben in der
/// State-Schale; nutzerseitige Meldungen laufen ueber den injizierten
/// [SnackEmitter]. Verhalten ist 1:1 zum vorherigen God-Object — die 283 Tests
/// gelten als Charakterisierung.
class HomeStore extends ChangeNotifier {
  HomeStore({
    required this.sync,
    required this.health,
    required this.notificationService,
    required this.initialUserName,
    required SnackEmitter emitSnack,
    this.debugCache,
  })  : _emitSnack = emitSnack {
    userName = initialUserName;
  }

  final FitPilotSync? sync;
  final HealthService health;
  final NotificationService notificationService;
  final String initialUserName;
  final LocalCache? debugCache;
  final SnackEmitter _emitSnack;

  bool _disposed = false;

  // --- State (vormals Felder von _ShiftFitHomePageState) --------------------
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
  HealthAuthState healthAuthState = HealthAuthState.unknown;
  DateTime? healthLastFetch;
  bool healthSyncing = false;

  /// In-Memory-Dedup fuer das HealthKit-Gewichts-Angebot: refreshHealthSteps()
  /// laeuft bei Kaltstart UND jedem App-Resume — ohne Dedup wuerde der
  /// „uebernehmen?"-Snack bei jedem Resume erneut aufpoppen. Merkt sich den
  /// zuletzt ANGEBOTENEN Wert; bewusst nicht persistiert (nach App-Neustart
  /// darf einmal erneut angeboten werden).
  double? _lastOfferedHealthWeightKg;
  LifetimeStats lifetimeStats = LifetimeStats();
  Timer? _statsSaveDebounce;

  bool _notificationsEnabled = false;
  int _pendingMealsDelta = 0;
  int _pendingWeightLogsDelta = 0;
  bool _statsFlushInFlight = false;
  String userName = 'Moritz';
  bool _onboardingDone = false;
  final Completer<void> _profileReadyCompleter = Completer<void>();

  LocalCache? _cache;
  bool _hydratedFromRealSource = false;

  // --- Read-only Sichten fuer die UI-Schale --------------------------------
  List<FitnessRecipe> get userRecipes => _userRecipes;
  bool get notificationsEnabled => _notificationsEnabled;
  Future<void> get profileReady => _profileReadyCompleter.future;

  /// Onboarding ist Pflicht, sobald ein echter Supabase-Sync existiert und das
  /// Profil noch nicht durchlaufen wurde. Ohne Sync (Test/Preview) nie.
  bool get needsOnboarding =>
      sync != null && !_onboardingDone && !profile.onboardingCompleted;

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
    await _bootFromSupabase();
    await _initNotificationsFromCache();
  }

  Future<void> _hydrateFromCache() async {
    final cache = _cache;
    if (cache == null) return;
    final today = DateTime.now();
    UserProfile? cachedProfile;
    LifetimeStats? cachedStats;
    try {
      cachedProfile = await cache.readProfile();
      cachedStats = await cache.readLifetimeStats();
    } catch (e, st) {
      dev.log('LocalCache hydrate failed',
          error: e, stackTrace: st, name: 'local_cache');
    }
    if (_disposed) return;
    if (cachedProfile == null && cachedStats == null) {
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
      dailyConsumedKcal = consumedKcalForFoodDate(today);
      macroProgress = macroProgressForFoodDate(today);
    });
  }

  Future<void> _bootFromSupabase() async {
    final s = sync!;
    final today = DateTime.now();
    final results = await Future.wait<Object?>([
      _safeLoad(() => s.profile.load()),
      _safeLoad(() => s.meals.loadLoggedMeals()),
      _safeLoad(() => s.meals.loadFavorites()),
      _safeLoad(() => s.tracking.loadWeightLog()),
      _safeLoad(() => s.lifetimeStats.load()),
      _safeLoad(() => s.userRecipes.load()),
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

      dailyConsumedKcal = consumedKcalForFoodDate(today);
      macroProgress = macroProgressForFoodDate(today);
    });
    unawaited(_writeCacheSnapshot());
    if (!_profileReadyCompleter.isCompleted) {
      _profileReadyCompleter.complete();
    }
  }

  Future<T?> _safeLoad<T>(Future<T?> Function() loader) async {
    try {
      return await loader();
    } catch (e, st) {
      dev.log('FitPilot load failed',
          error: e, stackTrace: st, name: 'fitpilot_sync');
      return null;
    }
  }

  // --- Fehler-/Sync-Routing -------------------------------------------------

  void _reportSyncError(String operation, Object error) {
    dev.log('$operation failed', error: error, name: 'fitpilot_sync');
    if (_disposed) return;
    final msg = error.toString();
    final short = msg.length > 140 ? '${msg.substring(0, 140)}…' : msg;
    _emitSnack(
      'Sync ($operation): $short',
      icon: Icons.error_outline_rounded,
      accent: danger,
      duration: kSnackError,
    );
  }

  /// Fire-and-forget Sync-Write MIT Rollback: schlägt der Write fehl, wird der
  /// Fehler sichtbar gemeldet UND der optimistische lokale State via [restore]
  /// zurückgerollt — sonst driften lokal und Remote auseinander.
  void _syncWithRollback(
    String operation,
    Future<void>? future,
    VoidCallback restore,
  ) {
    future?.catchError((Object e) {
      _reportSyncError(operation, e);
      if (!_disposed) _mutate(restore);
    });
  }

  void _showUndoSnackBar(String label, VoidCallback onUndo) {
    if (_disposed) return;
    _emitSnack(
      label,
      icon: Icons.delete_outline_rounded,
      accent: danger,
      action: SnackBarAction(label: 'Rückgängig', onPressed: onUndo),
    );
  }

  /// DSGVO Art. 17: löscht Konto + alle Daten serverseitig (RPC). Liefert true,
  /// wenn die Löschung durchlief (dann darf die Schale ausloggen). Bei Fehler
  /// false (kein Logout, damit der User es erneut versuchen kann).
  Future<bool> deleteAccount() async {
    try {
      await sync?.deleteAccount();
    } catch (e) {
      _reportSyncError('Konto-Löschung', e);
      return false;
    }
    await _clearCache();
    return true;
  }

  /// Räumt den lokalen Klartext-PII-Cache (Profil, Mood-Notiz, Lifetime-Stats,
  /// Notification-Flag) beim Sign-Out — anders als [deleteAccount] OHNE
  /// Server-RPC. Ohne diesen Schritt überlebten Gesundheits-/Profildaten den
  /// Logout unverschlüsselt in den SharedPreferences (Audit 2026-06-09, M-1).
  /// Muss VOR dem eigentlichen `signOut()` laufen, solange der User noch der
  /// aktuelle ist — der defensive Pfad braucht dessen ID.
  Future<void> signOutCleanup() => _clearCache();

  /// Löscht den lokalen Cache. Bevorzugt den bereits gebooteten [_cache], im
  /// Test den injizierten [debugCache]; kommt der Logout vor dem Boot-Ende
  /// (noch kein _cache), wird er defensiv aus der aktuellen Session-User-ID
  /// gebaut, damit auch dann nichts liegen bleibt.
  Future<void> _clearCache() async {
    final cache = _cache ?? debugCache ?? await _resolveCacheForCurrentUser();
    await cache?.clear();
  }

  Future<LocalCache?> _resolveCacheForCurrentUser() async {
    final userId = sync?.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return null;
    return LocalCache.create(userId);
  }

  // --- Persistenz-Helfer ----------------------------------------------------

  Future<void> _writeCacheSnapshot() async {
    final cache = _cache;
    if (cache == null) return;
    await cache.writeProfile(profile);
    await cache.writeLifetimeStats(lifetimeStats);
  }

  void _cacheLifetimeStats() {
    unawaited(_cache?.writeLifetimeStats(lifetimeStats) ?? Future<void>.value());
  }

  /// Schreibt den heutigen Logging-Tag serverseitig in die Streak
  /// (record_tracking_day, idempotent pro Tag) und adoptiert die frische
  /// Server-Zeile. Fehler bleiben still — der optimistische lokale
  /// recordTrackedDay-Stand gilt dann bis zum naechsten Load/Log weiter.
  void _recordTrackingDay() {
    final s = sync;
    if (s == null) return;
    s.lifetimeStats.recordTrackingDay(DateTime.now()).then((fresh) {
      if (_disposed) return;
      _mutate(() => lifetimeStats = fresh);
      _cacheLifetimeStats();
    }).catchError((Object e) {
      dev.log('recordTrackingDay failed', error: e, name: 'home_store');
    });
  }

  // --- Erinnerungen (PROD-1) ------------------------------------------------
  // Einziger Inhalt seit dem Heute-Tab-Aus: der abendliche Streak-Retter
  // (streak_reminder_planner.dart). Der Opt-in-Toggle + die Permission-Strecke
  // bleiben der Andock-Punkt fuer alles Weitere.

  Future<void> _initNotificationsFromCache() async {
    final cache = _cache;
    if (cache == null) return;
    final enabled = await cache.readNotificationsEnabled() ?? false;
    if (_disposed) return;
    if (!enabled) return;
    _mutate(() => _notificationsEnabled = true);
    await notificationService.init();
    // Boot mit aktiviertem Opt-in: Reminder-Fenster frisch aufziehen (die
    // Permission wurde beim Einschalten bereits erteilt, kein Re-Prompt).
    await _rescheduleStreakReminder();
  }

  Future<void> _setNotificationsEnabled(bool enabled) async {
    if (!_disposed) {
      _mutate(() => _notificationsEnabled = enabled);
    } else {
      _notificationsEnabled = enabled;
    }
    unawaited(
        _cache?.writeNotificationsEnabled(enabled) ?? Future<void>.value());
    if (enabled) {
      await notificationService.init();
      final granted = await notificationService.requestPermission();
      // Nur nach erteilter Permission planen — ohne sie wuerde zonedSchedule
      // ins Leere laufen (bzw. auf Android 13+ still verpuffen).
      if (granted) await _rescheduleStreakReminder();
    } else {
      await notificationService.cancelAll();
    }
  }

  /// Plant die abendlichen Streak-Reminder fuer die naechsten 7 Tage neu.
  /// scheduleAll arbeitet cancel-first, daher immer die volle Planner-Liste —
  /// kein Duplikat-Risiko bei wiederholten Aufrufen (Boot, Toggle, jeder Log).
  /// Guard: ohne Opt-in wird nie geplant.
  Future<void> _rescheduleStreakReminder() async {
    if (!_notificationsEnabled) return;
    await notificationService
        .scheduleAll(planStreakReminders(DateTime.now(), lifetimeStats));
  }

  /// Schaltet Erinnerungen ein/aus (Settings-Toggle). Oeffentliche Fassade fuer
  /// die Schale.
  Future<void> setNotificationsEnabled(bool enabled) =>
      _setNotificationsEnabled(enabled);

  // --- Lifetime-Stats-Deltas ------------------------------------------------

  void _queueStatsDelta({
    int meals = 0,
    int weightLogs = 0,
  }) {
    if (sync == null) return;
    _pendingMealsDelta += meals;
    _pendingWeightLogsDelta += weightLogs;
    _cacheLifetimeStats();
    _statsSaveDebounce?.cancel();
    _statsSaveDebounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(_flushStatsDelta());
    });
  }

  Future<void> _flushStatsDelta() async {
    final s = sync;
    if (s == null) return;
    if (_statsFlushInFlight) return;
    final meals = _pendingMealsDelta;
    final weightLogs = _pendingWeightLogsDelta;
    if (meals == 0 && weightLogs == 0) return;
    _pendingMealsDelta = 0;
    _pendingWeightLogsDelta = 0;
    _statsFlushInFlight = true;
    final prevStats = lifetimeStats;
    try {
      final fresh = await s.lifetimeStats.increment(
        meals: meals,
        weightLogs: weightLogs,
      );
      if (!_disposed) {
        _mutate(() {
          lifetimeStats = fresh;
        });
      }
      _cacheLifetimeStats();
    } catch (e) {
      _pendingMealsDelta += meals;
      _pendingWeightLogsDelta += weightLogs;
      _reportSyncError('Statistik', e);
      if (!_disposed) _mutate(() => lifetimeStats = prevStats);
    } finally {
      _statsFlushInFlight = false;
    }
  }

  /// Schreibt ausstehende debounced Writes sofort weg (App-Backgrounding).
  void flushPendingWrites() {
    final s = sync;
    if (s == null) return;
    _statsSaveDebounce?.cancel();
    _statsSaveDebounce = null;
    unawaited(_flushStatsDelta());
  }

  // --- Health ---------------------------------------------------------------

  Future<void> connectHealth() async {
    if (_disposed) return;
    _mutate(() => healthSyncing = true);
    final state = await health.requestAuthorization();
    if (_disposed) return;
    _mutate(() => healthAuthState = state);
    if (state == HealthAuthState.granted) {
      await refreshHealthSteps();
    } else {
      _mutate(() => healthSyncing = false);
    }
  }

  Future<void> refreshHealthSteps() async {
    if (_disposed) return;
    _mutate(() => healthSyncing = true);
    final snapshot = await health.readSnapshot();
    if (_disposed) return;
    _mutate(() {
      healthSyncing = false;
      if (snapshot != null) {
        dailySteps = snapshot.stepsToday;
        healthLastFetch = snapshot.fetchedAt;
        healthAuthState = HealthAuthState.granted;
      }
    });
    // Gewichts-Import-Pfad: das Snapshot-Gewicht nicht laenger wegwerfen,
    // sondern (dedupliziert) zum Uebernehmen anbieten.
    if (snapshot != null) {
      _maybeOfferHealthWeight(snapshot.latestWeightKg);
    }
  }

  /// Bietet ein aus Apple Health gelesenes Gewicht per Snack zum Uebernehmen
  /// an. Angeboten wird nur, wenn
  ///  * ueberhaupt ein Wert im Snapshot steckt,
  ///  * er sinnvoll vom letzten geloggten Gewicht abweicht (>= 0.1 kg) ODER
  ///    noch nie gewogen wurde,
  ///  * derselbe Wert nicht schon einmal angeboten wurde (In-Memory-Dedup,
  ///    siehe [_lastOfferedHealthWeightKg]).
  /// Nach einem Import greift die 0.1-kg-Schwelle von selbst, weil
  /// weightLog.latest dann == kg ist — kein erneutes Angebot.
  void _maybeOfferHealthWeight(double? kg) {
    if (_disposed || kg == null || kg <= 0) return;
    final lastLogged = weightLog.latest?.weightKg;
    if (lastLogged != null && (kg - lastLogged).abs() < 0.1) return;
    if (_lastOfferedHealthWeightKg == kg) return;
    _lastOfferedHealthWeightKg = kg;
    // Deutsche Formatierung: Komma, eine Nachkommastelle (z.B. "82,4").
    final label = kg.toStringAsFixed(1).replaceAll('.', ',');
    _emitSnack(
      'Apple Health: $label kg übernehmen?',
      icon: Icons.monitor_weight_outlined,
      accent: lime,
      // Unaufgefordertes Angebot beim Resume/Kaltstart: etwas laenger sichtbar
      // als Standard-Action-Snacks (kSnackAction), damit der Tap realistisch
      // treffbar ist, bevor der Toast von selbst verschwindet.
      duration: const Duration(milliseconds: 3500),
      action: SnackBarAction(
        label: 'Übernehmen',
        onPressed: () => importHealthWeight(kg),
      ),
    );
  }

  // --- Koerperdaten (Profil) ------------------------------------------------

  /// Manuelles Wiegen (User tippt den Wert ein): loggt lokal + synct + spiegelt
  /// den Wert per Write-Back nach HealthKit.
  void logWeight(double kg) => _logWeightInternal(kg, writeToHealth: true);

  /// Import AUS Apple Health (Tap auf die „Übernehmen"-Snack-Aktion): identisch
  /// zu [logWeight], aber OHNE `health.writeWeight` — der Wert stammt ja aus
  /// HealthKit, ein Write-Back wuerde dort ein Echo-Duplikat anlegen.
  void importHealthWeight(double kg) =>
      _logWeightInternal(kg, writeToHealth: false);

  /// Gemeinsamer Kern von [logWeight] und [importHealthWeight]. Die leichte
  /// Haptik laeuft bewusst in BEIDEN Pfaden: auch der Import wird durch einen
  /// User-Tap (Snack-Aktion) ausgeloest, die Bestaetigung ist also konsistent.
  void _logWeightInternal(double kg, {required bool writeToHealth}) {
    HapticFeedback.lightImpact();
    final ts = DateTime.now();
    final prevWeightLog = weightLog;
    final prevStats = lifetimeStats;
    _mutate(() {
      weightLog = weightLog.add(kg);
      lifetimeStats = lifetimeStats.incrementWeightLogs();
    });
    if (writeToHealth) {
      unawaited(health.writeWeight(kg, ts));
    }
    final s = sync;
    if (s == null) return;
    s.tracking.insertWeight(kg, ts).then((_) {
      _queueStatsDelta(weightLogs: 1);
    }).catchError((Object e) {
      _reportSyncError('Gewicht', e);
      if (!_disposed) {
        _mutate(() {
          weightLog = prevWeightLog;
          lifetimeStats = prevStats;
        });
        // Import-Rollback: Dedup-Marker wieder freigeben. Der Wert wurde NICHT
        // uebernommen — ohne Reset wuerde _maybeOfferHealthWeight ihn fuer den
        // Rest der Session nie wieder anbieten. Nur im Import-Pfad relevant:
        // beim manuellen Wiegen ist ein frueheres Angebot bewusst abgelehnt
        // worden und soll nicht erneut nerven.
        if (!writeToHealth && _lastOfferedHealthWeightKg == kg) {
          _lastOfferedHealthWeightKg = null;
        }
      }
    });
  }

  // --- Mahlzeiten -----------------------------------------------------------

  String addResultToDailyTotal(
    MealAnalysisResult result, {
    MealSlot? slot,
    DateTime? foodDate,
  }) {
    final targetDate = DateUtils.dateOnly(foodDate ?? selectedFoodDate);
    final entry = LoggedMeal(
      id: uuidV4(),
      result: result,
      loggedAt: _timestampForFoodDate(targetDate),
      forcedSlot: slot,
    );
    final targetIsToday = _isSameFoodDate(targetDate, DateTime.now());
    HapticFeedback.lightImpact();
    final prevMeals = loggedMeals;
    final prevKcal = dailyConsumedKcal;
    final prevMacros = macroProgress;
    final prevStats = lifetimeStats;
    _mutate(() {
      lifetimeStats = lifetimeStats.incrementMeals();
      if (targetIsToday) {
        // Logging-Streak: der heutige Log-Tag zaehlt sofort (optimistisch,
        // idempotent pro Tag). Nachtraege fuer vergangene Tage zaehlen nicht.
        lifetimeStats = lifetimeStats.recordTrackedDay(DateTime.now());
      }
      _rememberRecent(result);
      loggedMeals = [entry, ...loggedMeals];
      if (targetIsToday) {
        dailyConsumedKcal = consumedKcalForFoodDate(DateTime.now());
        macroProgress = macroProgressForFoodDate(DateTime.now());
      }
    });
    if (targetIsToday) {
      // Heute ist jetzt getrackt -> heutigen 20-Uhr-Reminder fallen lassen
      // und das 7-Tage-Fenster ab morgen neu aufziehen. Der optimistische
      // recordTrackedDay-Stand oben reicht dem Planner; der spaetere
      // Server-Refresh via _recordTrackingDay aendert am Plan nichts mehr.
      unawaited(_rescheduleStreakReminder());
    }
    final s = sync;
    if (s == null) return entry.id;
    s.meals.insertLoggedMeal(entry).then((_) {
      _queueStatsDelta(meals: 1);
      if (targetIsToday) _recordTrackingDay();
    }).catchError((Object e) {
      _reportSyncError('Mahlzeit', e);
      if (!_disposed) {
        _mutate(() {
          loggedMeals = prevMeals;
          lifetimeStats = prevStats;
          dailyConsumedKcal = prevKcal;
          macroProgress = prevMacros;
        });
        if (targetIsToday) {
          // Rollback macht heute wieder "ungetrackt" — den oben bereits
          // gecancelten heutigen 20-Uhr-Reminder zurueckholen, sonst bliebe
          // ausgerechnet der Abend ohne Streak-Retter, an dem der Log
          // fehlgeschlagen ist.
          unawaited(_rescheduleStreakReminder());
        }
      }
    });
    return entry.id;
  }

  void updateLoggedMealResult(String id, MealAnalysisResult scaled) {
    final index = loggedMeals.indexWhere((m) => m.id == id);
    if (index == -1) return;
    final target = loggedMeals[index];
    final prevMeals = loggedMeals;
    final prevKcal = dailyConsumedKcal;
    final prevMacros = macroProgress;
    final updated = target.copyWith(result: scaled);
    _mutate(() {
      final nextMeals = [...loggedMeals];
      nextMeals[index] = updated;
      loggedMeals = nextMeals;
      if (selectedFoodDateIsToday) {
        dailyConsumedKcal = consumedKcalForFoodDate(DateTime.now());
        macroProgress = macroProgressForFoodDate(DateTime.now());
      }
    });
    _syncWithRollback(
      'Mahlzeit-Update',
      sync?.meals.updateLoggedMeal(updated),
      () {
        loggedMeals = prevMeals;
        dailyConsumedKcal = prevKcal;
        macroProgress = prevMacros;
      },
    );
  }

  void removeLoggedMeal(String id) {
    final matches = loggedMeals.where((m) => m.id == id);
    final removed = matches.isEmpty ? null : matches.first;
    HapticFeedback.lightImpact();
    final prevMeals = loggedMeals;
    final prevKcal = dailyConsumedKcal;
    final prevMacros = macroProgress;
    _mutate(() {
      loggedMeals = loggedMeals.where((m) => m.id != id).toList();
      if (selectedFoodDateIsToday) {
        dailyConsumedKcal = consumedKcalForFoodDate(DateTime.now());
        macroProgress = macroProgressForFoodDate(DateTime.now());
      }
    });
    _syncWithRollback(
      'Mahlzeit-Delete',
      sync?.meals.deleteLoggedMeal(id),
      () {
        loggedMeals = prevMeals;
        dailyConsumedKcal = prevKcal;
        macroProgress = prevMacros;
      },
    );
    if (removed != null) {
      _showUndoSnackBar('Mahlzeit gelöscht', () => _restoreLoggedMeal(removed));
    }
  }

  void _restoreLoggedMeal(LoggedMeal meal) {
    if (loggedMeals.any((m) => m.id == meal.id)) return;
    _mutate(() {
      loggedMeals = [meal, ...loggedMeals];
      if (selectedFoodDateIsToday) {
        dailyConsumedKcal = consumedKcalForFoodDate(DateTime.now());
        macroProgress = macroProgressForFoodDate(DateTime.now());
      }
    });
    _syncWithRollback(
      'Mahlzeit-Restore',
      sync?.meals.insertLoggedMeal(meal),
      () {
        loggedMeals = loggedMeals.where((m) => m.id != meal.id).toList();
        if (selectedFoodDateIsToday) {
          dailyConsumedKcal = consumedKcalForFoodDate(DateTime.now());
          macroProgress = macroProgressForFoodDate(DateTime.now());
        }
      },
    );
  }

  static const int _maxAutoRecents = 5;

  void _rememberRecent(MealAnalysisResult result) {
    final id = FavoriteMeal.idFor(result);
    final existing = favorites.where((f) => f.id == id);
    final wasPinned = existing.isNotEmpty && existing.first.pinned;
    final entry = FavoriteMeal(
      id: id,
      result: result,
      addedAt: DateTime.now(),
      pinned: wasPinned,
    );
    favorites =
        _cappedFavorites([entry, ...favorites.where((f) => f.id != id)]);
    sync?.meals
        .upsertFavorite(entry)
        .catchError((e) => _reportSyncError('Favorit', e));
  }

  List<FavoriteMeal> _cappedFavorites(List<FavoriteMeal> source) {
    final pinned = source.where((f) => f.pinned).toList(growable: false);
    final recents =
        source.where((f) => !f.pinned).take(_maxAutoRecents).toList();
    return [...pinned, ...recents];
  }

  bool isFavorite(MealAnalysisResult result) {
    final id = FavoriteMeal.idFor(result);
    final matches = favorites.where((f) => f.id == id);
    return matches.isNotEmpty && matches.first.pinned;
  }

  void toggleFavorite(MealAnalysisResult result) {
    HapticFeedback.selectionClick();
    final id = FavoriteMeal.idFor(result);
    final existing = favorites.where((f) => f.id == id);
    final isPinned = existing.isNotEmpty && existing.first.pinned;
    final prev = favorites;

    if (isPinned) {
      final downgraded = existing.first.copyWith(pinned: false);
      final next = _cappedFavorites(
        [...favorites.where((f) => f.id != id), downgraded]
          ..sort((a, b) => b.addedAt.compareTo(a.addedAt)),
      );
      final survived = next.any((f) => f.id == id);
      _mutate(() => favorites = next);
      if (survived) {
        _syncWithRollback(
          'Favorit',
          sync?.meals.upsertFavorite(downgraded),
          () => favorites = prev,
        );
      } else {
        _syncWithRollback(
          'Favorit-Delete',
          sync?.meals.deleteFavorite(id),
          () => favorites = prev,
        );
      }
    } else {
      final entry = existing.isNotEmpty
          ? existing.first.copyWith(pinned: true)
          : FavoriteMeal(
              id: id, result: result, addedAt: DateTime.now(), pinned: true);
      _mutate(() {
        favorites = [entry, ...favorites.where((f) => f.id != id)];
      });
      _syncWithRollback(
        'Favorit',
        sync?.meals.upsertFavorite(entry),
        () => favorites = prev,
      );
    }
  }

  void removeFavorite(String id) {
    final matches = favorites.where((f) => f.id == id);
    final removed = matches.isEmpty ? null : matches.first;
    final prev = favorites;
    _mutate(() {
      favorites = favorites.where((f) => f.id != id).toList();
    });
    _syncWithRollback(
      'Favorit-Delete',
      sync?.meals.deleteFavorite(id),
      () => favorites = prev,
    );
    if (removed != null) {
      _showUndoSnackBar('Favorit entfernt', () => _restoreFavorite(removed));
    }
  }

  void _restoreFavorite(FavoriteMeal fav) {
    if (favorites.any((f) => f.id == fav.id)) return;
    _mutate(() {
      favorites = fav.pinned
          ? [fav, ...favorites]
          : _cappedFavorites([fav, ...favorites]);
    });
    _syncWithRollback(
      'Favorit-Restore',
      sync?.meals.upsertFavorite(fav),
      () => favorites = favorites.where((f) => f.id != fav.id).toList(),
    );
  }

  // --- Eigen-Rezepte --------------------------------------------------------

  void createUserRecipe(FitnessRecipe recipe) {
    final prev = _userRecipes;
    _mutate(() {
      _userRecipes = [
        recipe,
        ..._userRecipes.where((r) => r.slug != recipe.slug)
      ];
    });
    _syncWithRollback(
      'Rezept',
      sync?.userRecipes.upsert(recipe),
      () => _userRecipes = prev,
    );
  }

  void deleteUserRecipe(String slug) {
    final prev = _userRecipes;
    _mutate(() {
      _userRecipes = _userRecipes.where((r) => r.slug != slug).toList();
    });
    _syncWithRollback(
      'Rezept-Delete',
      sync?.userRecipes.delete(slug),
      () => _userRecipes = prev,
    );
  }

  // --- Settings / Reset / Onboarding ---------------------------------------

  /// Wendet das im Settings-Sheet bearbeitete Profil + Flags an (das Sheet
  /// selbst lebt in der context-tragenden Schale). Spiegelt das frühere
  /// `_openSettings` ohne den UI-/Navigations-Teil.
  Future<void> applySettings({
    required UserProfile newProfile,
    required bool notificationsEnabled,
    required bool resetDay,
  }) async {
    if (notificationsEnabled != _notificationsEnabled) {
      unawaited(_setNotificationsEnabled(notificationsEnabled));
    }
    final canPersistProfile = _hydratedFromRealSource;
    _mutate(() {
      profile = newProfile;
      if (resetDay) {
        _clearTodayState();
      }
    });
    final s = sync;
    if (s != null) {
      if (canPersistProfile) {
        unawaited(_cache?.writeProfile(newProfile) ?? Future<void>.value());
      }
      try {
        if (canPersistProfile) {
          await s.profile.save(newProfile);
        } else {
          dev.log(
              'ProfileSync.save uebersprungen: profile basiert auf Ctor-Defaults '
              '(kein Server-/Cache-Hydrate) — Clobber-Schutz',
              name: 'fitpilot_sync');
        }
      } catch (e) {
        if (!_disposed) {
          _emitSnack('Profil-Sync: $e',
              icon: Icons.error_outline_rounded,
              accent: danger,
              duration: kSnackError);
        }
      }
    }
    if (resetDay && !_disposed) {
      _emitSnack('Tagesdaten zurückgesetzt.',
          icon: Icons.restart_alt_rounded, accent: orange);
    }
  }

  void _clearTodayState() {
    dailyConsumedKcal = 0;
    dailySteps = 0;
    macroProgress = MacroProgress.empty;
    loggedMeals = <LoggedMeal>[];
    selectedFoodDate = DateUtils.dateOnly(DateTime.now());
  }

  void resetTodayData() {
    _mutate(_clearTodayState);
    _emitSnack('Tagesdaten zurückgesetzt.',
        icon: Icons.restart_alt_rounded, accent: orange);
  }

  Future<void> completeOnboarding(UserProfile finished) async {
    _mutate(() {
      profile = finished;
      _onboardingDone = true;
      _hydratedFromRealSource = true;
    });
    final s = sync;
    if (s == null) return;
    unawaited(_cache?.writeProfile(finished) ?? Future<void>.value());
    unawaited(_setNotificationsEnabled(true));
    try {
      await s.profile.save(finished);
    } catch (e) {
      if (!_disposed) {
        _emitSnack('Profil-Sync: $e',
            icon: Icons.error_outline_rounded,
            accent: danger,
            duration: kSnackError);
      }
    }
  }

  // --- Tab / Datum ----------------------------------------------------------

  void setTab(int index) => _mutate(() => selectedTab = index);

  void setFoodDate(DateTime date) =>
      _mutate(() => selectedFoodDate = DateUtils.dateOnly(date));

  @override
  void dispose() {
    _disposed = true;
    _statsSaveDebounce?.cancel();
    sync?.dispose();
    super.dispose();
  }
}
