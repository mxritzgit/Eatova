import 'dart:async';

import 'package:flutter/material.dart';

import '../models/macro_progress.dart';
import '../services/fitpilot_sync.dart';
import '../services/health_service.dart';
import '../services/kcal_calculator.dart';
import '../services/local_cache.dart';
import '../services/meal_analyzer.dart';
import '../services/meal_photo_input.dart';
import '../services/notification_service.dart';
import '../services/open_food_facts_product_service.dart';
import '../screens/coach_chat_screen.dart';
import '../screens/meal_analysis_screen.dart';
import '../screens/onboarding_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/recipes_screen.dart';
import '../screens/today_dashboard.dart';
import '../screens/today_dashboard_models.dart';
import '../screens/trends_screen.dart';
import '../screens/week_planner_screen.dart';
import '../theme/app_colors.dart';
import '../widgets/app_shell/shiftfit_bottom_nav.dart';
import '../widgets/auth/welcome_screen.dart';
import '../widgets/common/app_snack.dart';
import '../widgets/common/lively.dart';
import '../widgets/common/store_selector.dart';
import '../widgets/shared/settings_sheet.dart';
import '../widgets/today/mood_card.dart';
import '../widgets/today/wellness_widgets.dart';
import 'home_store.dart';

class ShiftFitHomePage extends StatefulWidget {
  ShiftFitHomePage({
    super.key,
    this.mealAnalyzer,
    this.productService,
    this.photoInput,
    this.healthService,
    this.notificationService = const NoopNotificationService(),
    this.initialUserName = 'Moritz',
    this.onSignOut,
    this.sync,
    this.showWelcome = false,
    this.debugCache,
  });

  final MealAnalyzer? mealAnalyzer;
  final ProductLookupService? productService;
  final MealPhotoInput? photoInput;
  final HealthService? healthService;

  /// On-device-Notification-Schicht (PROD-1). Default ist
  /// [NoopNotificationService], damit die Widget-Tests (die die Page OHNE
  /// Service konstruieren) nie einen Plattform-Channel ziehen oder crashen.
  /// In Production injiziert main.dart die echte LocalNotificationService.
  final NotificationService notificationService;

  final String initialUserName;
  final Future<void> Function()? onSignOut;
  final FitPilotSync? sync;

  /// Test-Seam (DATA-3): erlaubt es, den durablen Cache direkt zu injizieren,
  /// statt ihn ueber den SharedPreferences-Channel + auth.currentUser.id zu
  /// bauen. So laesst sich der Clobber-Guard/Hydration-Pfad deterministisch
  /// testen, ohne eine echte Supabase-Session zu stellen. In Production immer
  /// null — dann baut [HomeStore] den echten Cache.
  @visibleForTesting
  final LocalCache? debugCache;

  /// True nur bei frischem Login/Register in dieser App-Session.
  /// Bei Session-Restore (App-Kaltstart mit gueltigem Token) false -
  /// dann fliegt der User direkt aufs Home ohne Welcome-Phase.
  final bool showWelcome;

  @override
  State<ShiftFitHomePage> createState() => _ShiftFitHomePageState();
}

/// ARCH-4: Duenne, context-tragende Schale um den [HomeStore]. Sie haelt nur
/// noch das, was wirklich einen BuildContext braucht — Navigation, modale
/// Sheets, Snackbars und den Widget-Lifecycle — und delegiert allen State + alle
/// Mutationen an den Store. Der Home-Baum haengt per [ListenableBuilder] am
/// Store; eine Mutation `notifyListeners()` statt eines monolithischen setState.
class _ShiftFitHomePageState extends State<ShiftFitHomePage>
    with WidgetsBindingObserver {
  late final HomeStore _store;

  // ARCH-1/PERF-2: treibt die AnimatedBuilder-Bruecke in [_openProfile]. Die
  // gepushte ProfileScreen-Route ist ein eigener Navigator-Subtree, den ein
  // Store-Notify NICHT erreicht — ohne dieses Notifier wuerde ein mid-route
  // Health-Refresh auf einer OFFENEN ProfileScreen nicht ankommen. Gebumpt nur,
  // WENN die Route tatsaechlich offen ist ([_profileRouteOpen]).
  final ValueNotifier<int> _profileRefresh = ValueNotifier<int>(0);
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
    // Ohne Sync (Preview/Test) gibt es keine Boot-/Welcome-Phase — Tests pumpen
    // einen Frame und erwarten sofort das Home.
    _welcomeFinished = widget.sync == null;
    if (widget.healthService != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _store.connectHealth());
    }
    _store.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _store.removeListener(_onStoreChanged);
    _profileRefresh.dispose();
    _store.dispose();
    super.dispose();
  }

  /// Store hat einen Mutations-Notify abgesetzt. Der [ListenableBuilder] in
  /// [build] rebuildet den Home-Baum bereits; hier nur die Profil-Bruecke
  /// nachziehen, falls die ProfileScreen-Route gerade offen ist.
  void _onStoreChanged() {
    if (_profileRouteOpen && mounted) _profileRefresh.value++;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // App geht in den Hintergrund / wird beendet: ausstehende debounced Writes
    // sofort flushen, damit ein Kill im Debounce-Fenster keine Quick-Logs
    // verliert.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _store.flushPendingWrites();
    }
  }

  /// Context-Bruecke fuer den Store: uebersetzt eine context-FREIE Snack-
  /// Anforderung des Stores in ein echtes [showAppSnack].
  void _emitSnack(
    String message, {
    IconData icon = Icons.info_outline_rounded,
    Color accent = forgeLime,
    Duration? duration,
    SnackBarAction? action,
  }) {
    if (!mounted) return;
    if (duration != null) {
      showAppSnack(context, message,
          icon: icon, accent: accent, duration: duration, action: action);
    } else {
      showAppSnack(context, message,
          icon: icon, accent: accent, action: action);
    }
  }

  // --- context-tragende Flows (Sheets / Navigation) ------------------------

  Future<void> _editMoodNote() async {
    final result = await showMoodNoteSheet(context, initial: _store.mood.note);
    if (result != null && mounted) {
      _store.setMoodNote(result);
    }
  }

  Future<void> _logSleep() async {
    final entry = await showSleepLogSheet(context, initial: _store.lastSleep);
    if (entry != null && mounted) {
      _store.logSleep(entry);
    }
  }

  Future<void> _openSettings() async {
    final result = await showSettingsSheet(
      context,
      profile: _store.profile,
      notificationsEnabled: _store.notificationsEnabled,
    );
    if (result == null || !mounted) return;
    await _store.applySettings(
      newProfile: result.profile,
      notificationsEnabled: result.notificationsEnabled,
      resetDay: result.resetDay,
    );
  }

  /// DSGVO Art. 17: Store löscht Konto + Daten serverseitig; nur bei Erfolg
  /// ausloggen (Navigation lebt hier in der Schale).
  Future<void> _deleteAccount() async {
    if (await _store.deleteAccount()) {
      await widget.onSignOut?.call();
    }
  }

  /// Regulärer Sign-Out: erst den lokalen PII-Cache räumen (M-1), dann die
  /// Session beenden. Reihenfolge zählt — [HomeStore.signOutCleanup] braucht den
  /// noch eingeloggten User für den defensiven Cache-Pfad.
  Future<void> _signOut() async {
    await _store.signOutCleanup();
    await widget.onSignOut?.call();
  }

  Future<void> _openProfile() async {
    // ARCH-1/PERF-2: Route als offen markieren -> ab jetzt bumpt der Store-
    // Listener _profileRefresh, sodass ein mid-route State-Wechsel (z.B.
    // refreshHealthSteps) ueber den AnimatedBuilder auf der offenen
    // ProfileScreen ankommt.
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
              plan: _store.plan,
              weekPlan: _store.weekPlan,
              workoutStreak: _store.workoutStreak,
              dailyConsumedKcal: _store.dailyConsumedKcal,
              dailyWaterMl: _store.dailyWaterMl,
              dailySteps: _store.dailySteps,
              lastSleep: _store.lastSleep,
              healthAuthState: _store.healthAuthState,
              healthLastFetch: _store.healthLastFetch,
              favoritesCount: _store.favorites.length,
              onLogWeight: _store.logWeight,
              onEditProfile: _openSettings,
              onResetDay: _store.resetTodayData,
              onConnectHealth: _store.connectHealth,
              onRefreshHealth: _store.refreshHealthSteps,
              onSignOut: widget.onSignOut != null ? _signOut : null,
              onDeleteAccount: widget.sync != null ? _deleteAccount : null,
            ),
          ),
        ),
      );
    } finally {
      // Route gepoppt -> wieder zu. Ab jetzt bumpt der Listener _profileRefresh
      // nicht mehr (Quick-Logs auf dem Home rebuilden nur ihren eigenen Subtree).
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

    // PERF-2: nur (Tab, Onboarding-Gate) treiben einen Rebuild der Home-Schale.
    // Daten-Slices (Wasser, Mood, …) rebuilden gezielt ihre Tab-Inhalte
    // (Today via Sektions-Selektoren, andere Tabs via eigenem ListenableBuilder),
    // nicht mehr den ganzen Baum wie das frühere monolithische setState.
    return StoreSelector(
      store: _store,
      selector: () => (_store.selectedTab, _store.needsOnboarding),
      builder: (context) {
        // Verpflichtendes Onboarding: jeder echte User (mit Supabase-Sync) muss
        // es einmal durchlaufen. Im Test/Preview (sync == null) übersprungen,
        // damit die bestehenden Widget-Tests direkt auf dem Home landen.
        if (_store.needsOnboarding) {
          return OnboardingScreen(
            firstName: _store.userName,
            initialProfile: _store.profile,
            onComplete: _store.completeOnboarding,
          );
        }

        // Tab 3 (Food), Tab 4 (Rezepte) und Tab 5 (Coach) haben eigene
        // scroll-faehige Inhalte + fixierte Eingabe-Bereiche - die brauchen
        // feste Hoehe und keinen aeusseren SingleChildScrollView.
        final tab = _store.selectedTab;
        final fixedHeightTab = tab == 3 || tab == 4 || tab == 5;
        final body = fixedHeightTab
            ? Padding(
                key: ValueKey('tab-fixed-$tab'),
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                child: buildSelectedScreen(),
              )
            : SingleChildScrollView(
                key: ValueKey('tab-scroll-$tab'),
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                child: buildSelectedScreen(),
              );

        return Scaffold(
          backgroundColor: bg,
          // Food-Tab (3): Eingabe läuft nur über das modale AddMealSheet, das
          // seine Tastatur-Anpassung selbst macht. Würde der Home-Scaffold
          // zusätzlich resizen, schöbe sich der Hintergrund sichtbar hinter dem
          // halbtransparenten Barrier. Andere Tabs behalten das Default-Verhalten.
          resizeToAvoidBottomInset: tab != 3,
          bottomNavigationBar: ShiftFitBottomNav(
            selectedIndex: tab,
            onSelected: (index) => _store.setTab(index),
          ),
          // Sanfter Auftritt pro Tab-Wechsel — Key auf den Tab gepinnt, damit
          // der Effekt bei jedem Wechsel erneut abspielt.
          body: SafeArea(
            child: LivelyEntrance(
              key: ValueKey('lively-tab-$tab'),
              child: body,
            ),
          ),
        );
      },
    );
  }

  Widget buildSelectedScreen() {
    // Nicht-Today-Tabs behalten ihr gröberes Rebuild-Verhalten: ein eigener
    // ListenableBuilder zieht sie bei jeder Store-Mutation nach (wie vorher das
    // globale setState). Today (Default) liest den Store direkt und scoped seine
    // Sektionen selbst (PERF-2).
    return switch (_store.selectedTab) {
      1 => ListenableBuilder(
          listenable: _store,
          builder: (context, _) => WeekPlannerScreen(
            plan: _store.plan,
            weekPlan: _store.weekPlan,
            onShiftChanged: (dayIndex, shift) =>
                _store.setWeekPlanDay(dayIndex, shift),
            onSavePlan: widget.sync == null ? null : _store.saveWeeklyPlan,
            // PROD-5: Set-Logger nur mit echtem Sync (Test/Preview: sync == null
            // -> Karte bleibt verborgen). onLogSet persistiert idempotent und
            // haengt den Satz optimistisch vorn an die lokale History.
            workoutHistory: _store.workoutHistory,
            onLogSet: widget.sync == null ? null : _store.logWorkoutSet,
            onSettingsPressed: _openSettings,
            onProfilePressed: _openProfile,
            profileInitial: _store.profileInitial,
          ),
        ),
      2 => ListenableBuilder(
          listenable: _store,
          builder: (context, _) => TrendsScreen(
            plan: _store.plan,
            weekPlan: _store.weekPlan,
            dailyWaterMl: _store.dailyWaterMl,
            waterGoalMl: _store.profile.dailyWaterGoalMl,
            lastSleep: _store.lastSleep,
            sleepGoalMinutes: _store.profile.dailySleepGoalMinutes,
            workoutStreak: _store.workoutStreak,
            completedTodayCount: _store.completedBlockIds.length,
            totalBlocksToday: _store.plan.blocks.length,
            dailySteps: _store.dailySteps,
            stepsGoal: _store.stepsGoal,
            dailyConsumedKcal: _store.dailyConsumedKcal,
            kcalGoal: _store.profile.dailyKcalGoal,
            history: _store.trendsHistory,
            onSettingsPressed: _openSettings,
            onProfilePressed: _openProfile,
            profileInitial: _store.profileInitial,
          ),
        ),
      5 => ListenableBuilder(
          listenable: _store,
          builder: (context, _) => CoachChatScreen(
            service: widget.sync?.coachChat,
            userName: _store.userName,
            userContext: widget.sync != null ? _store.coachContext : null,
          ),
        ),
      3 => ListenableBuilder(
          listenable: _store,
          builder: (context, _) => MealAnalysisScreen(
            analyzer: widget.mealAnalyzer,
            productService: widget.productService,
            photoInput: widget.photoInput,
            selectedDate: _store.selectedFoodDate,
            onDateSelected: (date) => _store.setFoodDate(date),
            dailyConsumedKcal:
                _store.consumedKcalForFoodDate(_store.selectedFoodDate),
            macroProgress:
                _store.macroProgressForFoodDate(_store.selectedFoodDate),
            profile: _store.profile,
            favorites: _store.favorites,
            loggedMeals: _store.mealsForFoodDate(_store.selectedFoodDate),
            burnedKcal: _store.selectedFoodDateIsToday
                ? estimateKcalBurnedFromSteps(
                    steps: _store.dailySteps,
                    weightKg: _store.profile.weightKg,
                    heightCm: _store.profile.heightCm,
                    sex: _store.profile.sex,
                  )
                : 0,
            onAddMeal: (result, slot) =>
                _store.addResultToDailyTotal(result, slot: slot),
            onUpdateMeal: _store.updateLoggedMealResult,
            isFavorite: _store.isFavorite,
            onToggleFavorite: _store.toggleFavorite,
            onRemoveFavorite: _store.removeFavorite,
            onRemoveMeal: _store.removeLoggedMeal,
          ),
        ),
      4 => ListenableBuilder(
          listenable: _store,
          builder: (context, _) => RecipesScreen(
            onAddMeal: (result, slot) => _store.addResultToDailyTotal(
              result,
              slot: slot,
              foodDate: DateTime.now(),
            ),
            initialUserRecipes: _store.userRecipes,
            // Persistenz nur mit echtem Sync (Test/Preview: nur Session-lokal).
            onCreateRecipe:
                widget.sync == null ? null : _store.createUserRecipe,
            onDeleteRecipe:
                widget.sync == null ? null : _store.deleteUserRecipe,
            // Restmakros des Tages (Ziel − verbraucht) → „Passt zu deinem Ziel".
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
          ),
        ),
      _ => TodayDashboard(
          store: _store,
          // ARCH-3: Callbacks gebuendelt.
          actions: TodayActions(
            onShiftSelected: _store.setShift,
            onEnergySelected: _store.setEnergy,
            onStressSelected: _store.setStress,
            onToggleBlock: _store.toggleBlock,
            onConnectHealth: _store.connectHealth,
            onRefreshHealth: _store.refreshHealthSteps,
            onAddWater: _store.addWater,
            onSetSteps: _store.setSteps,
            onLogSleep: _logSleep,
            onMoodScore: _store.setMoodScore,
            onEditMoodNote: _editMoodNote,
            onToggleHabit: _store.toggleHabit,
            onAddCaffeine: _store.addCaffeine,
            onResetCaffeine: _store.resetCaffeine,
            onLogWeight: _store.logWeight,
            onOpenTraining: () => _store.setTab(1),
            onOpenFood: () => _store.setTab(3),
          ),
          onSettingsPressed: _openSettings,
          onProfilePressed: _openProfile,
          profileInitial: _store.profileInitial,
        ),
    };
  }
}
