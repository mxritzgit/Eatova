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

  /// On-device notification layer (PROD-1). Real [LocalNotificationService]
  /// in production; null in tests/preview, where EatovaHomePage falls back to
  /// NoopNotificationService.
  final NotificationService? notificationService;

  /// Display mode (light/dark/system). Injectable so a test can pin a mode
  /// without staging SharedPreferences.
  final ThemeModeController? themeModeController;

  /// Display language (system/German/English). Injectable like
  /// [themeModeController], so a test can pin a language.
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
    // Deeplink route guard (Audit 2026-08-14): must register here, above the
    // MaterialApp — the observer order is the whole trick, see
    // [didPushRouteInformation].
    WidgetsBinding.instance.addObserver(this);
    _eigenerController = widget.themeModeController == null;
    _themeMode = widget.themeModeController ?? ThemeModeController();
    if (_eigenerController) {
      // The stored mode arrives asynchronously; until then system mode, which
      // is also the first-start default, so no visible jump.
      unawaited(_themeMode.load());
    }
    _eigenerLocale = widget.localeController == null;
    _locale = widget.localeController ?? LocaleController();
    if (_eigenerLocale) {
      // Same for the stored language: until it lands, null override ->
      // resolveEatovaLocale.
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

  /// Swallows every platform route push (Audit 2026-08-14).
  ///
  /// The BROWSABLE intent filter lets any app send `eatova://…`, which Android
  /// also replays as a route name. This app has no named routes, so the failed
  /// `pushNamed` would let an attacker flood Sentry remotely. `onUnknownRoute`
  /// can only redirect a push, not cancel it, so the guard sits above the
  /// Navigator: observers are asked in registration order and `true` ends
  /// delivery. The real OAuth return runs over `app_links` and is unaffected.
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
      // Override from settings; null = system, then resolveEatovaLocale
      // decides (German -> de, otherwise en).
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
      // A11y: honour system text scaling, capped at 2.0 (WCAG 1.4.4 asks for
      // 200 %). Fixed containers (calorie ring, bottom nav) break beyond that;
      // test/text_scale_stress_test.dart proves 2.0 is overflow-free.
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
          // Keying on user.id rebuilds the page on sign-out/new login:
          // fresh state, own sync instance.
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

/// Builds the sync layer for [userId], or null when preview is allowed.
///
/// [allowPreview] (debug/test) lets flow tests pump `EatovaApp()` without
/// Supabase. In release the error rethrows instead of silently degrading a
/// signed-in user to data-less mode (Sentinel A2, sweep 2026-08-08).
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
