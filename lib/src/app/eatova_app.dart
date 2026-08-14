import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_repository.dart';
import '../l10n/l10n.dart';
import '../services/crash_reporter.dart';
import '../services/eatova_sync.dart';
import '../services/health_service.dart';
import '../services/meal_analyzer.dart';
import '../services/meal_camera_launcher.dart';
import '../services/meal_photo_input.dart';
import '../services/notification_service.dart';
import '../services/open_food_facts_product_service.dart';
import '../theme/app_theme.dart';
import '../theme/theme_mode_controller.dart';
import 'auth_gate.dart';
import 'eatova_home_page.dart';
import 'locale_controller.dart';

class EatovaApp extends StatefulWidget {
  const EatovaApp({
    super.key,
    this.mealAnalyzer,
    this.productService,
    this.photoInput,
    this.mealCameraLauncher,
    this.healthService,
    this.authRepository,
    this.notificationService,
    this.themeModeController,
    this.localeController,
  });

  final MealAnalyzer? mealAnalyzer;
  final ProductLookupService? productService;
  final MealPhotoInput? photoInput;
  final MealCameraLauncher? mealCameraLauncher;
  final HealthService? healthService;
  final AuthRepository? authRepository;

  /// On-device-Notification-Schicht (PROD-1). In Production die echte
  /// [LocalNotificationService] (s. main.dart); in Tests/Preview null ->
  /// EatovaHomePage faellt auf NoopNotificationService zurueck.
  final NotificationService? notificationService;

  /// Anzeige-Modus (Hell/Dunkel/System). In Tests injizierbar, damit ein
  /// Test einen Modus festnageln kann, ohne SharedPreferences zu stellen.
  final ThemeModeController? themeModeController;

  /// Anzeigesprache (System/Deutsch/Englisch). In Tests injizierbar, damit
  /// ein Test eine Sprache festnageln kann, ohne SharedPreferences zu
  /// stellen (Spiegel von [themeModeController]).
  final LocaleController? localeController;

  @override
  State<EatovaApp> createState() => _EatovaAppState();
}

class _EatovaAppState extends State<EatovaApp> with WidgetsBindingObserver {
  late final ThemeModeController _themeMode;
  late final bool _eigenerController;
  late final LocaleController _locale;
  late final bool _eigenerLocale;

  @override
  void initState() {
    super.initState();
    // AUDIT 2026-08-14, Deeplink-Route-Waechter: MUSS hier in initState
    // haengen und nicht irgendwo tiefer. Die Reihenfolge ist der ganze Trick,
    // s. [didPushRouteInformation].
    WidgetsBinding.instance.addObserver(this);
    _eigenerController = widget.themeModeController == null;
    _themeMode = widget.themeModeController ?? ThemeModeController();
    if (_eigenerController) {
      // Der gespeicherte Modus kommt asynchron nach. Bis dahin laeuft die App
      // im System-Modus — dem Default, der auch beim ersten Start gilt, also
      // ohne sichtbaren Sprung fuer alle, die nichts umgestellt haben.
      unawaited(_themeMode.load());
    }
    _eigenerLocale = widget.localeController == null;
    _locale = widget.localeController ?? LocaleController();
    if (_eigenerLocale) {
      // Analog: die gespeicherte Sprache kommt asynchron nach, bis dahin
      // laeuft die App im System-Modus (null-Override -> resolveEatovaLocale).
      unawaited(_locale.load());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_eigenerController) _themeMode.dispose();
    if (_eigenerLocale) _locale.dispose();
    super.dispose();
  }

  /// AUDIT 2026-08-14 — fernausloesbare Fehlerberichte ueber den
  /// BROWSABLE-Intent-Filter.
  ///
  /// Der Intent-Filter in `android/app/src/main/AndroidManifest.xml` ist
  /// BROWSABLE: jede fremde App und jede Webseite darf `eatova://…` schicken.
  /// Android reicht so eine URI beim `onNewIntent` NICHT nur an `app_links`
  /// weiter (dort greift das Session-Praedikat aus
  /// `EatovaSupabaseConfig.isOAuthCallbackDeeplink`), sondern zusaetzlich als
  /// ROUTE ueber `SystemChannels.navigation` an das Framework — aus
  /// `eatova://login-callback/#access_token=…` wird der Routenname
  /// `/#access_token=…`.
  ///
  /// Diese App hat KEINE benannten Routen: kein `routes:`-Tabelle, kein
  /// `onGenerateRoute`, kein Router — nur `home:` und imperative
  /// `Navigator.push`-Aufrufe. `_WidgetsAppState.didPushRouteInformation`
  /// ruft aber ungebremst `navigator.pushNamed(name)`, und dort scheitert
  /// jeder Name ausser `/`:
  ///
  ///   Could not find a generator for route RouteSettings("/#access_token=…")
  ///   in the _WidgetsAppState. … Unfortunately, onUnknownRoute was not set.
  ///
  /// Das landet via `FlutterError.reportError` in den globalen Handlern aus
  /// `main.dart` (`_installGlobalErrorHandlers`) und damit in Sentry. Ein
  /// Angreifer kann so aus der Ferne beliebig viele Fehlerberichte erzeugen
  /// und die echten Meldungen im Fehlerbudget zudecken. Am 2026-08-14 auf dem
  /// Emulator per `adb shell am start -a android.intent.action.VIEW -d
  /// "eatova://login-callback/#access_token=FAKE&…"` reproduziert.
  ///
  /// WARUM HIER UND NICHT `onUnknownRoute`/`onGenerateRoute`: beide koennen
  /// den Push nur UMLENKEN, nicht abbestellen. `WidgetsApp._onUnknownRoute`
  /// verlangt eine Route zurueck (`result!`, app.dart:1590-1602) — ein `null`
  /// wirft im Debug per assert und im Release als TypeError. Jeder Handler
  /// dort muesste also eine (leere) Seite auf den Stapel legen, die der
  /// Nutzer wegtippen muss und die sich bei Wiederholung stapelt. Genau das
  /// soll nicht passieren.
  ///
  /// Der Beobachter dagegen sitzt VOR dem Navigator:
  /// `WidgetsBinding.handlePushRoute`/`_handlePushRouteInformation`
  /// (binding.dart:1256-1303) fragt die Beobachter in
  /// REGISTRIERUNGSREIHENFOLGE, bis einer `true` meldet. `_EatovaAppState`
  /// registriert sich in `initState` und liegt UEBER der `MaterialApp` — der
  /// Widget-Lebenszyklus garantiert damit, dass wir vor
  /// `_WidgetsAppState.initState` (app.dart:1464-1469) in der Liste stehen.
  /// `true` = „behandelt", die Zustellung endet hier: kein `pushNamed`, keine
  /// Exception, kein Frame, kein Eintrag im Navigationsstapel. Der Nutzer
  /// bleibt exakt da, wo er ist.
  ///
  /// Bewusst OHNE Filterung auf „unbekannt": adressierbar waere hoechstens
  /// `/`, und der zeigt bereits auf `home` — ein Push davon legte nur eine
  /// zweite Kopie der laufenden App auf den Stapel. Es gibt also keinen
  /// Routennamen, den eine fremde App sinnvoll schicken koennte.
  ///
  /// KEINE Auswirkung auf den echten OAuth-Rueckweg: der laeuft ueber den
  /// `app_links`-EventChannel in `SupabaseAuth._handleIncomingLinks` und das
  /// `detectSessionInUriPredicate` in `supabase_config.dart` — ein voellig
  /// anderer Kanal als `SystemChannels.navigation`. `eatova://login-callback/
  /// ?code=…` wird dort unveraendert ausgetauscht; hier faellt nur der
  /// sinnlose Routen-Nachhall desselben Intents weg.
  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) =>
      Future<bool>.value(true);

  @override
  Widget build(BuildContext context) {
    final repository = widget.authRepository ?? defaultAuthRepository();

    return LocaleScope(
      controller: _locale,
      child: ThemeModeScope(
        controller: _themeMode,
        child: ListenableBuilder(
          listenable: Listenable.merge([_themeMode, _locale]),
          builder: (context, _) => _buildApp(context, repository),
        ),
      ),
    );
  }

  Widget _buildApp(BuildContext context, AuthRepository repository) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Eatova',
      theme: buildEatovaTheme(Brightness.light),
      darkTheme: buildEatovaTheme(Brightness.dark),
      themeMode: _themeMode.mode,
      // Sprache: Override aus den Einstellungen; null = System, dann
      // entscheidet resolveEatovaLocale (deutsch -> de, sonst en). Der alte
      // Pin auf de stammte aus der Zeit ohne App-Lokalisierung.
      locale: _locale.override,
      supportedLocales: const [Locale('de'), Locale('en')],
      localeListResolutionCallback: (locales, supported) =>
          _locale.override ?? resolveEatovaLocale(locales),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      onGenerateTitle: (context) => 'Eatova',
      // A11y: System-Großschrift respektieren, aber deckeln. Cap bei 2.0
      // (WCAG 1.4.4 erwartet Lesbarkeit bis 200 %): die Kern-Screens (Auth,
      // Food-Tab) sind per Stress-Test (test/text_scale_stress_test.dart)
      // bei 2.0 overflow-frei; nur ungebremste Skalierung (iOS bis 235 %)
      // bleibt gedeckelt, weil feste Container (Kalorienring, Bottom-Nav)
      // jenseits von 2.0 zerbrechen.
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: mq.textScaler.clamp(maxScaleFactor: 2.0),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: AuthGate(
        authRepository: repository,
        builder: (context, user, freshLogin) => EatovaHomePage(
          // Key auf user.id pinnen: bei Sign-Out und neuem Login wird die
          // Page komplett neu erstellt (frischer State, eigene Sync-Instanz).
          key: ValueKey('home-${user.id}'),
          mealAnalyzer: widget.mealAnalyzer,
          productService: widget.productService,
          photoInput: widget.photoInput,
          mealCameraLauncher: widget.mealCameraLauncher,
          healthService: widget.healthService,
          notificationService:
              widget.notificationService ?? const NoopNotificationService(),
          initialUserName: user.firstName,
          userEmail: user.email,
          authRepository: repository,
          onSignOut: repository.signOut,
          sync: _syncFor(user.id),
          showWelcome: freshLogin,
        ),
      ),
    );
  }

  EatovaSync? _syncFor(String userId) => buildSyncForUser(userId);
}

/// Sentinel-Rest A2 (Sweep 2026-08-08): vorher fing der Fallback JEDEN
/// Fehler zu `null` — dem Zustand, der sonst „Test/Preview, bewusst ohne
/// Backend" bedeutet. Ein eingeloggter Nutzer lief damit still im
/// Datenlos-Modus (kein Cache, keine Outbox, jeder Log nur im RAM).
///
/// [allowPreview] haelt den gewollten Teil am Leben: In Debug/Test (Default
/// kDebugMode) pumpen die Flow-Tests `EatovaApp()` ohne Supabase und die
/// Home-Page laeuft mit Defaults. Im Release-/Profile-Build fliegt der
/// Fehler stattdessen — sichtbar via globale Handler + Sentry. Praktisch
/// unerreichbar: der builder laeuft nur mit echtem Nutzer, also nachdem
/// `Supabase.instance` im AuthRepository bereits funktioniert hat.
@visibleForTesting
EatovaSync? buildSyncForUser(String userId, {bool allowPreview = kDebugMode}) {
  try {
    return EatovaSync.forUser(Supabase.instance.client, userId);
  } catch (error, stack) {
    if (allowPreview) return null;
    unawaited(CrashReporter.capture(error, stack, context: 'sync-for-user'));
    Error.throwWithStackTrace(error, stack);
  }
}
