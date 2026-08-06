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

  // --- DATA-7 Write-Outbox --------------------------------------------------
  // Fehlgeschlagene Sync-Writes rollen den lokalen State NICHT mehr zurueck,
  // sondern landen als persistierte [SyncOp]s hier und werden idempotent
  // nachgespielt: beim Boot, beim Lifecycle-Flush (flushPendingWrites), nach
  // der naechsten erfolgreichen Operation und ueber den Backoff-Timer.
  List<SyncOp> _outbox = <SyncOp>[];
  bool _outboxReplayInFlight = false;
  Timer? _outboxRetryTimer;
  int _outboxRetryAttempt = 0;

  /// Der dezente Queue-Hinweis (Offline ODER "wird automatisch erneut
  /// versucht") wird pro Fehler-Episode nur EINMAL gezeigt (Reset beim
  /// naechsten Sync-Erfolg) — sonst wuerde jede weitere Aktion erneut toasten.
  /// Welcher der beiden Texte kommt, entscheidet der ERSTE Fehler der Episode
  /// (Klassifizierung: [isNetworkSyncError]).
  bool _syncHintShown = false;
  String userName = 'Moritz';
  bool _onboardingDone = false;
  final Completer<void> _profileReadyCompleter = Completer<void>();

  LocalCache? _cache;
  bool _hydratedFromRealSource = false;

  // --- On-Demand-Laden alter Tage (ausserhalb des Boot-Fensters) ------------
  // Der Boot laedt nur das 35-Tage-Fenster (MealsSync.loggedMealsWindowDays).
  // Waehlt der Nutzer per Kalender einen aelteren Tag, wird GENAU dieser Tag
  // nachgeladen und in loggedMeals gemerged. Nachgeladene Alt-Tage bleiben
  // bewusst In-Memory (Session-lokal): sie wandern NICHT in den durablen
  // LocalCache (siehe _cacheableLoggedMeals) und fliegen beim naechsten
  // Fenster-Load wieder raus — die Merge-Quelle ist immer der Server-Stand.
  /// Bereits nachgeladene Alt-Tage (localDayKey) — verhindert wiederholte
  /// Queries beim Hin- und Herspringen. Wird beim Fenster-Refresh geleert.
  final Set<String> _loadedArchiveDays = <String>{};

  /// Gerade in-flight nachladende Alt-Tage (localDayKey) — treibt den
  /// Lade-Zustand der UI und dedupliziert parallele Trigger.
  final Set<String> _loadingArchiveDays = <String>{};

  // --- Read-only Sichten fuer die UI-Schale --------------------------------
  List<FitnessRecipe> get userRecipes => _userRecipes;

  /// Noch nicht synchronisierte Write-Operationen (Sicht fuer Tests/Debug).
  List<SyncOp> get pendingOutbox => List.unmodifiable(_outbox);
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

  /// True, waehrend [day] gerade on-demand nachgeladen wird (Alt-Tag
  /// ausserhalb des Boot-Fensters) — die UI zeigt dann einen Spinner statt
  /// eines faelschlich leeren Tages.
  bool isLoadingFoodDay(DateTime day) =>
      _loadingArchiveDays.contains(localDayKey(DateUtils.dateOnly(day)));

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

  /// Liegt [day] ausserhalb des Boot-Fensters von
  /// [MealsSync.loadLoggedMeals]? Der Fenster-Cutoff ist ein Zeitstempel
  /// (jetzt − 35 Tage), der Grenztag ist also nur PARTIELL geladen — er
  /// zaehlt deshalb bewusst als „ausserhalb" und wird on-demand vollstaendig
  /// nachgeladen (der Merge ist duplikat-sicher per id).
  bool _isOutsideBootWindow(DateTime day) =>
      DateUtils.dateOnly(DateTime.now())
          .difference(DateUtils.dateOnly(day))
          .inDays >=
      MealsSync.loggedMealsWindowDays;

  /// Laedt einen Alt-Tag (ausserhalb des Boot-Fensters) on-demand nach und
  /// merged ihn in [loggedMeals]. Pro Session genau einmal pro Tag
  /// (_loadedArchiveDays); Fehler zeigen die bestehende klassifizierte
  /// Meldung (sync_error_messages) und lassen den Tag beim naechsten Tap
  /// erneut versuchen.
  Future<void> _ensureArchiveDayLoaded(DateTime day) async {
    final s = sync;
    if (s == null) return;
    final target = DateUtils.dateOnly(day);
    final key = localDayKey(target);
    if (_loadedArchiveDays.contains(key) || _loadingArchiveDays.contains(key)) {
      return;
    }
    _loadingArchiveDays.add(key);
    if (!_disposed) notifyListeners(); // Spinner an
    try {
      final rows = await s.meals.loadLoggedMealsForDay(target);
      if (_disposed) return;
      _loadedArchiveDays.add(key);
      _mutate(() => _mergeArchiveMeals(rows));
      // BEWUSST kein _cacheLoggedMeals(): nachgeladene Alt-Tage bleiben
      // In-Memory (siehe _cacheableLoggedMeals) — der durable Cache traegt
      // weiterhin nur das Boot-Fenster.
    } catch (e, st) {
      // Read-Fehler ohne Outbox-Netz (nichts nachzuspielen): klassifizierte
      // Meldung ueber das bestehende Muster, Roh-Fehler an dev.log/Reporter.
      _reportSyncError('Tag-Nachladen', e, st);
    } finally {
      _loadingArchiveDays.remove(key);
      if (!_disposed) notifyListeners(); // Spinner aus
    }
  }

  /// Merged frisch nachgeladene Server-Zeilen eines Alt-Tags duplikat-sicher
  /// in [loggedMeals] (Muster analog [_applyPendingOpsToState]): nur FEHLENDE
  /// ids kommen dazu — eine bereits vorhandene lokale Zeile (z.B. mit noch
  /// nicht synchronisiertem Edit) gewinnt gegen die aeltere Server-Kopie.
  /// Danach werden pendende Outbox-Ops erneut ueberlagert, damit ein noch
  /// nicht replayter Delete keine frisch geladene Zeile wiederbelebt. Muss
  /// innerhalb eines _mutate-Blocks laufen.
  void _mergeArchiveMeals(List<LoggedMeal> rows) {
    final known = loggedMeals.map((m) => m.id).toSet();
    final missing =
        rows.where((m) => !known.contains(m.id)).toList(growable: false);
    if (missing.isNotEmpty) {
      // Server-Sortierung (logged_at absteigend) nach dem Merge herstellen.
      loggedMeals = [...loggedMeals, ...missing]
        ..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
    }
    _applyPendingOpsToState();
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

  // --- Fehler-/Sync-Routing -------------------------------------------------

  /// Fehler einer Operation OHNE Outbox-Netz (z.B. Konto-Löschung): roter
  /// Snack mit freundlicher, klassifizierter Meldung — NIE der rohe
  /// Exception-Text (Schema-Leakage, unlesbar). Die Roh-Exception geht an
  /// dev.log + CrashReporter.
  void _reportSyncError(String operation, Object error, StackTrace stack) {
    dev.log('$operation failed', error: error, name: 'eatova_sync');
    unawaited(CrashReporter.capture(error, stack, context: operation));
    if (_disposed) return;
    _emitSnack(
      directSyncErrorMessage(error),
      icon: Icons.error_outline_rounded,
      accent: danger,
      duration: kSnackError,
    );
  }

  /// Fire-and-forget Sync-Write OHNE Rollback (DATA-7): schlaegt der Write
  /// fehl, bleibt der optimistische lokale State stehen und die Operation
  /// wandert als persistierter Outbox-Eintrag in die Retry-Queue. Frueher
  /// wurde hier zurueckgerollt — der Eintrag des Nutzers war dann bei jedem
  /// Netz-Schluckauf weg.
  ///
  /// Haengt fuer dieselbe Entitaet bereits eine Op in der Outbox, wird die
  /// neue Operation direkt DAHINTER eingereiht statt live zu schreiben: ein
  /// Live-Write wuerde die pendende Op ueberholen (z.B. ein Update, dessen
  /// Insert noch aussteht, traefe serverseitig 0 Zeilen und der Replay
  /// schriebe danach den alten Stand).
  void _syncOrQueue(
    String operation,
    Future<void> Function() action,
    SyncOp Function() buildOp,
  ) {
    if (sync == null) return;
    final op = buildOp();
    if (_outbox.any((o) => o.entityKey == op.entityKey)) {
      _enqueueOp(op);
      _notifyQueued(null);
      _scheduleOutboxRetry();
      return;
    }
    action().then((_) => _onSyncSuccess()).catchError((Object e, StackTrace st) {
      _handleSyncFailure(operation, e, st, op);
    });
  }

  /// Sync-Write fehlgeschlagen: Op persistiert einreihen, dezent hinweisen,
  /// Retry planen. KEIN Rollback, KEIN roter Fehler-Toast mehr.
  void _handleSyncFailure(
      String operation, Object error, StackTrace stack, SyncOp op) {
    dev.log('$operation failed — Op wandert in die Outbox',
        error: error, name: 'eatova_sync');
    unawaited(CrashReporter.capture(error, stack, context: operation));
    _enqueueOp(op);
    if (_disposed) return;
    _notifyQueued(error);
    _scheduleOutboxRetry();
  }

  void _enqueueOp(SyncOp op) {
    // Waehrend eines laufenden Replays nur anhaengen — der Replay koennte
    // gerade genau die Op abspielen, deren Payload sonst koalesziert (und beim
    // Entfernen verworfen) wuerde.
    _outbox = enqueueCoalesced(_outbox, op, appendOnly: _outboxReplayInFlight);
    _persistOutbox();
  }

  /// Dezenter Hinweis, dass ein Write in der Outbox gelandet ist. Der Text
  /// kommt aus dem puren Mapping (sync_error_messages.dart): Netzwerkfehler ->
  /// "Offline …", alles andere -> freundliche Retry-Meldung OHNE
  /// Exception-Details. [error] ist null, wenn die Op ohne Live-Versuch hinter
  /// eine bereits pendende Op eingereiht wurde (kein frischer Fehler) — dann
  /// gilt der neutrale Retry-Text.
  void _notifyQueued(Object? error) {
    if (_disposed || _syncHintShown) return;
    _syncHintShown = true;
    final offline = error != null && isNetworkSyncError(error);
    _emitSnack(
      queuedSyncHint(error),
      icon: offline ? Icons.cloud_off_rounded : Icons.sync_problem_rounded,
      accent: textMuted,
    );
  }

  /// Nach einem erfolgreichen Sync-Write: Fehler-Episode beenden, Backoff
  /// zuruecksetzen und liegengebliebene Ops direkt nachspielen.
  void _onSyncSuccess() {
    if (_disposed) return;
    _syncHintShown = false;
    _outboxRetryAttempt = 0;
    if (_outbox.isNotEmpty && !_outboxReplayInFlight) {
      unawaited(_replayOutbox());
    }
  }

  /// Plant den naechsten Outbox-/Stats-Retry mit exponentiellem Backoff
  /// (30s -> 1m -> 2m -> 4m Cap; Reset bei Erfolg). Bewusst ohne
  /// connectivity-Paket: der Timer ist der einzige Waechter, zusaetzlich
  /// stossen Boot, Lifecycle-Flush und der naechste Erfolg den Replay an.
  void _scheduleOutboxRetry() {
    if (_disposed || sync == null) return;
    if (_outbox.isEmpty &&
        _pendingMealsDelta == 0 &&
        _pendingWeightLogsDelta == 0) {
      return;
    }
    _outboxRetryTimer?.cancel();
    final delay = Duration(seconds: 30 * (1 << _outboxRetryAttempt));
    if (_outboxRetryAttempt < 3) _outboxRetryAttempt++;
    _outboxRetryTimer = Timer(delay, () {
      unawaited(_replayOutbox());
      unawaited(_flushStatsDelta());
    });
  }

  /// Spielt die persistierte Outbox strikt FIFO gegen Supabase ab. Pro
  /// Entitaet bleibt die Reihenfolge erhalten (insert vor update vor delete);
  /// schlaegt eine Op fehl, blockiert sie nur ihre EIGENE Entitaet fuer diesen
  /// Lauf — Ops anderer Entitaeten laufen weiter. Jede erfolgreiche Op wird
  /// sofort entfernt und der Rest persistiert (kill-sicher: ein Abbruch
  /// mittendrin wiederholt hoechstens bereits bestaetigte, idempotente Ops).
  Future<void> _replayOutbox() async {
    final s = sync;
    if (s == null || _outboxReplayInFlight || _outbox.isEmpty) return;
    _outboxReplayInFlight = true;
    final blocked = <String>{};
    var anySuccess = false;
    try {
      var i = 0;
      while (i < _outbox.length) {
        final op = _outbox[i];
        if (blocked.contains(op.entityKey)) {
          i++;
          continue;
        }
        try {
          await _performOp(s, op);
        } catch (e, st) {
          dev.log('Outbox-Replay: ${op.kind.name} bleibt liegen',
              error: e, name: 'eatova_sync');
          unawaited(CrashReporter.capture(e, st,
              context: 'outbox-replay-${op.kind.name}'));
          blocked.add(op.entityKey);
          i++;
          continue;
        }
        anySuccess = true;
        _outbox = [..._outbox]..removeAt(i);
        _persistOutbox();
      }
    } finally {
      _outboxReplayInFlight = false;
    }
    if (_disposed) return;
    if (blocked.isEmpty) {
      _outboxRetryAttempt = 0;
      _outboxRetryTimer?.cancel();
      if (anySuccess) _syncHintShown = false;
    } else {
      _scheduleOutboxRetry();
    }
  }

  /// Fuehrt EINE Outbox-Op gegen den Server aus. Wirft bei Sync-Fehler (der
  /// Replay-Loop behaelt die Op dann). Nachgelagerte Zaehler laufen wie im
  /// jeweiligen Online-Erfolgspfad.
  Future<void> _performOp(EatovaSync s, SyncOp op) async {
    switch (op.kind) {
      case SyncOpKind.mealInsert:
        final meal = op.meal;
        if (meal == null) return; // korrupter Payload -> Op verfaellt still
        await s.meals.insertLoggedMeal(meal);
        _queueStatsDelta(meals: 1);
        // Streak-Tag der MAHLZEIT verbuchen, nicht "heute" — der Replay kann
        // Tage spaeter laufen. record_tracking_day ist idempotent pro Tag und
        // fuer Tage vor dem letzten gezaehlten Tag ein Server-No-op.
        if (op.trackDay) {
          _recordTrackingDay(day: DateTime.parse(meal.effectiveLocalDay));
        }
      case SyncOpKind.mealUpsert:
        final meal = op.meal;
        if (meal == null) return;
        await s.meals.insertLoggedMeal(meal);
      case SyncOpKind.mealDelete:
        await s.meals.deleteLoggedMeal(op.entityId);
      case SyncOpKind.weightInsert:
        final kg = op.weightKg;
        final ts = op.recordedAt;
        if (kg == null || ts == null) return;
        await s.tracking.insertWeight(kg, ts, id: op.entityId);
        _queueStatsDelta(weightLogs: 1);
      case SyncOpKind.favoriteUpsert:
        final fav = op.favorite;
        if (fav == null) return;
        await s.meals.upsertFavorite(fav);
      case SyncOpKind.favoriteDelete:
        await s.meals.deleteFavorite(op.entityId);
      case SyncOpKind.recipeUpsert:
        final recipe = op.recipe;
        if (recipe == null) return;
        await s.userRecipes.upsert(recipe);
      case SyncOpKind.recipeDelete:
        await s.userRecipes.delete(op.entityId);
    }
  }

  /// Spiegelt noch nicht synchronisierte Outbox-Ops in den (gecachten oder
  /// frisch geladenen) State. Idempotent — mehrfaches Anwenden aendert nichts:
  /// Upserts ersetzen vorhandene Eintraege bzw. fuegen fehlende ein, Deletes
  /// entfernen. Muss innerhalb eines _mutate-Blocks laufen.
  void _applyPendingOpsToState() {
    if (_outbox.isEmpty) return;
    var mealsTouched = false;
    for (final op in _outbox) {
      switch (op.kind) {
        case SyncOpKind.mealInsert:
        case SyncOpKind.mealUpsert:
          final meal = op.meal;
          if (meal == null) break;
          final index = loggedMeals.indexWhere((m) => m.id == meal.id);
          if (index >= 0) {
            final next = [...loggedMeals];
            next[index] = meal;
            loggedMeals = next;
          } else {
            loggedMeals = [meal, ...loggedMeals];
          }
          mealsTouched = true;
        case SyncOpKind.mealDelete:
          loggedMeals = loggedMeals.where((m) => m.id != op.entityId).toList();
        case SyncOpKind.weightInsert:
          final kg = op.weightKg;
          final ts = op.recordedAt;
          if (kg == null || ts == null) break;
          if (weightLog.entries.any((e) => e.timestamp.isAtSameMomentAs(ts))) {
            break;
          }
          final entries = [
            ...weightLog.entries,
            WeightLogEntry(timestamp: ts, weightKg: kg),
          ]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
          weightLog = WeightLog(entries: entries);
        case SyncOpKind.favoriteUpsert:
          final fav = op.favorite;
          if (fav == null) break;
          favorites = [fav, ...favorites.where((f) => f.id != fav.id)];
        case SyncOpKind.favoriteDelete:
          favorites = favorites.where((f) => f.id != op.entityId).toList();
        case SyncOpKind.recipeUpsert:
          final recipe = op.recipe;
          if (recipe == null) break;
          _userRecipes = [
            recipe,
            ..._userRecipes.where((r) => r.slug != recipe.slug),
          ];
        case SyncOpKind.recipeDelete:
          _userRecipes =
              _userRecipes.where((r) => r.slug != op.entityId).toList();
      }
    }
    if (mealsTouched) {
      // Server-Sortierung (logged_at absteigend) nach dem Merge wiederherstellen.
      loggedMeals = [...loggedMeals]
        ..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
    }
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
    } catch (e, st) {
      _reportSyncError('Konto-Löschung', e, st);
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
    await cache.writeLoggedMeals(_cacheableLoggedMeals());
    await cache.writeFavorites(favorites);
    await cache.writeWeightLog(weightLog);
  }

  /// Bewusste Entscheidung: nur Eintraege innerhalb des Boot-Fensters wandern
  /// in den durablen Cache. On-Demand nachgeladene Alt-Tage bleiben
  /// In-Memory — sie wuerden den SharedPreferences-Blob unbegrenzt aufblaehen,
  /// und der naechste Besuch laedt sie ohnehin frisch vom Server. Pendende
  /// WRITES fuer Alt-Tage sind davon unabhaengig kill-sicher: sie leben in
  /// der persistierten Outbox und werden beim Boot via
  /// _applyPendingOpsToState wieder sichtbar.
  List<LoggedMeal> _cacheableLoggedMeals() {
    final cutoff = DateTime.now()
        .subtract(const Duration(days: MealsSync.loggedMealsWindowDays));
    return loggedMeals
        .where((m) => !m.loggedAt.isBefore(cutoff))
        .toList(growable: false);
  }

  void _cacheLifetimeStats() {
    unawaited(_cache?.writeLifetimeStats(lifetimeStats) ?? Future<void>.value());
  }

  // Write-Through fuer die Offline-Slots (DATA-7): jede lokale Mutation
  // spiegelt sich sofort in den Cache, damit ein Kaltstart ohne Netz den
  // letzten Stand zeigt. Fire-and-forget — ein Cache-Write darf nie den
  // UI-Pfad blockieren. Gefiltert auf das Boot-Fenster (s.
  // _cacheableLoggedMeals) — Alt-Tage blaehen den Cache nicht auf.
  void _cacheLoggedMeals() {
    unawaited(_cache?.writeLoggedMeals(_cacheableLoggedMeals()) ??
        Future<void>.value());
  }

  void _cacheFavorites() {
    unawaited(_cache?.writeFavorites(favorites) ?? Future<void>.value());
  }

  void _cacheWeightLog() {
    unawaited(_cache?.writeWeightLog(weightLog) ?? Future<void>.value());
  }

  void _persistOutbox() {
    unawaited(_cache?.writeOutbox(_outbox) ?? Future<void>.value());
  }

  void _persistPendingStatsDeltas() {
    unawaited(_cache?.writePendingStatsDeltas(
          meals: _pendingMealsDelta,
          weightLogs: _pendingWeightLogsDelta,
        ) ??
        Future<void>.value());
  }

  /// Schreibt einen Logging-Tag serverseitig in die Streak
  /// (record_tracking_day, idempotent pro Tag) und adoptiert die frische
  /// Server-Zeile. Default ist "heute"; ein Outbox-Replay uebergibt den Tag
  /// der nachgeholten Mahlzeit. Fehler bleiben still — der optimistische
  /// lokale recordTrackedDay-Stand gilt dann bis zum naechsten Load/Log
  /// weiter.
  void _recordTrackingDay({DateTime? day}) {
    final s = sync;
    if (s == null) return;
    s.lifetimeStats.recordTrackingDay(day ?? DateTime.now()).then((fresh) {
      if (_disposed) return;
      _mutate(() => lifetimeStats = fresh);
      _cacheLifetimeStats();
    }).catchError((Object e, StackTrace st) {
      dev.log('recordTrackingDay failed', error: e, name: 'home_store');
      unawaited(CrashReporter.capture(e, st, context: 'record-tracking-day'));
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
    // Pendende Deltas kill-sicher machen (DATA-7): ein App-Kill im Debounce-
    // Fenster oder nach fehlgeschlagenem Flush verliert sie nicht mehr — der
    // naechste Boot hydriert und flusht sie nach.
    _persistPendingStatsDeltas();
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
    // In-Flight-Stand sofort persistieren: ein Kill WAEHREND des RPCs zaehlt
    // die Deltas schlimmstenfalls nicht — besser als ein Doppel-Increment
    // beim naechsten Boot (der Server ADDIERT, ein Replay eines bereits
    // verbuchten Deltas wuerde die Lebenszeit-Zaehler permanent verfaelschen).
    _persistPendingStatsDeltas();
    _statsFlushInFlight = true;
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
      _onSyncSuccess();
    } catch (e, st) {
      // DATA-7: kein roter Fehler-Toast, kein Rollback — die Deltas gehen
      // zurueck in die (persistierte) Queue und laufen ueber die Retry-Pfade.
      dev.log('Statistik-Sync failed — Deltas bleiben gequeued',
          error: e, name: 'eatova_sync');
      unawaited(CrashReporter.capture(e, st, context: 'lifetime-stats-flush'));
      _pendingMealsDelta += meals;
      _pendingWeightLogsDelta += weightLogs;
      _persistPendingStatsDeltas();
      if (!_disposed) {
        _notifyQueued(e);
        _scheduleOutboxRetry();
      }
    } finally {
      _statsFlushInFlight = false;
    }
  }

  /// Schreibt ausstehende debounced Writes sofort weg (App-Backgrounding)
  /// und spielt liegengebliebene Outbox-Ops nach.
  void flushPendingWrites() {
    final s = sync;
    if (s == null) return;
    _statsSaveDebounce?.cancel();
    _statsSaveDebounce = null;
    unawaited(_flushStatsDelta());
    unawaited(_replayOutbox());
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
    _mutate(() {
      weightLog = weightLog.add(kg);
      lifetimeStats = lifetimeStats.incrementWeightLogs();
    });
    _cacheWeightLog();
    if (writeToHealth) {
      unawaited(health.writeWeight(kg, ts));
    }
    final s = sync;
    if (s == null) return;
    // Client-UUID fuer die Server-Zeile: Live-Write und ein spaeterer
    // Outbox-Retry teilen dieselbe id -> Upsert statt Insert, ein Retry nach
    // unklarem Timeout erzeugt kein Duplikat (DATA-7-Idempotenz).
    final rowId = uuidV4();
    s.tracking.insertWeight(kg, ts, id: rowId).then((_) {
      _queueStatsDelta(weightLogs: 1);
      _onSyncSuccess();
    }).catchError((Object e, StackTrace st) {
      // Kein Rollback mehr: das Gewicht bleibt geloggt (damit bleibt auch der
      // Health-Import-Dedup-Marker korrekt gesetzt) und wird per Outbox
      // nachgeholt.
      _handleSyncFailure(
        'Gewicht',
        e,
        st,
        SyncOp.weightInsert(id: rowId, weightKg: kg, recordedAt: ts),
      );
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
    _cacheLoggedMeals();
    _cacheFavorites(); // _rememberRecent hat die Favoriten/Recents mutiert
    final s = sync;
    if (s == null) return entry.id;
    s.meals.insertLoggedMeal(entry).then((_) {
      _queueStatsDelta(meals: 1);
      if (targetIsToday) _recordTrackingDay();
      _onSyncSuccess();
    }).catchError((Object e, StackTrace st) {
      // DATA-7: KEIN Rollback mehr — die Mahlzeit bleibt im Tagebuch stehen
      // und wird als Outbox-Op nachgeholt (inkl. Stats-/Streak-Zaehlung beim
      // Replay-Erfolg). Der Streak-Reminder-Plan von oben bleibt damit
      // ebenfalls korrekt.
      _handleSyncFailure(
        'Mahlzeit',
        e,
        st,
        SyncOp.mealInsert(entry, trackDay: targetIsToday),
      );
    });
    return entry.id;
  }

  void updateLoggedMealResult(String id, MealAnalysisResult scaled) {
    final index = loggedMeals.indexWhere((m) => m.id == id);
    if (index == -1) return;
    final target = loggedMeals[index];
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
    _cacheLoggedMeals();
    // Im Outbox-Fall laeuft das Update als voller Upsert derselben Client-UUID
    // — landet auch dann korrekt, wenn der urspruengliche Insert selbst noch
    // in der Queue haengt (Koaleszenz bzw. FIFO pro Entitaet).
    _syncOrQueue(
      'Mahlzeit-Update',
      () => sync!.meals.updateLoggedMeal(updated),
      () => SyncOp.mealUpsert(updated),
    );
  }

  /// Bearbeiten-Sheet: aendert Portion/Bestandteile ([result]), den Slot
  /// ([slot]) und/oder den Tag ([day]) einer bereits geloggten Mahlzeit in
  /// EINEM outbox-sicheren Update (Upsert auf die Client-UUID, kein Rollback).
  /// Nur uebergebene Felder aendern sich; `null` heisst „unveraendert".
  ///
  /// Tag-Verschiebung (DATA-6-konsistent): [loggedAt] wandert unter Erhalt der
  /// lokalen Wanduhr-Zeit auf den Zieltag, [LoggedMeal.localDay] wird auf den
  /// neuen kanonischen Tages-Schluessel gesetzt — Bucketing, Tageszaehler und
  /// Server-Zeile (logged_at + local_day) bleiben damit deckungsgleich.
  ///
  /// Streak-Entscheidung: eine Verschiebung AUF heute verbucht heute als
  /// getrackten Tag (idempotent pro Tag, wie ein frischer Log — heute hat
  /// danach ja >= 1 Mahlzeit). Verschiebungen auf vergangene Tage sind
  /// Nachtraege und lassen die Streak unangetastet (record_tracking_day ist
  /// fuer p_day <= last_workout_date serverseitig ein No-op). Eine
  /// Verschiebung WEG von heute kann den Tag nicht „ent-tracken" — es gibt
  /// serverseitig kein Decrement; bewusst akzeptiert.
  ///
  /// Liefert die aktualisierte Mahlzeit (fuer lokale Sheet-Listen) oder null,
  /// wenn [id] nicht (mehr) existiert. Nach dem Speichern erscheint ein
  /// dezenter Hinweis mit „Rückgängig" (analog zum Loesch-Undo).
  LoggedMeal? updateLoggedMealDetails(
    String id, {
    MealAnalysisResult? result,
    MealSlot? slot,
    DateTime? day,
  }) {
    final index = loggedMeals.indexWhere((m) => m.id == id);
    if (index == -1) return null;
    final previous = loggedMeals[index];

    var updated = previous.copyWith(result: result, forcedSlot: slot);
    var dayChanged = false;
    var movedToToday = false;
    if (day != null) {
      final targetDay = DateUtils.dateOnly(day);
      final targetKey = localDayKey(targetDay);
      if (targetKey != previous.effectiveLocalDay) {
        // Lokale Wanduhr-Zeit der Mahlzeit beibehalten, nur den Kalendertag
        // tauschen — so bleibt die Slot-Heuristik (loggedAt.hour) stabil.
        final local = previous.loggedAt.toLocal();
        updated = updated.copyWith(
          loggedAt: DateTime(targetDay.year, targetDay.month, targetDay.day,
              local.hour, local.minute),
          localDay: targetKey,
        );
        dayChanged = true;
        movedToToday = _isSameFoodDate(targetDay, DateTime.now());
      }
    }
    if (result == null && slot == null && !dayChanged) return previous;

    HapticFeedback.lightImpact();
    _applyLoggedMealDetails(updated, recordToday: movedToToday);
    final message = dayChanged
        ? 'Mahlzeit auf ${_moveDayLabel(updated.loggedAt)} verschoben.'
        : 'Mahlzeit aktualisiert.';
    _emitSnack(
      message,
      icon: Icons.check_circle_rounded,
      accent: lime,
      action: SnackBarAction(
        label: 'Rückgängig',
        onPressed: () => _revertLoggedMealUpdate(previous),
      ),
    );
    return updated;
  }

  /// Undo des Bearbeiten-Sheets: stellt den vorherigen Stand der Mahlzeit
  /// wieder her (gleicher outbox-sicherer Upsert-Pfad). Wurde die Mahlzeit
  /// inzwischen geloescht, passiert nichts. Die Streak wird bewusst NICHT
  /// zurueckgerollt (kein Server-Decrement, siehe updateLoggedMealDetails).
  void _revertLoggedMealUpdate(LoggedMeal previous) {
    _applyLoggedMealDetails(previous);
  }

  /// Gemeinsamer Apply-Kern von Update + Undo: ersetzt die Zeile, stellt die
  /// Server-Sortierung (logged_at absteigend) wieder her, zieht die
  /// Tageszaehler/Makros fuer HEUTE nach (eine Verschiebung kann heute auch
  /// betreffen, wenn gerade ein anderer Tag angezeigt wird), spiegelt in den
  /// LocalCache und synct outbox-sicher als idempotenten Upsert.
  void _applyLoggedMealDetails(LoggedMeal updated, {bool recordToday = false}) {
    final index = loggedMeals.indexWhere((m) => m.id == updated.id);
    if (index == -1) return;
    _mutate(() {
      final next = [...loggedMeals];
      next[index] = updated;
      next.sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
      loggedMeals = next;
      dailyConsumedKcal = consumedKcalForFoodDate(DateTime.now());
      macroProgress = macroProgressForFoodDate(DateTime.now());
      if (recordToday) {
        // Optimistisch wie beim frischen Log; der Server-Refresh via
        // _recordTrackingDay adoptiert danach die autoritative Zeile.
        lifetimeStats = lifetimeStats.recordTrackedDay(DateTime.now());
      }
    });
    _cacheLoggedMeals();
    if (recordToday) {
      unawaited(_rescheduleStreakReminder());
      _recordTrackingDay();
    }
    _syncOrQueue(
      'Mahlzeit-Update',
      () => sync!.meals.updateLoggedMeal(updated),
      () => SyncOp.mealUpsert(updated),
    );
  }

  /// Deutsches Kurzlabel fuer den Zieltag der Verschiebe-Bestaetigung.
  String _moveDayLabel(DateTime day) {
    final today = DateUtils.dateOnly(DateTime.now());
    final target = DateUtils.dateOnly(day);
    final offset = today.difference(target).inDays;
    if (offset == 0) return 'heute';
    if (offset == 1) return 'gestern';
    return 'den ${target.day}.${target.month}.';
  }

  void removeLoggedMeal(String id) {
    final matches = loggedMeals.where((m) => m.id == id);
    final removed = matches.isEmpty ? null : matches.first;
    HapticFeedback.lightImpact();
    _mutate(() {
      loggedMeals = loggedMeals.where((m) => m.id != id).toList();
      if (selectedFoodDateIsToday) {
        dailyConsumedKcal = consumedKcalForFoodDate(DateTime.now());
        macroProgress = macroProgressForFoodDate(DateTime.now());
      }
    });
    _cacheLoggedMeals();
    _syncOrQueue(
      'Mahlzeit-Delete',
      () => sync!.meals.deleteLoggedMeal(id),
      () => SyncOp.mealDelete(id),
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
    _cacheLoggedMeals();
    // Restore zaehlt (wie bisher) KEINE Stats erneut -> mealUpsert, nicht
    // mealInsert. Haengt der Delete noch in der Outbox, sortiert sich der
    // Upsert per FIFO dahinter ein — Endzustand: Zeile existiert wieder.
    _syncOrQueue(
      'Mahlzeit-Restore',
      () => sync!.meals.insertLoggedMeal(meal),
      () => SyncOp.mealUpsert(meal),
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
    _syncOrQueue(
      'Favorit',
      () => sync!.meals.upsertFavorite(entry),
      () => SyncOp.favoriteUpsert(entry),
    );
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

    if (isPinned) {
      final downgraded = existing.first.copyWith(pinned: false);
      final next = _cappedFavorites(
        [...favorites.where((f) => f.id != id), downgraded]
          ..sort((a, b) => b.addedAt.compareTo(a.addedAt)),
      );
      final survived = next.any((f) => f.id == id);
      _mutate(() => favorites = next);
      _cacheFavorites();
      if (survived) {
        _syncOrQueue(
          'Favorit',
          () => sync!.meals.upsertFavorite(downgraded),
          () => SyncOp.favoriteUpsert(downgraded),
        );
      } else {
        _syncOrQueue(
          'Favorit-Delete',
          () => sync!.meals.deleteFavorite(id),
          () => SyncOp.favoriteDelete(id),
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
      _cacheFavorites();
      _syncOrQueue(
        'Favorit',
        () => sync!.meals.upsertFavorite(entry),
        () => SyncOp.favoriteUpsert(entry),
      );
    }
  }

  void removeFavorite(String id) {
    final matches = favorites.where((f) => f.id == id);
    final removed = matches.isEmpty ? null : matches.first;
    _mutate(() {
      favorites = favorites.where((f) => f.id != id).toList();
    });
    _cacheFavorites();
    _syncOrQueue(
      'Favorit-Delete',
      () => sync!.meals.deleteFavorite(id),
      () => SyncOp.favoriteDelete(id),
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
    _cacheFavorites();
    _syncOrQueue(
      'Favorit-Restore',
      () => sync!.meals.upsertFavorite(fav),
      () => SyncOp.favoriteUpsert(fav),
    );
  }

  // --- Eigen-Rezepte --------------------------------------------------------

  void createUserRecipe(FitnessRecipe recipe) {
    _mutate(() {
      _userRecipes = [
        recipe,
        ..._userRecipes.where((r) => r.slug != recipe.slug)
      ];
    });
    _syncOrQueue(
      'Rezept',
      () => sync!.userRecipes.upsert(recipe),
      () => SyncOp.recipeUpsert(recipe),
    );
  }

  void deleteUserRecipe(String slug) {
    _mutate(() {
      _userRecipes = _userRecipes.where((r) => r.slug != slug).toList();
    });
    _syncOrQueue(
      'Rezept-Delete',
      () => sync!.userRecipes.delete(slug),
      () => SyncOp.recipeDelete(slug),
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
              name: 'eatova_sync');
        }
      } catch (e, st) {
        // Kein Outbox-Netz fuer den Profil-Save: freundliche Meldung OHNE
        // Exception-Details (frueher stand hier der rohe Postgrest-Text im
        // Snack), Roh-Fehler geht an dev.log/CrashReporter.
        dev.log('Profil-Sync failed', error: e, name: 'eatova_sync');
        unawaited(CrashReporter.capture(e, st, context: 'profil-settings'));
        if (!_disposed) {
          _emitSnack(profileSyncErrorMessage(e),
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
    } catch (e, st) {
      // Wie in applySettings: klassifizierte, freundliche Meldung statt des
      // rohen Exception-Texts; Diagnose laeuft ueber dev.log/CrashReporter.
      dev.log('Profil-Sync (Onboarding) failed', error: e, name: 'eatova_sync');
      unawaited(CrashReporter.capture(e, st, context: 'profil-onboarding'));
      if (!_disposed) {
        _emitSnack(profileSyncErrorMessage(e),
            icon: Icons.error_outline_rounded,
            accent: danger,
            duration: kSnackError);
      }
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
