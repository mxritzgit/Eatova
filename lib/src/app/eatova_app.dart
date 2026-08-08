import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_repository.dart';
import '../services/crash_reporter.dart';
import '../services/eatova_sync.dart';
import '../services/health_service.dart';
import '../services/meal_analyzer.dart';
import '../services/meal_camera_launcher.dart';
import '../services/meal_photo_input.dart';
import '../services/notification_service.dart';
import '../services/open_food_facts_product_service.dart';
import '../theme/app_theme.dart';
import 'auth_gate.dart';
import 'eatova_home_page.dart';

class EatovaApp extends StatelessWidget {
  const EatovaApp({
    super.key,
    this.mealAnalyzer,
    this.productService,
    this.photoInput,
    this.mealCameraLauncher,
    this.healthService,
    this.authRepository,
    this.notificationService,
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

  @override
  Widget build(BuildContext context) {
    final repository = authRepository ?? defaultAuthRepository();

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Eatova',
      theme: buildEatovaTheme(),
      // Deutsche Material-Lokalisierung: die App-Texte sind durchgehend
      // deutsch, aber SDK-Dialoge zogen bislang die englischen Defaults —
      // showTimePicker (Schlafziel im Settings-Sheet) rendert erst mit
      // de-Locale 24h (HH:mm) statt AM/PM, showDatePicker deutsche Monats-/
      // Wochentagsnamen. Locale fest auf de gepinnt (einzige supportedLocale),
      // damit das Verhalten nicht von der Geraete-Sprache abhaengt.
      locale: const Locale('de'),
      supportedLocales: const [Locale('de')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
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
          mealAnalyzer: mealAnalyzer,
          productService: productService,
          photoInput: photoInput,
          mealCameraLauncher: mealCameraLauncher,
          healthService: healthService,
          notificationService:
              notificationService ?? const NoopNotificationService(),
          initialUserName: user.firstName,
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
