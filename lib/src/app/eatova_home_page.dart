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

  /// On-device-Notification-Schicht (PROD-1). Default ist
  /// [NoopNotificationService], damit die Widget-Tests (die die Page OHNE
  /// Service konstruieren) nie einen Plattform-Channel ziehen oder crashen.
  /// In Production injiziert main.dart die echte LocalNotificationService.
  final NotificationService notificationService;

  final String initialUserName;

  /// Mailadresse der Session — der Einstellungs-Screen zeigt sie an.
  /// Null in Tests/Preview ohne Auth; der Screen blendet die Zeile dann aus.
  final String? userEmail;

  /// Traegt die Konto-Aenderungen (Passwort, Mailadresse) in den
  /// Einstellungen. Null in Tests/Preview ohne Auth — die Zeilen
  /// entfallen dann, statt ins Leere zu fuehren.
  final AuthRepository? authRepository;
  final Future<void> Function()? onSignOut;
  final EatovaSync? sync;

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
  State<EatovaHomePage> createState() => _EatovaHomePageState();
}

/// Test-Seam: gibt den privaten [HomeStore] der Schale frei.
///
/// Die Resume-Uebergaben (Tageswechsel B4, Health-Heilung B3, Berechtigungs-
/// Heilung D11) mutieren ausschliesslich Store-State, den die Schale nicht
/// rendert — von aussen waeren sie sonst nur ueber Umwege (Datums-Chips,
/// Settings-Sheet) beobachtbar. Gleiches Muster wie [EatovaHomePage.debugCache]
/// und `HomeStore.initNotificationsFromCache`.
@visibleForTesting
abstract interface class HomePageDebugAccess {
  HomeStore get debugStore;
}

/// ARCH-4: Duenne, context-tragende Schale um den [HomeStore]. Sie haelt nur
/// noch das, was wirklich einen BuildContext braucht — Navigation, modale
/// Sheets, Snackbars und den Widget-Lifecycle — und delegiert allen State + alle
/// Mutationen an den Store. Der Home-Baum haengt per [StoreSelector] am Store;
/// eine Mutation `notifyListeners()` statt eines monolithischen setState.
class _EatovaHomePageState extends State<EatovaHomePage>
    with WidgetsBindingObserver
    implements HomePageDebugAccess {
  @override
  HomeStore get debugStore => _store;

  late final HomeStore _store;

  // ARCH-1/PERF-2: treibt die AnimatedBuilder-Bruecke in [_openProfile]. Die
  // gepushte ProfileScreen-Route ist ein eigener Navigator-Subtree, den ein
  // Store-Notify NICHT erreicht — ohne dieses Notifier wuerde ein mid-route
  // Health-Refresh auf einer OFFENEN ProfileScreen nicht ankommen. Gebumpt nur,
  // WENN die Route tatsaechlich offen ist ([_profileRouteOpen]).
  final ValueNotifier<int> _profileRefresh = ValueNotifier<int>(0);

  /// Ein Tipp auf eine Mahlzeit-Zeile in „Heute" soll im Food-Tab das
  /// Hinzufuegen-Fenster fuer GENAU diesen Slot oeffnen. Seit der
  /// „Essen loggen"-Knopf entfallen ist (Nutzer-Wunsch 2026-08-10), ist das
  /// der einzige Weg zum Nachtragen — er darf den Slot nicht unterwegs
  /// verlieren.
  ///
  /// Ein Notifier statt eines Parameters, weil die Schale die Tab-Widgets
  /// nach Identitaet cached (`_tabViews`): ein geaenderter Parameter erreichte
  /// den bereits gebauten Tab nie.
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
    // Ohne Sync (Preview/Test) gibt es keine Boot-/Welcome-Phase — Tests pumpen
    // einen Frame und erwarten sofort das Home.
    _welcomeFinished = widget.sync == null;
    if (widget.healthService != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _store.connectHealth());
    }
    _store.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Der Store haelt bewusst nie einen BuildContext (ARCH-4) — hier ist
    // `context.l10n` sicher verfuegbar (anders als in initState) und wird bei
    // jedem Aufruf (Kaltstart UND Sprachwechsel in den Einstellungen) frisch
    // durchgereicht, damit die wenigen Snack-Texte, die der Store selbst noch
    // baut (sync_error_messages.dart), der aktiven Sprache folgen.
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

  /// Store hat einen Mutations-Notify abgesetzt.
  ///
  /// Der [StoreSelector] in [build] rebuildet die betroffenen Teilbaeume
  /// bereits; hier haengen nur die beiden Dinge, die kein Widget beobachtet:
  /// die Profil-Bruecke in eine gepushte Route und der Kalendertag-Waechter
  /// fuer den Schrittstand (B3b).
  void _onStoreChanged() {
    if (_profileRouteOpen && mounted) _profileRefresh.value++;
    // B3b: Liegt die App ueber Mitternacht offen, feuert der Mitternachts-
    // Timer im Store `maybeRollOverToToday()` — der laesst `dailySteps`
    // bewusst stehen (eine erfundene 0 waere die schlechtere Auskunft, s.
    // home_store.dart). Damit GESTERN gemessene Schritte aber nicht den ganzen
    // neuen Tag ueber `burnedKcal`/`adjustedGoal` speisen, zieht die Schale
    // hier genau einen Refresh pro Kalendertag nach. Der Rollover-Notify ist
    // dafuer der frueheste verlaessliche Anlass; ein eigener Timer waere ein
    // zweiter, der mit dem des Stores auseinanderlaufen kann.
    if (!DateUtils.isSameDay(_healthDay, clock.now())) _refreshHealthSteps();
  }

  /// Kalendertag, fuer den zuletzt ein Health-Refresh angestossen wurde
  /// (Waechter fuer [_onStoreChanged], s. dort).
  DateTime _healthDay = DateUtils.dateOnly(clock.now());

  /// Darf ein Refresh laufen, ohne nur sinnlos `healthSyncing` zu toggeln?
  ///
  /// `refreshHealthSteps()` prueft selbst NICHT auf „verbunden", der Guard
  /// sitzt hier am Callsite.
  ///
  /// `granted` **und** `unverified` **und** `denied` (B3): `readSnapshot()`
  /// verifiziert die Berechtigung bei jedem Aufruf neu und zeigt dabei keinen
  /// Dialog (apple_health_service.dart:319-334) — der Refresh ist also der
  /// einzige Weg zurueck, wenn der Nutzer in den iOS-Einstellungen nachtraeglich
  /// freigibt. Ohne `unverified`/`denied` koennten diese Zustaende nie heilen
  /// und der Nutzer muesste die App neu starten.
  ///
  /// `unknown` bleibt draussen: das ist der Zustand VOR dem ersten Connect,
  /// und dort gehoert der Uebergang `connectHealth()` (mit Sheet), nicht einem
  /// stillen Resume-Refresh. `unsupported` sowieso (Noop-Service/Android).
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
    // App geht in den Hintergrund / wird beendet: ausstehende debounced Writes
    // sofort flushen, damit ein Kill im Debounce-Fenster keine Quick-Logs
    // verliert.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _store.flushPendingWrites();
    }
    if (state != AppLifecycleState.resumed) return;

    // Der Resume refresht Health am Ende dieses Blocks ohnehin — den
    // Tages-Waechter deshalb VORHER auf heute stellen, sonst loest der
    // Rollover-Notify gleich darunter einen zweiten, identischen Refresh aus.
    _healthDay = DateUtils.dateOnly(clock.now());

    // B4: Eine suspendierte App bekommt keinen Timer-Tick — der Tageswechsel
    // faellt ohne diesen Aufruf komplett aus. Reihenfolge ist Absicht: erst den
    // Tag vorruecken, DANN flushen, damit ein durch den Flush ausgeloester
    // Refresh schon den neuen Tag traegt. Ohne Tageswechsel ein reiner No-op
    // (kein notifyListeners()).
    _store.maybeRollOverToToday();

    // Liegengebliebene Outbox-Ops / Stats-Deltas nachspielen (DATA-7) — der
    // Resume ist der typische Moment, in dem das Netz wieder da ist.
    _store.flushPendingWrites();

    // D11: Der Nutzer war womoeglich gerade in den Systemeinstellungen. Liest
    // die OS-Berechtigung still gegen (kein Dialog) und holt ihn aus
    // `ReminderState.blocked` zurueck — ohne App-Neustart.
    unawaited(_store.refreshNotificationPermission());

    // Schritte neu lesen, sonst bleiben sie (und die „Verbrannt"-kcal im Ring)
    // den ganzen Tag auf dem Stand des Kaltstarts.
    _refreshHealthSteps();
  }

  /// Context-Bruecke fuer den Store: uebersetzt eine context-FREIE Snack-
  /// Anforderung des Stores in ein echtes [showAppSnack].
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

  // --- context-tragende Flows (Sheets / Navigation) ------------------------

  /// „Profil & Ziele" — Koerperdaten, Aktivitaet, Ziel, Energie/Makros,
  /// Tagesziele, Erinnerungen.
  ///
  /// Seit dem Design-Refactor 2026-08-09 eine ROUTE statt eines modalen
  /// Sheets; seit dem 2026-08-10 von den Einstellungen getrennt (die tragen
  /// jetzt Konto- und Anzeige-Themen). Der Rueckgabewert bleibt
  /// [SettingsResult], die Verarbeitung darunter also unveraendert.
  Future<void> _openGoals() async {
    final result = await Navigator.of(context).push<SettingsResult>(
      MaterialPageRoute<SettingsResult>(
        builder: (_) => GoalsScreen(
          profile: _store.profile,
          notificationsEnabled: _store.notificationsEnabled,
          // D11: ohne diese Zeile erreicht der dritte Zustand `blocked` den
          // Screen nie — der Schalter zeigte weiter „Aktiv. Du bekommst
          // gezielte Nudges", waehrend das OS gar nichts zustellt.
          // `onOpenSystemSettings` bleibt offen, solange das Projekt keinen
          // Weg dorthin hat (url_launcher baut nur ACTION_VIEW,
          // Settings.ACTION_APP_NOTIFICATION_SETTINGS ist eine Action ohne
          // URI); der Screen zeigt dann nur den Text.
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

  /// Die Einstellungen — Konto, Anzeige, Daten, Gefahrenzone.
  ///
  /// Bewusst OHNE Koerperdaten und Ziele: die haben mit [_openGoals] eine
  /// eigene Seite, erreichbar aus dem Profil. Ein Screen, der Gewicht und
  /// Kontoloeschung mischt, war der Grund, warum das alte Sheet auf 1922
  /// Zeilen kam.
  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          // Nur echte Daten: die Mailadresse kommt aus der Session. Einen
          // „verbundenes Konto"-Eintrag gibt es bewusst nicht — welcher
          // Anbieter die Anmeldung getragen hat, weiss die App heute nicht,
          // und eine geratene Zeile waere schlimmer als keine.
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
              dailyConsumedKcal: _store.dailyConsumedKcal,
              dailySteps: _store.dailySteps,
              healthAuthState: _store.healthAuthState,
              healthLastFetch: _store.healthLastFetch,
              onLogWeight: _store.logWeight,
              onEditProfile: _openGoals,
              onOpenSettings: _openSettings,
              onConnectHealth: _store.connectHealth,
              onRefreshHealth: _store.refreshHealthSteps,
              // Ausloggen, Kontoloeschung, Datenauskunft und „Über Eatova"
              // haengen seit 2026-08-10 ausschliesslich an [_openSettings]
              // (Zahnrad im Profil-Kopf) — der Block „Daten & Konto" im Profil
              // doppelte die Einstellungen und ist auf Nutzer-Entscheid weg.
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
    // Daten-Slices rebuilden gezielt ihre Tab-Inhalte (via eigenem
    // StoreSelector), nicht den ganzen Baum wie ein monolithisches setState.
    return StoreSelector(
      store: _store,
      selector: () => (_store.selectedTab, _store.needsOnboarding),
      builder: (context) {
        // Verpflichtendes Onboarding: jeder echte User (mit Supabase-Sync) muss
        // es einmal durchlaufen. Im Test/Preview (sync == null) übersprungen,
        // damit die bestehenden Widget-Tests direkt auf dem Home landen.
        //
        // D7: Der Early-Return steht VOR dem PopScope der Schale — und muss
        // dort bleiben. Die OnboardingScreen bringt seit D4 ein eigenes
        // PopScope mit (onboarding_screen.dart), und
        // `ModalRoute.onPopInvokedWithResult` ruft ALLE in der Route
        // registrierten PopScopes auf: stuenden beide gleichzeitig im Baum,
        // ginge ein Systemzurueck einen Onboarding-Schritt zurueck UND
        // wechselte gleichzeitig den Tab.
        if (_store.needsOnboarding) {
          return OnboardingScreen(
            firstName: _store.userName,
            initialProfile: _store.profile,
            onComplete: _store.completeOnboarding,
          );
        }

        final tab = _store.selectedTab;

        // D7: Aus einem Nicht-Food-Tab schloss die Zurueck-Taste die App. Jetzt
        // faengt die Schale den Pop ab und schaltet erst auf Food zurueck.
        // `canPop: tab == 0` heisst: auf Food gibt die Schale den Pop frei —
        // dort gehoert die App wirklich zu, statt zu klemmen. Liegt eine
        // gepushte Route (Profil, Rezept-Detail) darueber, sieht dieses
        // PopScope den Pop gar nicht erst: es gehoert der Home-Route.
        return PopScope<Object?>(
          canPop: tab == 0,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            _store.setTab(0);
          },
          child: Scaffold(
            backgroundColor: context.t.bg,
            // Food-Tab (1): Eingabe läuft nur über das modale AddMealSheet, das
            // seine Tastatur-Anpassung selbst macht. Würde der Home-Scaffold
            // zusätzlich resizen, schöbe sich der Hintergrund sichtbar hinter
            // dem halbtransparenten Barrier. Andere Tabs behalten das
            // Default-Verhalten.
            resizeToAvoidBottomInset: tab != _tabFood,
            bottomNavigationBar: AppNavBar(
              index: tab,
              onChanged: (index) => _store.setTab(index),
              items: _navItems(context),
            ),
            // Alle Tabs haben eigene scroll-faehige Inhalte + fixierte
            // Eingabe-Bereiche - die brauchen feste Hoehe und keinen
            // aeusseren SingleChildScrollView.
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

  /// Tab-Ordnung seit dem Design-Refactor 2026-08-09:
  /// 0 = Heute (Landepunkt), 1 = Food, 2 = Rezepte, 3 = Coach.
  ///
  /// „Heute" ist zurueck, aber mit anderer Aufgabe als der 2026-08-03
  /// entfernte gleichnamige Tab: damals doppelte er den Food-Tab, jetzt
  /// traegt er den Tagesueberblick (Kalorien-Hero, Makros, Streak) und der
  /// Food-Tab wird zum reinen Tagebuch.
  static const int _tabHeute = 0;
  static const int _tabFood = 1;
  static const int _tabRezepte = 2;
  static const int _tabCoach = 3;
  static const int _tabCount = 4;

  /// Die keyIds tragen die Testschluessel (`nav-Heute` & Co.) und bleiben
  /// deutsch; die sichtbaren Labels kommen aus der ARB (Spec §4).
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

  /// Tabs, die schon einmal sichtbar waren (D6, Lazy-Building).
  final Set<int> _mountedTabs = <int>{};

  /// Gecachte Widget-INSTANZEN der gemounteten Tabs.
  ///
  /// Der Cache ist nicht Bequemlichkeit, sondern der halbe Fix: der
  /// Shell-Rebuild beim Tab-Wechsel reicht so exakt dieselbe Instanz erneut
  /// ein, und Flutters `Element.updateChild` ueberspringt den Teilbaum, weil
  /// `identical(newWidget, oldWidget)`. Ohne den Cache rebuildete jeder
  /// Tab-Wechsel ALLE gemounteten Tabs — im [IndexedStack] waeren das mehr
  /// Rebuilds als vorher, nicht weniger (G11).
  final List<Widget?> _tabViews = List<Widget?>.filled(_tabCount, null);

  @override
  void didUpdateWidget(EatovaHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Neue Widget-Konfiguration (andere injizierte Dienste/Callbacks): die
    // gecachten Instanzen haengen an der alten — verwerfen. Der Element-Baum
    // bleibt dabei stehen (gleiche Typen + Keys an gleicher Stelle), der
    // Zustand der Tabs geht also nicht verloren.
    _tabViews.fillRange(0, _tabCount, null);
  }

  /// D6: [IndexedStack] statt `switch` — jeder je besuchte Tab bleibt
  /// gemountet, ein Wechsel wirft seinen Zustand nicht mehr weg.
  ///
  /// **Lazy:** ein Tab wird erst gebaut, wenn er zum ersten Mal sichtbar wird,
  /// und danach behalten. Ein eager [IndexedStack] baute beim Kaltstart auch
  /// den Coach — und dessen `initState` feuert `loadSessions` + `loadHistory` +
  /// `loadQuotaToday`, drei Netzaufrufe fuer einen Tab, den viele Nutzer in der
  /// Session nie oeffnen. Der Kaltstart bleibt damit exakt so teuer wie vorher:
  /// genau ein Teilbaum (Food).
  ///
  /// **[TickerMode]:** [IndexedStack] haelt versteckte Kinder mit
  /// `maintainAnimation: true` am Leben — der endlos rotierende CoachOrb liefe
  /// also im Hintergrund weiter (Akku; und in Widget-Tests settlet dann kein
  /// `pumpAndSettle` mehr). Der Ticker des nicht sichtbaren Tabs wird deshalb
  /// stummgeschaltet.
  Widget _buildTabStack(int tab) {
    _mountedTabs.add(tab);
    return IndexedStack(
      key: const ValueKey('home-tab-stack'),
      index: tab,
      // Wie vorher: der sichtbare Tab bekommt die volle Flaeche der Padding-Box
      // (StackFit.loose wuerde ihn shrink-wrappen).
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
        // G10 (Teil „Ausloeser"): der Auftritt spielt jetzt einmal pro Tab —
        // beim ersten Besuch — statt bei JEDEM Wechsel. Vorher pinnte ein
        // `ValueKey('lively-tab-$tab')` ueber dem GANZEN Body die Animation an
        // den ausgewaehlten Tab und erzwang damit genau das Unmounten, das D6
        // beklagt; nebenbei rasterte es 320 ms lang jeden Frame der
        // Kalorienkarte neu (deren BackdropFilter ist nicht raster-cachebar,
        // das RepaintBoundary in LivelyEntrance schuetzt nur den Inhalt, nicht
        // den Backdrop-Pass). Der Key bleibt statisch pro Tab — es gibt keinen
        // Wechsel mehr, der ihn aendern koennte.
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

  /// Der Tagesueberblick. Eigene, engere Selector-Slice als der Food-Tab:
  /// „Heute" zeigt zusaetzlich Streak und Name, braucht aber weder Favoriten
  /// noch die Analyzer-Dienste.
  Widget _todayTab() => StoreSelector(
        store: _store,
        selector: () => (
          _store.selectedFoodDate,
          _store.loggedMeals,
          _store.profile,
          _store.dailySteps,
          // Map-Identitaet als Fingerabdruck (G11): jeder Upsert/Backfill
          // ersetzt die Map, ein Archivtag-Nachtrag erreicht die Kachel also.
          _store.dailyActivity,
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
            // Heute live aus dem Schrittstand, Archivtage aus dem pro Tag
            // festgeschriebenen Endwert (0 = kein Eintrag -> Kachel zeigt „—").
            burnedKcal: _store.burnedKcalForFoodDate(tag),
            streak: _store.lifetimeStats.effectiveStreakOn(clock.now()),
            profileInitial: _store.profileInitial,
            onDateSelected: _store.setFoodDate,
            onOpenCoach: () => _store.setTab(_tabCoach),
            onOpenProfile: _openProfile,
            onOpenMealSlot: (slot) {
              // Reihenfolge zaehlt: der Food-Tab wird lazy gebaut. Steht der
              // Wunsch schon fest, bevor er mountet, findet ihn sein initState
              // vor — sonst liefe der Notify ins Leere.
              _addSlotRequest.value = slot;
              _store.setTab(_tabFood);
            },
          );
        },
      );

  // MealEditScope reicht die Bearbeiten-Callbacks des Stores an der
  // Screen-Signatur VORBEI an Verlaufskarte + Add-Sheet (dort oeffnet ein
  // Tap auf eine geloggte Mahlzeit das Bearbeiten-Sheet).
  Widget _foodTab() => StoreSelector(
        store: _store,
        // G11: gefasste Slice statt eines blanken ListenableBuilder. Bewusst
        // nur EINGANGSgroessen, keine abgeleiteten Werte: `mealsForFoodDate`
        // & Co. filtern `loggedMeals` bei jedem Aufruf in eine NEUE Liste, ein
        // Selektor darauf waere per Identitaet immer „geaendert" (und
        // allokierte pro Notify drei Listen ueber 210 Mahlzeiten). Die
        // Store-Listen werden bei jeder Mutation neu zugewiesen, ihre
        // Identitaet ist also ein exakter und O(1)-billiger Fingerabdruck.
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
        // Nur was die Rezepte-Ansicht wirklich liest: die eigenen Rezepte und
        // (fuer „Passt zu deinem Ziel") Ziele + Tagesfortschritt. Ein
        // Mahlzeit-Log auf dem Food-Tab aendert `macroProgress` — genau dann
        // soll die Restmakro-Rechnung mitziehen, sonst nie.
        selector: () => (
          _store.userRecipes,
          _store.profile,
          _store.macroProgress,
        ),
        builder: (context) {
          assert(_countTabBuild(_tabRezepte));
          return RecipesScreen(
            // Kein hartes foodDate mehr: addResultToDailyTotal faellt auf das
            // im Store gewaehlte selectedFoodDate zurueck (Closure liest den
            // Store erst beim Aufruf — reaktiv). „Zum Tracker hinzufügen"
            // landet damit auf dem im Food-Tab gewaehlten Tag, wie der
            // Food-Tab-Pfad selbst.
            onAddMeal: (result, slot) => _store.addResultToDailyTotal(
              result,
              slot: slot,
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
          );
        },
      );

  Widget _coachTab() => StoreSelector(
        store: _store,
        // Die EINGANGSgroessen von `coachContext` (Profil, Tagesbilanz,
        // geloggte Mahlzeiten) plus Name und Streak. `coachContext` selbst
        // gehoert NICHT in den Selektor: der Getter baut bei jedem Aufruf einen
        // frischen String samt Mahlzeiten-Liste.
        selector: () => (
          _store.userName,
          _store.lifetimeStats,
          _store.profile,
          _store.dailyConsumedKcal,
          _store.macroProgress,
          _store.loggedMeals,
        ),
        builder: (context) {
          assert(_countTabBuild(_tabCoach));
          // C8 (KI-Offenlegung) liegt vollstaendig in den Coach-Screens: der
          // Composer-Platzhalter nennt die KI durchgaengig, der Leerzustand
          // traegt einen antippbaren Hinweis, und das (i)-Sheet listet auf,
          // welche Daten mitgehen und an wen. Eine zusaetzliche Zeile im
          // Tab-Rahmen waere dieselbe Aussage ein zweites Mal — im
          // Leerzustand direkt uebereinander.
          return CoachChatScreen(
            service: widget.sync?.coachChat,
            userName: _store.userName,
            streak: _store.lifetimeStats.effectiveStreakOn(clock.now()),
            userContext: widget.sync != null ? _store.coachContext : null,
            // /rezept-Vorschlaege laufen nach der Bestaetigung im Sheet ueber
            // DENSELBEN 3-Netz-Pfad wie das manuelle Rezept-Formular.
            onCreateRecipe:
                widget.sync == null ? null : _store.createUserRecipe,
          );
        },
      );
}

/// Test-Seam (G11): zaehlt pro Tab-Index, wie oft sein Teilbaum gebaut wurde.
///
/// Wird ausschliesslich unter `assert` gepflegt — im Release-Build faellt der
/// Zaehler samt Aufrufen weg. Tests raeumen ihn selbst per `clear()`.
@visibleForTesting
final Map<int, int> debugTabBuilds = <int, int>{};

bool _countTabBuild(int tab) {
  debugTabBuilds.update(tab, (value) => value + 1, ifAbsent: () => 1);
  return true;
}

