import 'dart:async';
import 'dart:developer' as dev;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import '../l10n/l10n.dart';
import '../models/favorite_meal.dart';
import '../models/fitness_recipe.dart';
import '../models/lifetime_stats.dart';
import '../models/logged_meal.dart';
import '../models/macro_progress.dart';
import '../models/meal_analysis_result.dart';
import '../models/model_limits.dart' show isValidWeightLogKg;
import '../models/user_profile.dart';
import '../models/weight_log.dart';
import '../services/crash_reporter.dart';
import '../services/day_math.dart';
import '../services/eatova_sync.dart';
import '../services/health_service.dart';
import '../services/kcal_calculator.dart';
import '../services/local_cache.dart';
import '../services/local_day.dart';
import '../services/meal_totals.dart' as totals;
import '../services/meals_sync.dart' show MealsSync;
import '../services/notification_service.dart';
import '../services/recipe_image_store.dart';
import '../services/search_credentials.dart';
import '../services/secure_cache_store.dart';
import '../services/stale_auth_retry.dart';
import '../services/streak_reminder_planner.dart';
import '../services/sync_error_messages.dart';
import '../services/sync_outbox.dart';
import '../services/trend_service.dart' show TrendTotalsCache;
import '../services/user_recipes_sync.dart' show UserRecipesSync;
import '../services/uuid.dart';
import '../widgets/common/app_snack.dart';
// P1-03: `signOutCleanup` is the only code that knows when the cleanup ended,
// so it is the only place that can hand the sign-out intent back to the gate.
import 'auth_gate.dart' show IntentionalSignOut;

part 'home_store_meals.dart';
part 'home_store_profile.dart';
part 'home_store_sync.dart';
part 'home_store_tracking.dart';

/// Context-free snackbar request emitted by [HomeStore].
///
/// The store never holds a BuildContext (ARCH-4 store seam); it only signals
/// the message and `_EatovaHomePageState` turns it into a [showAppSnack].
typedef SnackEmitter = void Function(
  String message, {
  IconData icon,
  SnackTone tone,
  Duration? duration,
  SnackBarAction? action,
});

/// Hard boot budget: how long the network part of the start may hold the
/// welcome gate ([HomeStore.profileReady]).
///
/// No boot step carries a timeout of its own, so a silent socket (captive
/// portal) would pin the app on the WelcomeScreen forever. This is the safety
/// net for the no-usable-cache case; with a cached profile the gate opens
/// earlier (see [HomeStore._hydrateThenBoot]). 8 s: longer than a healthy
/// mobile boot, short enough not to look like a crash. Boot continues in the
/// background afterwards.
const Duration kBootNetworkBudget = Duration(seconds: 8);

/// Wall-clock distance from [now] to the next local midnight — the wait for
/// the midnight timer (B4).
///
/// Midnight is not always 24 h away, so the target comes from [addDays]
/// (calendar arithmetic); `Duration(days: 1)` lands 1 h late on a DST spring
/// forward and in the PAST on a fall back, which would spin the
/// self-rescheduling timer in a hot loop.
Duration durationUntilNextLocalMidnight(DateTime now) {
  final delta = addDays(startOfDay(now), 1).difference(now);
  // Zones that shift at midnight: never return <= 0, or the timer runs hot.
  return delta > Duration.zero ? delta : const Duration(minutes: 1);
}

/// Mirror of `MAX_USER_CONTEXT_CHARS` in coach-chat/guardrails.ts, where the
/// Edge Function truncates `user_context` (tail dropped). Documented bound for
/// the [_HomeStoreBase.coachContext] length tests only — the store never caps,
/// the server stays authoritative. A test keeps the mirror in sync.
const int kCoachContextCapChars = 1200;

/// Shared core of the [HomeStore] parts: constructor dependencies, state used
/// by several parts, and the pure helpers/views on it. Part mixins attach via
/// `on`, so every private member stays library-private. Part-owned state
/// (outbox, health snapshot, flags, archive day sets) lives in its own part.
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

  /// Strings for the few snack texts the store still builds itself.
  ///
  /// The store holds no BuildContext (see [SnackEmitter]), so
  /// [setLocalizations] injects the resolved [AppLocalizations] from
  /// `didChangeDependencies`. German default keeps store tests that never call
  /// the setter on the previously hardcoded text.
  AppLocalizations _l10n = deL10n;

  void setLocalizations(AppLocalizations l10n) => _l10n = l10n;

  bool _disposed = false;

  // --- State --------------------------------------------------------------
  // Tab indices: 0 = Food, 1 = Rezepte, 2 = Coach.
  int selectedTab = 0;
  int dailyConsumedKcal = 0;
  int dailySteps = 0;
  // Lives here, not in _HomeStoreTrackingPart: the logout path in
  // _HomeStoreSyncPart resets it on user change (B3), and tracking depends on
  // sync, not the other way round.
  HealthAuthState healthAuthState = HealthAuthState.unknown;
  DateTime selectedFoodDate = DateUtils.dateOnly(clock.now());
  MacroProgress macroProgress = MacroProgress.empty;
  String userName = 'Moritz';

  // The six server-mirrored collections sit behind setters that bump a
  // per-collection version (F1-01, review 2026-08-27). Every assignment in
  // any part goes through them, so the boot load can tell "unchanged since
  // the request went out" (full replacement) from "mutated in the window"
  // (merge, local wins) without the parts knowing about it.
  UserProfile _profileState = const UserProfile();
  List<FavoriteMeal> _favoritesState = <FavoriteMeal>[];
  List<LoggedMeal> _loggedMealsState = <LoggedMeal>[];
  List<FitnessRecipe> _userRecipesState = const <FitnessRecipe>[];
  WeightLog _weightLogState = const WeightLog();
  LifetimeStats _lifetimeStatsState = LifetimeStats();

  int _profileVersion = 0;
  int _favoritesVersion = 0;
  int _loggedMealsVersion = 0;
  int _userRecipesVersion = 0;
  int _weightLogVersion = 0;
  int _lifetimeStatsVersion = 0;

  UserProfile get profile => _profileState;
  set profile(UserProfile value) {
    _profileState = value;
    _profileVersion++;
  }

  List<FavoriteMeal> get favorites => _favoritesState;
  set favorites(List<FavoriteMeal> value) {
    _favoritesState = value;
    _favoritesVersion++;
  }

  List<LoggedMeal> get loggedMeals => _loggedMealsState;
  set loggedMeals(List<LoggedMeal> value) {
    _loggedMealsState = value;
    _loggedMealsVersion++;
  }

  List<FitnessRecipe> get _userRecipes => _userRecipesState;
  set _userRecipes(List<FitnessRecipe> value) {
    _userRecipesState = value;
    _userRecipesVersion++;
  }

  WeightLog get weightLog => _weightLogState;
  set weightLog(WeightLog value) {
    _weightLogState = value;
    _weightLogVersion++;
  }

  LifetimeStats get lifetimeStats => _lifetimeStatsState;
  set lifetimeStats(LifetimeStats value) {
    _lifetimeStatsState = value;
    _lifetimeStatsVersion++;
  }

  LocalCache? _cache;
  bool _hydratedFromRealSource = false;

  /// B4: the calendar day the store last saw as "today".
  ///
  /// Reference for [HomeStore.maybeRollOverToToday]: only a
  /// [selectedFoodDate] equal to this day was the current day and may roll
  /// over. A date rather than a "follows today" flag, because a flag would
  /// have to be maintained by every writer of [selectedFoodDate].
  DateTime _lastKnownToday = DateUtils.dateOnly(clock.now());

  // --- Read-only views for the UI shell ------------------------------------
  List<FitnessRecipe> get userRecipes => _userRecipes;

  /// Own recipes the recipes tab is holding inside an undo window: delete
  /// tapped, toast still up, nothing persisted yet (`_PendingDelete` there).
  /// The row stays in [userRecipes] until that window commits, so every
  /// reader OUTSIDE the tab takes [visibleUserRecipes] — the coach card
  /// derived "Hinzugefügt" from [userRecipes] and kept its button locked
  /// until the toast had gone (2026-09-02). A fresh Set per change: the tab
  /// selectors compare their slices with `!=`, and a mutated Set is
  /// identical to itself.
  Set<String> _pendingRecipeDeletes = const <String>{};
  Set<String> get pendingRecipeDeletes => _pendingRecipeDeletes;

  /// [userRecipes] minus the pending deletes — "the user's recipes right now"
  /// for everything that is not the recipes tab itself.
  List<FitnessRecipe> get visibleUserRecipes => _pendingRecipeDeletes.isEmpty
      ? _userRecipes
      : _userRecipes
          .where((r) => !_pendingRecipeDeletes.contains(r.slug))
          .toList(growable: false);

  /// The recipes tab reports a slug entering ([pending] true) or leaving
  /// (undo, commit) its undo window. Idempotent; notifies only on a change.
  void setRecipeDeletePending(String slug, {required bool pending}) {
    if (pending == _pendingRecipeDeletes.contains(slug)) return;
    _mutate(() {
      final next = <String>{..._pendingRecipeDeletes};
      if (pending) {
        next.add(slug);
      } else {
        next.remove(slug);
      }
      _pendingRecipeDeletes = next;
    });
  }

  String get profileInitial {
    final parts = userName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return 'S';
    return parts.first.substring(0, 1).toUpperCase();
  }

  /// Compact day/profile snapshot for the AI coach, so it can advise on
  /// concrete numbers.
  ///
  /// Order is FIXED because the Edge Function truncates the TAIL of
  /// `user_context` at [kCoachContextCapChars]: language hint, core values
  /// (weight, effective weight goal, balance, open macros), per-slot macros
  /// ([_todaysSlotSummary]), then the food list ([_todaysFoodSummary]) — the
  /// only line the cap may hit.
  String get coachContext {
    final p = profile;
    final remKcal = p.dailyKcalGoal - dailyConsumedKcal;
    final remProt = (p.proteinGoalG - macroProgress.proteinG).round();
    final remCarbs = (p.carbsGoalG - macroProgress.carbsG).round();
    final remFat = (p.fatGoalG - macroProgress.fatG).round();
    final lines = [
      // Always-English protocol field for the model, not UI text (no ARB).
      // First, never last, so the Edge Function's cap can never hit it. The
      // data stays German; the system prompt's language rule governs the
      // REPLY language only.
      'App language of the user: ${_l10n.localeName}.',
      'Körpergewicht: ${p.weightKg} kg (Ziel ${p.targetWeightKg} kg).',
      // The direction that is actually running (P9-08d). Weight and target
      // alone left the model to infer the plan, and a stored row like "80 kg,
      // Ziel 90 kg" on a deficit goal handed it a target ABOVE the weight next
      // to a deficit daily goal — a contradiction it then advised on.
      // `effectiveWeightGoal` is DERIVED, so this holds for every stored row
      // without a save; nothing is invented here, all three values are read.
      // German like the rest of the context, hence the fixed German bundle and
      // not the user's — the reply language is the system prompt's business.
      'Wirksames Gewichtsziel: ${p.effectiveWeightGoal.label(deL10n)}.',
      'Heute gegessen: $dailyConsumedKcal von ${p.dailyKcalGoal} kcal '
          '(noch $remKcal kcal übrig).',
      'Makros heute noch offen: Protein $remProt g, Kohlenhydrate $remCarbs g, '
          'Fett $remFat g.',
    ];
    // Slot totals BEFORE the food list: short, capped at four slots, and the
    // only source for per-meal macros.
    final perSlot = _todaysSlotSummary();
    if (perSlot != null) lines.add(perSlot);
    // Food names last, so the Edge Function's char cap only ever truncates
    // this line and not the core values before it.
    final foods = _todaysFoodSummary();
    if (foods != null) lines.add(foods);
    return lines.join(' ');
  }

  /// Today's kcal and macros per meal slot, or null if nothing is logged
  /// (then the line is absent from the context instead of empty).
  ///
  /// Only slots with entries, in [MealSlot] order; aggregation is the pure,
  /// unit-tested [totals.slotTotalsForFoodDate]. German labels like
  /// [_todaysFoodSummary]; grams rounded.
  String? _todaysSlotSummary() {
    final bySlot = totals.slotTotalsForFoodDate(loggedMeals, clock.now());
    if (bySlot.isEmpty) return null;
    final parts = bySlot.entries.map((e) {
      final m = e.value.macros;
      final n = e.value.entries;
      final count = n == 1 ? '1 Eintrag' : '$n Einträge';
      return '${e.key.germanLabel} ${m.kcal} kcal '
          '(P ${m.proteinG.round()} g, K ${m.carbsG.round()} g, '
          'F ${m.fatG.round()} g, $count)';
    }).join('; ');
    return 'Pro Mahlzeit heute: $parts.';
  }

  /// Today's logged meals as `slot: name (kcal)`, or null if none.
  ///
  /// Capped at `maxFoods` entries and 40-char names to stay inside
  /// [kCoachContextCapChars]; a trailing "…" marks a shortened list.
  String? _todaysFoodSummary() {
    const maxFoods = 10;
    final meals = mealsForFoodDate(clock.now());
    if (meals.isEmpty) return null;
    final shown = meals.take(maxFoods).map((m) {
      final raw = m.result.mealName.trim();
      final name = raw.isEmpty
          ? 'Mahlzeit'
          : (raw.length > 40 ? '${raw.substring(0, 39)}…' : raw);
      return '${m.slot.germanLabel}: $name (${m.result.caloriesKcal} kcal)';
    }).join(', ');
    final suffix = meals.length > maxFoods ? ' …' : '';
    return 'Heute gegessene Lebensmittel — $shown$suffix.';
  }

  bool get selectedFoodDateIsToday =>
      _isSameFoodDate(selectedFoodDate, clock.now());

  // Pure aggregation lives in services/meal_totals.dart; these are thin
  // wrappers binding the current loggedMeals.
  List<LoggedMeal> mealsForFoodDate(DateTime date) =>
      totals.mealsForFoodDate(loggedMeals, date);

  int consumedKcalForFoodDate(DateTime date) =>
      totals.consumedKcalForFoodDate(loggedMeals, date);

  MacroProgress macroProgressForFoodDate(DateTime date) =>
      totals.macroProgressForFoodDate(loggedMeals, date);

  // --- internal helpers -----------------------------------------------------
  /// Runs [fn], then notifies listeners. No-op on the notify side after
  /// dispose.
  void _mutate(VoidCallback fn) {
    fn();
    if (!_disposed) notifyListeners();
  }

  /// Drops the cached 90-day trend window after a change the SERVER will see.
  ///
  /// TrendService reads logged_meals straight from the server, so a cached
  /// window survives a write the user just made and the chart shows a short
  /// bar for today. The TTL bounds that to two minutes; this closes it at the
  /// source. Deliberately NOT hung on [_mutate]: seven of its ~40 call sites
  /// sit in the sync path and fire during boot, which would drop the entry
  /// before it was ever read.
  ///
  /// Only logged_meals matters — the projection is kcal + macros
  /// (trend_service.dart `_projection`); weight and steps never reach it.
  void _invalidateTrendWindow() => TrendTotalsCache.instance.invalidate();

  bool _isSameFoodDate(DateTime a, DateTime b) => DateUtils.isSameDay(a, b);

  DateTime _timestampForFoodDate(DateTime date) {
    final now = clock.now();
    final day = DateUtils.dateOnly(date);
    return DateTime(day.year, day.month, day.day, now.hour, now.minute);
  }
}

/// ARCH-4: single source of truth for the home state, as a [ChangeNotifier] —
/// the UI attaches via `ListenableBuilder`/slice selectors and rebuilds
/// selectively.
///
/// The store knows NO BuildContext: navigation and modal sheets stay in the
/// state shell, user-facing messages go through the injected [SnackEmitter].
///
/// Deliberately ONE class (dozens of tests and widgets depend on the API),
/// split mechanically into `part` files/mixins — same library, private members
/// stay private:
///  * `home_store.dart`          — core: ctor, boot/hydration, shared state
///    and views ([_HomeStoreBase]), tab/date, dispose
///  * `home_store_sync.dart`     — outbox (DATA-7) with replay/backoff, stats
///    deltas, cache write-through, error/snack paths, account cleanup
///  * `home_store_meals.dart`    — meal log/edit/delete, favorites/recents,
///    own recipes, archive day loading
///  * `home_store_profile.dart`  — profile/settings, onboarding, reminders
///  * `home_store_tracking.dart` — weight, health import, streak
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

  /// Guard over [kBootNetworkBudget] — armed in [start], cleared by
  /// [_completeProfileReady]. The only way out of a boot step that never
  /// answers; covers the whole chain, including a hanging cache/keystore
  /// access before the first network call.
  Timer? _bootBudgetTimer;

  Future<void> get profileReady => _profileReadyCompleter.future;

  /// Opens the welcome gate exactly once and clears the budget guard. Every
  /// path that completes [profileReady] goes through here, or the timer would
  /// stay armed for minutes after a fast boot.
  void _completeProfileReady() {
    _bootBudgetTimer?.cancel();
    _bootBudgetTimer = null;
    if (!_profileReadyCompleter.isCompleted) _profileReadyCompleter.complete();
  }

  // --- Boot / Hydration -----------------------------------------------------

  /// Starts the boot. Without sync (test/preview) it is ready immediately;
  /// with sync it hydrates from the durable cache first, then boots over the
  /// network.
  void start() {
    if (sync == null) {
      _completeProfileReady();
      return;
    }
    // Warm up search credentials in the background; never throws, never
    // blocks the boot. After the sync guard so test/preview touch neither
    // SharedPreferences nor Supabase.
    unawaited(SearchCredentialsStore.instance.warmUp());
    // B4: midnight timer while the app is open. Also after the sync guard, so
    // a preview/test instance drags no long-running timers along; the resume
    // path ([maybeRollOverToToday]) still works there, it needs no timer.
    _scheduleMidnightRollover();
    // Arm BEFORE the boot, not inside it: the first step of
    // [_hydrateThenBoot] is `LocalCache.create` (OS keystore), which can hang
    // too — a guard created afterwards would miss exactly that case.
    _bootBudgetTimer = Timer(kBootNetworkBudget, () {
      _bootBudgetTimer = null;
      if (_disposed) return;
      dev.log(
          'Boot-Budget (${kBootNetworkBudget.inSeconds}s) aufgebraucht — die '
          'App wird ohne Server-Antwort angezeigt, der Boot laeuft weiter',
          name: 'eatova_sync');
      _completeProfileReady();
    });
    unawaited(_hydrateThenBootGuarded());
  }

  /// F1-09: the boot chain is fire-and-forget, so a throw anywhere in it (a
  /// PlatformException from the notification plugin at its very end) used to
  /// be an unhandled zone error — "fatal" in Sentry, boot half done. Reported
  /// through the sync filter (an outage is not an incident) and the gate is
  /// opened so the user is not stuck until the budget.
  Future<void> _hydrateThenBootGuarded() async {
    // The whole chain counts as "loading" for the shell: the budget can open
    // the gate while the chain is still before its server load (keystore,
    // hydration, replay), and a retry then must show progress, not start a
    // parallel load.
    _bootChainInFlight = true;
    try {
      await _hydrateThenBoot();
    } catch (e, st) {
      dev.log('Boot-Kette abgebrochen', error: e, stackTrace: st,
          name: 'eatova_sync');
      unawaited(CrashReporter.captureSyncFailure(e, st, context: 'boot'));
      if (!_disposed) _completeProfileReady();
    } finally {
      if (_disposed) {
        _bootChainInFlight = false;
      } else {
        _mutate(() => _bootChainInFlight = false);
      }
    }
  }

  // --- Boot without an answer (F1-06) ---------------------------------------

  /// The boot-profile load has ANSWERED — a row or "no row" — at least once.
  /// An error or a timeout is not an answer.
  bool _serverProfileAnswered = false;

  /// The boot load of `user_recipes` has ANSWERED — a list, possibly empty.
  /// An error, a timeout or a still-running load is not an answer.
  bool _serverRecipesAnswered = false;

  /// The answered recipe load came back with a FULL page
  /// ([UserRecipesSync.userRecipesLimit] rows), so the account may hold older
  /// recipes this list never saw (review 2026-08-31, A).
  ///
  /// An answer is not the same as a complete answer. `load()` reads the newest
  /// 200 rows while the table itself allows 5000 (migration 20260829120000),
  /// so above 200 recipes the boot list is a WINDOW. Everything that only
  /// READS it survives that fine — but the orphan photo sweep draws a
  /// conclusion from what is MISSING, and a window's missing entries are not
  /// missing entries.
  bool _serverRecipesPageFull = false;

  /// A server load is running ([_bootFromSupabase]); the shell shows progress
  /// instead of the retry button. Also the re-entry guard of that method.
  bool _bootLoadInFlight = false;

  /// The boot chain ([_hydrateThenBootGuarded]) is running — covers the
  /// phase BEFORE the server load too.
  bool _bootChainInFlight = false;

  /// True while the store knows nothing about the user: no cached profile,
  /// and the server has not answered yet. Once the welcome gate has fallen
  /// (budget or fast failure) the shell shows the "slow connection" state
  /// instead of the onboarding that `needsOnboarding` would claim from ctor
  /// defaults — a returning user must never see onboarding for a slow socket,
  /// and `completeOnboarding` must never overwrite a real profile row.
  bool get bootUnanswered =>
      sync != null && !_hydratedFromRealSource && !_serverProfileAnswered;

  bool get bootLoadInFlight => _bootLoadInFlight || _bootChainInFlight;

  /// True once [userRecipes] is an AUTHORITATIVE statement about which recipes
  /// this account has — the boot load answered for that collection (P3-04b).
  ///
  /// Everything before is provisional, and looks exactly the same from the
  /// outside: the ctor default, a cache slot that is legitimately empty and a
  /// cache slot that lost its last 400 ms to a kill are all `[]`. Only the
  /// server answer separates "the user has no recipes" from "we do not know
  /// yet", and only after it may a consumer draw conclusions from what is
  /// MISSING — the orphan photo sweep in `recipes_screen.dart` deletes files
  /// on exactly that conclusion.
  ///
  /// Deliberately the recipe load, not the end of [_bootFromSupabase]: the six
  /// loads answer independently, and a failed recipe load leaves the list as
  /// provisional as it was before.
  ///
  /// An ANSWER alone is not enough (review 2026-08-31, A). Two more states
  /// look like a complete list and are not, and both end in deleted photos
  /// that exist nowhere else:
  ///
  ///   * [_serverRecipesPageFull] — the server page is exhausted, so recipe
  ///     #201 and older are simply not in it. Whoever has more recipes than
  ///     the page holds would lose every photo of the older ones on the first
  ///     boot whose recipe cache slot fails to hydrate.
  ///   * [_outboxHydrationFailed] — the outbox slot threw on read, so a queued
  ///     `recipeUpsert` was never replayed into the list. That recipe exists
  ///     (on this device, undelivered), its photo exists, and neither is in
  ///     the list. The brake lifts by itself once [_repairOutboxHydration]
  ///     recovers the ops and `_applyPendingOpsToState` puts them back.
  ///
  /// The page-full test says "possibly truncated", not "truncated": exactly
  /// 200 recipes trips it too, and then the sweep never runs again for that
  /// account. Deliberate — the cost of that mistake is uncollected bytes, the
  /// cost of the opposite is the user's photos. Reading one row beyond the cap
  /// would sharpen the test, but only for the exactly-200 case: above it the
  /// list stays a window either way.
  bool get userRecipesAuthoritative =>
      _serverRecipesAnswered &&
      !_serverRecipesPageFull &&
      !_outboxHydrationFailed;

  /// Retry button of the unanswered state: runs the server load again. No-op
  /// while the boot chain or a load is running — two taps are one load.
  Future<void> retryBoot() async {
    if (sync == null || _disposed || bootLoadInFlight) return;
    try {
      await _bootFromSupabase();
    } catch (e, st) {
      unawaited(CrashReporter.captureSyncFailure(e, st, context: 'boot-retry'));
      if (!_disposed && _bootLoadInFlight) {
        _mutate(() => _bootLoadInFlight = false);
      }
    }
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
    } else {
      // Without a cache there is no persisted sync state an early logout
      // would have to preserve — the A2 window does not exist here.
      _syncStateHydrated = true;
    }
    // A real cached profile makes the state displayable, so the server load
    // becomes a correction rather than a start step and may finish in the
    // background instead of holding the WelcomeScreen on a silent socket.
    //
    // Tied to [_hydratedFromRealSource] on purpose: without a cached profile
    // `needsOnboarding` would be true and the user would flash through
    // onboarding. That case is covered by [kBootNetworkBudget].
    if (_hydratedFromRealSource) _completeProfileReady();
    // A1: if the DEK restart discarded an unreadable cache, a persisted flag
    // says so — a silent fresh start would let the user believe the offline
    // diary is still there.
    //
    // Not awaited: a hanging prefs access would otherwise stall the start
    // before the first frame. The flag is persisted, so a late snack is fine.
    unawaited(CacheKeyProvider.consumeCacheResetNotice().then((liegtAn) {
      if (!liegtAn || _disposed) return;
      _emitSnack(
        _l10n.commonCacheResetNotice,
        icon: Icons.info_outline_rounded,
        duration: const Duration(seconds: 6),
      );
    }));
    // Replay the outbox BEFORE the server load (best effort), so the refresh
    // already contains the caught-up writes. Offline the replay just fails;
    // the ops stay queued and _applyPendingOpsToState layers them on top.
    await _replayOutbox();
    await _bootFromSupabase();
    // Flush stats deltas persisted from the last run: the boot load just reset
    // lifetimeStats, and increment_lifetime_stats adds atomically on top.
    if (_pendingMealsDelta != 0 || _pendingWeightLogsDelta != 0) {
      unawaited(_flushStatsDelta());
    }
    await _initNotificationsFromCache();
  }

  /// Reads ONE cache slot fault-tolerantly (gap F).
  ///
  /// One `try` per slot, so a broken slot costs only its own content: `null`
  /// means "nothing usable", and the server load or next write repairs it.
  /// Previously a single shared `try` let an unreadable PROFILE skip the
  /// outbox read, silently discarding up to [kOutboxMaxOps] undelivered
  /// writes.
  ///
  /// [onFehler] fires only on a THROW, not on an empty slot — for the outbox
  /// "unreadable" differs from "empty". That distinction requires the throwing
  /// read variants ([LocalCache.readOutboxOrThrow] /
  /// [LocalCache.readPendingStatsDeltasOrThrow]); every other reader swallows
  /// its error and returns `null`.
  Future<T?> _leseSlot<T>(
    String slot,
    Future<T?> Function() read, {
    VoidCallback? onFehler,
  }) async {
    try {
      return await read();
    } catch (e, st) {
      onFehler?.call();
      dev.log('LocalCache hydrate failed ($slot)',
          error: e, stackTrace: st, name: 'local_cache');
      unawaited(CrashReporter.capture(e, st, context: 'cache-hydrate-$slot'));
      return null;
    }
  }

  Future<void> _hydrateFromCache() async {
    final cache = _cache;
    if (cache == null) return;
    final today = clock.now();
    var outboxLesefehler = false;
    var deltaLesefehler = false;
    // The nine slot reads are independent, so they run concurrently and the
    // boot gate waits for the slowest decrypt instead of the sum (perf
    // finding 4, 2026-08-31). Waves of three, not one big Future.wait: each
    // read decrypts in its own compute() isolate, and an unbounded spawn
    // burst at cold start is exactly the memory pressure the slot-repair
    // paths anticipate failing under. [_leseSlot] never throws, so a wave
    // cannot end in a ParallelWaitError. Pinned in
    // home_store_hydration_parallel_test.dart.
    final (cachedProfile, cachedStats, cachedMeals) = await (
      _leseSlot('profile', cache.readProfile),
      _leseSlot('stats', cache.readLifetimeStats),
      _leseSlot('logged_meals', cache.readLoggedMeals),
    ).wait;
    _cachedProfileAtBoot = cachedProfile;
    final (cachedFavorites, cachedWeightLog, cachedOutbox) = await (
      _leseSlot('favorites', cache.readFavorites),
      _leseSlot('weight_log', cache.readWeightLog),
      _leseSlot('outbox', cache.readOutboxOrThrow,
          onFehler: () => outboxLesefehler = true),
    ).wait;
    final (cachedDeltas, cachedRecipes, cachedActivity) = await (
      _leseSlot('pending_stats', cache.readPendingStatsDeltasOrThrow,
          onFehler: () => deltaLesefehler = true),
      _leseSlot('user_recipes', cache.readUserRecipes),
      _leseSlot('daily_activity', cache.readDailyActivity),
    ).wait;
    if (_disposed) return;
    // Leave the persisted blob untouched while it could not be read, or the
    // next write would overwrite it.
    _outboxHydrationFailed = outboxLesefehler;
    // Same brake for the second half of the sync state (W7b): otherwise the
    // next flush restarts the deltas slot at 0 and the previous session's
    // meals are missing from the lifetime counters for good.
    _statsHydrationFailed = deltaLesefehler;
    // From here the in-memory state mirrors the blob (the take-over below is
    // synchronous), so signOutCleanup may trust `_outbox.length` again. Tied
    // to the sync state only: an unreadable profile says nothing about pending
    // writes and must not stall the logout cleanup.
    if (!outboxLesefehler && !deltaLesefehler) _syncStateHydrated = true;
    // Always adopt outbox + stats deltas — the kill-safe part of the sync
    // state, regardless of what else was cached.
    if (cachedOutbox != null) {
      // Second entry point that bypasses enqueueing: a queue grown by an older
      // uncapped build arrives unchecked, so the cap must run here too.
      final capped = capOutbox(cachedOutbox);
      _outbox = capped.queue;
      if (capped.dropped.isNotEmpty) {
        dev.log(
            'Outbox-Hydration: ${capped.dropped.length} aelteste Op(s) '
            'verworfen (Queue > $kOutboxMaxOps)',
            name: 'eatova_sync');
        CrashReporter.breadcrumb(
            'outbox-hydrate-cap: ${capped.dropped.length} ops dropped');
        _persistOutbox();
        // The cap can hit delete ops too (writes are trimmed first, but a
        // queue of pure deletions falls eventually). Report both loss kinds
        // separately. No _restoreDroppedDeletes here: _bootFromSupabase runs
        // right after hydration and its window load re-fetches those rows.
        _notifyDroppedOps(capped.dropped);
      }
    }
    if (cachedDeltas != null) {
      _pendingMealsDelta += cachedDeltas.meals;
      _pendingWeightLogsDelta += cachedDeltas.weightLogs;
      // The bundle's request id must survive the cold start: the flush right
      // after boot is a retry, and a retry only works with the SAME id
      // (finding B). `??=` because a bundle already running here wins; a slot
      // from an older build carries none and `_flushStatsDelta` assigns one.
      _pendingStatsRequestId ??= cachedDeltas.requestId;
    }
    if (cachedProfile == null &&
        cachedStats == null &&
        cachedMeals == null &&
        cachedFavorites == null &&
        cachedWeightLog == null &&
        cachedRecipes == null &&
        cachedActivity == null &&
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
      // Gap A: without this, airplane mode always started with an empty own
      // recipe list, because only the failing server load knew them.
      //
      // An EMPTY slot is adopted like any other (P3-04b): here it is a no-op
      // anyway (the ctor default is `[]` too), and the case it looks like it
      // could catch — a slot the 400 ms debounce never got to write — is
      // indistinguishable from a genuinely empty one at this point. That
      // distinction is not hydration's job and cannot be made here; only the
      // server answer makes it, and [userRecipesAuthoritative] carries it to
      // the one consumer that draws conclusions from a missing entry.
      if (cachedRecipes != null) _userRecipes = cachedRecipes;
      // Merge, not assign: an early health refresh may already have written
      // today before hydration finished — the newer in-memory value wins for
      // shared days.
      if (cachedActivity != null) {
        dailyActivity = <String, ({int steps, int kcal})>{
          ...cachedActivity,
          ...dailyActivity,
        };
      }
      _applyPendingOpsToState();
      dailyConsumedKcal = consumedKcalForFoodDate(today);
      macroProgress = macroProgressForFoodDate(today);
    });
  }

  /// Recomputes the two day values when re-hydration recovered outbox ops.
  ///
  /// `_repairOutboxHydration` is the only caller of
  /// `_applyPendingOpsToState` that does not recompute itself
  /// ([_hydrateFromCache] and [_bootFromSupabase] do; `_mergeArchiveMeals`
  /// never touches today). A meal recovered for TODAY would otherwise show in
  /// the diary but be missing from the day balance and macro rings.
  ///
  /// An override rather than a line in the repair path, because that lives in
  /// the sync part (audit 2026-08-14). If the recompute moves there, this
  /// override can go — doing it twice would only be redundant.
  @override
  Future<void> _repairOutboxHydration() async {
    final mealsVorher = loggedMeals;
    await super._repairOutboxHydration();
    // Only when something actually came back; the normal case must neither
    // recompute nor notify a second time.
    if (_disposed || identical(loggedMeals, mealsVorher)) return;
    final today = clock.now();
    _mutate(() {
      dailyConsumedKcal = consumedKcalForFoodDate(today);
      macroProgress = macroProgressForFoodDate(today);
    });
  }

  Future<void> _bootFromSupabase() async {
    // Re-entry guard: a second concurrent load would reset the flag from the
    // first finished run and adopt a stale snapshot over a fresh one.
    if (_bootLoadInFlight || _disposed) return;
    final s = sync!;
    final today = clock.now();
    _mutate(() => _bootLoadInFlight = true);
    // F1-01: the gate is open on the cached profile while these loads run, so
    // a live write can land in the window. Remember each collection's version
    // and content BEFORE the requests go out: unchanged afterwards means the
    // answer may replace the list wholesale; changed means the answer is a
    // snapshot from before the write and gets MERGED (local wins, missing
    // server ids added, ids deleted locally in the window not revived).
    final vorher = _BootBaseline.of(this);
    // Sentry FLUTTER-9/-A/-B: at every cold start the server rejected ONE of
    // these six loads for its (freshly refreshed) token, and that load was
    // lost for the session. StaleAuthRetry waits and retries, refreshing
    // only on the second strike — see its doc for the edge-log evidence.
    final auth = StaleAuthRetry(() => s.client.auth.refreshSession());
    final results = await Future.wait<Object?>([
      _safeLoad('boot-profile', () async {
        final loaded = await auth.run(s.profile.load);
        // "No row" is an answer too (fresh user -> onboarding); only a throw
        // leaves this unset (F1-06).
        _serverProfileAnswered = true;
        return loaded;
      }),
      _safeLoad('boot-meals', () => auth.run(s.meals.loadLoggedMeals)),
      _safeLoad('boot-favorites', () => auth.run(s.meals.loadFavorites)),
      _safeLoad('boot-weight-log', () => auth.run(s.tracking.loadWeightLog)),
      _safeLoad('boot-lifetime-stats', () => auth.run(s.lifetimeStats.load)),
      _safeLoad('boot-user-recipes', () => auth.run(s.userRecipes.load)),
    ]);
    if (_disposed) {
      _bootLoadInFlight = false;
      return;
    }
    var healSave = false;
    _mutate(() {
      _bootLoadInFlight = false;
      final loadedProfile = results[0] as UserProfile?;
      // A profile written in the window (onboarding completed, settings
      // saved) is newer than any snapshot the server can return.
      if (loadedProfile != null && vorher.profileVersion == _profileVersion) {
        profile = loadedProfile;
        _hydratedFromRealSource = true;
        healSave =
            s.profile.lastLoadHealed && _serverGoalsLookStale(loadedProfile);
        // The adopted row is the new reference, so a retryBoot does not
        // queue the same correction twice.
        _cachedProfileAtBoot = loadedProfile;
      }

      final loadedMeals = results[1] as List<LoggedMeal>?;
      if (loadedMeals != null) {
        loggedMeals = vorher.loggedMealsVersion == _loggedMealsVersion
            ? loadedMeals
            : _mergeRacedLoad(
                local: loggedMeals,
                server: loadedMeals,
                baseline: vorher.loggedMeals,
                keyOf: (m) => m.id,
                sort: (a, b) => b.loggedAt.compareTo(a.loggedAt),
              );
        // The fresh window load REPLACES the list, so previously fetched
        // archive days are gone and must be reloaded on re-selection. Without
        // this reset the session cache would call the day "loaded" and show it
        // empty. Ghost duplicates cannot happen (merge dedups by id).
        _loadedArchiveDays.clear();
      }

      final loadedFavorites = results[2] as List<FavoriteMeal>?;
      // The cap on automatic recents ([_cappedFavorites], [_maxAutoRecents])
      // is a purely LOCAL rule; favorite_meals does not know it, so without
      // capping here the add sheet would show the full history after every
      // cold start. `loadFavorites` returns added_at DESC, the order the cap
      // relies on (pinned favorites stay untouched).
      if (loadedFavorites != null) {
        favorites = vorher.favoritesVersion == _favoritesVersion
            ? _cappedFavorites(loadedFavorites)
            : _cappedFavorites(_mergeRacedLoad(
                local: favorites,
                server: loadedFavorites,
                baseline: vorher.favorites,
                keyOf: (f) => f.id,
                sort: (a, b) => b.addedAt.compareTo(a.addedAt),
              ));
      }

      final loadedWeightLog = results[3] as WeightLog?;
      if (loadedWeightLog != null) {
        weightLog = vorher.weightLogVersion == _weightLogVersion
            ? loadedWeightLog
            : WeightLog(
                entries: _mergeRacedLoad(
                  local: weightLog.entries,
                  server: loadedWeightLog.entries,
                  baseline: vorher.weightLog.entries,
                  keyOf: (e) => e.timestamp.toUtc().toIso8601String(),
                  sort: (a, b) => a.timestamp.compareTo(b.timestamp),
                ),
              );
      }

      final loadedStats = results[4] as LifetimeStats?;
      // A row adopted in the window (live meal, RPC answer) is newer than
      // the snapshot; the next flush brings the authoritative counters.
      if (loadedStats != null &&
          vorher.lifetimeStatsVersion == _lifetimeStatsVersion) {
        lifetimeStats = loadedStats;
      }

      final loadedRecipes = results[5] as List<FitnessRecipe>?;
      if (loadedRecipes != null) {
        // The server named the account's recipes; from here the list is a
        // statement, not a guess ([userRecipesAuthoritative], P3-04b).
        _serverRecipesAnswered = true;
        // ... unless the page is exhausted, in which case it names only the
        // NEWEST ones and says nothing about the rest (review 2026-08-31, A).
        // Recomputed per answered load, so a shrinking library becomes
        // authoritative again.
        _serverRecipesPageFull =
            loadedRecipes.length >= UserRecipesSync.userRecipesLimit;
        _userRecipes = vorher.userRecipesVersion == _userRecipesVersion
            ? _mergeUserRecipes(loadedRecipes)
            : _mergeRacedLoad(
                local: _userRecipes,
                server: loadedRecipes,
                baseline: vorher.userRecipes,
                keyOf: (r) => r.slug,
              );
      }

      // Cache-then-network merge: server data wins for synced entries, but
      // undelivered outbox writes stay visible (otherwise the fresh load would
      // throw an offline-logged meal back out of the diary).
      _applyPendingOpsToState();

      dailyConsumedKcal = consumedKcalForFoodDate(today);
      macroProgress = macroProgressForFoodDate(today);
    });
    // Selection sits on an archive day (boot ran during a calendar visit):
    // reload it instead of showing it empty after the window replace.
    if (_isOutsideBootWindow(selectedFoodDate)) {
      unawaited(_ensureArchiveDayLoaded(selectedFoodDate));
    }
    if (healSave) _queueHealedProfileSave();
    unawaited(_writeCacheSnapshot());
    _completeProfileReady();
  }

  // --- Live-goal write-back (F7-01, boot hook) -----------------------------

  /// The profile slot as hydration found it, replaced by the adopted server
  /// row after each load — the re-entry guard for [_serverGoalsLookStale].
  UserProfile? _cachedProfileAtBoot;

  /// Whether a healed load still needs its write-back.
  ///
  /// The exact signal is `ProfileSync.lastLoadHealed` (checked by the
  /// caller): the row differed from the CURRENT calculator and `load` healed
  /// it locally but stayed a read. This guard only keeps the write from
  /// repeating: skipped while a profile op is queued (that save carries the
  /// fix) and when the adopted reference already carries the healed goals
  /// (a retryBoot before the save landed). Without a reference (fresh
  /// device) the healed signal alone decides.
  bool _serverGoalsLookStale(UserProfile loaded) {
    if (loaded.manualEnergy || !loaded.onboardingCompleted) return false;
    if (_outbox.any((o) => o.kind == SyncOpKind.profileUpsert)) return false;
    final cached = _cachedProfileAtBoot;
    if (cached == null) return true;
    return cached.dailyKcalGoal != loaded.dailyKcalGoal ||
        cached.proteinGoalG != loaded.proteinGoalG ||
        cached.carbsGoalG != loaded.carbsGoalG ||
        cached.fatGoalG != loaded.fatGoalG;
  }

  /// Writes the healed live goals back — one full-row upsert through the
  /// regular outbox path (same entity key as every profile op, so it
  /// coalesces and never double-saves).
  void _queueHealedProfileSave() {
    final s = sync;
    if (s == null || _disposed) return;
    final healed = profile;
    dev.log(
        'Live-Ziele nach Boot-Heilung zurueckgeschrieben '
        '(${healed.dailyKcalGoal} kcal)',
        name: 'eatova_sync');
    // Silent: an automatic correction at cold start must not raise the
    // "queued, will retry" snack the user did nothing to cause; the outbox
    // still carries the op.
    unawaited(_syncOrQueue(
      'Profil-Sync (Heilung)',
      () => s.profile.save(healed),
      () => SyncOp.profileUpsert(healed),
      aufruferMeldetAusgang: true,
    ));
  }

  /// Gap C: layers the freshly loaded server list OVER the local one instead
  /// of replacing it.
  ///
  /// Plain assignment lost an own recipe whenever its outbox op never existed
  /// or had fallen at the queue cap — and `_writeCacheSnapshot` then made the
  /// loss permanent ("airplane mode -> recipe -> restart online -> gone").
  ///
  /// Same pattern as [_HomeStoreMealsPart._mergeArchiveMeals]: only MISSING
  /// slugs are added, the server row wins for shared ones;
  /// `_applyPendingOpsToState` puts undelivered local state back on top.
  ///
  /// Source is the LIVE `_userRecipes`, not the raw cache blob: hydration has
  /// already applied pending ops, so a local deletion is done. Merging from
  /// the blob would resurrect a recipe deleted inside the 400 ms debounce
  /// window.
  ///
  /// Accepted: a recipe deleted on ANOTHER device survives here until deleted
  /// locally too — the opposite error (own recipe silently gone) is worse.
  List<FitnessRecipe> _mergeUserRecipes(List<FitnessRecipe> fromServer) {
    final serverSlugs = fromServer.map((r) => r.slug).toSet();
    final nurLokal =
        _userRecipes.where((r) => !serverSlugs.contains(r.slug)).toList();
    if (nurLokal.isEmpty) return fromServer;
    // Local first: the list shows own recipes on top, and the one just
    // created is what the user is looking at.
    return <FitnessRecipe>[...nurLokal, ...fromServer];
  }

  /// F1-01 merge for a collection mutated while its load was in flight.
  ///
  /// [local] wins for every shared key (it may carry an edit the snapshot
  /// predates). Server rows are added only if they are in NEITHER list: a key
  /// in [baseline] but not in [local] was deleted locally in the window and
  /// must not come back. [sort] restores the server order afterwards.
  static List<T> _mergeRacedLoad<T>({
    required List<T> local,
    required List<T> server,
    required List<T> baseline,
    required String Function(T) keyOf,
    int Function(T, T)? sort,
  }) {
    final localKeys = local.map(keyOf).toSet();
    final baselineKeys = baseline.map(keyOf).toSet();
    final merged = <T>[
      ...local,
      ...server.where((row) {
        final key = keyOf(row);
        return !localKeys.contains(key) && !baselineKeys.contains(key);
      }),
    ];
    if (sort != null) merged.sort(sort);
    return merged;
  }

  Future<T?> _safeLoad<T>(
      String operation, Future<T?> Function() loader) async {
    try {
      return await loader();
    } catch (e, st) {
      dev.log('Eatova load failed ($operation)',
          error: e, stackTrace: st, name: 'eatova_sync');
      // `captureSyncFailure`, not `capture`: a cold start offline is the
      // designed cache-then-network flow, not an incident — and since the
      // expired-JWT retry the refresh itself can fail offline here too.
      unawaited(CrashReporter.captureSyncFailure(e, st, context: operation));
      return null;
    }
  }

  // --- Tab / date -----------------------------------------------------------

  void setTab(int index) => _mutate(() => selectedTab = index);

  void setFoodDate(DateTime date) {
    final day = DateUtils.dateOnly(date);
    _mutate(() => selectedFoodDate = day);
    // Calendar pick outside the boot window: load the day on demand instead
    // of showing it wrongly empty.
    if (_isOutsideBootWindow(day)) {
      unawaited(_ensureArchiveDayLoaded(day));
    }
    // Archive day: pull the burned-kcal value from the health history if this
    // session has not fetched it yet.
    unawaited(_maybeBackfillDailyActivity(day));
  }

  // --- Day rollover (B4) ----------------------------------------------------

  /// Safety margin on the timer wait so the callback runs AFTER midnight, not
  /// in the last millisecond before it (drift/rounding would make it a no-op
  /// that immediately rearms on the same second).
  static const Duration _midnightSafetyMargin = Duration(seconds: 2);

  /// One-shot timer to the next local midnight — not `Timer.periodic`, whose
  /// 24 h grid drifts across every DST switch. The callback rearms it.
  Timer? _midnightTimer;

  /// Whether the midnight timer is armed. Tests only.
  @visibleForTesting
  bool get debugMidnightTimerIsActive => _midnightTimer?.isActive ?? false;

  /// B4: advances the store to today when midnight has passed since the last
  /// look at the clock. Returns `true` if a rollover was processed.
  ///
  /// Two callers: the midnight timer while the app is open, and
  /// `didChangeAppLifecycleState(resumed)` — a suspended app gets no tick.
  ///
  /// [selectedFoodDate] only follows if it sat exactly on [_lastKnownToday];
  /// a deliberately opened archive day stays put.
  ///
  /// [dailyConsumedKcal] and [macroProgress] are ALWAYS recomputed, even on an
  /// archive day: they always describe today, and the profile tiles and
  /// [coachContext] hang off them.
  ///
  /// [dailySteps] stays untouched: it belongs to the health path, whose
  /// snapshot returns `null` (not 0) while unverified, and the resume calls
  /// `refreshHealthSteps()` anyway.
  bool maybeRollOverToToday() {
    if (_disposed) return false;
    final today = DateUtils.dateOnly(clock.now());
    final previousToday = _lastKnownToday;
    if (_isSameFoodDate(previousToday, today)) return false;

    final folgteHeute = _isSameFoodDate(selectedFoodDate, previousToday);
    _lastKnownToday = today;
    _mutate(() {
      if (folgteHeute) selectedFoodDate = today;
      dailyConsumedKcal = consumedKcalForFoodDate(today);
      macroProgress = macroProgressForFoodDate(today);
    });
    // A suspend halts timers, so after a rollover the timer may point at a
    // long-past midnight. Rearm — but only if it was armed, so a resume in a
    // sync-less instance creates no timer out of nowhere.
    if (_midnightTimer != null) _scheduleMidnightRollover();
    return true;
  }

  void _scheduleMidnightRollover() {
    _midnightTimer?.cancel();
    _midnightTimer = null;
    if (_disposed) return;
    _midnightTimer = Timer(
      durationUntilNextLocalMidnight(clock.now()) + _midnightSafetyMargin,
      () {
        // Clear before the rollover: [maybeRollOverToToday] only rearms an
        // armed timer, and the line below rearms unconditionally — also when
        // the timer fired a second early and there was no rollover.
        _midnightTimer = null;
        if (_disposed) return;
        maybeRollOverToToday();
        _scheduleMidnightRollover();
      },
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _statsSaveDebounce?.cancel();
    _outboxRetryTimer?.cancel();
    _outboxRetryTimer = null;
    _midnightTimer?.cancel();
    _midnightTimer = null;
    _bootBudgetTimer?.cancel();
    _bootBudgetTimer = null;
    // F1-02: a debounce armed by the last mutation must not write this
    // store's mirror state after the session it belonged to is gone. Discard,
    // not close — the instance may still serve a purge.
    _cache?.discardPendingWrites();
    sync?.dispose();
    super.dispose();
  }
}

/// Versions and contents of the mirrored collections at the moment the boot
/// loads went out (F1-01). Contents are the immutable list instances of that
/// moment, so holding them costs nothing.
class _BootBaseline {
  const _BootBaseline({
    required this.profileVersion,
    required this.loggedMealsVersion,
    required this.favoritesVersion,
    required this.weightLogVersion,
    required this.lifetimeStatsVersion,
    required this.userRecipesVersion,
    required this.loggedMeals,
    required this.favorites,
    required this.weightLog,
    required this.userRecipes,
  });

  factory _BootBaseline.of(_HomeStoreBase store) => _BootBaseline(
        profileVersion: store._profileVersion,
        loggedMealsVersion: store._loggedMealsVersion,
        favoritesVersion: store._favoritesVersion,
        weightLogVersion: store._weightLogVersion,
        lifetimeStatsVersion: store._lifetimeStatsVersion,
        userRecipesVersion: store._userRecipesVersion,
        loggedMeals: store.loggedMeals,
        favorites: store.favorites,
        weightLog: store.weightLog,
        userRecipes: store._userRecipes,
      );

  final int profileVersion;
  final int loggedMealsVersion;
  final int favoritesVersion;
  final int weightLogVersion;
  final int lifetimeStatsVersion;
  final int userRecipesVersion;
  final List<LoggedMeal> loggedMeals;
  final List<FavoriteMeal> favorites;
  final WeightLog weightLog;
  final List<FitnessRecipe> userRecipes;
}
