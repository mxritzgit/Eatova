import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../models/logged_meal.dart';
import '../models/macro_progress.dart';
import '../services/data_export.dart';
import '../services/eatova_sync.dart';
import '../services/health_service.dart';
import '../services/local_cache.dart';
import '../services/meal_analyzer.dart';
import '../services/meal_camera_launcher.dart';
import '../services/meal_photo_input.dart';
import '../services/notification_service.dart';
import '../services/open_food_facts_product_service.dart';
import '../screens/coach/coach_chat_screen.dart';
import '../screens/meal_analysis_screen.dart';
import '../screens/onboarding_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/recipes/recipes_screen.dart';
import '../screens/settings/goals_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/today/today_screen.dart';
import '../l10n/l10n.dart';
import '../theme/app_tokens.dart';
import '../widgets/auth/welcome_screen.dart';
import '../widgets/common/app_snack.dart';
import '../widgets/common/lively.dart';
import '../widgets/common/store_selector.dart';
import '../widgets/design/design.dart';
import '../widgets/kcal/edit_meal_sheet.dart';
import '../widgets/shared/settings_sheet.dart';
import 'auth_gate.dart';
import 'home_store.dart';

class EatovaHomePage extends StatefulWidget {
  EatovaHomePage({
    super.key,
    this.mealAnalyzer,
    this.productService,
    this.photoInput,
    this.mealCameraLauncher,
    this.healthService,
    this.notificationService = const NoopNotificationService(),
    this.initialUserName = 'Moritz',
    this.userEmail,
    this.authRepository,
    this.onSignOut,
    this.sync,
    this.showWelcome = false,
    this.debugCache,
  });

  final MealAnalyzer? mealAnalyzer;
  final ProductLookupService? productService;
  final MealPhotoInput? photoInput;
  final MealCameraLauncher? mealCameraLauncher;
  final HealthService? healthService;

  /// On-device notifications (PROD-1). Defaults to
  /// [NoopNotificationService] so widget tests never touch a platform channel.
  final NotificationService notificationService;

  final String initialUserName;

  /// Session mail address for settings. Null without auth; the row hides.
  final String? userEmail;

  /// Backs password/mail changes in settings. Null without auth, so those
  /// rows are omitted.
  final AuthRepository? authRepository;
  final Future<void> Function()? onSignOut;
  final EatovaSync? sync;

  /// Test seam (DATA-3): inject the durable cache so clobber-guard and
  /// hydration are testable without a Supabase session. Null in production.
  @visibleForTesting
  final LocalCache? debugCache;

  /// True only on a fresh login/register; false on session restore.
  final bool showWelcome;

  @override
  State<EatovaHomePage> createState() => _EatovaHomePageState();
}

/// Test seam: exposes the shell's private [HomeStore].
///
/// The resume handovers mutate only store state the shell does not render.
@visibleForTesting
abstract interface class HomePageDebugAccess {
  HomeStore get debugStore;
}

/// ARCH-4: thin, context-carrying shell around [HomeStore] — navigation,
/// sheets, snackbars, lifecycle. All state lives in the store.
class _EatovaHomePageState extends State<EatovaHomePage>
    with WidgetsBindingObserver
    implements HomePageDebugAccess {
  @override
  HomeStore get debugStore => _store;

  late final HomeStore _store;

  // ARCH-1/PERF-2: drives the AnimatedBuilder bridge in [_openProfile]; a
  // store notify never reaches that pushed route's navigator subtree.
  final ValueNotifier<int> _profileRefresh = ValueNotifier<int>(0);

  /// Requests the food tab's add sheet for exactly one slot.
  ///
  /// A notifier, not a parameter: the shell caches tab widgets by identity
  /// (`_tabViews`), so a changed parameter would never reach a built tab.
  final ValueNotifier<MealSlot?> _addSlotRequest =
      ValueNotifier<MealSlot?>(null);
  bool _profileRouteOpen = false;
  late bool _welcomeFinished;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _store = HomeStore(
      sync: widget.sync,
      health: widget.healthService ?? const NoopHealthService(),
      notificationService: widget.notificationService,
      initialUserName: widget.initialUserName,
      debugCache: widget.debugCache,
      emitSnack: _emitSnack,
    );
    _store.addListener(_onStoreChanged);
    // No sync (preview/test) means no boot/welcome phase.
    _welcomeFinished = widget.sync == null;
    if (widget.healthService != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _store.connectHealth());
    }
    _store.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The store holds no BuildContext (ARCH-4). Re-pushed on every call, so
    // store-built snack texts follow the active locale.
    _store.setLocalizations(context.l10n);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _store.removeListener(_onStoreChanged);
    _profileRefresh.dispose();
    _addSlotRequest.dispose();
    _store.dispose();
    super.dispose();
  }

  /// The store emitted a mutation notify.
  ///
  /// Only what no widget observes hangs here: the profile bridge into a
  /// pushed route and the calendar-day guard for steps (B3b).
  void _onStoreChanged() {
    if (_profileRouteOpen && mounted) _profileRefresh.value++;
    // B3b: the midnight rollover keeps `dailySteps`, so pull one refresh per
    // calendar day or yesterday's steps feed `burnedKcal` all day.
    if (!DateUtils.isSameDay(_healthDay, clock.now())) _refreshHealthSteps();
  }

  /// Calendar day of the last health refresh (guard for [_onStoreChanged]).
  DateTime _healthDay = DateUtils.dateOnly(clock.now());

  /// May a refresh run without pointlessly toggling `healthSyncing`?
  ///
  /// `refreshHealthSteps()` does not check "connected"; the guard sits here.
  /// `unverified`/`denied` are in (B3): `readSnapshot()` re-verifies silently,
  /// so a late grant heals only here. `unknown` belongs to `connectHealth()`.
  bool get _healthMayRefresh => switch (_store.healthAuthState) {
        HealthAuthState.granted ||
        HealthAuthState.unverified ||
        HealthAuthState.denied =>
          true,
        HealthAuthState.unknown || HealthAuthState.unsupported => false,
      };

  void _refreshHealthSteps() {
    _healthDay = DateUtils.dateOnly(clock.now());
    if (!_healthMayRefresh) return;
    unawaited(_store.refreshHealthSteps());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Flush debounced writes so a kill in that window loses no quick logs.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _store.flushPendingWrites();
    }
    if (state != AppLifecycleState.resumed) return;

    // Set the day guard first, or the rollover notify below fires a second,
    // identical refresh.
    _healthDay = DateUtils.dateOnly(clock.now());

    // B4: a suspended app gets no timer tick. Advance the day BEFORE the
    // flush, so a flush-triggered refresh carries the new day.
    _store.maybeRollOverToToday();

    // Replay stranded outbox ops / stats deltas (DATA-7).
    _store.flushPendingWrites();

    // D11: re-read the OS permission silently; lifts `ReminderState.blocked`.
    unawaited(_store.refreshNotificationPermission());

    // Otherwise steps stay at the cold-start value all day.
    _refreshHealthSteps();
  }

  /// Turns the store's context-free snack request into [showAppSnack].
  void _emitSnack(
    String message, {
    IconData icon = Icons.info_outline_rounded,
    SnackTone tone = SnackTone.positive,
    Duration? duration,
    SnackBarAction? action,
  }) {
    if (!mounted) return;
    if (duration != null) {
      showAppSnack(context, message,
          icon: icon, tone: tone, duration: duration, action: action);
    } else {
      showAppSnack(context, message, icon: icon, tone: tone, action: action);
    }
  }

  // --- context-carrying flows (sheets / navigation) ------------------------

  /// "Profil & Ziele" — body data, activity, goal, macros, reminders.
  ///
  /// A pushed route, separate from settings. Returns [SettingsResult].
  Future<void> _openGoals() async {
    final result = await Navigator.of(context).push<SettingsResult>(
      MaterialPageRoute<SettingsResult>(
        builder: (_) => GoalsScreen(
          profile: _store.profile,
          notificationsEnabled: _store.notificationsEnabled,
          // D11: without this the `blocked` state never reaches the screen
          // and the switch keeps claiming reminders are active.
          reminderState: _store.reminderState,
        ),
      ),
    );
    if (result == null || !mounted) return;
    await _store.applySettings(
      newProfile: result.profile,
      notificationsEnabled: result.notificationsEnabled,
    );
  }

  /// Settings — account, display, data, danger zone. Body data and goals live
  /// in [_openGoals]; mixing them is what bloated the old sheet.
  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          // No "linked account" row: the app does not know which provider
          // carried the sign-in, and a guessed row is worse than none.
          email: widget.userEmail,
          authRepository: widget.authRepository,
          onOpenGoals: _openGoals,
          onSignOut: widget.onSignOut != null ? _signOut : null,
          onDeleteAccount: widget.sync != null ? _deleteAccount : null,
          onExportData: widget.sync != null
              ? () => DataExportService(
                    widget.sync!.client,
                    widget.sync!.userId,
                  ).buildExportJson()
              : null,
        ),
      ),
    );
  }

  /// GDPR Art. 17: the store deletes account and data; sign out on success.
  Future<void> _deleteAccount() async {
    if (await _store.deleteAccount()) {
      // An INTENTIONAL logout: without the flag [AuthGate] would report an
      // expired session (Review 2026-08-19).
      IntentionalSignOut.mark();
      await widget.onSignOut?.call();
    }
  }

  /// Regular sign-out: clear the local PII cache (M-1) first — cleanup needs
  /// the still-logged-in user. The flag comes before both, since only it tells
  /// [AuthGate] "signed out" from "session lost".
  Future<void> _signOut() async {
    IntentionalSignOut.mark();
    try {
      await _store.signOutCleanup();
      await widget.onSignOut?.call();
    } catch (_) {
      // Sign-out failed, so no intent may explain a later auth event.
      IntentionalSignOut.clear();
      rethrow;
    }
  }

  Future<void> _openProfile() async {
    // ARCH-1/PERF-2: while open, the store listener bumps _profileRefresh so
    // mid-route state changes reach the ProfileScreen.
    _profileRouteOpen = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AnimatedBuilder(
            animation: _profileRefresh,
            builder: (_, __) => ProfileScreen(
              name: _store.userName,
              profile: _store.profile,
              weightLog: _store.weightLog,
              stats: _store.lifetimeStats,
              dailyConsumedKcal: _store.dailyConsumedKcal,
              dailySteps: _store.dailySteps,
              healthAuthState: _store.healthAuthState,
              healthLastFetch: _store.healthLastFetch,
              onLogWeight: _store.logWeight,
              onEditProfile: _openGoals,
              onOpenSettings: _openSettings,
              onConnectHealth: _store.connectHealth,
              onRefreshHealth: _store.refreshHealthSteps,
              // Sign-out, deletion, export and "about" hang off
              // [_openSettings]; the profile block duplicated them.
            ),
          ),
        ),
      );
    } finally {
      // Route popped: the listener stops bumping _profileRefresh again.
      _profileRouteOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_welcomeFinished) {
      return WelcomeScreen(
        firstName: _store.userName,
        profileReady: _store.profileReady,
        celebrateLogin: widget.showWelcome,
        onComplete: () {
          if (mounted) setState(() => _welcomeFinished = true);
        },
      );
    }

    // PERF-2: only (tab, onboarding gate) rebuild the shell; data slices
    // rebuild their own tab contents.
    return StoreSelector(
      store: _store,
      selector: () => (_store.selectedTab, _store.needsOnboarding),
      builder: (context) {
        // Mandatory onboarding for real users; skipped in test/preview.
        //
        // D7: must stay ABOVE the shell's PopScope — OnboardingScreen has its
        // own, and a pop invokes ALL of them (step back AND switch tab).
        if (_store.needsOnboarding) {
          return OnboardingScreen(
            firstName: _store.userName,
            initialProfile: _store.profile,
            onComplete: _store.completeOnboarding,
          );
        }

        final tab = _store.selectedTab;

        // D7: back used to close the app from any tab. The shell now switches
        // to tab 0 first and only there releases the pop.
        return PopScope<Object?>(
          canPop: tab == 0,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            _store.setTab(0);
          },
          child: Scaffold(
            backgroundColor: context.t.bg,
            // AddMealSheet does its own keyboard inset; a resizing scaffold
            // would shift the background behind the translucent barrier.
            resizeToAvoidBottomInset: tab != _tabFood,
            bottomNavigationBar: AppNavBar(
              index: tab,
              onChanged: (index) => _store.setTab(index),
              items: _navItems(context),
            ),
            // Tabs scroll internally, so no outer SingleChildScrollView.
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                child: _buildTabStack(tab),
              ),
            ),
          ),
        );
      },
    );
  }

  // --- Tabs (D6) ------------------------------------------------------------

  /// Tab order: 0 = today (day overview, landing), 1 = food (diary),
  /// 2 = recipes, 3 = coach.
  static const int _tabHeute = 0;
  static const int _tabFood = 1;
  static const int _tabRezepte = 2;
  static const int _tabCoach = 3;
  static const int _tabCount = 4;

  /// keyIds carry the test keys and stay German; labels come from the ARB.
  List<AppNavItem> _navItems(BuildContext context) {
    final l10n = context.l10n;
    return <AppNavItem>[
      AppNavItem(
        icon: Icons.home_outlined,
        activeIcon: Icons.home_rounded,
        label: l10n.navToday,
        keyId: 'Heute',
      ),
      AppNavItem(
        icon: Icons.restaurant_outlined,
        activeIcon: Icons.restaurant_rounded,
        label: l10n.navFood,
        keyId: 'Food',
      ),
      AppNavItem(
        icon: Icons.menu_book_outlined,
        activeIcon: Icons.menu_book_rounded,
        label: l10n.navRecipes,
        keyId: 'Rezepte',
      ),
      AppNavItem(
        icon: Icons.auto_awesome_outlined,
        activeIcon: Icons.auto_awesome_rounded,
        label: l10n.navCoach,
        keyId: 'Coach',
      ),
    ];
  }

  /// Tabs that have been visible at least once (D6, lazy building).
  final Set<int> _mountedTabs = <int>{};

  /// Cached widget INSTANCES of the mounted tabs.
  ///
  /// Identical instances let `Element.updateChild` skip the subtree; without
  /// the cache every switch would rebuild ALL mounted tabs (G11).
  final List<Widget?> _tabViews = List<Widget?>.filled(_tabCount, null);

  @override
  void didUpdateWidget(EatovaHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // New widget config: drop the cached instances. The element tree survives
    // (same types and keys), so tab state is not lost.
    _tabViews.fillRange(0, _tabCount, null);
  }

  /// D6: [IndexedStack] instead of `switch`, so a visited tab stays mounted.
  ///
  /// **Lazy:** built on first display — an eager stack would fire the coach's
  /// three cold-start network calls. **[TickerMode]:** hidden children keep
  /// animating, so their tickers are muted (battery, `pumpAndSettle`).
  Widget _buildTabStack(int tab) {
    _mountedTabs.add(tab);
    return IndexedStack(
      key: const ValueKey('home-tab-stack'),
      index: tab,
      // StackFit.loose would shrink-wrap the visible tab.
      sizing: StackFit.expand,
      children: <Widget>[
        for (var i = 0; i < _tabCount; i++)
          if (_mountedTabs.contains(i))
            TickerMode(enabled: i == tab, child: _tabAt(i))
          else
            const SizedBox.shrink(),
      ],
    );
  }

  Widget _tabAt(int index) => _tabViews[index] ??= KeyedSubtree(
        key: ValueKey('tab-fixed-$index'),
        // G10: the entrance plays once per tab, not on every switch. A key
        // over the whole body forced the unmount D6 fixes and re-rasterised
        // the kcal card (BackdropFilter is not raster-cacheable).
        child: LivelyEntrance(
          key: ValueKey('lively-tab-$index'),
          child: switch (index) {
            _tabFood => _foodTab(),
            _tabRezepte => _recipesTab(),
            _tabCoach => _coachTab(),
            _ => _todayTab(),
          },
        ),
      );

  /// The day overview. Narrower slice than the food tab: streak and name,
  /// but no favourites or analyzers.
  Widget _todayTab() => StoreSelector(
        store: _store,
        selector: () => (
          _store.selectedFoodDate,
          _store.loggedMeals,
          _store.profile,
          _store.dailySteps,
          // Map identity as fingerprint (G11): an upsert replaces the map.
          _store.dailyActivity,
          // Decides whether the steps card appears (granted -> 0 is a value).
          _store.healthAuthState,
          _store.userName,
          _store.lifetimeStats,
          _store.isLoadingFoodDay(_store.selectedFoodDate),
          _store.selectedFoodDateIsToday,
        ),
        builder: (context) {
          assert(_countTabBuild(_tabHeute));
          final tag = _store.selectedFoodDate;
          return TodayScreen(
            userName: _store.userName,
            profile: _store.profile,
            selectedDate: tag,
            consumedKcal: _store.consumedKcalForFoodDate(tag),
            macroProgress: _store.macroProgressForFoodDate(tag),
            meals: _store.mealsForFoodDate(tag),
            dayLoading: _store.isLoadingFoodDay(tag),
            // Today live, archive days from the value frozen per day.
            burnedKcal: _store.burnedKcalForFoodDate(tag),
            // null = no step source -> no steps card.
            steps: _store.stepsForFoodDate(tag),
            streak: _store.lifetimeStats.effectiveStreakOn(clock.now()),
            profileInitial: _store.profileInitial,
            onDateSelected: _store.setFoodDate,
            onOpenCoach: () => _store.setTab(_tabCoach),
            onOpenProfile: _openProfile,
            onOpenMealSlot: (slot) {
              // The food tab builds lazily: set the request before it mounts.
              _addSlotRequest.value = slot;
              _store.setTab(_tabFood);
            },
          );
        },
      );

  // MealEditScope passes the edit callbacks around the screen signature.
  Widget _foodTab() => StoreSelector(
        store: _store,
        // G11: INPUT values only. Derived getters return a NEW list per call,
        // so a selector on them is always "changed"; the store's lists are
        // reassigned per mutation, making identity an O(1) fingerprint.
        selector: () => (
          _store.selectedFoodDate,
          _store.loggedMeals,
          _store.favorites,
          _store.profile,
          _store.dailySteps,
          _store.userName,
          _store.isLoadingFoodDay(_store.selectedFoodDate),
          _store.selectedFoodDateIsToday,
        ),
        builder: (context) {
          assert(_countTabBuild(_tabFood));
          return MealEditScope(
            onUpdateMeal: _store.updateLoggedMealDetails,
            onRemoveMeal: _store.removeLoggedMeal,
            child: MealAnalysisScreen(
              analyzer: widget.mealAnalyzer,
              productService: widget.productService,
              photoInput: widget.photoInput,
              cameraLauncher: widget.mealCameraLauncher,
              selectedDate: _store.selectedFoodDate,
              onDateSelected: (date) => _store.setFoodDate(date),
              dayLoading: _store.isLoadingFoodDay(_store.selectedFoodDate),
              dailyConsumedKcal:
                  _store.consumedKcalForFoodDate(_store.selectedFoodDate),
              profile: _store.profile,
              favorites: _store.favorites,
              loggedMeals: _store.mealsForFoodDate(_store.selectedFoodDate),
              onAddMeal: (result, slot) =>
                  _store.addResultToDailyTotal(result, slot: slot),
              onUpdateMeal: _store.updateLoggedMealResult,
              isFavorite: _store.isFavorite,
              onToggleFavorite: _store.toggleFavorite,
              onRemoveFavorite: _store.removeFavorite,
              onRemoveMeal: _store.removeLoggedMeal,
              onSettingsPressed: _openSettings,
              onProfilePressed: _openProfile,
              profileInitial: _store.profileInitial,
              addSlotRequest: _addSlotRequest,
            ),
          );
        },
      );

  Widget _recipesTab() => StoreSelector(
        store: _store,
        // Only what the view reads: own recipes plus goals and daily progress
        // for the "fits your goal" filter.
        selector: () => (
          _store.userRecipes,
          _store.profile,
          _store.macroProgress,
        ),
        builder: (context) {
          assert(_countTabBuild(_tabRezepte));
          return RecipesScreen(
            // No hard foodDate: falls back to the store's selectedFoodDate,
            // read at call time, so adding lands on the food tab's day.
            onAddMeal: (result, slot) => _store.addResultToDailyTotal(
              result,
              slot: slot,
            ),
            initialUserRecipes: _store.userRecipes,
            // Persistence only with real sync (test/preview: session-local).
            onCreateRecipe:
                widget.sync == null ? null : _store.createUserRecipe,
            onDeleteRecipe:
                widget.sync == null ? null : _store.deleteUserRecipe,
            // Remaining macros for the day (goal - consumed).
            remainingMacros: MacroProgress(
              proteinG:
                  (_store.profile.proteinGoalG - _store.macroProgress.proteinG)
                      .clamp(0.0, double.infinity)
                      .toDouble(),
              carbsG: (_store.profile.carbsGoalG - _store.macroProgress.carbsG)
                  .clamp(0.0, double.infinity)
                  .toDouble(),
              fatG: (_store.profile.fatGoalG - _store.macroProgress.fatG)
                  .clamp(0.0, double.infinity)
                  .toDouble(),
              kcal: (_store.profile.dailyKcalGoal - _store.macroProgress.kcal)
                  .clamp(0, 1 << 30)
                  .toInt(),
            ),
          );
        },
      );

  Widget _coachTab() => StoreSelector(
        store: _store,
        // The INPUTS of `coachContext`; the getter itself builds a fresh
        // string per call and must stay out.
        selector: () => (
          _store.userName,
          _store.lifetimeStats,
          _store.profile,
          _store.dailyConsumedKcal,
          _store.macroProgress,
          _store.loggedMeals,
          // Deleting in the recipes tab must re-enable the card button.
          _store.userRecipes,
        ),
        builder: (context) {
          assert(_countTabBuild(_tabCoach));
          // C8 (AI disclosure) lives in the coach screens; another line here
          // would only repeat it.
          return CoachChatScreen(
            service: widget.sync?.coachChat,
            userName: _store.userName,
            streak: _store.lifetimeStats.effectiveStreakOn(clock.now()),
            userContext: widget.sync != null ? _store.coachContext : null,
            // Confirmed /recipe suggestions take the manual form's path.
            onCreateRecipe:
                widget.sync == null ? null : _store.createUserRecipe,
            userRecipeSlugs: {
              for (final recipe in _store.userRecipes) recipe.slug,
            },
          );
        },
      );
}

/// Test seam (G11): counts subtree builds per tab index. Only maintained
/// under `assert`, so it vanishes in release builds.
@visibleForTesting
final Map<int, int> debugTabBuilds = <int, int>{};

bool _countTabBuild(int tab) {
  debugTabBuilds.update(tab, (value) => value + 1, ifAbsent: () => 1);
  return true;
}

